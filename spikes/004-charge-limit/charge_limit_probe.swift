// charge_limit_probe — what can we actually ask the system about the battery charge limit?
//
// Control Center references:
//     smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:
//     Charge to Full Now / charge to full now / charge to full failed
//     CBController, CBConnection, CBClient, CBControllerInfo, OBCController, manualChargeLimitState
// Those live in private frameworks, so ask the ObjC runtime what actually exists.
//
// Lessons that shaped this file:
//   * do NOT walk objc_copyClassList and touch every class — one class in this runtime aborts the
//     process the moment it is touched. Use objc_copyClassNamesForImage() to ask for one image's
//     classes by name, then NSClassFromString() them.
//   * stdout is block-buffered when piped; setbuf(stdout, nil) or a crash eats every print.
//
// Usage: charge_limit_probe [framework path]

import Foundation
import Darwin
import ObjectiveC

setbuf(stdout, nil)

let frameworkPaths = [
    "/System/Library/PrivateFrameworks/BatteryUIKit.framework/Versions/A/BatteryUIKit",
    "/System/Library/PrivateFrameworks/BatteryCenter.framework/Versions/A/BatteryCenter",
    "/System/Library/PrivateFrameworks/BatteryCenterUI.framework/Versions/A/BatteryCenterUI",
]

// Selectors worth surfacing; the interesting ones are about the charge limit and the adapter.
let interesting = ["charge", "limit", "smartcharging", "obc", "override", "plugged",
                   "full", "adapter", "power"]

let wanted = CommandLine.arguments.count > 1 ? [CommandLine.arguments[1]] : frameworkPaths

for path in wanted {
    guard let handle = dlopen(path, RTLD_NOW) else {
        print("!! could not load \(path): \(String(cString: dlerror()))")
        continue
    }
    let imageName = path.split(separator: "/").last.map(String.init) ?? path
    print("=== \(imageName) ===")

    var nameCount: UInt32 = 0
    guard let names = objc_copyClassNamesForImage(path, &nameCount) else {
        print("   (runtime knows no classes for this image — try the leaf name)")
        var alt: UInt32 = 0
        if let altNames = objc_copyClassNamesForImage(imageName, &alt) {
            print("   via leaf name: \(alt) classes")
            for i in 0..<Int(alt) { print("      \(String(cString: altNames[i]))") }
            free(altNames)
        }
        dlclose(handle)
        continue
    }

    print("   \(nameCount) classes")
    var seen = Set<String>()
    for i in 0..<Int(nameCount) {
        let name = String(cString: names[i])
        guard !seen.contains(name), let cls = NSClassFromString(name) else { continue }
        seen.insert(name)

        var lines: [String] = []
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(cls, &methodCount) {
            for m in 0..<Int(methodCount) {
                let sel = NSStringFromSelector(method_getName(methods[m]))
                if interesting.contains(where: { sel.lowercased().contains($0) }) {
                    lines.append("      - \(sel)")
                }
            }
            free(methods)
        }
        if let meta = object_getClass(cls), meta != cls {
            var metaCount: UInt32 = 0
            if let methods = class_copyMethodList(meta, &metaCount) {
                for m in 0..<Int(metaCount) {
                    let sel = NSStringFromSelector(method_getName(methods[m]))
                    if interesting.contains(where: { sel.lowercased().contains($0) }) {
                        lines.append("      + \(sel)")
                    }
                }
                free(methods)
            }
        }
        if !lines.isEmpty {
            print("   class \(name)")
            print(lines.sorted().joined(separator: "\n"))
        }
    }
    free(names)
    dlclose(handle)
}
