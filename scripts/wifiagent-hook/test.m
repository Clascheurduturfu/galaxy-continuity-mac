#define GCL_TESTING 1
#import "GalaxyContinuityWiFiMenuHook.m"
#import <assert.h>

@interface TestDevice: NSObject
@property NSString *address;
@end
@implementation TestDevice
@end
static id cachedFixture(id self, SEL cmd) {
    TestDevice *fake = [TestDevice new]; fake.address = GCLFakeAddress();
    TestDevice *real = [TestDevice new]; real.address = @"stock-device";
    return [NSSet setWithObjects:fake, real, nil];
}
static void put(NSString *name, NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    int fd = GCLOpen(name, O_CREAT | O_WRONLY | O_TRUNC);
    assert(fd >= 0); assert(write(fd, data.bytes, data.length) == (ssize_t)data.length); close(fd);
}
int main(void) { @autoreleasepool {
    assert([NSFileManager.defaultManager createDirectoryAtPath:GCLDir() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL]);
    put(@"status.json", @{@"name":@"Test phone", @"ssid":@"Test hotspot", @"connected":@YES});
    GCLTouch(@"available");
    assert(GCLConnectedToHotspot());
    NSSet *clean = GCLCached(nil, NULL, (IMP)cachedFixture);
    assert(clean.count == 1 && !GCLIsOurDevice(clean.anyObject));
    GCLRemove(@"available");
    assert(!GCLConnectedToHotspot());
    assert([GCLCached(nil, NULL, (IMP)cachedFixture) count] == 1);
    TestDevice *device = [TestDevice new]; device.address = GCLFakeAddress();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL joined = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{
        NSError *error = nil;
        joined = gcl_hook_connectTether(nil, NULL, device, NO, &error);
        assert(!error); dispatch_semaphore_signal(done);
    });
    NSDictionary *trigger = nil;
    for (int i=0; i<100 && !trigger; i++) { usleep(10000); trigger = GCLReadJSON(@"trigger"); }
    assert(trigger[@"id"]);
    // A concurrent click must not overwrite the live operation.
    __block BOOL rejected = NO;
    dispatch_semaphore_t second = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{
        NSError *error = nil;
        rejected = !gcl_hook_connectTether(nil, NULL, device, NO, &error) && error.code == 6;
        dispatch_semaphore_signal(second);
    });
    assert(dispatch_semaphore_wait(second,dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 && rejected);
    put(@"creds.json", @{@"id":NSUUID.UUID.UUIDString, @"joined":@YES});
    assert(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW, 250*NSEC_PER_MSEC)) != 0);
    put(@"reply.pending", @{@"id":trigger[@"id"], @"joined":@YES});
    assert(rename([[GCLDir() stringByAppendingPathComponent:@"reply.pending"] fileSystemRepresentation], [[GCLDir() stringByAppendingPathComponent:@"creds.json"] fileSystemRepresentation]) == 0);
    assert(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)) == 0 && joined);
    assert([NSFileManager.defaultManager removeItemAtPath:GCLDir() error:NULL]);
    puts("Hook tests passed: connected visibility, stale cache removal, duplicate click exclusion, reply correlation.");
} return 0; }
