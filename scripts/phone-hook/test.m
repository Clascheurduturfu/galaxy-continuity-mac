#define GCL_TESTING 1
#import "GalaxyContinuityPhoneHook.m"
#import <assert.h>

@interface MockHandle : NSObject
@property (copy) NSString *value;
@end
@implementation MockHandle
@end

@interface MockProvider : NSObject
@property (copy) NSString *identifier;
@property BOOL isTelephonyProvider;
@end
@implementation MockProvider
@end

@interface MockRelayCall : NSObject
@property (copy) NSString *uniqueProxyIdentifier;
@property (strong) MockHandle *handle;
@property (strong) MockProvider *provider;
@property BOOL isEmergency;
@property BOOL isSOS;
@property BOOL isVideo;
@property BOOL endpointOnCurrentDevice;
@property BOOL startedOutgoing;
@property BOOL sentInvitation;
@property BOOL connecting;
@property BOOL connected;
@property int disconnectedReason;
@property BOOL uplinkMuted;
@end
@implementation MockRelayCall
- (void)setLocallyHasStartedOutgoing { self.startedOutgoing = YES; }
- (void)setLocallyHasSentInvitation { self.sentInvitation = YES; }
- (void)setLocallyConnecting { self.connecting = YES; }
- (void)setLocallyConnected { self.connected = YES; }
- (void)setLocallyDisconnectedWithReasonIfNone:(int)reason { self.disconnectedReason = reason ?: 1; }
- (void)setUplinkMuted:(BOOL)muted userInitiated:(BOOL)ui { self.uplinkMuted = muted; }
@end

static NSInteger gTUHandleNormCalls = 0;
static NSString *gTUHandleLastISO = nil;

@interface TUHandle : NSObject
@property (nonatomic, assign) NSInteger type;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, copy) NSString *isoCountryCode;
+ (instancetype)normalizedPhoneNumberHandleForValue:(NSString *)value isoCountryCode:(NSString *)isoCountryCode;
- (instancetype)initWithType:(NSInteger)type value:(NSString *)value;
@end

@implementation TUHandle
+ (instancetype)normalizedPhoneNumberHandleForValue:(NSString *)value isoCountryCode:(NSString *)isoCountryCode {
    gTUHandleNormCalls++;
    gTUHandleLastISO = isoCountryCode ?: @"";
    if (!value.length) return nil;
    TUHandle *h = [TUHandle new];
    h.type = 2;
    h.value = value;
    if (isoCountryCode.length > 0) {
        h.isoCountryCode = [isoCountryCode lowercaseString];
    } else if ([value hasPrefix:@"+33"]) {
        h.isoCountryCode = @"fr";
    } else {
        h.isoCountryCode = @"";
    }
    return h;
}
- (instancetype)initWithType:(NSInteger)type value:(NSString *)value {
    self = [super init];
    if (self) {
        _type = type;
        _value = [value copy];
    }
    return self;
}
@end

@interface TUMutableCallDisplayContext : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *contactName;
@property (nonatomic, copy) NSString *suggestedName;
@end

@implementation TUMutableCallDisplayContext
@end

@interface CSDMessagingRelayMessage : NSObject
@property (nonatomic, assign) int type;
@property (nonatomic, copy) NSString *uniqueProxyIdentifier;
@property (nonatomic, strong) TUHandle *tuHandle;
@property (nonatomic, copy) NSSet *remoteParticipantTUHandles;
@property (nonatomic, copy) NSString *isoCountryCode;
@property (nonatomic, copy) NSString *callerNameFromNetwork;
@property (nonatomic, strong) TUMutableCallDisplayContext *displayContext;
- (instancetype)initWithType:(int)type uniqueProxyIdentifier:(NSString *)upi;
@end

@implementation CSDMessagingRelayMessage
- (instancetype)initWithType:(int)type uniqueProxyIdentifier:(NSString *)upi {
    self = [super init];
    if (self) {
        _type = type;
        _uniqueProxyIdentifier = [upi copy];
    }
    return self;
}
@end

@interface CSDRelayCall : NSObject
@property (nonatomic, strong) CSDMessagingRelayMessage *relayMessage;
@property (nonatomic, assign) BOOL outgoing;
@property (nonatomic, assign) BOOL endpointOnCurrentDevice;
@property (nonatomic, assign) BOOL locallyStartedOutgoing;
- (instancetype)initWithRelayMessage:(id)message outgoing:(BOOL)outgoing;
- (void)setLocallyHasStartedOutgoing;
@end

