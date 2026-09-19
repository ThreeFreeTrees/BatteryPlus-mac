// READ-ONLY probe: dlopen + dlsym ONLY. Never calls the functions.
#include <dlfcn.h>
#include <stdio.h>

int main(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    const char *names[] = {
        "IOPMSetEnergyModePreference",
        "IOPMFeatureIsAvailable",
        "IOPMSetPMPreference",
        "IOPSGetProvidingPowerSourceType",
    };
    for (int i = 0; i < 4; i++) {
        void *p = dlsym(h, names[i]);
        printf("%-32s dlsym -> %p%s\n", names[i], p, p ? "" : "  (NULL)");
    }
    return 0;
}
