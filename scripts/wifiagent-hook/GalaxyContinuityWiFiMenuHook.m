// GalaxyContinuityWiFiMenuHook.m — v6
//
// Shows the user's Samsung Galaxy under the native macOS Wi-Fi menu's
// "Personal Hotspots" section and joins it when clicked. Loaded through
// DYLD_INSERT_LIBRARIES into WiFiAgent/ControlCenter by the Galaxy Continuity
// "macOS Wi-Fi menu" option (SIP must be disabled).
//
// File protocol with the app, in /tmp/gcl-wifi-menu:
//   status.json  app -> hook: {name, battery, bars, network, ssid}
//   available    app -> hook: touched while the phone session is live
//   menu_opened  hook -> app: the Wi-Fi menu was opened (app may prefetch)
//   trigger      hook -> app: the entry was clicked; answered via creds.json
//   creds.json   app -> hook: {isSuccess, ssid, password, reason}
//   hook.log     hook: diagnostics, one line per interesting event
//
// Everything resolves classes and selectors at runtime and no-ops when they
// are missing, so the dylib is inert in processes that lack CoreWLAN
// internals. The retained v4 source is the reference; private selectors are checked
// at runtime and collection return types are preserved.

#import <Foundation/Foundation.h>
#import <CoreWLAN/CoreWLAN.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>
#import <unistd.h>
#import <fcntl.h>

#pragma mark - Files and logging

static NSString *GCLDir(void) { return @"/tmp/gcl-wifi-menu"; }

// Validate the owner-only IPC directory and use openat/O_NOFOLLOW for every file.
static int GCLDirectoryFD(void) {
    int fd = open(GCLDir().fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (fd >= 0 && (fstat(fd, &info) || info.st_uid != getuid() || (info.st_mode & 077) != 0)) { close(fd); return -1; }
    return fd;
}
static int GCLOpen(NSString *name, int flags) {
    int directory = GCLDirectoryFD(); if (directory < 0) return -1;
    int fd = openat(directory, name.fileSystemRepresentation, flags | O_NOFOLLOW | O_CLOEXEC, 0600); close(directory);
    struct stat info;
    if (fd >= 0 && (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1 || (info.st_mode & 077) != 0)) { close(fd); return -1; }
    return fd;
}
static void GCLLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [[NSProcessInfo processInfo] processName], message];
    int fd = GCLOpen(@"hook.log", O_WRONLY | O_APPEND | O_CREAT);
    if (fd >= 0) { struct stat info; if (!fstat(fd, &info) && info.st_size < 262144) { NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding]; write(fd, data.bytes, data.length); } close(fd); }
}
static void GCLTouch(NSString *name) {
    int fd = GCLOpen(name, O_CREAT | O_WRONLY); if (fd >= 0) { futimes(fd, NULL); close(fd); }
}
static void GCLRemove(NSString *name) {
    int directory = GCLDirectoryFD(); if (directory >= 0) { unlinkat(directory, name.fileSystemRepresentation, 0); close(directory); }
}
static NSDictionary *GCLReadJSON(NSString *name) {
    int fd = GCLOpen(name, O_RDONLY); if (fd < 0) return nil;
    struct stat info; if (fstat(fd, &info) || info.st_size > 65536) { close(fd); return nil; }
    NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSData *data = [handle readDataToEndOfFile]; [handle closeFile];
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}
static BOOL GCLAvailableFresh(void) {
    int fd = GCLOpen(@"available", O_RDONLY); if (fd < 0) return NO;
    struct stat info; BOOL valid = !fstat(fd, &info) && time(NULL) >= info.st_mtime && time(NULL) - info.st_mtime <= 10; close(fd); return valid;
}

#pragma mark - Status snapshot

typedef struct {
    BOOL ok;                 // entry should be visible at all
    NSString *name;
    NSString *ssid;          // "" when unknown
    NSInteger battery, bars;
    NSString *network;
} GCLStatus;

static GCLStatus GCLLoadStatus(void) {
    GCLStatus st = {NO, @"Galaxy", @"", -1, -1, nil};
    if (!GCLAvailableFresh()) return st;
    NSDictionary *json = GCLReadJSON(@"status.json");
    if (!json) return st;
    st.name = json[@"name"] ?: st.name;
    if ([json[@"battery"] isKindOfClass:[NSNumber class]]) st.battery = [json[@"battery"] integerValue];
    st.bars = [json[@"bars"] integerValue] ?: st.bars;
    st.network = json[@"network"] ?: st.network;
    st.ssid = json[@"ssid"] ?: @"";
    st.ok = YES;
    return st;
}

