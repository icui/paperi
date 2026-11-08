// Transfer dispatch adapted from yabai dd845723416f5fe92af49fad5ebab00369e07edd,
// src/space_manager.c. See THIRD_PARTY_NOTICES.md for its MIT license.
// Disposable probe only: never accepts another process's window ID.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <dlfcn.h>

static int connection;
static CFArrayRef (*copySpaces)(int, int, CFArrayRef);
static CFArrayRef (*copyDisplays)(int);
static int (*spaceType)(int, uint64_t);
static int64_t (*performOperation)(void *);
// Private headers disagree about this return type. The reference callers ignore
// its return; do not interpret a return register as a documented CGError.
static void (*setCompatID)(int, uint64_t, int);
static int (*getCompatID)(int, uint64_t);
static int (*setWorkspace)(int, uint32_t *, int, int);
static NSMutableDictionary *submission;

static NSArray *membership(uint32_t wid) {
    CFArrayRef result = copySpaces(connection, 7, (__bridge CFArrayRef)@[@(wid)]);
    return result ? CFBridgingRelease(result) : nil;
}

static NSDictionary *topology(uint64_t sid) {
    NSArray *displays = CFBridgingRelease(copyDisplays(connection));
    for (NSDictionary *display in displays) {
        for (NSDictionary *space in display[@"Spaces"]) {
            if ([space[@"ManagedSpaceID"] unsignedLongLongValue] == sid) return display;
        }
    }
    return nil;
}

static BOOL moveOwnWindow(NSWindow *window, uint64_t sid) {
    // The only window accepted is the one allocated by this probe.
    if (!window || !topology(sid) || spaceType(connection, sid) != 0) return NO;
    Class cls = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    SEL init = NSSelectorFromString(@"initWithWindows:spaceID:");
    if (performOperation && cls && [cls instancesRespondToSelector:init]) {
        id operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)([cls alloc], init,
                       @[@((uint32_t)window.windowNumber)], sid);
        if (!operation) return NO;
        submission[@"backend"] = @"bridgedOperation";
        submission[@"dispatchResult"] = @(performOperation((__bridge void *)operation));
        return YES; // Submission only. Membership polling determines success.
    }
    if (!setCompatID || !setWorkspace) return NO;
    submission[@"backend"] = @"compatibilityWorkspace";
    uint32_t wid = (uint32_t)window.windowNumber;
    int previous = getCompatID ? getCompatID(connection, sid) : 0;
    submission[@"previousCompatID"] = @(previous);
    setCompatID(connection, sid, 0x79616265);
    if (getCompatID) submission[@"assignedCompatID"] = @(getCompatID(connection, sid));
    submission[@"workspaceAssignmentReturn"] = @(setWorkspace(connection, &wid, 1, 0x79616265));
    setCompatID(connection, sid, previous);
    if (getCompatID) submission[@"restoredCompatID"] = @(getCompatID(connection, sid));
    submission[@"workspaceAssignmentAttempted"] = @YES;
    return YES; // As in the reference callers, only membership proves a move.
}

@interface Probe : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@property(strong) NSMutableDictionary *report;
@property uint64_t source;
@property uint64_t destination;
@property int exitCode;
@end

