// GalaxyContinuityPhoneHook.m — v1
//
// Bridges native macOS Phone.app (and system-wide tel: / Contacts / FaceTime
// telephony relay) to Galaxy Continuity's Samsung CMC CallingController by
// hooking callservicesd's relay seams when SIP is disabled.
//
// Safety invariants:
// 1. Only activates inside `callservicesd` (or unit tests with GCL_TESTING).
// 2. Crash-loop breaker: if callservicesd restarts >= 4 times within 15 s, or
//    if `/tmp/gcl-phone-app/disabled` exists, the constructor aborts before
//    swizzling any Objective-C method.
// 3. Live availability gate: relay capabilities and call interception only
//    apply while `/tmp/gcl-phone-app/available` is fresh (<= 15 s), touched by
//    Galaxy Continuity while Samsung CMC calling is registered.
// 4. FaceTime & emergency pass-through: non-telephony providers (FaceTime
//    audio/video) and all emergency/SOS numbers always pass untouched to
//    Apple's original implementations.
//
// IPC directory `/tmp/gcl-phone-app` (mode 0700, owner-only, O_NOFOLLOW):
//   available            app -> hook: touched every 5 s while CMC is registered
//   disabled             hook/app: kill-switch flag
//   startups             hook: recent constructor timestamps (crash-loop guard)
//   status.json          app -> hook: {"deviceName": "S26 Ultra"}
//   app_commands.jsonl   app -> hook: {"session","seq","cmd","upi",...}
//   daemon_events.jsonl  hook -> app: {"seq","type","upi",...}
//   hook.log             hook: bounded diagnostics (no raw phone numbers logged)

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/file.h>
#import <time.h>
#import <unistd.h>
#import <fcntl.h>

#pragma mark - Hardened IPC helpers

static NSString *GCLPhoneDir(void) {
#ifdef GCL_TESTING
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [NSFileManager.defaultManager.currentDirectoryPath
            stringByAppendingPathComponent:[NSString stringWithFormat:@".build/phone-hook-fixture-%d", getpid()]];
    });
    return dir;
#else
    return @"/tmp/gcl-phone-app";
#endif
}

static int GCLPhoneDirectoryFD(void) {
    int fd = open(GCLPhoneDir().fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (fd >= 0 && (fstat(fd, &info) || info.st_uid != getuid() || (info.st_mode & 077) != 0)) {
        close(fd);
        return -1;
    }
    return fd;
}

static int GCLPhoneOpen(NSString *name, int flags) {
    int directory = GCLPhoneDirectoryFD();
    if (directory < 0) return -1;
    int fd = openat(directory, name.fileSystemRepresentation, flags | O_NOFOLLOW | O_CLOEXEC, 0600);
    close(directory);
    struct stat info;
    if (fd >= 0 && (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1 || (info.st_mode & 077) != 0)) {
        close(fd);
        return -1;
    }
    return fd;
}

static BOOL GCLPhoneFileExists(NSString *name) {
    int fd = GCLPhoneOpen(name, O_RDONLY);
    if (fd < 0) return NO;
    close(fd);
    return YES;
}

static void GCLPhoneLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", NSProcessInfo.processInfo.processName, message];
    int fd = GCLPhoneOpen(@"hook.log", O_WRONLY | O_APPEND | O_CREAT);
    if (fd >= 0) {
        struct stat info;
        if (!fstat(fd, &info) && info.st_size < 262144) {
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            (void)write(fd, data.bytes, data.length);
        }
        close(fd);
    }
}

static BOOL GCLPhoneCheckCrashGuardAndRecordStartup(void) {
    if (GCLPhoneFileExists(@"disabled")) return NO;
    int fd = GCLPhoneOpen(@"startups", O_CREAT | O_RDWR);
    if (fd < 0) return NO;
    if (flock(fd, LOCK_EX) != 0) { close(fd); return NO; }
    char buf[512] = {0};
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    time_t now = time(NULL);
    NSMutableArray<NSNumber *> *recent = [NSMutableArray array];
    if (n > 0) {
        NSString *text = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding];
        for (NSString *part in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
            long long ts = part.longLongValue;
            if (ts > 0 && now >= ts && (now - ts) <= 15) {
                [recent addObject:@(ts)];
            }
        }
    }
    [recent addObject:@((long long)now)];
    NSMutableString *out = [NSMutableString string];
    for (NSNumber *num in recent) [out appendFormat:@"%lld\n", num.longLongValue];
    NSData *outData = [out dataUsingEncoding:NSUTF8StringEncoding];
    (void)ftruncate(fd, 0);
    (void)lseek(fd, 0, SEEK_SET);
    (void)write(fd, outData.bytes, outData.length);
    flock(fd, LOCK_UN);
    close(fd);
    if (recent.count >= 4) {
        int dfd = GCLPhoneOpen(@"disabled", O_CREAT | O_WRONLY | O_TRUNC);
        if (dfd >= 0) close(dfd);
        GCLPhoneLog(@"crash-loop guard tripped (%lu starts in 15s) — disabling hook", (unsigned long)recent.count);
        return NO;
    }
    return YES;
}

static BOOL GCLPhoneAvailableFresh(void) {
    if (GCLPhoneFileExists(@"disabled")) return NO;
    int fd = GCLPhoneOpen(@"available", O_RDONLY);
    if (fd < 0) return NO;
    struct stat info;
    time_t now = time(NULL);
    BOOL valid = !fstat(fd, &info) && now >= info.st_mtime && (now - info.st_mtime) <= 15;
    close(fd);
    return valid;
}

static NSDictionary *GCLPhoneReadJSON(NSString *name) {
    int fd = GCLPhoneOpen(name, O_RDONLY);
    if (fd < 0) return nil;
    struct stat info;
    if (fstat(fd, &info) || info.st_size == 0 || info.st_size > 65536) { close(fd); return nil; }
    NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static uint64_t gcl_eventSeq = 0;

static void GCLPhoneEmitEvent(NSDictionary *fields) {
    int fd = GCLPhoneOpen(@"daemon_events.jsonl", O_CREAT | O_WRONLY | O_APPEND);
    if (fd < 0) return;
    if (flock(fd, LOCK_EX) == 0) {
        struct stat info;
        if (!fstat(fd, &info) && info.st_size > 262144) {
            (void)ftruncate(fd, 0);
        }
        NSMutableDictionary *payload = [fields mutableCopy];
        payload[@"seq"] = @(++gcl_eventSeq);
        payload[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
        NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
        if (json) {
            (void)write(fd, json.bytes, json.length);
            (void)write(fd, "\n", 1);
        }
        flock(fd, LOCK_UN);
    }
    close(fd);
}

#pragma mark - Emergency & telephony guards

static NSString *GCLSanitizeDialDigits(NSString *raw) {
    if (![raw isKindOfClass:NSString.class]) return @"";
    NSMutableString *clean = [NSMutableString stringWithCapacity:raw.length];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= '0' && c <= '9') || c == '+' || c == '*' || c == '#') {
            [clean appendFormat:@"%C", c];
        }
    }
    return clean;
}

