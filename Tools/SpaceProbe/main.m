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

// ---------------------------------------------------------------------------
// Input-driven backends (schema 3). Both act only on this probe's own window.
// `mission-control` follows installed PaperWM.spoon's Mission Control drag
// (f86f76b, mission_control.lua; MIT). `drag-switch` holds the probe window's
// title bar while posting the user's configured "Move left/right a space"
// symbolic hotkey. Every synthetic mouse-down is preceded by a window-list check
// that the topmost visible window under the point is the probe window, and every
// exit path releases a held button and restores the cursor position.
// ---------------------------------------------------------------------------

static uint64_t (*activeSpace)(int);
static BOOL buttonHeld;
static CGPoint heldPoint;
static CGPoint originalCursor;
static BOOL cursorSaved;

static void after(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static void postMouse(CGEventType type, CGPoint point) {
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, point, kCGMouseButtonLeft);
    if (!event) return;
    if (type != kCGEventMouseMoved) CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    if (type == kCGEventLeftMouseDown) { buttonHeld = YES; heldPoint = point; }
    if (type == kCGEventLeftMouseDragged) heldPoint = point;
    if (type == kCGEventLeftMouseUp) buttonHeld = NO;
}

static void releaseHeldButton(void) {
    if (buttonHeld) postMouse(kCGEventLeftMouseUp, heldPoint);
}

static void postKey(CGKeyCode code, CGEventFlags flags) {
    for (int down = 1; down >= 0; down--) {
        CGEventRef event = CGEventCreateKeyboardEvent(NULL, code, down);
        if (!event) return;
        CGEventSetFlags(event, flags);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
}

static CGPoint currentCursor(void) {
    CGEventRef event = CGEventCreate(NULL);
    CGPoint point = event ? CGEventGetLocation(event) : CGPointZero;
    if (event) CFRelease(event);
    return point;
}

// Global top-left (CG/AX) coordinates for an AppKit rect.
static CGRect cgRect(NSRect rect) {
    CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
    return CGRectMake(rect.origin.x, primaryHeight - NSMaxY(rect), rect.size.width, rect.size.height);
}

static uint32_t topmostWindowAt(CGPoint point) {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *info in list) { // front to back
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &bounds)) continue;
        if (!CGRectContainsPoint(bounds, point)) continue;
        if ([info[(id)kCGWindowAlpha] doubleValue] <= 0) continue;
        return [info[(id)kCGWindowNumber] unsignedIntValue];
    }
    return 0;
}

// Reads the user's configured chord; never writes preferences.
static BOOL symbolicHotKey(int identifier, CGKeyCode *code, CGEventFlags *flags, NSMutableDictionary *report) {
    NSDictionary *all = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("AppleSymbolicHotKeys"), CFSTR("com.apple.symbolichotkeys")));
    NSDictionary *entry = [all isKindOfClass:NSDictionary.class] ? all[[@(identifier) stringValue]] : nil;
    if (!entry) {
        // macOS defaults: Control-Left/Right with the function-key flag arrows carry.
        *code = identifier == 79 ? 123 : 124;
        *flags = (CGEventFlags)0x840000;
        report[@"hotKeySource"] = @"systemDefault";
        return YES;
    }
    report[@"hotKeySource"] = @"userPreferences";
    if (![entry[@"enabled"] boolValue]) return NO;
    NSArray *parameters = entry[@"value"][@"parameters"];
    if (![parameters isKindOfClass:NSArray.class] || parameters.count < 3) return NO;
    *code = (CGKeyCode)[parameters[1] unsignedIntValue];
    *flags = (CGEventFlags)[parameters[2] unsignedLongLongValue];
    return *code != 0xFFFF;
}

static id axValue(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return nil;
    return CFBridgingRelease(value);
}

static NSArray *axChildrenWithIdentifier(AXUIElementRef element, NSString *identifier) {
    NSMutableArray *matches = [NSMutableArray new];
    for (id child in axValue(element, kAXChildrenAttribute) ?: @[]) {
        if ([axValue((__bridge AXUIElementRef)child, CFSTR("AXIdentifier")) isEqual:identifier]) [matches addObject:child];
    }
    return matches;
}

static BOOL axCenter(id element, CGPoint *center) {
    id value = axValue((__bridge AXUIElementRef)element, CFSTR("AXFrame"));
    CGRect frame;
    if (!value || !AXValueGetValue((__bridge AXValueRef)value, kAXValueTypeCGRect, &frame)) return NO;
    *center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    return YES;
}