/// True while the Mac's current SSID is the phone's hotspot (v5: while
/// connected, the fake entry is suppressed so it does not duplicate the
/// joined network in the menu).
static BOOL GCLConnectedToHotspot(void) {
    GCLStatus st = GCLLoadStatus();
    if (!st.ok || st.ssid.length == 0) return NO;
    Class wifiClient = NSClassFromString(@"CWWiFiClient");
    id client = nil, interface = nil;
    if (wifiClient) {
        SEL factories[3] = {@selector(sharedClient), @selector(sharedWiFiClient), @selector(shared)};
        for (int i = 0; i < 3 && !client; i++) {
            if ([wifiClient respondsToSelector:factories[i]]) client = ((id (*)(id, SEL)) objc_msgSend)(wifiClient, factories[i]);
        }
    }
    if ([client respondsToSelector:@selector(interface)]) interface = ((id (*)(id, SEL)) objc_msgSend)(client, @selector(interface));
    if (!interface) return NO;
    NSString *current = ((NSString *(*)(id, SEL)) objc_msgSend)(interface, @selector(ssid));
    return [current isEqualToString:st.ssid];
}

static NSString *GCLFakeAddress(void) { return @"AA:BB:CC:DD:EE:FF"; }

static BOOL GCLIsOurDevice(id device) {
    if (!device) return NO;
    if ([device respondsToSelector:NSSelectorFromString(@"deviceIdentifier")]) {
        id identifier = ((id (*)(id, SEL))objc_msgSend)(device, NSSelectorFromString(@"deviceIdentifier"));
        if ([identifier isKindOfClass:[NSString class]] && [identifier isEqualToString:GCLFakeAddress()]) return YES;
    }
    // CWTetherDevice exposes the source remote hotspot's address; our fake is
    // recognized by its marker address.
    if ([device respondsToSelector:@selector(address)]) {
        NSString *address = ((NSString *(*)(id, SEL)) objc_msgSend)(device, @selector(address));
        if ([address isEqualToString:GCLFakeAddress()]) return YES;
    }
    if ([device respondsToSelector:@selector(remoteAddress)]) {
        NSString *address = ((NSString *(*)(id, SEL)) objc_msgSend)(device, @selector(remoteAddress));
        if ([address isEqualToString:GCLFakeAddress()]) return YES;
    }
    return NO;
}

#pragma mark - Fake device construction

/// Builds an SFRemoteHotspotDevice via KVC against several candidate property
/// names (the class is private and its layout shifts between macOS releases);
/// every hit is logged so a future release only needs the names updated.
static id GCLMakeFakeRemoteDevice(GCLStatus st) {
    Class cls = NSClassFromString(@"SFRemoteHotspotDevice");
    if (!cls) { GCLLog(@"no SFRemoteHotspotDevice class"); return nil; }
    id device = [[cls alloc] init];
    if (!device) { GCLLog(@"SFRemoteHotspotDevice alloc failed"); return nil; }
    NSDictionary *candidates = @{
        @"name": st.name, @"deviceName": st.name, @"displayName": st.name,
        @"address": GCLFakeAddress(), @"remoteAddress": GCLFakeAddress(), @"uniqueID": GCLFakeAddress(),
        @"identifier": GCLFakeAddress(), @"deviceID": GCLFakeAddress(), @"deviceIdentifier": GCLFakeAddress()
    };
    for (NSString *key in candidates) {
        @try {
            if ([device respondsToSelector:NSSelectorFromString(key)]) {
                [device setValue:candidates[key] forKey:key];
            }
        } @catch (NSException *e) { GCLLog(@"fake KVC %@: %@", key, e.reason); }
    }
    if (st.battery >= 0 && st.battery <= 100) {
        @try { [device setValue:@(st.battery) forKey:@"batteryLife"]; } @catch (NSException *e) {}
    }
    return device;
}

#pragma mark - Swizzling helpers

static void GCLSwap(Class cls, SEL selector, IMP implementation, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) { GCLLog(@"missing method -[%@ %@]", cls, NSStringFromSelector(selector)); return; }
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, implementation, method_getTypeEncoding(method))) method_setImplementation(method, implementation);
    GCLLog(@"hooked -[%@ %@]", cls, NSStringFromSelector(selector));
}

#pragma mark - CWWiFiAgent hooks

static IMP gcl_orig_startBrowsing;
static void gcl_hook_startBrowsing(id self, SEL _cmd, id reply) {
    GCLLog(@"tether browsing started");
    GCLTouch(@"menu_opened");   // the app may prefetch a fresh hotspot answer
    if (gcl_orig_startBrowsing) ((void (*)(id, SEL, id)) gcl_orig_startBrowsing)(self, _cmd, reply);
}