@implementation Probe
- (void)finish:(NSString *)result reason:(NSString *)reason {
    self.report[@"result"] = result;
    self.report[@"reason"] = reason;
    NSData *json = [NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted error:NULL];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    self.exitCode = [result isEqual:@"passed"] ? 0 : ([result isEqual:@"unsupported"] ? 2 : 1);
    [self.window close];
    exit(self.exitCode);
}
- (void)poll:(uint64_t)sid remaining:(int)remaining completion:(void (^)(BOOL))completion {
    NSArray *spaces = membership((uint32_t)self.window.windowNumber);
    if ([spaces isEqual:@[@(sid)]]) { completion(YES); return; }
    if (remaining == 0) { completion(NO); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self poll:sid remaining:remaining - 1 completion:completion];
    });
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.report = [@{@"schemaVersion": @2, @"scope": @"Own disposable window; membership round trip only, no Space activation or focus changes",
                    @"os": NSProcessInfo.processInfo.operatingSystemVersionString} mutableCopy];
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    int (*mainConnection)(void) = sky ? dlsym(sky, "SLSMainConnectionID") : NULL;
    copySpaces = sky ? dlsym(sky, "SLSCopySpacesForWindows") : NULL;
    copyDisplays = sky ? dlsym(sky, "SLSCopyManagedDisplaySpaces") : NULL;
    spaceType = sky ? dlsym(sky, "SLSSpaceGetType") : NULL;
    performOperation = sky ? dlsym(sky, "SLSPerformAsynchronousBridgedWindowManagementOperation") : NULL;
    setCompatID = sky ? dlsym(sky, "SLSSpaceSetCompatID") : NULL;
    getCompatID = sky ? dlsym(sky, "SLSSpaceGetCompatID") : NULL;
    setWorkspace = sky ? dlsym(sky, "SLSSetWindowListWorkspace") : NULL;
    connection = mainConnection ? mainConnection() : 0;
    self.report[@"availableSymbols"] = @{@"bridgedOperation": @(performOperation != NULL),
        @"compatibilityID": @(setCompatID != NULL), @"workspaceAssignment": @(setWorkspace != NULL)};
    if (!connection || !copySpaces || !copyDisplays || !spaceType) {
        [self finish:@"unsupported" reason:@"Required query symbols unavailable"]; return;
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(160, 160, 420, 240)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed = NO;
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.window.title = @"Paperi disposable Space probe";
    [self.window orderFrontRegardless];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        uint32_t wid = (uint32_t)self.window.windowNumber;
        NSArray *before = membership(wid);
        self.report[@"before"] = before ?: (id)NSNull.null;
        if (before.count != 1) { [self finish:@"unsupported" reason:@"Initial membership is not one Space"]; return; }
        self.source = [before.firstObject unsignedLongLongValue];
        NSDictionary *display = topology(self.source);
        NSMutableArray *userSpaces = [NSMutableArray new];
        for (NSDictionary *space in display[@"Spaces"]) {
            uint64_t sid = [space[@"ManagedSpaceID"] unsignedLongLongValue];
            if (sid && spaceType(connection, sid) == 0) {
                [userSpaces addObject:@(sid)];
                if (sid != self.source && !self.destination) self.destination = sid;
            }
        }
        self.report[@"sourceDisplayFound"] = @(display != nil);
        self.report[@"sourceDisplayUserSpaces"] = userSpaces;
        int sourceType = spaceType(connection, self.source);
        self.report[@"sourceSpaceType"] = @(sourceType);
        if (sourceType != 0) {
            [self finish:@"unsupported" reason:@"Source is not a user Space; rerun from a normal desktop"]; return;
        }
        if (!self.destination) {
            [self finish:@"unsupported" reason:@"Need two existing user Spaces on the source display"]; return;
        }
        self.report[@"destination"] = @(self.destination);
        submission = [NSMutableDictionary new];
        self.report[@"outboundSubmission"] = submission;
        if (!moveOwnWindow(self.window, self.destination)) {
            [self finish:@"failed" reason:@"Transfer submission unavailable or rejected"]; return;
        }
        [self poll:self.destination remaining:30 completion:^(BOOL moved) {
            self.report[@"outboundConfirmed"] = @(moved);
            self.report[@"afterOutbound"] = membership(wid) ?: (id)NSNull.null;
            // Attempt return even after an outbound timeout; never infer success
            // from dispatch, and never leave a persistent user document behind.
            submission = [NSMutableDictionary new];
            self.report[@"returnSubmission"] = submission;
            BOOL submitted = moveOwnWindow(self.window, self.source);
            [self poll:self.source remaining:30 completion:^(BOOL restored) {
                self.report[@"sourceMembershipConfirmed"] = @(restored);
                self.report[@"returnConfirmed"] = @(moved && submitted && restored);
                self.report[@"afterReturn"] = membership(wid) ?: (id)NSNull.null;
                [self finish:moved && submitted && restored ? @"passed" : @"failed"
                      reason:@"Transfer requires observed destination and restored source membership"];
            }];
        }];
    });
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        Probe *probe = [Probe new];
        app.delegate = probe;
        [app run];
        return probe.exitCode;
    }
}
