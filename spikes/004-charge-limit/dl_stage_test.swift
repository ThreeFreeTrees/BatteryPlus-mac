// dl_stage_test — find out which step kills us when touching the private battery frameworks.
// Usage: dl_stage_test <stage> [framework]
//   stage 1 = dlopen only
//   stage 2 = dlopen + objc_copyClassList count
//   stage 3 = + filter by image name and print class names
//   stage 4 = + method lists

import Foundation
import Darwin

setbuf(stdout, nil)

let stage = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 1 : 1
let path = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "/System/Library/PrivateFrameworks/BatteryUIKit.framework/Versions/A/BatteryUIKit"
let imageName = path.split(separator: "/").last.map(String.init) ?? path

print("[1] dlopen \(path)")
guard let handle = dlopen(path, RTLD_NOW) else {
    print("    failed: \(String(cString: dlerror()))")
    exit(1)
}
print("    ok, handle = \(handle)")
if stage < 2 { exit(0) }

print("[2] objc_copyClassList")
var count: UInt32 = 0
guard let classes = objc_copyClassList(&count) else { exit(1) }
print("    \(count) classes in the runtime")
if stage < 3 { exit(0) }

print("[3] filter classes from this image")
var fromImage: [AnyClass] = []
for i in 0..<Int(count) {
    let cls: AnyClass = classes[i]
    guard let image = class_getImageName(cls) else { continue }
    if String(cString: image).contains(imageName) {
        fromImage.append(cls)
        print("    class \(NSStringFromClass(cls))")
    }
}
print("    \(fromImage.count) classes from \(imageName)")
if stage < 4 { exit(0) }

print("[4] method lists")
for cls in fromImage {
    var n: UInt32 = 0
    guard let methods = class_copyMethodList(cls, &n) else { continue }
    print("    \(NSStringFromClass(cls)): \(n) instance methods")
    for m in 0..<Int(n) {
        let sel = NSStringFromSelector(method_getName(methods[m]))
        if sel.lowercased().contains("charge") || sel.lowercased().contains("limit") {
            print("        - \(sel)")
        }
    }
    free(methods)
}
print("done")