@implementation CSDRelayCall
- (instancetype)initWithRelayMessage:(id)message outgoing:(BOOL)outgoing {
    self = [super init];
    if (self) {
        _relayMessage = message;
        _outgoing = outgoing;
    }
    return self;
}
- (void)setLocallyHasStartedOutgoing {
    _locallyStartedOutgoing = YES;
}
@end

@interface MockStateController : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) id lastCallDelegates;
@property (nonatomic, strong) id lastPropertiesCall;
- (void)setCallDelegatesIfNeeded:(id)call;
- (void)propertiesChangedForCall:(id)call;
@end

@implementation MockStateController
- (void)setCallDelegatesIfNeeded:(id)call { _lastCallDelegates = call; }
- (void)propertiesChangedForCall:(id)call { _lastPropertiesCall = call; }
@end

static BOOL passthroughCalled = NO;
static void mockOrigDidDial(id self, SEL _cmd, id call) { passthroughCalled = YES; }
static BOOL messagingCallChangedPassthrough = NO;
static void mockOrigRelayMessagingHandleCallChanged(id self, SEL _cmd, id notification) { messagingCallChangedPassthrough = YES; }

static void writeFileJSON(NSString *name, NSDictionary *obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    int fd = GCLPhoneOpen(name, O_CREAT | O_WRONLY | O_TRUNC);
    assert(fd >= 0);
    assert(write(fd, d.bytes, d.length) == (ssize_t)d.length);
    close(fd);
}

