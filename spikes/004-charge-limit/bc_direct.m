// bc_direct.m — can the charge limit be read and SET directly through PowerUI's private client?
//
// The class list is wide open: -currentChargeLimit:, -getMCLLimitWithError: and -setMCLLimit:error:
// ("MCL" = manual charge limit). If these answer an ordinary process, the whole UI-automation path
// is unnecessary. This tries, in order: find the designated init, create a client, read the limit,
// and — only with --write N — set it, then print the result so powerd's record can be checked
// from the shell.
//
// Build: clang -fno-objc-arc -framework Foundation -o bc_direct bc_direct.m

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static NSArray<NSString *> *methodNames(Class cls, BOOL classMethods) {
    Class target = classMethods ? object_getClass(cls) : cls;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(target, &count);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        [names addObject:[NSString stringWithUTF8String:sel_getName(method_getName(methods[i]))]];
    }
    free(methods);
    return names;
}

int main(int argc, const char *argv[]) {
    dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW);
    Class client = NSClassFromString(@"PowerUISmartChargeClient");
    if (!client) { printf("PowerUISmartChargeClient missing\n"); return 1; }

    NSArray<NSString *> *all = methodNames(client, NO);
    printf("total instance methods: %lu\n", (unsigned long)all.count);
    for (NSString *name in all) {
        if ([name hasPrefix:@"init"] || [name containsString:@"Client"] || [name containsString:@"client"]) {
            printf("   -%s\n", name.UTF8String);
        }
    }

    // build an instance: try the common initialisers in turn
    NSArray<NSString *> *inits = @[@"initWithClientName:", @"init"];
    id instance = nil;
    for (NSString *initName in inits) {
        SEL sel = NSSelectorFromString(initName);
        if (![client instancesRespondToSelector:sel]) continue;
        @try {
            id allocated = ((id (*)(id, SEL))objc_msgSend)((id)client, sel_registerName("alloc"));
            id candidate = nil;
            if ([initName isEqualToString:@"init"]) {
                candidate = ((id (*)(id, SEL))objc_msgSend)(allocated, sel);
            } else if ([initName isEqualToString:@"initWithClientName:"]) {
                candidate = ((id (*)(id, SEL, id))objc_msgSend)(allocated, sel, @"BatteryPlus");
            } else {
                candidate = ((id (*)(id, SEL, id, id))objc_msgSend)(allocated, sel, @"BatteryPlus", dispatch_get_main_queue());
            }
            if (candidate) { instance = candidate; printf("created client with -%s\n", initName.UTF8String); break; }
        } @catch (NSException *e) {
            printf("-%s threw: %s\n", initName.UTF8String, e.reason.UTF8String);
        }
    }
    if (!instance) { printf("could not create a client\n"); return 1; }

    // reads
    @try {
        SEL sel = NSSelectorFromString(@"getMCLLimitWithError:");
        if ([instance respondsToSelector:sel]) {
            NSError *error = nil;
            unsigned char (*call)(id, SEL, NSError **) = (void *)objc_msgSend;
            unsigned char limit = call(instance, sel, &error);
            printf("getMCLLimitWithError:      -> %u   error: %s\n", (unsigned)limit,
                   error ? error.localizedDescription.UTF8String : "none");
        }
        SEL currentSel = NSSelectorFromString(@"currentChargeLimit:");
        if ([instance respondsToSelector:currentSel]) {
            NSError *error = nil;
            unsigned long (*call)(id, SEL, NSError **) = (void *)objc_msgSend;
            unsigned long limit = call(instance, currentSel, &error);
            printf("currentChargeLimit:        -> %lu  error: %s\n", limit,
                   error ? error.localizedDescription.UTF8String : "none");
        }
        SEL uiSel = NSSelectorFromString(@"smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:");
        if ([instance respondsToSelector:uiSel]) {
            NSError *error = nil;
            unsigned long state = 0, limit = 0;
            BOOL allowed = NO;
            BOOL (*call)(id, SEL, unsigned long *, unsigned long *, BOOL *, NSError **) = (void *)objc_msgSend;
            BOOL ok = call(instance, uiSel, &state, &limit, &allowed, &error);
            printf("smartChargingUIState:      -> ok=%d state=%lu limit=%lu overrideAllowed=%d error: %s\n",
                   ok, state, limit, allowed, error ? error.localizedDescription.UTF8String : "none");
        }
    } @catch (NSException *e) {
        printf("read threw: %s\n", e.reason.UTF8String);
    }

    // write, only when asked
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--write") == 0) {
            unsigned char target = (unsigned char)atoi(argv[i + 1]);
            @try {
                SEL sel = NSSelectorFromString(@"setMCLLimit:error:");
                if (![instance respondsToSelector:sel]) { printf("setMCLLimit:error: not available\n"); break; }
                NSError *error = nil;
                BOOL (*call)(id, SEL, unsigned char, NSError **) = (void *)objc_msgSend;
                BOOL ok = call(instance, sel, target, &error);
                printf("setMCLLimit:%u error:      -> ok=%d error: %s\n", (unsigned)target, ok,
                       error ? error.localizedDescription.UTF8String : "none");
            } @catch (NSException *e) {
                printf("write threw: %s\n", e.reason.UTF8String);
            }
        }
    }
    return 0;
}