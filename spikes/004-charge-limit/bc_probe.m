// bc_probe.m — what does the private charging API actually expose to a non-Apple process?
//
// PowerUI.framework loads and the charging classes resolve, so the question is no longer "is the API
// there" but "which calls work from an ordinary process". This dumps the real method signatures and
// then tries the reads and (only if asked) the writes.
//
// Build: clang -fno-objc-arc -framework Foundation -o bc_probe bc_probe.m

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void dumpMethods(Class cls, BOOL classMethods, const char *needle) {
    Class target = classMethods ? object_getClass(cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    printf("%s %s methods containing \"%s\":\n", class_getName(cls), classMethods ? "CLASS" : "instance", needle);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (strcasestr(name, needle)) {
            printf("    %s%s   [%s]\n", classMethods ? "+" : "-", name,
                   method_getTypeEncoding(methods[i]));
        }
    }
    free(methods);
}

int main(int argc, const char *argv[]) {
    void *powerUI = dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW);
    printf("PowerUI loaded: %s\n\n", powerUI ? "yes" : dlerror());

    Class smart = NSClassFromString(@"PowerUISmartChargeClient");
    Class controller = NSClassFromString(@"CBController");
    Class info = NSClassFromString(@"CBControllerInfo");
    printf("classes: smartChargeClient=%s controller=%s info=%s\n\n",
           smart ? "yes" : "no", controller ? "yes" : "no", info ? "yes" : "no");

    if (smart) {
        dumpMethods(smart, YES, "harg");
        dumpMethods(smart, YES, "imit");
        dumpMethods(smart, NO, "harg");
        dumpMethods(smart, NO, "imit");
    }
    if (controller) {
        printf("\n");
        dumpMethods(controller, YES, "harg");
        dumpMethods(controller, YES, "imit");
        dumpMethods(controller, NO, "harg");
        dumpMethods(controller, NO, "imit");
    }
    if (info) {
        printf("\nCBControllerInfo instance properties:\n");
        unsigned int pcount = 0;
        objc_property_t *props = class_copyPropertyList(info, &pcount);
        for (unsigned int i = 0; i < pcount; i++) {
            const char *name = property_getName(props[i]);
            if (strcasestr(name, "charge") || strcasestr(name, "limit") || strcasestr(name, "hold")) {
                printf("    %s\n", name);
            }
        }
        free(props);
    }
    return 0;
}