static IMP gcl_orig_updatedFoundDevices;
static void gcl_hook_updatedFoundDevices(id self, SEL _cmd, id session, NSArray *devices) {
    GCLStatus st = GCLLoadStatus();
    if (st.ok && !GCLConnectedToHotspot()) {
        id fake = GCLMakeFakeRemoteDevice(st);
        if (fake && ![devices containsObject:fake]) devices = [(devices ?: @[]) arrayByAddingObject:fake];
    }
    if (gcl_orig_updatedFoundDevices) ((void (*)(id, SEL, id, NSArray *)) gcl_orig_updatedFoundDevices)(self, _cmd, session, devices);
}

static IMP gcl_orig_cachedTetherDevices, gcl_orig_cachedCurrent;
static id GCLCached(id self, SEL cmd, IMP originalIMP) {
    id original = originalIMP ? ((id (*)(id, SEL))originalIMP)(self, cmd) : nil;
    GCLStatus st = GCLLoadStatus();
    if (!st.ok || GCLConnectedToHotspot()) return original;
    id fake = GCLMakeFakeRemoteDevice(st);
    SEL convert = NSSelectorFromString(@"__tetherDevicesForRemoteHotspots:");
    if (!fake || ![self respondsToSelector:convert]) return original;
    id converted = ((id (*)(id, SEL, id))objc_msgSend)(self, convert, @[fake]);
    // macOS returns NSSet here, not NSArray. Never send an array selector to a set.
    if ([converted isKindOfClass:[NSSet class]]) {
        NSMutableSet *merged = [NSMutableSet set];
        if ([original isKindOfClass:[NSSet class]]) [merged unionSet:original];
        else if ([original isKindOfClass:[NSArray class]]) [merged addObjectsFromArray:original];
        [merged unionSet:converted]; return [merged copy];
    }
    if ([converted isKindOfClass:[NSArray class]] && [original isKindOfClass:[NSArray class]]) return [original arrayByAddingObjectsFromArray:converted];
    return original;
}
static id gcl_hook_cachedTetherDevices(id self, SEL cmd) { return GCLCached(self, cmd, gcl_orig_cachedTetherDevices); }
static id gcl_hook_cachedCurrent(id self, SEL cmd) { return GCLCached(self, cmd, gcl_orig_cachedCurrent); }

#pragma mark - CWInterface hooks