static BOOL GCLIsEmergencyDigits(NSString *raw) {
    NSString *digits = GCLSanitizeDialDigits(raw);
    if (digits.length == 0) return NO;
    static NSSet<NSString *> *emergencySet;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        emergencySet = [NSSet setWithArray:@[
            @"112", @"911", @"999", @"000", @"110", @"111", @"118", @"119",
            @"15", @"17", @"18", @"114", @"115", @"191", @"196", @"197",
            @"*911", @"#911", @"+112", @"+911"
        ]];
    });
    return [emergencySet containsObject:digits];
}

static NSString *GCLExtractHandleValue(id handleObj) {
    if (!handleObj) return @"";
    SEL valSel = NSSelectorFromString(@"value");
    if ([handleObj respondsToSelector:valSel]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(handleObj, valSel);
        if ([v isKindOfClass:NSString.class]) return v;
    }
    return @"";
}

static BOOL GCLIsTelephonyProvider(id provider) {
    if (!provider) return NO;
    SEL isTel = NSSelectorFromString(@"isTelephonyProvider");
    if ([provider respondsToSelector:isTel]) {
        if (((BOOL (*)(id, SEL))objc_msgSend)(provider, isTel)) return YES;
    }
    SEL idSel = NSSelectorFromString(@"identifier");
    if ([provider respondsToSelector:idSel]) {
        id ident = ((id (*)(id, SEL))objc_msgSend)(provider, idSel);
        if ([ident isKindOfClass:NSString.class] && [ident isEqualToString:@"com.apple.coretelephony"]) return YES;
    }
    return NO;
}

static BOOL GCLIsEmergencyDialRequest(id request) {
    if (!request) return NO;
    SEL isSOS = NSSelectorFromString(@"isSOS");
    if ([request respondsToSelector:isSOS] && ((BOOL (*)(id, SEL))objc_msgSend)(request, isSOS)) return YES;
    SEL dialType = NSSelectorFromString(@"dialType");
    if ([request respondsToSelector:dialType]) {
        NSInteger dt = ((NSInteger (*)(id, SEL))objc_msgSend)(request, dialType);
        if (dt == 1 || dt == 2) return YES; // Emergency / EmergencyCallback
    }
    SEL handleSel = NSSelectorFromString(@"handle");
    if ([request respondsToSelector:handleSel]) {
        id h = ((id (*)(id, SEL))objc_msgSend)(request, handleSel);
        if (GCLIsEmergencyDigits(GCLExtractHandleValue(h))) return YES;
    }
    return NO;
}

static BOOL GCLIsEmergencyCall(id call) {
    if (!call) return NO;
    for (NSString *selName in @[@"isEmergency", @"isSOS"]) {
        SEL s = NSSelectorFromString(selName);
        if ([call respondsToSelector:s] && ((BOOL (*)(id, SEL))objc_msgSend)(call, s)) return YES;
    }
    SEL handleSel = NSSelectorFromString(@"handle");
    if ([call respondsToSelector:handleSel]) {
        id h = ((id (*)(id, SEL))objc_msgSend)(call, handleSel);
        if (GCLIsEmergencyDigits(GCLExtractHandleValue(h))) return YES;
    }
    return NO;
}

static BOOL GCLIsRelayTelephonyCall(id call) {
    if (!call) return NO;
    SEL isVid = NSSelectorFromString(@"isVideo");
    if ([call respondsToSelector:isVid] && ((BOOL (*)(id, SEL))objc_msgSend)(call, isVid)) return NO;
    for (NSString *selName in @[@"provider", @"localProvider"]) {
        SEL s = NSSelectorFromString(selName);
        if ([call respondsToSelector:s]) {
            id prov = ((id (*)(id, SEL))objc_msgSend)(call, s);
            if (GCLIsTelephonyProvider(prov)) return YES;
        }
    }
    return NO;
}

#pragma mark - State tracking

static __weak id gcl_stateController;
static __weak id gcl_relayClient;
static NSMapTable<NSString *, id> *gcl_trackedCalls;
static NSMutableSet<NSString *> *gcl_mirroredOutgoingUPIs;
static NSMutableSet<NSString *> *gcl_pendingIncomingUPIs;
static NSLock *gcl_callsLock;
static BOOL gcl_suppressDisconnectEcho = NO;
static BOOL gcl_suppressMuteEcho = NO;

static void GCLBeginPendingIncoming(NSString *upi) {
    if (!upi.length) return;
    [gcl_callsLock lock];
    if (!gcl_pendingIncomingUPIs) gcl_pendingIncomingUPIs = [NSMutableSet set];
    [gcl_pendingIncomingUPIs addObject:upi];
    [gcl_callsLock unlock];
}

static void GCLEndPendingIncoming(NSString *upi) {
    if (!upi.length) return;
    [gcl_callsLock lock];
    [gcl_pendingIncomingUPIs removeObject:upi];
    [gcl_callsLock unlock];
}

static void GCLTrackCall(NSString *upi, id call) {
    if (!upi.length || !call) return;
    [gcl_callsLock lock];
    if (!gcl_trackedCalls) gcl_trackedCalls = [NSMapTable strongToWeakObjectsMapTable];
    [gcl_trackedCalls setObject:call forKey:upi];
    [gcl_callsLock unlock];
}

static id GCLTrackedCall(NSString *upi) {
    if (!upi.length) return nil;
    [gcl_callsLock lock];
    id call = [gcl_trackedCalls objectForKey:upi];
    [gcl_callsLock unlock];
    if (!call) {
        id rc = gcl_relayClient;
        SEL sel = NSSelectorFromString(@"callWithUniqueProxyIdentifier:");
        if (rc && [rc respondsToSelector:sel]) {
            call = ((id (*)(id, SEL, id))objc_msgSend)(rc, sel, upi);
        }
    }
    return call;
}