int main(void) {
    @autoreleasepool {
        assert([NSFileManager.defaultManager createDirectoryAtPath:GCLPhoneDir()
                                       withIntermediateDirectories:YES
                                                        attributes:@{NSFilePosixPermissions: @0700}
                                                             error:NULL]);

        // 1. Emergency number guard must catch EU/US/FR emergency numbers even with formatting.
        assert(GCLIsEmergencyDigits(@"112"));
        assert(GCLIsEmergencyDigits(@"911"));
        assert(GCLIsEmergencyDigits(@"15"));
        assert(GCLIsEmergencyDigits(@"17"));
        assert(GCLIsEmergencyDigits(@"18"));
        assert(GCLIsEmergencyDigits(@"999"));
        assert(GCLIsEmergencyDigits(@" 112 "));
        assert(!GCLIsEmergencyDigits(@"+33612345678"));

        // 2. Crash-loop guard trips on the 4th rapid startup within 15s.
        assert(GCLPhoneCheckCrashGuardAndRecordStartup());
        assert(GCLPhoneCheckCrashGuardAndRecordStartup());
        assert(GCLPhoneCheckCrashGuardAndRecordStartup());
        assert(!GCLPhoneCheckCrashGuardAndRecordStartup());
        assert(GCLPhoneFileExists(@"disabled"));
        int dir = GCLPhoneDirectoryFD();
        unlinkat(dir, "disabled", 0);
        unlinkat(dir, "startups", 0);
        close(dir);

        // 3. Availability freshness + FaceTime & emergency pass-through vs telephony interception.
        int afd = GCLPhoneOpen(@"available", O_CREAT | O_WRONLY);
        assert(afd >= 0); futimes(afd, NULL); close(afd);
        writeFileJSON(@"status.json", @{@"deviceName": @"S26 Ultra"});
        assert(GCLPhoneAvailableFresh());

        gcl_orig_didDial = (IMP)mockOrigDidDial;

        MockProvider *ftProv = [MockProvider new];
        ftProv.identifier = @"com.apple.telephonyutilities.callservicesd.FaceTimeProvider";
        ftProv.isTelephonyProvider = NO;
        MockProvider *telProv = [MockProvider new];
        telProv.identifier = @"com.apple.coretelephony";
        telProv.isTelephonyProvider = YES;

        // FaceTime call -> passes through untouched
        MockRelayCall *ftCall = [MockRelayCall new];
        ftCall.uniqueProxyIdentifier = @"FT-1";
        ftCall.provider = ftProv;
        ftCall.handle = [MockHandle new]; ftCall.handle.value = @"+33612345678";
        passthroughCalled = NO;
        gcl_hook_didDial(nil, NULL, ftCall);
        assert(passthroughCalled && !ftCall.startedOutgoing);

        // Emergency call -> passes through untouched
        MockRelayCall *emCall = [MockRelayCall new];
        emCall.uniqueProxyIdentifier = @"EM-1";
        emCall.provider = telProv;
        emCall.handle = [MockHandle new]; emCall.handle.value = @"112";
        passthroughCalled = NO;
        gcl_hook_didDial(nil, NULL, emCall);
        assert(passthroughCalled && !emCall.startedOutgoing);

        // Normal telephony call -> intercepted, emits dial event, transitions states via app commands
        MockRelayCall *telCall = [MockRelayCall new];
        telCall.uniqueProxyIdentifier = @"TEL-1";
        telCall.provider = telProv;
        telCall.handle = [MockHandle new]; telCall.handle.value = @"+33 6 12 34 56 78";
        passthroughCalled = NO;
        gcl_hook_didDial(nil, NULL, telCall);
        assert(!passthroughCalled && telCall.startedOutgoing && telCall.endpointOnCurrentDevice);

        int efd = GCLPhoneOpen(@"daemon_events.jsonl", O_RDONLY);
        assert(efd >= 0);
        NSData *evData = [[[NSFileHandle alloc] initWithFileDescriptor:efd closeOnDealloc:YES] readDataToEndOfFile];
        NSString *evStr = [[NSString alloc] initWithData:evData encoding:NSUTF8StringEncoding];
        assert([evStr containsString:@"\"type\":\"dial\""] && [evStr containsString:@"\"+33612345678\""]);

        // Feed connected + mute + disconnected commands from app
        NSString *cmds = @"{\"session\":\"s1\",\"seq\":1,\"cmd\":\"ringing\",\"upi\":\"TEL-1\"}\n"
                         @"{\"session\":\"s1\",\"seq\":2,\"cmd\":\"connected\",\"upi\":\"TEL-1\"}\n"
                         @"{\"session\":\"s1\",\"seq\":3,\"cmd\":\"mute\",\"upi\":\"TEL-1\",\"muted\":true}\n"
                         @"{\"session\":\"s1\",\"seq\":4,\"cmd\":\"disconnected\",\"upi\":\"TEL-1\",\"reason\":2}\n";
        int cfd = GCLPhoneOpen(@"app_commands.jsonl", O_CREAT | O_WRONLY | O_TRUNC);
        assert(cfd >= 0);
        NSData *cmdBytes = [cmds dataUsingEncoding:NSUTF8StringEncoding];
        assert(write(cfd, cmdBytes.bytes, cmdBytes.length) == (ssize_t)cmdBytes.length);
        close(cfd);

        GCLPollAppCommands();
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        assert(telCall.sentInvitation && telCall.connected && telCall.uplinkMuted && telCall.disconnectedReason == 2);

        // 4. CSDRelayMessagingController._handleCallChanged: suppression for pending/tracked incoming calls vs unmanaged calls
        gcl_orig_relayMessagingHandleCallChanged = (IMP)mockOrigRelayMessagingHandleCallChanged;
        MockRelayCall *incomingCall = [MockRelayCall new];
        incomingCall.uniqueProxyIdentifier = @"IN-1";
        GCLBeginPendingIncoming(@"IN-1");
        NSNotification *inNotif = [NSNotification notificationWithName:@"TUCallCenterCallStatusChangedInternalNotification" object:incomingCall];
        messagingCallChangedPassthrough = NO;
        gcl_hook_relayMessagingHandleCallChanged(nil, NULL, inNotif);
        assert(!messagingCallChangedPassthrough);

        GCLTrackCall(@"IN-1", incomingCall);
        GCLEndPendingIncoming(@"IN-1");
        messagingCallChangedPassthrough = NO;
        gcl_hook_relayMessagingHandleCallChanged(nil, NULL, inNotif);
        assert(!messagingCallChangedPassthrough);

        MockRelayCall *otherRelayCall = [MockRelayCall new];
        otherRelayCall.uniqueProxyIdentifier = @"OTHER-1";
        NSNotification *otherNotif = [NSNotification notificationWithName:@"TUCallCenterCallStatusChangedInternalNotification" object:otherRelayCall];
        messagingCallChangedPassthrough = NO;
        gcl_hook_relayMessagingHandleCallChanged(nil, NULL, otherNotif);
        assert(messagingCallChangedPassthrough);
        GCLUntrackCall(@"IN-1");

        // Verify GCLBuildRelayMessage populates remoteParticipantTUHandles, isoCountryCode, and displayContext.
        gTUHandleNormCalls = 0;
        gTUHandleLastISO = nil;
        CSDMessagingRelayMessage *e164Msg = (CSDMessagingRelayMessage *)GCLBuildRelayMessage(@"UPI-E164", @"+33612345678", @"Alice Example", 1);
        assert(e164Msg != nil);
        assert(gTUHandleNormCalls == 1);
        assert([gTUHandleLastISO isEqualToString:@""]);
        assert(e164Msg.tuHandle != nil);
        assert([e164Msg.tuHandle.value isEqualToString:@"+33612345678"]);
        assert(e164Msg.remoteParticipantTUHandles.count == 1);
        assert([e164Msg.remoteParticipantTUHandles containsObject:e164Msg.tuHandle]);
        assert([e164Msg.isoCountryCode isEqualToString:@"fr"]);
        assert([e164Msg.callerNameFromNetwork isEqualToString:@"Alice Example"]);
        assert(e164Msg.displayContext != nil);
        assert([e164Msg.displayContext.name isEqualToString:@"Alice Example"]);
        assert([e164Msg.displayContext.contactName isEqualToString:@"Alice Example"]);
        assert([e164Msg.displayContext.suggestedName isEqualToString:@"Alice Example"]);

        // National number passes locale fallback ISO (not forced empty) and omits displayContext when callerName is empty.
        gTUHandleNormCalls = 0;
        CSDMessagingRelayMessage *natMsg = (CSDMessagingRelayMessage *)GCLBuildRelayMessage(@"UPI-NAT", @"0612345678", @"", 1);
        assert(natMsg != nil);
        assert(gTUHandleNormCalls == 1);
        assert(natMsg.tuHandle != nil);
        assert(natMsg.remoteParticipantTUHandles.count == 1);
        assert([natMsg.remoteParticipantTUHandles containsObject:natMsg.tuHandle]);
        assert(natMsg.displayContext == nil);

        // Verify outgoing_mirror propagates callerName through GCLBuildRelayMessage into CSDRelayCall.
        MockStateController *sc = [MockStateController new];
        sc.queue = dispatch_queue_create("gcl.phone.test", DISPATCH_QUEUE_SERIAL);
        id prevSC = gcl_stateController;
        gcl_stateController = sc;
        GCLHandleAppCommand(@{
            @"cmd": @"outgoing_mirror",
            @"upi": @"UPI-OUT-1",
            @"number": @"+33612345678",
            @"callerName": @"Bob Mirror"
        });
        dispatch_sync(sc.queue, ^{});
        CSDRelayCall *mirrored = (CSDRelayCall *)GCLTrackedCall(@"UPI-OUT-1");
        assert(mirrored != nil);
        assert(mirrored.outgoing == YES);
        assert(mirrored.endpointOnCurrentDevice == YES);
        assert(mirrored.locallyStartedOutgoing == YES);
        assert(mirrored.relayMessage != nil);
        assert(mirrored.relayMessage.type == 2);
        assert(mirrored.relayMessage.remoteParticipantTUHandles.count == 1);
        assert([mirrored.relayMessage.isoCountryCode isEqualToString:@"fr"]);
        assert([mirrored.relayMessage.callerNameFromNetwork isEqualToString:@"Bob Mirror"]);
        assert([mirrored.relayMessage.displayContext.name isEqualToString:@"Bob Mirror"]);
        assert([mirrored.relayMessage.displayContext.contactName isEqualToString:@"Bob Mirror"]);
        assert([mirrored.relayMessage.displayContext.suggestedName isEqualToString:@"Bob Mirror"]);
        GCLUntrackCall(@"UPI-OUT-1");
        gcl_stateController = prevSC;

        assert([NSFileManager.defaultManager removeItemAtPath:GCLPhoneDir() error:NULL]);
        puts("Phone hook tests passed: emergency guard, crash-loop breaker, FaceTime passthrough, dial/state sync, incoming session guard.");
    }
    return 0;
}