static IMP gcl_orig_connectTether;
static BOOL gcl_hook_connectTether(id self, SEL _cmd, id device, BOOL remember, NSError **error) {
    if (!GCLIsOurDevice(device)) {
        return gcl_orig_connectTether
            ? ((BOOL (*)(id, SEL, id, BOOL, NSError **)) gcl_orig_connectTether)(self, _cmd, device, remember, error)
            : NO;
    }
    GCLLog(@"our tether device clicked: joining via the app");
    if ([NSThread isMainThread]) { if (error) *error = [NSError errorWithDomain:@"GalaxyContinuityWiFiMenu" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Use Connect in Galaxy Continuity for this macOS menu path."}]; return NO; }
    GCLRemove(@"creds.json");
    GCLTouch(@"trigger");
    NSDictionary *creds = nil;
    for (int i = 0; i < 100 && !creds; i++) { usleep(100000); creds = GCLReadJSON(@"creds.json"); }
    if (!creds) { GCLLog(@"no creds.json within 10 s"); if (error) *error = [NSError errorWithDomain:@"GalaxyContinuityWiFiMenu" code:1 userInfo:@{NSLocalizedDescriptionKey: @"The phone did not answer in time."}]; return NO; }
    GCLRemove(@"creds.json");
    if (![creds[@"isSuccess"] boolValue]) {
        GCLLog(@"creds report failure reason %@", creds[@"reason"]);
        if (error) *error = [NSError errorWithDomain:@"GalaxyContinuityWiFiMenu" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The phone declined the hotspot request (reason %@).", creds[@"reason"] ?: @"?"]}];
        return NO;
    }
    NSString *ssid = creds[@"ssid"], *password = creds[@"password"];
    GCLRemove(@"creds.json");
    if (![ssid isKindOfClass:[NSString class]] || !ssid.length || ![password isKindOfClass:[NSString class]]) return NO;
    NSData *ssidData = [ssid dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *networks = nil;
    if ([self respondsToSelector:@selector(scanForNetworksWithSSID:error:)]) {
        networks = ((NSArray *(*)(id, SEL, NSData *, NSError **)) objc_msgSend)(self, @selector(scanForNetworksWithSSID:error:), ssidData, NULL);
    } else if ([self respondsToSelector:@selector(scanForNetworksForSSID:error:)]) {
        networks = ((NSArray *(*)(id, SEL, NSData *, NSError **)) objc_msgSend)(self, @selector(scanForNetworksForSSID:error:), ssidData, NULL);
    } else if ([self respondsToSelector:@selector(scanForNetworksWithError:)]) {
        NSArray *all = ((NSArray *(*)(id, SEL, NSError **)) objc_msgSend)(self, @selector(scanForNetworksWithError:), NULL);
        networks = [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"ssid == %@", ssid]];
    } else {
        GCLLog(@"no scan selector available on CWInterface");
        if (error) *error = [NSError errorWithDomain:@"GalaxyContinuityWiFiMenu" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Could not scan for the hotspot."}];
        return NO;
    }
    if (networks.count == 0) { GCLLog(@"hotspot ssid not found in scan"); if (error) *error = [NSError errorWithDomain:@"GalaxyContinuityWiFiMenu" code:3 userInfo:@{NSLocalizedDescriptionKey: @"The phone's hotspot was not visible yet."}]; return NO; }
    BOOL ok = ((BOOL (*)(id, SEL, id, id, NSError **)) objc_msgSend)(self, @selector(associateToNetwork:password:error:), networks.firstObject, password, error);
    GCLLog(@"hotspot association ok=%d", ok);
    return ok;
}

#pragma mark - CWNetwork / CWTrimmedNetwork display hooks

// One hook function, per-class originals: CWNetwork and CWTrimmedNetwork are
// distinct classes, and calling one class's original IMP on the other's
// instance would be undefined behavior.
static IMP gcl_orig_isPH_network, gcl_orig_isPH_trimmed;
static BOOL gcl_hook_networkIsPersonalHotspot(id self, SEL _cmd) {
    GCLStatus st = GCLLoadStatus();
    if (st.ok && st.ssid.length > 0 && [self respondsToSelector:@selector(ssid)]) {
        NSString *ssid = ((NSString *(*)(id, SEL)) objc_msgSend)(self, @selector(ssid));
        if ([ssid isEqualToString:st.ssid]) return YES;
    }
    IMP original = object_getClass(self) == NSClassFromString(@"CWTrimmedNetwork") ? gcl_orig_isPH_trimmed : gcl_orig_isPH_network;
    return original ? ((BOOL (*)(id, SEL)) original)(self, _cmd) : NO;
}

#pragma mark - Load

__attribute__((constructor))
static void gcl_init(void) {
    NSString *processName = [NSProcessInfo processInfo].processName;
    if (![@[@"WiFiAgent", @"ControlCenter"] containsObject:processName]) return;
    int directory = GCLDirectoryFD(); if (directory < 0) return; close(directory);
    GCLLog(@"hook loaded");
    Class agent = NSClassFromString(@"CWWiFiAgent");
    if (agent) {
        GCLSwap(agent, NSSelectorFromString(@"internal_startBrowsingForTetherDevicesAndReply:"), (IMP)gcl_hook_startBrowsing, &gcl_orig_startBrowsing);
        GCLSwap(agent, NSSelectorFromString(@"session:updatedFoundDevices:"), (IMP)gcl_hook_updatedFoundDevices, &gcl_orig_updatedFoundDevices);
        GCLSwap(agent, NSSelectorFromString(@"__cachedTetherDevices"), (IMP)gcl_hook_cachedTetherDevices, &gcl_orig_cachedTetherDevices);
        GCLSwap(agent, NSSelectorFromString(@"__cachedTetherDevicesFromCurrentBrowseSession"), (IMP)gcl_hook_cachedCurrent, &gcl_orig_cachedCurrent);
    }
    Class interface = NSClassFromString(@"CWInterface");
    if (interface) {
        GCLSwap(interface, @selector(connectToTetherDevice:remember:error:), (IMP)gcl_hook_connectTether, &gcl_orig_connectTether);
        // Keep stock lastTetherDeviceJoined: it must return a CWTetherDevice, not an SFRemoteHotspotDevice.
    }
    for (NSString *name in @[@"CWNetwork", @"CWTrimmedNetwork"]) {
        Class network = NSClassFromString(name);
        if (network) GCLSwap(network, @selector(isPersonalHotspot), (IMP)gcl_hook_networkIsPersonalHotspot,
                             [name isEqualToString:@"CWTrimmedNetwork"] ? &gcl_orig_isPH_trimmed : &gcl_orig_isPH_network);
    }
    GCLLog(@"hook install complete");
}
