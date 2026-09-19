// brightness_probe.c — read/write the display brightness through DisplayServices (private).
//
// Low Power Mode dims the display on this hardware; the fix is to restore the previous brightness
// after toggling, so the app needs a programmatic read and write. This measures both, plus whether
// the write works unprivileged.
//
// Build: clang -framework Foundation -framework CoreGraphics -o brightness_probe brightness_probe.c

#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef int (*GetBrightnessFn)(CGDirectDisplayID, float *);
typedef int (*SetBrightnessFn)(CGDirectDisplayID, float);
typedef int (*CanChangeFn)(CGDirectDisplayID);

int main(int argc, char *argv[]) {
    setbuf(stdout, NULL);
    void *handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
    if (!handle) { printf("dlopen failed: %s\n", dlerror()); return 1; }

    GetBrightnessFn get = (GetBrightnessFn)dlsym(handle, "DisplayServicesGetBrightness");
    SetBrightnessFn set = (SetBrightnessFn)dlsym(handle, "DisplayServicesSetBrightness");
    CanChangeFn canChange = (CanChangeFn)dlsym(handle, "DisplayServicesCanChangeBrightness");

    CGDirectDisplayID display = CGMainDisplayID();
    printf("display %u  get=%s set=%s canChange=%s\n", (unsigned)display,
           get ? "yes" : "no", set ? "yes" : "no", canChange ? "yes" : "no");
    if (canChange) printf("canChangeBrightness: %s\n", canChange(display) ? "true" : "false");

    if (get) {
        float brightness = -1;
        int rc = get(display, &brightness);
        printf("current brightness: %.4f (rc=%d)\n", brightness, rc);
    }
    if (argc > 1 && set) {
        float target = (float)atof(argv[1]);
        int rc = set(display, target);
        printf("set %.4f → rc=%d\n", target, rc);
    }
    if (get) {
        float brightness = -1;
        get(display, &brightness);
        printf("brightness now: %.4f\n", brightness);
    }
    return 0;
}