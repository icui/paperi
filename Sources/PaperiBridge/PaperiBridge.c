#include "PaperiBridge.h"
#include <dlfcn.h>
#include <pthread.h>
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void *sky;
static void load(void) { sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL); }
static int connection(void) {
    pthread_once(&once, load);
    int (*fn)(void) = sky ? dlsym(sky, "SLSMainConnectionID") : NULL;
    return fn ? fn() : 0;
}
uint32_t paperi_window_id(AXUIElementRef element) {
    AXError (*fn)(AXUIElementRef, uint32_t *) = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    uint32_t wid = 0;
    return fn && fn(element, &wid) == kAXErrorSuccess ? wid : 0;
}
CFArrayRef paperi_copy_display_spaces(void) {
    int cid = connection();
    CFArrayRef (*fn)(int) = sky ? dlsym(sky, "SLSCopyManagedDisplaySpaces") : NULL;
    return cid && fn ? fn(cid) : NULL;
}
CFArrayRef paperi_copy_window_spaces(uint32_t window) {
    int cid = connection();
    CFArrayRef (*fn)(int, int, CFArrayRef) = sky ? dlsym(sky, "SLSCopySpacesForWindows") : NULL;
    if (!cid || !fn || !window) return NULL;
    int64_t value = window;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
    const void *values[] = { number };
    CFArrayRef windows = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    CFArrayRef result = fn(cid, 7, windows);
    CFRelease(windows); CFRelease(number);
    return result;
}