static BOOL GCLIsManagedRelayCallUPI(NSString *upi) {
    if (!upi.length) return NO;
    [gcl_callsLock lock];
    BOOL pending = [gcl_pendingIncomingUPIs containsObject:upi];
    id tracked = [gcl_trackedCalls objectForKey:upi];
    [gcl_callsLock unlock];
    return pending || tracked != nil;
}

static void GCLUntrackCall(NSString *upi) {
    if (!upi.length) return;
    [gcl_callsLock lock];
    [gcl_trackedCalls removeObjectForKey:upi];
    [gcl_mirroredOutgoingUPIs removeObject:upi];
    [gcl_pendingIncomingUPIs removeObject:upi];
    [gcl_callsLock unlock];
}

static NSString *GCLCallUPI(id call) {
    SEL sel = NSSelectorFromString(@"uniqueProxyIdentifier");
    if (call && [call respondsToSelector:sel]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(call, sel);
        if ([v isKindOfClass:NSString.class]) return v;
    }
    return nil;
}

static dispatch_queue_t GCLObjectQueue(id obj) {
    SEL qSel = NSSelectorFromString(@"queue");
    if (obj && [obj respondsToSelector:qSel]) {
        id q = ((id (*)(id, SEL))objc_msgSend)(obj, qSel);
        if (q) return (dispatch_queue_t)q;
    }
    return dispatch_get_main_queue();
}

static void GCLNotifyPropertiesChanged(id call) {
    id sc = gcl_stateController;
    SEL sel = NSSelectorFromString(@"propertiesChangedForCall:");
    if (sc && call && [sc respondsToSelector:sel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(sc, sel, call);
    }
}

#pragma mark - Swizzle helper

#define GCL_MAYBE_UNUSED __attribute__((unused))

GCL_MAYBE_UNUSED static void GCLPhoneSwap(Class cls, SEL selector, IMP implementation, IMP *original) {
    if (!cls || !selector) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        GCLPhoneLog(@"missing method -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(selector));
        return;
    }
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, implementation, method_getTypeEncoding(method))) {
        method_setImplementation(method, implementation);
    }
    GCLPhoneLog(@"hooked -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(selector));
}

#pragma mark - Capability hooks

