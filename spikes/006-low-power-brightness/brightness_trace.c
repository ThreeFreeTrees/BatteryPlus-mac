// brightness_trace.c — sample the display brightness every 80 ms for N seconds and print the series,
// so a Low Power Mode transition can be judged as a trajectory (does it bounce?) instead of an
// end state. Started in the background while the toggle happens.
//
// Build: clang -framework CoreGraphics -o brightness_trace brightness_trace.c

#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef int (*GetBrightnessFn)(CGDirectDisplayID, float *);

int main(int argc, char *argv[]) {
    setbuf(stdout, NULL);
    double seconds = argc > 1 ? atof(argv[1]) : 6.0;

    void *handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
    if (!handle) { printf("dlopen failed\n"); return 1; }
    GetBrightnessFn get = (GetBrightnessFn)dlsym(handle, "DisplayServicesGetBrightness");
    if (!get) { printf("no getter\n"); return 1; }

    CGDirectDisplayID display = CGMainDisplayID();
    int samples = (int)(seconds / 0.08);
    for (int i = 0; i < samples; i++) {
        float brightness = -1;
        if (get(display, &brightness) == 0) {
            printf("%6.3f %s\n", brightness, i % 10 == 0 ? "|" : "");
        }
        usleep(80000);
    }
    return 0;
}