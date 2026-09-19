// READ-ONLY: dlopen + dlsym + memcpy of the function's code bytes.
// The target function is NEVER called; no state is modified.
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

static void dump(const char *name, void *p, int nwords) {
    printf("### %s @ %p\n", name, p);
    for (int i = 0; i < nwords; i++) {
        uint32_t w; memcpy(&w, (const char *)p + i * 4, 4);
        printf("0x%08x\n", w);
    }
}

int main(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    void *a = dlsym(h, "IOPMSetEnergyModePreference");
    void *b = dlsym(h, "IOPMFeatureIsAvailable");
    if (a) dump("IOPMSetEnergyModePreference", a, 48);
    if (b) dump("IOPMFeatureIsAvailable", b, 24);
    return 0;
}
