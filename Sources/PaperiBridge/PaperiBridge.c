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
int paperi_space_type(uint64_t space) {
    int cid = connection();
    int (*fn)(int, uint64_t) = sky ? dlsym(sky, "SLSSpaceGetType") : NULL;
    return cid && fn && space ? fn(cid, space) : -1;
}
uint64_t paperi_active_space(void) {
    int cid = connection();
    uint64_t (*fn)(int) = sky ? dlsym(sky, "SLSGetActiveSpace") : NULL;
    return cid && fn ? fn(cid) : 0;
}

// MARK: MultitouchSupport
//
// FRAGILE: MultitouchSupport is private and undocumented. The record layout
// below was found by inspection and verified on macOS 26.7.2 (arm64) on
// 2026-11-10; any macOS update may change it. Missing symbols make
// paperi_mt_start return 0 (no blocking). A changed layout gives wrong counts:
// app gestures leak during swipes, or two-finger scrolling is withheld.
// Re-verify after OS updates (README: "Trackpad swipe and blocking app gestures").

#include <stdatomic.h>

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, void *, int, double, int);

// Per-contact record layout (stride 96); `state` is at offset 20.
// States 3 (make touch) and 4 (touching) are fingers on the surface.
enum { MT_STRIDE = 96, MT_STATE_OFFSET = 20, MT_MAX_DEVICES = 8 };

static pthread_mutex_t mt_mutex = PTHREAD_MUTEX_INITIALIZER;
static void *mt_lib;
static CFArrayRef mt_list;
static MTDeviceRef mt_devices[MT_MAX_DEVICES];
static _Atomic int mt_down[MT_MAX_DEVICES];
static _Atomic int mt_device_count;

static int mt_contacts(MTDeviceRef device, void *contacts, int count, double timestamp, int frame) {
    (void)timestamp; (void)frame;
    int down = 0;
    for (int i = 0; i < count; i++) {
        int state = *(int *)((char *)contacts + (size_t)i * MT_STRIDE + MT_STATE_OFFSET);
        if (state == 3 || state == 4) down++;
    }
    int n = atomic_load(&mt_device_count);
    for (int i = 0; i < n; i++) {
        if (mt_devices[i] == device) { atomic_store(&mt_down[i], down); break; }
    }
    return 0;
}

int paperi_mt_start(void) {
    pthread_mutex_lock(&mt_mutex);
    int n = atomic_load(&mt_device_count);
    if (n > 0) { pthread_mutex_unlock(&mt_mutex); return n; }
    if (!mt_lib) mt_lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY | RTLD_LOCAL);
    CFMutableArrayRef (*create_list)(void) = mt_lib ? dlsym(mt_lib, "MTDeviceCreateList") : NULL;
    void (*reg)(MTDeviceRef, MTContactCallback) = mt_lib ? dlsym(mt_lib, "MTRegisterContactFrameCallback") : NULL;
    int (*start)(MTDeviceRef, int) = mt_lib ? dlsym(mt_lib, "MTDeviceStart") : NULL;
    if (!create_list || !reg || !start) { pthread_mutex_unlock(&mt_mutex); return 0; }
    CFArrayRef list = create_list();
    if (!list) { pthread_mutex_unlock(&mt_mutex); return 0; }
    CFIndex total = CFArrayGetCount(list);
    n = 0;
    for (CFIndex i = 0; i < total && n < MT_MAX_DEVICES; i++) {
        mt_devices[n] = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        atomic_store(&mt_down[n], 0);
        n++;
    }
    atomic_store(&mt_device_count, n);
    for (int i = 0; i < n; i++) {
        reg(mt_devices[i], mt_contacts);
        start(mt_devices[i], 0);
    }
    mt_list = list;
    pthread_mutex_unlock(&mt_mutex);
    return n;
}

void paperi_mt_stop(void) {
    pthread_mutex_lock(&mt_mutex);
    int n = atomic_load(&mt_device_count);
    void (*unreg)(MTDeviceRef, MTContactCallback) = mt_lib ? dlsym(mt_lib, "MTUnregisterContactFrameCallback") : NULL;
    void (*stop)(MTDeviceRef) = mt_lib ? dlsym(mt_lib, "MTDeviceStop") : NULL;
    for (int i = 0; i < n; i++) {
        if (unreg) unreg(mt_devices[i], mt_contacts);
        if (stop) stop(mt_devices[i]);
    }
    atomic_store(&mt_device_count, 0);
    for (int i = 0; i < MT_MAX_DEVICES; i++) { mt_devices[i] = NULL; atomic_store(&mt_down[i], 0); }
    if (mt_list) { CFRelease(mt_list); mt_list = NULL; }
    pthread_mutex_unlock(&mt_mutex);
}

int paperi_mt_fingers_down(void) {
    int n = atomic_load(&mt_device_count), sum = 0;
    for (int i = 0; i < n; i++) sum += atomic_load(&mt_down[i]);
    return sum;
}