static id missionControlGroup(void) {
    NSRunningApplication *dock = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"].firstObject;
    if (!dock) return nil;
    AXUIElementRef app = AXUIElementCreateApplication(dock.processIdentifier);
    id group = axChildrenWithIdentifier(app, @"mc").firstObject;
    CFRelease(app);
    return group;
}

@interface Probe : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@property(strong) NSMutableDictionary *report;
@property(copy) NSString *backend;
@property(copy) NSString *title;
@property uint64_t source;
@property uint64_t destination;
@property BOOL destinationIsRight;
@property int exitCode;
@end

@implementation Probe
- (void)finish:(NSString *)result reason:(NSString *)reason {
    releaseHeldButton();
    if (cursorSaved) CGWarpMouseCursorPosition(originalCursor);
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
- (void)waitForMissionControl:(int)remaining completion:(void (^)(id))completion {
    id group = missionControlGroup();
    if (group || remaining == 0) { completion(group); return; }
    after(0.1, ^{ [self waitForMissionControl:remaining - 1 completion:completion]; });
}
- (void)missionControlLegTo:(uint64_t)sid leg:(NSMutableDictionary *)leg completion:(void (^)(BOOL))completion {
    NSURL *app = [NSURL fileURLWithPath:@"/System/Applications/Mission Control.app"];
    [NSWorkspace.sharedWorkspace openApplicationAtURL:app configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
    [self waitForMissionControl:30 completion:^(id group) {
        leg[@"missionControlOpened"] = @(group != nil);
        if (!group) { completion(NO); return; }
        // Hovering the top edge expands the Spaces bar, as in PaperWM.
        CGRect screen = cgRect(self.window.screen.frame);
        postMouse(kCGEventMouseMoved, CGPointMake(screen.origin.x + 10, screen.origin.y + 10));
        after(0.8, ^{ [self dragInMissionControlTo:sid leg:leg completion:completion]; });
    }];
}
- (void)dragInMissionControlTo:(uint64_t)sid leg:(NSMutableDictionary *)leg completion:(void (^)(BOOL))completion {
    void (^abort)(NSString *) = ^(NSString *why) {
        leg[@"failure"] = why;
        postKey(53, 0); // Escape closes Mission Control without choosing a Space.
        after(0.8, ^{ completion(NO); });
    };
    id group = missionControlGroup();
    if (!group) { abort(@"Mission Control closed before the drag"); return; }
    // Titles of other windows are compared in memory only and never recorded.
    id windowElement = nil, displayGroup = nil;
    for (id display in axChildrenWithIdentifier((__bridge AXUIElementRef)group, @"mc.display")) {
        for (id list in axChildrenWithIdentifier((__bridge AXUIElementRef)display, @"mc.windows")) {
            for (id candidate in axValue((__bridge AXUIElementRef)list, kAXChildrenAttribute) ?: @[]) {
                if ([axValue((__bridge AXUIElementRef)candidate, kAXTitleAttribute) isEqual:self.title]) {
                    if (windowElement) { abort(@"Probe title matched more than one Mission Control window"); return; }
                    windowElement = candidate; displayGroup = display;
                }
            }
        }
    }
    if (!windowElement) { abort(@"Probe window not found in Mission Control"); return; }
    CFArrayRef names = NULL;
    if (AXUIElementCopyAttributeNames((__bridge AXUIElementRef)windowElement, &names) == kAXErrorSuccess && names) {
        leg[@"windowElementAttributes"] = CFBridgingRelease(names);
    }
    NSArray *thumbnails = @[];
    for (id spaces in axChildrenWithIdentifier((__bridge AXUIElementRef)displayGroup, @"mc.spaces")) {
        for (id list in axChildrenWithIdentifier((__bridge AXUIElementRef)spaces, @"mc.spaces.list")) {
            thumbnails = axValue((__bridge AXUIElementRef)list, kAXChildrenAttribute) ?: @[];
        }
    }
    NSArray *displaySpaces = topology(sid)[@"Spaces"];
    NSUInteger index = [[displaySpaces valueForKey:@"ManagedSpaceID"] indexOfObject:@(sid)];
    leg[@"spaceThumbnailCount"] = @(thumbnails.count);
    leg[@"displaySpaceCount"] = @(displaySpaces.count);
    // Never guess a thumbnail when Mission Control and WindowServer disagree.
    if (index == NSNotFound || thumbnails.count != displaySpaces.count) { abort(@"Space thumbnail order unverified"); return; }
    CGPoint start, end;
    if (!axCenter(windowElement, &start) || !axCenter(thumbnails[index], &end)) { abort(@"Mission Control frame unavailable"); return; }
    // The collapsed Spaces bar leaves thumbnails above the screen. Hover the top
    // edge over the destination and re-read until its thumbnail is on screen.
    CGRect screen = cgRect(self.window.screen.frame);
    int attempts = [leg[@"thumbnailExpandAttempts"] intValue];
    leg[@"collapsedThumbnailCenter"] = leg[@"collapsedThumbnailCenter"] ?: @[@(end.x), @(end.y)];
    if (end.y < screen.origin.y + 8) {
        if (attempts >= 5) { abort(@"Spaces bar did not expand"); return; }
        leg[@"thumbnailExpandAttempts"] = @(attempts + 1);
        postMouse(kCGEventMouseMoved, CGPointMake(end.x, screen.origin.y + 4));
        after(0.1, ^{ postMouse(kCGEventMouseMoved, CGPointMake(end.x + 2, screen.origin.y)); });
        after(0.8, ^{ [self dragInMissionControlTo:sid leg:leg completion:completion]; });
        return;
    }
    // Wait for the bar expansion animation to settle and re-read both frames.
    if (![leg[@"barExpansionSettled"] boolValue]) {
        leg[@"barExpansionSettled"] = @YES;
        after(0.45, ^{ [self dragInMissionControlTo:sid leg:leg completion:completion]; });
        return;
    }
    NSMutableArray *centers = [NSMutableArray new];
    for (id thumbnail in thumbnails) {
        CGPoint center;
        [centers addObject:axCenter(thumbnail, &center) ? @[@(center.x), @(center.y)] : (id)NSNull.null];
    }
    leg[@"thumbnailCenters"] = centers;
    leg[@"displaySpaceIDs"] = [displaySpaces valueForKey:@"ManagedSpaceID"] ?: @[];
    leg[@"destinationIndex"] = @(index);
    if (CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft)) { abort(@"Physical mouse button held"); return; }
    postMouse(kCGEventMouseMoved, start);
    after(0.15, ^{
        postMouse(kCGEventLeftMouseDown, start);
        for (int step = 1; step <= 14; step++) {
            after(0.04 * step, ^{
                CGFloat t = step / 14.0;
                postMouse(kCGEventLeftMouseDragged, CGPointMake(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t));
            });
        }
        after(0.7, ^{
            // Re-read the destination thumbnail while dragging: dragging near the
            // Spaces bar can shift thumbnail positions on a second Mission Control entry.
            CGPoint drop = end;
            axCenter(thumbnails[index], &drop);
            postMouse(kCGEventLeftMouseDragged, drop);
            after(0.45, ^{
                postMouse(kCGEventLeftMouseUp, drop);
                leg[@"dragPosted"] = @YES;
                leg[@"dragStart"] = @[@(start.x), @(start.y)];
                leg[@"dragEnd"] = @[@(drop.x), @(drop.y)];
                // Clicking the destination thumbnail follows the window, as in PaperWM.
                after(0.6, ^{
                    CGPoint click = drop;
                    axCenter(thumbnails[index], &click);
                    leg[@"membershipAfterDrop"] = membership((uint32_t)self.window.windowNumber) ?: (id)NSNull.null;
                    leg[@"missionControlOpenBeforeClick"] = @(missionControlGroup() != nil);
                    postMouse(kCGEventMouseMoved, click);
                    after(0.05, ^{ postMouse(kCGEventLeftMouseDown, click); });
                    after(0.13, ^{ postMouse(kCGEventLeftMouseUp, click); });
                    after(1.3, ^{
                        BOOL stillOpen = missionControlGroup() != nil;
                        leg[@"missionControlOpenAfterClick"] = @(stillOpen);
                        if (stillOpen) postKey(53, 0);
                        after(stillOpen ? 0.8 : 0, ^{ [self poll:sid remaining:30 completion:completion]; });
                    });
                });
            });
        });
    });
}
- (void)dragSwitchLegTo:(uint64_t)sid right:(BOOL)right leg:(NSMutableDictionary *)leg completion:(void (^)(BOOL))completion {
    CGKeyCode code; CGEventFlags flags;
    BOOL available = symbolicHotKey(right ? 81 : 79, &code, &flags, leg);
    leg[@"hotKeyAvailable"] = @(available);
    if (!available) { leg[@"failure"] = @"Move-a-space shortcut disabled"; completion(NO); return; }
    leg[@"hotKey"] = @{@"keyCode": @(code), @"flags": @(flags)};
    [NSApp activate];
    [self.window makeKeyAndOrderFront:nil];
    after(0.6, ^{
        CGRect frame = cgRect(self.window.frame);
        CGPoint grab = CGPointMake(CGRectGetMidX(frame), frame.origin.y + 12);
        uint32_t top = topmostWindowAt(grab);
        leg[@"topmostWindowAtGrab"] = @(top);
        leg[@"grabVerified"] = @(top == (uint32_t)self.window.windowNumber);
        if (top != (uint32_t)self.window.windowNumber) { leg[@"failure"] = @"Probe title bar is not topmost"; completion(NO); return; }
        if (CGEventSourceButtonState(kCGEventSourceStateHIDSystemState, kCGMouseButtonLeft)) {
            leg[@"failure"] = @"Physical mouse button held"; completion(NO); return;
        }
        postMouse(kCGEventMouseMoved, grab);
        after(0.1, ^{
            postMouse(kCGEventLeftMouseDown, grab);
            after(0.15, ^{ postMouse(kCGEventLeftMouseDragged, CGPointMake(grab.x + 4, grab.y)); });
            after(0.25, ^{ postMouse(kCGEventLeftMouseDragged, CGPointMake(grab.x + 8, grab.y)); });
            after(0.45, ^{ postKey(code, flags); leg[@"hotKeyPosted"] = @YES; });
            after(1.65, ^{
                postMouse(kCGEventLeftMouseUp, heldPoint);
                after(0.4, ^{ [self poll:sid remaining:30 completion:completion]; });
            });
        });
    });
}
- (void)runInputLegTo:(uint64_t)sid right:(BOOL)right name:(NSString *)name completion:(void (^)(BOOL))completion {
    NSMutableDictionary *leg = [NSMutableDictionary new];
    self.report[name] = leg;
    leg[@"activeSpaceBefore"] = activeSpace ? @(activeSpace(connection)) : (id)NSNull.null;
    void (^done)(BOOL) = ^(BOOL confirmed) {
        leg[@"membershipConfirmed"] = @(confirmed);
        leg[@"membershipAfter"] = membership((uint32_t)self.window.windowNumber) ?: (id)NSNull.null;
        leg[@"activeSpaceAfter"] = activeSpace ? @(activeSpace(connection)) : (id)NSNull.null;
        completion(confirmed);
    };
    if ([self.backend isEqual:@"mission-control"]) [self missionControlLegTo:sid leg:leg completion:done];
    else [self dragSwitchLegTo:sid right:right leg:leg completion:done];
}
- (void)runInputBackend {
    if (!AXIsProcessTrusted()) { [self finish:@"unsupported" reason:@"Accessibility trust required to post input and read Mission Control"]; return; }
    originalCursor = currentCursor();
    cursorSaved = YES;
    after(45, ^{ [self finish:@"failed" reason:@"Watchdog expired"]; });
    [self runInputLegTo:self.destination right:self.destinationIsRight name:@"outbound" completion:^(BOOL moved) {
        if (!moved) { [self finish:@"failed" reason:@"Outbound membership not observed; return not attempted"]; return; }
        [self runInputLegTo:self.source right:!self.destinationIsRight name:@"return" completion:^(BOOL restored) {
            [self finish:restored ? @"passed" : @"failed"
                  reason:@"Transfer requires observed destination and restored source membership"];
        }];
    }];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSArray *arguments = NSProcessInfo.processInfo.arguments;
    NSUInteger flag = [arguments indexOfObject:@"--backend"];
    self.backend = flag != NSNotFound && flag + 1 < arguments.count ? arguments[flag + 1] : @"skylight";
    BOOL input = [self.backend isEqual:@"mission-control"] || [self.backend isEqual:@"drag-switch"];
    self.report = [@{@"schemaVersion": @3, @"backendRequested": self.backend,
                    @"scope": input ? @"Own disposable window; synthetic input targets only this window and follows it to the destination Space and back"
                                    : @"Own disposable window; membership round trip only, no Space activation or focus changes",
                    @"os": NSProcessInfo.processInfo.operatingSystemVersionString} mutableCopy];
    if (!input && ![self.backend isEqual:@"skylight"]) {
        [self finish:@"unsupported" reason:@"--backend must be skylight, mission-control or drag-switch"]; return;
    }
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    int (*mainConnection)(void) = sky ? dlsym(sky, "SLSMainConnectionID") : NULL;
    copySpaces = sky ? dlsym(sky, "SLSCopySpacesForWindows") : NULL;
    copyDisplays = sky ? dlsym(sky, "SLSCopyManagedDisplaySpaces") : NULL;
    spaceType = sky ? dlsym(sky, "SLSSpaceGetType") : NULL;
    activeSpace = sky ? dlsym(sky, "SLSGetActiveSpace") : NULL;
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
    // A unique title lets Mission Control identify only this probe's window.
    self.title = [@"Paperi disposable Space probe " stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:8]];
    self.window.title = self.title;
    [self.window orderFrontRegardless];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        uint32_t wid = (uint32_t)self.window.windowNumber;
        NSArray *before = membership(wid);
        self.report[@"before"] = before ?: (id)NSNull.null;
        if (before.count != 1) { [self finish:@"unsupported" reason:@"Initial membership is not one Space"]; return; }
        self.source = [before.firstObject unsignedLongLongValue];
        NSDictionary *display = topology(self.source);
        NSArray *displaySpaces = display[@"Spaces"];
        NSMutableArray *userSpaces = [NSMutableArray new];
        for (NSDictionary *space in displaySpaces) {
            uint64_t sid = [space[@"ManagedSpaceID"] unsignedLongLongValue];
            if (sid && spaceType(connection, sid) == 0) {
                [userSpaces addObject:@(sid)];
                if ((!input || [self.backend isEqual:@"mission-control"]) && sid != self.source && !self.destination) self.destination = sid;
            }
        }
        if ([self.backend isEqual:@"drag-switch"]) {
            // Move-a-space shortcuts reach only the immediate neighbor, which must be a user Space.
            NSUInteger index = [[displaySpaces valueForKey:@"ManagedSpaceID"] indexOfObject:@(self.source)];
            for (NSNumber *offset in @[@1, @-1]) {
                NSInteger neighbor = (NSInteger)index + offset.integerValue;
                if (index == NSNotFound || neighbor < 0 || neighbor >= (NSInteger)displaySpaces.count) continue;
                uint64_t sid = [displaySpaces[neighbor][@"ManagedSpaceID"] unsignedLongLongValue];
                if (sid && spaceType(connection, sid) == 0) { self.destination = sid; self.destinationIsRight = offset.integerValue > 0; break; }
            }
        }
        self.report[@"sourceDisplayFound"] = @(display != nil);
        self.report[@"sourceDisplayUserSpaces"] = userSpaces;
        NSMutableArray *order = [NSMutableArray new];
        for (NSDictionary *space in displaySpaces) {
            uint64_t sid = [space[@"ManagedSpaceID"] unsignedLongLongValue];
            [order addObject:@{@"id": @(sid), @"type": @(spaceType(connection, sid))}];
        }
        self.report[@"sourceDisplaySpaceOrder"] = order;
        int sourceType = spaceType(connection, self.source);
        self.report[@"sourceSpaceType"] = @(sourceType);
        if (sourceType != 0) {
            [self finish:@"unsupported" reason:@"Source is not a user Space; rerun from a normal desktop"]; return;
        }
        if (!self.destination) {
            [self finish:@"unsupported" reason:[self.backend isEqual:@"drag-switch"] ? @"Need an adjacent user Space on the source display"
                                                     : @"Need two existing user Spaces on the source display"]; return;
        }
        self.report[@"destination"] = @(self.destination);
        if ([self.backend isEqual:@"drag-switch"]) {
            CGKeyCode code; CGEventFlags flags;
            NSMutableDictionary *hotKeys = [NSMutableDictionary new];
            BOOL left = symbolicHotKey(79, &code, &flags, hotKeys);
            BOOL right = symbolicHotKey(81, &code, &flags, hotKeys);
            self.report[@"moveSpaceHotKeys"] = @{@"moveLeftEnabled": @(left), @"moveRightEnabled": @(right),
                                                 @"source": hotKeys[@"hotKeySource"] ?: @"unknown"};
            if (!left || !right) {
                [self finish:@"unsupported" reason:@"System Move-left/right-a-space shortcuts are disabled"]; return;
            }
        }
        if (input) { [self runInputBackend]; return; }
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
