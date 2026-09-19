// PowerUIChargeLimit.m — the Objective-C side of the direct charge-limit access.
//
// Swift cannot message an undeclared selector, so the objc_msgSend dance lives here behind three C
// functions. Everything is wrapped in @try/@catch and re-checks the class and selectors on every
// call: a private API that disappears must degrade to a code, never crash the app.
//
// Measured on macOS 27 (full evidence in spikes/004-charge-limit/README.md):
//   getMCLLimitWithError:            -> the real limit (80)
//   setMCLLimit:error:               -> ok, and the system then holds charging at the new value
//   availableChargeLimitsWithError:  -> (80, 85, 90, 95, 100)

#import "PowerUIChargeLimit.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static const char *const kFrameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI";
static NSString *const kClientName = @"BatteryPlus";

/// The class, loaded once. Nil ⇒ this build has no such API (callers get code 1).
static Class BMClientClass(void) {
    static Class clientClass = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen(kFrameworkPath, RTLD_NOW);
        clientClass = NSClassFromString(@"PowerUISmartChargeClient");
    });
    return clientClass;
}

/// A fresh client per call: each one opens its own XPC connection to powerd, which keeps a stale
/// connection from a long-running app from silently answering with defaults.
static id BMNewClient(void) {
    Class cls = BMClientClass();
    if (!cls) return nil;
    @try {
        SEL allocSel = sel_registerName("alloc");
        SEL initSel = sel_registerName("initWithClientName:");
        if (![cls respondsToSelector:allocSel]) return nil;
        id allocated = ((id (*)(id, SEL))objc_msgSend)((id)cls, allocSel);
        if (![allocated respondsToSelector:initSel]) return nil;
        return ((id (*)(id, SEL, id))objc_msgSend)(allocated, initSel, kClientName);
    } @catch (NSException *exception) {
        return nil;
    }
}

int bm_charge_limit_read(int *outLimit) {
    id client = BMNewClient();
    if (!client) return 1;
    @try {
        SEL sel = NSSelectorFromString(@"getMCLLimitWithError:");
        if (![client respondsToSelector:sel]) return 1;
        NSError *error = nil;
        unsigned char (*call)(id, SEL, NSError **) = (void *)objc_msgSend;
        unsigned char limit = call(client, sel, &error);
        if (error) return 2;
        if (outLimit) *outLimit = (int)limit;
        return 0;
    } @catch (NSException *exception) {
        return 2;
    }
}

int bm_charge_limit_write(int limit) {
    if (limit < 0 || limit > 100) return 3;
    id client = BMNewClient();
    if (!client) return 1;
    @try {
        SEL sel = NSSelectorFromString(@"setMCLLimit:error:");
        if (![client respondsToSelector:sel]) return 1;
        NSError *error = nil;
        BOOL (*call)(id, SEL, unsigned char, NSError **) = (void *)objc_msgSend;
        BOOL ok = call(client, sel, (unsigned char)limit, &error);
        if (!ok || error) return 2;
        return 0;
    } @catch (NSException *exception) {
        return 2;
    }
}

int bm_charge_limit_available(int *outValues, int capacity, int *outCount) {
    id client = BMNewClient();
    if (!client) return 1;
    @try {
        SEL sel = NSSelectorFromString(@"availableChargeLimitsWithError:");
        if (![client respondsToSelector:sel]) return 1;
        NSError *error = nil;
        NSArray *values = ((id (*)(id, SEL, NSError **))objc_msgSend)(client, sel, &error);
        if (error || ![values isKindOfClass:[NSArray class]]) return 2;
        int count = 0;
        for (id value in values) {
            if (![value isKindOfClass:[NSNumber class]]) continue;
            if (count < capacity && outValues) outValues[count] = [value intValue];
            count++;
        }
        if (outCount) *outCount = count;
        return 0;
    } @catch (NSException *exception) {
        return 2;
    }
}