static IMP gcl_orig_updateRelayCapabilities;
GCL_MAYBE_UNUSED static void gcl_hook_updateRelayCapabilities(id self, SEL _cmd) {
    if (gcl_orig_updateRelayCapabilities) {
        ((void (*)(id, SEL))gcl_orig_updateRelayCapabilities)(self, _cmd);
    }
    if (!GCLPhoneAvailableFresh()) return;
    SEL stateSel = NSSelectorFromString(@"state");
    if (![self respondsToSelector:stateSel]) return;
    id st = ((id (*)(id, SEL))objc_msgSend)(self, stateSel);
    if (!st) return;

    NSDictionary *status = GCLPhoneReadJSON(@"status.json");
    NSString *deviceName = [status[@"deviceName"] isKindOfClass:NSString.class] && [status[@"deviceName"] length] > 0
        ? status[@"deviceName"] : @"Galaxy Phone";

    Class ccdCls = NSClassFromString(@"TUCloudCallingDevice");
    if (ccdCls) {
        id dev = [[ccdCls alloc] init];
        if (dev) {
            if ([dev respondsToSelector:NSSelectorFromString(@"setName:")])
                ((void (*)(id, SEL, id))objc_msgSend)(dev, NSSelectorFromString(@"setName:"), deviceName);
            if ([dev respondsToSelector:NSSelectorFromString(@"setModelIdentifier:")])
                ((void (*)(id, SEL, id))objc_msgSend)(dev, NSSelectorFromString(@"setModelIdentifier:"), @"iPhone17,2");
            if ([dev respondsToSelector:NSSelectorFromString(@"setUniqueID:")])
                ((void (*)(id, SEL, id))objc_msgSend)(dev, NSSelectorFromString(@"setUniqueID:"), @"GCL-GALAXY-RELAY-HOST");
            if ([dev respondsToSelector:NSSelectorFromString(@"setDefaultPairedDevice:")])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(dev, NSSelectorFromString(@"setDefaultPairedDevice:"), YES);
            if ([st respondsToSelector:NSSelectorFromString(@"setCloudCallingDevices:")])
                ((void (*)(id, SEL, id))objc_msgSend)(st, NSSelectorFromString(@"setCloudCallingDevices:"), @[dev]);
        }
    }

    for (NSString *boolSetter in @[
        @"setSupportsRelayCalling:",
        @"setRelayCallingEnabled:",
        @"setRelayCallingFeaturesEnabled:",
        @"setSupportsTelephonyRelayCalling:",
        @"setAccountsMatchForSecondaryCalling:",
        @"setAccountsSupportSecondaryCalling:"
    ]) {
        SEL s = NSSelectorFromString(boolSetter);
        if ([st respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(st, s, YES);
    }
    SEL availSel = NSSelectorFromString(@"setRelayCallingAvailability:");
    if ([st respondsToSelector:availSel]) ((void (*)(id, SEL, int))objc_msgSend)(st, availSel, 2);
}

static void GCLRefreshDaemonCapabilities(void) {
    Class capCls = NSClassFromString(@"CSDCallCapabilities");
    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if (!capCls || ![capCls respondsToSelector:sharedSel]) return;
    id cap = ((id (*)(id, SEL))objc_msgSend)(capCls, sharedSel);
    if (!cap) return;
    dispatch_queue_t q = GCLObjectQueue(cap);
    dispatch_async(q, ^{
        SEL upd = NSSelectorFromString(@"updateState");
        if ([cap respondsToSelector:upd]) {
            ((void (*)(id, SEL))objc_msgSend)(cap, upd);
            GCLPhoneLog(@"refreshed CSDCallCapabilities (available=%d)", GCLPhoneAvailableFresh());
        }
    });
}

#pragma mark - Singleton capture & outgoing request routing

static IMP gcl_orig_scInit;
GCL_MAYBE_UNUSED static id gcl_hook_scInit(id self, SEL _cmd, id q, id ch, id ff, id ds, id nc) {
    id res = gcl_orig_scInit ? ((id (*)(id, SEL, id, id, id, id, id))gcl_orig_scInit)(self, _cmd, q, ch, ff, ds, nc) : self;
    gcl_stateController = res;
    return res;
}

static IMP gcl_orig_rcInit2, gcl_orig_rcInit1;
GCL_MAYBE_UNUSED static id gcl_hook_rcInit2(id self, SEL _cmd, id q, id ff) {
    id res = gcl_orig_rcInit2 ? ((id (*)(id, SEL, id, id))gcl_orig_rcInit2)(self, _cmd, q, ff) : self;
    gcl_relayClient = res;
    return res;
}
GCL_MAYBE_UNUSED static id gcl_hook_rcInit1(id self, SEL _cmd, id q) {
    id res = gcl_orig_rcInit1 ? ((id (*)(id, SEL, id))gcl_orig_rcInit1)(self, _cmd, q) : self;
    gcl_relayClient = res;
    return res;
}

static IMP gcl_orig_outgoingFromDial;
GCL_MAYBE_UNUSED static id gcl_hook_outgoingFromDial(id self, SEL _cmd, id request) {
    gcl_stateController = self;
    if (request && GCLPhoneAvailableFresh() && !GCLIsEmergencyDialRequest(request)) {
        SEL isVid = NSSelectorFromString(@"isVideo");
        BOOL video = [request respondsToSelector:isVid] && ((BOOL (*)(id, SEL))objc_msgSend)(request, isVid);
        SEL provSel = NSSelectorFromString(@"provider");
        id prov = [request respondsToSelector:provSel] ? ((id (*)(id, SEL))objc_msgSend)(request, provSel) : nil;
        if (!video && GCLIsTelephonyProvider(prov)) {
            SEL setHost = NSSelectorFromString(@"setHostOnCurrentDevice:");
            SEL setEnd = NSSelectorFromString(@"setEndpointOnCurrentDevice:");
            if ([request respondsToSelector:setHost]) ((void (*)(id, SEL, BOOL))objc_msgSend)(request, setHost, NO);
            if ([request respondsToSelector:setEnd]) ((void (*)(id, SEL, BOOL))objc_msgSend)(request, setEnd, YES);
        }
    }
    return gcl_orig_outgoingFromDial ? ((id (*)(id, SEL, id))gcl_orig_outgoingFromDial)(self, _cmd, request) : nil;
}

#pragma mark - CSDRelayCallDelegate hooks

static IMP gcl_orig_didDial;
static void gcl_hook_didDial(id self, SEL _cmd, id call) {
    SEL scSel = NSSelectorFromString(@"callStateController");
    if ([self respondsToSelector:scSel]) {
        id sc = ((id (*)(id, SEL))objc_msgSend)(self, scSel);
        if (sc) gcl_stateController = sc;
    }
    if (!GCLPhoneAvailableFresh() || !GCLIsRelayTelephonyCall(call) || GCLIsEmergencyCall(call)) {
        if (GCLIsEmergencyCall(call)) GCLPhoneLog(@"emergency call bypassed hook");
        if (gcl_orig_didDial) ((void (*)(id, SEL, id))gcl_orig_didDial)(self, _cmd, call);
        return;
    }
    NSString *upi = GCLCallUPI(call);
    SEL handleSel = NSSelectorFromString(@"handle");
    id handle = [call respondsToSelector:handleSel] ? ((id (*)(id, SEL))objc_msgSend)(call, handleSel) : nil;
    NSString *digits = GCLSanitizeDialDigits(GCLExtractHandleValue(handle));
    if (!upi.length || !digits.length) {
        if (gcl_orig_didDial) ((void (*)(id, SEL, id))gcl_orig_didDial)(self, _cmd, call);
        return;
    }
    GCLTrackCall(upi, call);
    if ([call respondsToSelector:NSSelectorFromString(@"setEndpointOnCurrentDevice:")])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(call, NSSelectorFromString(@"setEndpointOnCurrentDevice:"), YES);
    if ([call respondsToSelector:NSSelectorFromString(@"setLocallyHasStartedOutgoing")])
        ((void (*)(id, SEL))objc_msgSend)(call, NSSelectorFromString(@"setLocallyHasStartedOutgoing"));
    GCLNotifyPropertiesChanged(call);

    [gcl_callsLock lock];
    BOOL mirrored = [gcl_mirroredOutgoingUPIs containsObject:upi];
    [gcl_callsLock unlock];
    if (!mirrored) {
        GCLPhoneLog(@"intercepted outgoing dial upi=%@ len=%lu", upi, (unsigned long)digits.length);
        GCLPhoneEmitEvent(@{@"type": @"dial", @"upi": upi, @"number": digits});
    }
}

static IMP gcl_orig_didAnswer;
GCL_MAYBE_UNUSED static void gcl_hook_didAnswer(id self, SEL _cmd, id call, id request) {
    NSString *upi = GCLCallUPI(call);
    if (!upi.length || !GCLTrackedCall(upi)) {
        if (gcl_orig_didAnswer) ((void (*)(id, SEL, id, id))gcl_orig_didAnswer)(self, _cmd, call, request);
        return;
    }
    if ([call respondsToSelector:NSSelectorFromString(@"setEndpointOnCurrentDevice:")])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(call, NSSelectorFromString(@"setEndpointOnCurrentDevice:"), YES);
    if ([call respondsToSelector:NSSelectorFromString(@"setLocallyConnecting")])
        ((void (*)(id, SEL))objc_msgSend)(call, NSSelectorFromString(@"setLocallyConnecting"));
    GCLNotifyPropertiesChanged(call);
    GCLPhoneLog(@"intercepted answer upi=%@", upi);
    GCLPhoneEmitEvent(@{@"type": @"answer", @"upi": upi});
}

static IMP gcl_orig_didDisconnect;
GCL_MAYBE_UNUSED static void gcl_hook_didDisconnect(id self, SEL _cmd, id call) {
    NSString *upi = GCLCallUPI(call);
    if (!upi.length || (!GCLTrackedCall(upi) && !gcl_suppressDisconnectEcho)) {
        if (gcl_orig_didDisconnect) ((void (*)(id, SEL, id))gcl_orig_didDisconnect)(self, _cmd, call);
        return;
    }
    GCLUntrackCall(upi);
    if (!gcl_suppressDisconnectEcho) {
        GCLPhoneLog(@"intercepted local disconnect upi=%@", upi);
        GCLPhoneEmitEvent(@{@"type": @"disconnect", @"upi": upi});
    }
}

static IMP gcl_orig_didHold, gcl_orig_didUnhold;
GCL_MAYBE_UNUSED static void gcl_hook_didHold(id self, SEL _cmd, id call) {
    NSString *upi = GCLCallUPI(call);
    if (!upi.length || !GCLTrackedCall(upi)) {
        if (gcl_orig_didHold) ((void (*)(id, SEL, id))gcl_orig_didHold)(self, _cmd, call);
        return;
    }
    GCLPhoneEmitEvent(@{@"type": @"hold", @"upi": upi, @"held": @YES});
}
GCL_MAYBE_UNUSED static void gcl_hook_didUnhold(id self, SEL _cmd, id call) {
    NSString *upi = GCLCallUPI(call);
    if (!upi.length || !GCLTrackedCall(upi)) {
        if (gcl_orig_didUnhold) ((void (*)(id, SEL, id))gcl_orig_didUnhold)(self, _cmd, call);
        return;
    }
    GCLPhoneEmitEvent(@{@"type": @"hold", @"upi": upi, @"held": @NO});
}

static IMP gcl_orig_didDTMF;
GCL_MAYBE_UNUSED static void gcl_hook_didDTMF(id self, SEL _cmd, id call, unsigned char key) {
    NSString *upi = GCLCallUPI(call);
    if (!upi.length || !GCLTrackedCall(upi)) {
        if (gcl_orig_didDTMF) ((void (*)(id, SEL, id, unsigned char))gcl_orig_didDTMF)(self, _cmd, call, key);
        return;
    }
    SEL playerSel = NSSelectorFromString(@"dtmfSoundPlayer");
    SEL playSel = NSSelectorFromString(@"attemptToPlayKey:");
    if ([self respondsToSelector:playerSel]) {
        id player = ((id (*)(id, SEL))objc_msgSend)(self, playerSel);
        if (player && [player respondsToSelector:playSel]) {
            ((void (*)(id, SEL, unsigned char))objc_msgSend)(player, playSel, key);
        }
    }
    if (key >= 32 && key < 127) {
        NSString *digit = [NSString stringWithFormat:@"%c", (char)key];
        GCLPhoneEmitEvent(@{@"type": @"dtmf", @"upi": upi, @"digit": digit});
    }
}

static IMP gcl_orig_didMute;
GCL_MAYBE_UNUSED static void gcl_hook_didMute(id self, SEL _cmd, id call, BOOL muted) {
    NSString *upi = GCLCallUPI(call);
    if (!upi.length || !GCLTrackedCall(upi)) {
        if (gcl_orig_didMute) ((void (*)(id, SEL, id, BOOL))gcl_orig_didMute)(self, _cmd, call, muted);
        return;
    }
    if (!gcl_suppressMuteEcho) {
        GCLPhoneEmitEvent(@{@"type": @"mute", @"upi": upi, @"muted": @(muted)});
    }
}

static IMP gcl_orig_relayMessagingHandleCallChanged;
GCL_MAYBE_UNUSED static void gcl_hook_relayMessagingHandleCallChanged(id self, SEL _cmd, id notification) {
    SEL objSel = NSSelectorFromString(@"object");
    id call = (notification && [notification respondsToSelector:objSel])
        ? ((id (*)(id, SEL))objc_msgSend)(notification, objSel)
        : nil;
    NSString *upi = GCLCallUPI(call);
    if (upi.length && GCLIsManagedRelayCallUPI(upi)) {
        // CSDRelayMessagingController auto-terminates incoming relay calls lacking an IDS relay session;
        // Galaxy Continuity manages the SIP/TLS signaling session externally.
        return;
    }
    if (gcl_orig_relayMessagingHandleCallChanged) {
        ((void (*)(id, SEL, id))gcl_orig_relayMessagingHandleCallChanged)(self, _cmd, notification);
    }
}

#pragma mark - Synthesizing Incoming / Mirrored Calls & State Transitions

static id GCLBuildRelayMessage(NSString *upi, NSString *number, NSString *callerName, int msgType) {
    Class msgCls = NSClassFromString(@"CSDMessagingRelayMessage");
    if (!msgCls) return nil;
    id msg = nil;
    SEL initSel = NSSelectorFromString(@"initWithType:uniqueProxyIdentifier:");
    if ([msgCls instancesRespondToSelector:initSel]) {
        msg = ((id (*)(id, SEL, int, id))objc_msgSend)([msgCls alloc], initSel, msgType, upi);
    } else {
        msg = [[msgCls alloc] init];
        if ([msg respondsToSelector:NSSelectorFromString(@"setUniqueProxyIdentifier:")])
            ((void (*)(id, SEL, id))objc_msgSend)(msg, NSSelectorFromString(@"setUniqueProxyIdentifier:"), upi);
    }
    if (!msg) return nil;

    Class handleCls = NSClassFromString(@"TUHandle");
    if (handleCls && number.length > 0) {
        id handle = nil;
        NSString *fallbackISO = @"";
        id localeCountry = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
        if ([localeCountry isKindOfClass:NSString.class] && [(NSString *)localeCountry length] > 0) {
            fallbackISO = [(NSString *)localeCountry lowercaseString];
        }
        SEL normSel = NSSelectorFromString(@"normalizedPhoneNumberHandleForValue:isoCountryCode:");
        SEL isoSel = NSSelectorFromString(@"isoCountryCode");
        if ([handleCls respondsToSelector:normSel]) {
            NSString *initialISO = [number hasPrefix:@"+"] ? @"" : fallbackISO;
            handle = ((id (*)(id, SEL, id, id))objc_msgSend)(handleCls, normSel, number, initialISO);
            BOOL missingISO = YES;
            if (handle && [handle respondsToSelector:isoSel]) {
                id hISO = ((id (*)(id, SEL))objc_msgSend)(handle, isoSel);
                missingISO = ![hISO isKindOfClass:NSString.class] || [(NSString *)hISO length] == 0;
            }
            if ((!handle || missingISO) && [number hasPrefix:@"+"] && fallbackISO.length > 0) {
                id fallbackHandle = ((id (*)(id, SEL, id, id))objc_msgSend)(handleCls, normSel, number, fallbackISO);
                if (fallbackHandle) {
                    handle = fallbackHandle;
                }
            }
        }
        if (!handle && [handleCls instancesRespondToSelector:NSSelectorFromString(@"initWithType:value:")]) {
            handle = ((id (*)(id, SEL, NSInteger, id))objc_msgSend)([handleCls alloc], NSSelectorFromString(@"initWithType:value:"), 2, number);
        }
        if (handle) {
            if ([msg respondsToSelector:NSSelectorFromString(@"setTuHandle:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(msg, NSSelectorFromString(@"setTuHandle:"), handle);
            }
            if ([msg respondsToSelector:NSSelectorFromString(@"setRemoteParticipantTUHandles:")]) {
                NSSet *handles = [NSSet setWithObject:handle];
                ((void (*)(id, SEL, id))objc_msgSend)(msg, NSSelectorFromString(@"setRemoteParticipantTUHandles:"), handles);
            }
            NSString *resolvedISO = nil;
            if ([handle respondsToSelector:isoSel]) {
                id hISO = ((id (*)(id, SEL))objc_msgSend)(handle, isoSel);
                if ([hISO isKindOfClass:NSString.class] && [(NSString *)hISO length] > 0) {
                    resolvedISO = [(NSString *)hISO lowercaseString];
                }
            }
            if (resolvedISO.length > 0 && [msg respondsToSelector:NSSelectorFromString(@"setIsoCountryCode:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(msg, NSSelectorFromString(@"setIsoCountryCode:"), resolvedISO);
            }
        }
    }

    if (callerName.length > 0) {
        if ([msg respondsToSelector:NSSelectorFromString(@"setCallerNameFromNetwork:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(msg, NSSelectorFromString(@"setCallerNameFromNetwork:"), callerName);
        }
        Class dcCls = NSClassFromString(@"TUMutableCallDisplayContext");
        if (dcCls && [msg respondsToSelector:NSSelectorFromString(@"setDisplayContext:")]) {
            id dc = [[dcCls alloc] init];
            if (dc) {
                SEL setNameSel = NSSelectorFromString(@"setName:");
                SEL setContactNameSel = NSSelectorFromString(@"setContactName:");
                SEL setSuggestedNameSel = NSSelectorFromString(@"setSuggestedName:");
                if ([dc respondsToSelector:setNameSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(dc, setNameSel, callerName);
                }
                if ([dc respondsToSelector:setContactNameSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(dc, setContactNameSel, callerName);
                }
                if ([dc respondsToSelector:setSuggestedNameSel]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(dc, setSuggestedNameSel, callerName);
                }
                ((void (*)(id, SEL, id))objc_msgSend)(msg, NSSelectorFromString(@"setDisplayContext:"), dc);
            }
        }
    }

    id sc = gcl_stateController;
    id telProv = nil;
    if (sc && [sc respondsToSelector:NSSelectorFromString(@"relayCallDelegate")]) {
        id del = ((id (*)(id, SEL))objc_msgSend)(sc, NSSelectorFromString(@"relayCallDelegate"));
        SEL locProv = NSSelectorFromString(@"localProviderWithIdentifier:");
        if (del && [del respondsToSelector:locProv]) {
            telProv = ((id (*)(id, SEL, id))objc_msgSend)(del, locProv, @"com.apple.coretelephony");
        }
    }
    if (telProv && [msg respondsToSelector:NSSelectorFromString(@"setTuProvider:isVideo:")]) {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(msg, NSSelectorFromString(@"setTuProvider:isVideo:"), telProv, NO);
    }
    if ([msg respondsToSelector:NSSelectorFromString(@"setProtoService:")]) {
        ((void (*)(id, SEL, int))objc_msgSend)(msg, NSSelectorFromString(@"setProtoService:"), 1);
    }
    return msg;
}

static void GCLHandleAppCommand(NSDictionary *cmdDict) {
    NSString *cmd = cmdDict[@"cmd"];
    if (![cmd isKindOfClass:NSString.class]) return;
    if ([cmd isEqualToString:@"refresh_caps"]) {
        GCLRefreshDaemonCapabilities();
        return;
    }
    NSString *upi = [cmdDict[@"upi"] isKindOfClass:NSString.class] ? cmdDict[@"upi"] : @"";
    if (!upi.length) return;

    if ([cmd isEqualToString:@"incoming"]) {
        NSString *number = [cmdDict[@"number"] isKindOfClass:NSString.class] ? cmdDict[@"number"] : @"";
        NSString *callerName = [cmdDict[@"callerName"] isKindOfClass:NSString.class] ? cmdDict[@"callerName"] : @"";
        GCLBeginPendingIncoming(upi);
        id rc = gcl_relayClient;
        id sc = gcl_stateController;
        if (rc && [rc respondsToSelector:NSSelectorFromString(@"handleIncomingCallMessageFromHost:fromPairedDevice:")]) {
            dispatch_async(GCLObjectQueue(rc), ^{
                if (GCLTrackedCall(upi)) { GCLEndPendingIncoming(upi); return; }
                id msg = GCLBuildRelayMessage(upi, number, callerName, 1);
                if (!msg) { GCLEndPendingIncoming(upi); return; }
                ((void (*)(id, SEL, id, BOOL))objc_msgSend)(rc, NSSelectorFromString(@"handleIncomingCallMessageFromHost:fromPairedDevice:"), msg, YES);
                SEL findSel = NSSelectorFromString(@"callWithUniqueProxyIdentifier:");
                id call = [rc respondsToSelector:findSel] ? ((id (*)(id, SEL, id))objc_msgSend)(rc, findSel, upi) : nil;
                if (call) {
                    if ([call respondsToSelector:NSSelectorFromString(@"status")] &&
                        ((int (*)(id, SEL))objc_msgSend)(call, NSSelectorFromString(@"status")) != 4 &&
                        [call respondsToSelector:NSSelectorFromString(@"setCallStatus:")]) {
                        ((void (*)(id, SEL, int))objc_msgSend)(call, NSSelectorFromString(@"setCallStatus:"), 4);
                        GCLNotifyPropertiesChanged(call);
                    }
                    GCLTrackCall(upi, call);
                    GCLEndPendingIncoming(upi);
                    if (sc && [sc respondsToSelector:NSSelectorFromString(@"_launchInCallApplicationForIncomingCallIfNecessary:")]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(sc, NSSelectorFromString(@"_launchInCallApplicationForIncomingCallIfNecessary:"), call);
                    }
                    GCLPhoneLog(@"registered incoming call upi=%@", upi);
                } else {
                    GCLEndPendingIncoming(upi);
                }
            });
        } else if (sc) {
            dispatch_async(GCLObjectQueue(sc), ^{
                if (GCLTrackedCall(upi)) { GCLEndPendingIncoming(upi); return; }
                id msg = GCLBuildRelayMessage(upi, number, callerName, 1);
                Class callCls = NSClassFromString(@"CSDRelayCall");
                SEL initSel = NSSelectorFromString(@"initWithRelayMessage:outgoing:");
                if (!msg || !callCls || ![callCls instancesRespondToSelector:initSel]) { GCLEndPendingIncoming(upi); return; }
                id call = ((id (*)(id, SEL, id, BOOL))objc_msgSend)([callCls alloc], initSel, msg, NO);
                if (!call) { GCLEndPendingIncoming(upi); return; }
                GCLTrackCall(upi, call);
                GCLEndPendingIncoming(upi);
                if ([sc respondsToSelector:NSSelectorFromString(@"setCallDelegatesIfNeeded:")])
                    ((void (*)(id, SEL, id))objc_msgSend)(sc, NSSelectorFromString(@"setCallDelegatesIfNeeded:"), call);
                if ([call respondsToSelector:NSSelectorFromString(@"setEndpointOnCurrentDevice:")])
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(call, NSSelectorFromString(@"setEndpointOnCurrentDevice:"), YES);
                if ([call respondsToSelector:NSSelectorFromString(@"status")] &&
                    ((int (*)(id, SEL))objc_msgSend)(call, NSSelectorFromString(@"status")) != 4 &&
                    [call respondsToSelector:NSSelectorFromString(@"setCallStatus:")]) {
                    ((void (*)(id, SEL, int))objc_msgSend)(call, NSSelectorFromString(@"setCallStatus:"), 4);
                }
                GCLNotifyPropertiesChanged(call);
                if ([sc respondsToSelector:NSSelectorFromString(@"_launchInCallApplicationForIncomingCallIfNecessary:")])
                    ((void (*)(id, SEL, id))objc_msgSend)(sc, NSSelectorFromString(@"_launchInCallApplicationForIncomingCallIfNecessary:"), call);
                GCLPhoneLog(@"registered fallback incoming call upi=%@", upi);
            });
        } else {
            GCLEndPendingIncoming(upi);
        }
        return;
    }

    if ([cmd isEqualToString:@"outgoing_mirror"]) {
        NSString *number = [cmdDict[@"number"] isKindOfClass:NSString.class] ? cmdDict[@"number"] : @"";
        NSString *callerName = [cmdDict[@"callerName"] isKindOfClass:NSString.class] ? cmdDict[@"callerName"] : @"";
        id sc = gcl_stateController;
        if (!sc) return;
        dispatch_async(GCLObjectQueue(sc), ^{
            if (GCLTrackedCall(upi)) return;
            [gcl_callsLock lock];
            if (!gcl_mirroredOutgoingUPIs) gcl_mirroredOutgoingUPIs = [NSMutableSet set];
            [gcl_mirroredOutgoingUPIs addObject:upi];
            [gcl_callsLock unlock];
            id msg = GCLBuildRelayMessage(upi, number, callerName, 2);
            Class callCls = NSClassFromString(@"CSDRelayCall");
            SEL initSel = NSSelectorFromString(@"initWithRelayMessage:outgoing:");
            if (!msg || !callCls || ![callCls instancesRespondToSelector:initSel]) return;
            id call = ((id (*)(id, SEL, id, BOOL))objc_msgSend)([callCls alloc], initSel, msg, YES);
            if (!call) return;
            GCLTrackCall(upi, call);
            if ([sc respondsToSelector:NSSelectorFromString(@"setCallDelegatesIfNeeded:")])
                ((void (*)(id, SEL, id))objc_msgSend)(sc, NSSelectorFromString(@"setCallDelegatesIfNeeded:"), call);
            if ([call respondsToSelector:NSSelectorFromString(@"setEndpointOnCurrentDevice:")])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(call, NSSelectorFromString(@"setEndpointOnCurrentDevice:"), YES);
            if ([call respondsToSelector:NSSelectorFromString(@"setLocallyHasStartedOutgoing")])
                ((void (*)(id, SEL))objc_msgSend)(call, NSSelectorFromString(@"setLocallyHasStartedOutgoing"));
            GCLNotifyPropertiesChanged(call);
            GCLPhoneLog(@"mirrored app-initiated outgoing call upi=%@", upi);
        });
        return;
    }

    id sc = gcl_stateController;
    dispatch_queue_t q = sc ? GCLObjectQueue(sc) : dispatch_get_main_queue();
    dispatch_async(q, ^{
        id call = GCLTrackedCall(upi);
        if (!call) return;
        if ([cmd isEqualToString:@"ringing"]) {
            if ([call respondsToSelector:NSSelectorFromString(@"setLocallyHasSentInvitation")])
                ((void (*)(id, SEL))objc_msgSend)(call, NSSelectorFromString(@"setLocallyHasSentInvitation"));
            GCLNotifyPropertiesChanged(call);
        } else if ([cmd isEqualToString:@"connecting"]) {
            if ([call respondsToSelector:NSSelectorFromString(@"setLocallyConnecting")])
                ((void (*)(id, SEL))objc_msgSend)(call, NSSelectorFromString(@"setLocallyConnecting"));
            GCLNotifyPropertiesChanged(call);
        } else if ([cmd isEqualToString:@"connected"]) {
            if ([call respondsToSelector:NSSelectorFromString(@"setLocallyConnected")])
                ((void (*)(id, SEL))objc_msgSend)(call, NSSelectorFromString(@"setLocallyConnected"));
            GCLNotifyPropertiesChanged(call);
            GCLPhoneLog(@"call connected upi=%@", upi);
        } else if ([cmd isEqualToString:@"disconnected"]) {
            int reason = [cmdDict[@"reason"] isKindOfClass:NSNumber.class] ? [cmdDict[@"reason"] intValue] : 0;
            gcl_suppressDisconnectEcho = YES;
            if ([call respondsToSelector:NSSelectorFromString(@"setLocallyDisconnectedWithReasonIfNone:")])
                ((void (*)(id, SEL, int))objc_msgSend)(call, NSSelectorFromString(@"setLocallyDisconnectedWithReasonIfNone:"), reason);
            GCLNotifyPropertiesChanged(call);
            gcl_suppressDisconnectEcho = NO;
            GCLUntrackCall(upi);
            GCLPhoneLog(@"call disconnected upi=%@ reason=%d", upi, reason);
        } else if ([cmd isEqualToString:@"mute"]) {
            BOOL muted = [cmdDict[@"muted"] boolValue];
            gcl_suppressMuteEcho = YES;
            if ([call respondsToSelector:NSSelectorFromString(@"setUplinkMuted:userInitiated:")])
                ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(call, NSSelectorFromString(@"setUplinkMuted:userInitiated:"), muted, NO);
            GCLNotifyPropertiesChanged(call);
            gcl_suppressMuteEcho = NO;
        }
    });
}

#pragma mark - Command Watcher

static NSString *gcl_lastSession = @"";
static uint64_t gcl_lastCmdSeq = 0;
static BOOL gcl_lastAvailableState = NO;

static void GCLPollAppCommands(void) {
    BOOL avail = GCLPhoneAvailableFresh();
    if (avail != gcl_lastAvailableState) {
        gcl_lastAvailableState = avail;
        GCLRefreshDaemonCapabilities();
    }
    int fd = GCLPhoneOpen(@"app_commands.jsonl", O_RDONLY);
    if (fd < 0) return;
    struct stat info;
    if (fstat(fd, &info) || info.st_size == 0 || info.st_size > 262144) { close(fd); return; }
    NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    if (!data.length) return;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (!line.length) continue;
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:NULL];
        if (![obj isKindOfClass:NSDictionary.class]) continue;
        NSString *session = [obj[@"session"] isKindOfClass:NSString.class] ? obj[@"session"] : @"";
        uint64_t seq = [obj[@"seq"] respondsToSelector:@selector(unsignedLongLongValue)] ? [obj[@"seq"] unsignedLongLongValue] : 0;
        if (![session isEqualToString:gcl_lastSession]) {
            gcl_lastSession = [session copy];
            gcl_lastCmdSeq = 0;
        }
        if (seq <= gcl_lastCmdSeq) continue;
        gcl_lastCmdSeq = seq;
        GCLHandleAppCommand(obj);
    }
}

static dispatch_queue_t gcl_watcherQueue;
static dispatch_source_t gcl_vnodeSource;
static dispatch_source_t gcl_timerSource;

GCL_MAYBE_UNUSED static void GCLStartWatcher(void) {
    gcl_watcherQueue = dispatch_queue_create("local.galaxy-continuity-lab.phone-hook", DISPATCH_QUEUE_SERIAL);
    int dirFD = GCLPhoneDirectoryFD();
    if (dirFD >= 0) {
        gcl_vnodeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)dirFD,
                                                 DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB,
                                                 gcl_watcherQueue);
        dispatch_source_set_event_handler(gcl_vnodeSource, ^{ GCLPollAppCommands(); });
        dispatch_source_set_cancel_handler(gcl_vnodeSource, ^{ close(dirFD); });
        dispatch_resume(gcl_vnodeSource);
    }
    gcl_timerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gcl_watcherQueue);
    dispatch_source_set_timer(gcl_timerSource, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 2 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gcl_timerSource, ^{ GCLPollAppCommands(); });
    dispatch_resume(gcl_timerSource);
}

#pragma mark - Constructor

__attribute__((constructor))
static void gcl_phone_init(void) {
#ifdef GCL_TESTING
    gcl_callsLock = [[NSLock alloc] init];
    return;
#else
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"callservicesd"]) return;
    int directory = GCLPhoneDirectoryFD();
    if (directory < 0) return;
    close(directory);
    gcl_callsLock = [[NSLock alloc] init];
    if (!GCLPhoneCheckCrashGuardAndRecordStartup()) return;

    GCLPhoneLog(@"hook loaded");

    Class capCls = NSClassFromString(@"CSDCallCapabilities");
    if (capCls) {
        GCLPhoneSwap(capCls, NSSelectorFromString(@"_updateRelayCapabilities"), (IMP)gcl_hook_updateRelayCapabilities, &gcl_orig_updateRelayCapabilities);
    }

    Class scCls = NSClassFromString(@"CSDCallStateController");
    if (scCls) {
        GCLPhoneSwap(scCls, NSSelectorFromString(@"initWithQueue:chManager:featureFlags:deviceSupport:notificationCenter:"), (IMP)gcl_hook_scInit, &gcl_orig_scInit);
        GCLPhoneSwap(scCls, NSSelectorFromString(@"outgoingCallFromDialRequest:"), (IMP)gcl_hook_outgoingFromDial, &gcl_orig_outgoingFromDial);
    }

    Class rcCls = NSClassFromString(@"CSDRelayClientController");
    if (rcCls) {
        GCLPhoneSwap(rcCls, NSSelectorFromString(@"initWithQueue:featureFlags:"), (IMP)gcl_hook_rcInit2, &gcl_orig_rcInit2);
        GCLPhoneSwap(rcCls, NSSelectorFromString(@"initWithQueue:"), (IMP)gcl_hook_rcInit1, &gcl_orig_rcInit1);
    }

    Class rmcCls = NSClassFromString(@"CSDRelayMessagingController");
    if (rmcCls) {
        GCLPhoneSwap(rmcCls, NSSelectorFromString(@"_handleCallChanged:"), (IMP)gcl_hook_relayMessagingHandleCallChanged, &gcl_orig_relayMessagingHandleCallChanged);
    }

    Class delCls = NSClassFromString(@"CSDRelayCallDelegate");
    if (delCls) {
        GCLPhoneSwap(delCls, NSSelectorFromString(@"relayCallDidDial:"), (IMP)gcl_hook_didDial, &gcl_orig_didDial);
        GCLPhoneSwap(delCls, NSSelectorFromString(@"relayCall:didAnswerWithRequest:"), (IMP)gcl_hook_didAnswer, &gcl_orig_didAnswer);
        GCLPhoneSwap(delCls, NSSelectorFromString(@"relayCallDidDisconnect:"), (IMP)gcl_hook_didDisconnect, &gcl_orig_didDisconnect);
        GCLPhoneSwap(delCls, NSSelectorFromString(@"relayCallDidHold:"), (IMP)gcl_hook_didHold, &gcl_orig_didHold);
        GCLPhoneSwap(delCls, NSSelectorFromString(@"relayCallDidUnhold:"), (IMP)gcl_hook_didUnhold, &gcl_orig_didUnhold);
        GCLPhoneSwap(delCls, NSSelectorFromString(@"relayCall:didPlayLocalDTMFToneForKey:"), (IMP)gcl_hook_didDTMF, &gcl_orig_didDTMF);
        GCLPhoneSwap(delCls, NSSelectorFromString(@"relayCallDidPerformUplinkMuted:uplinkMuted:"), (IMP)gcl_hook_didMute, &gcl_orig_didMute);
    }

    GCLStartWatcher();
    GCLPhoneLog(@"hook install complete");
#endif
}
