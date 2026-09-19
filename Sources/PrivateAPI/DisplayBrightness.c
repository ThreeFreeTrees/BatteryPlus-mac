// DisplayBrightness.c — DisplayServices (private) behind two plain C calls.
//
// Everything is resolved at runtime: the framework lives only in the dyld shared cache, so there is
// nothing to link against, and a future build that drops a symbol must degrade to a failure value
// rather than crash the app.

#include "DisplayBrightness.h"
#include <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>

typedef int (*GetBrightnessFn)(CGDirectDisplayID, float *);
typedef int (*SetBrightnessFn)(CGDirectDisplayID, float);

static const char *const kDisplayServicesPath =
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices";

static GetBrightnessFn loadGetter(void) {
    static GetBrightnessFn getter = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen(kDisplayServicesPath, RTLD_NOW);
        if (handle) getter = (GetBrightnessFn)dlsym(handle, "DisplayServicesGetBrightness");
    });
    return getter;
}

static SetBrightnessFn loadSetter(void) {
    static SetBrightnessFn setter = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen(kDisplayServicesPath, RTLD_NOW);
        if (handle) setter = (SetBrightnessFn)dlsym(handle, "DisplayServicesSetBrightness");
    });
    return setter;
}

float bm_display_brightness(void) {
    GetBrightnessFn getter = loadGetter();
    if (!getter) return -1.0f;
    float brightness = -1.0f;
    if (getter(CGMainDisplayID(), &brightness) != 0) return -1.0f;
    return brightness;
}

int bm_set_display_brightness(float value) {
    SetBrightnessFn setter = loadSetter();
    if (!setter) return 1;
    if (value < 0.0f) value = 0.0f;
    if (value > 1.0f) value = 1.0f;
    return setter(CGMainDisplayID(), value) == 0 ? 0 : 2;
}