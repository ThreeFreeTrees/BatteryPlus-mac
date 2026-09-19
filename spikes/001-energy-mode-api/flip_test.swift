// Spike 001 — live flip test for the private energy-mode API (approved by the user).
//
//   IOReturn IOPMSetEnergyModePreference(CFStringRef mode, CFStringRef powerSource)
//      mode        : "Automatic" | "LowPowerMode" | "HighPowerMode"
//      powerSource : "AC Power"  | "Battery Power" | "UPS Power"
//
// Recovered by decoding the Swift small-string constants at Control Center's call site
// (0x1000296b8) and confirmed by the function's own argument validation.
//
// The test is reversible: it restores the exact original mode for the battery power source
// and verifies the state reads back. Wrong strings return kIOReturnError and change nothing.

import Foundation

typealias SetEnergyMode = @convention(c) (CFString, CFString) -> Int32

let kIOReturnSuccess: Int32 = 0
let kIOReturnError: Int32 = Int32(bitPattern: 0xE00002BC)

func hex(_ v: Int32) -> String { String(format: "0x%08X", UInt32(bitPattern: v)) }

func lpm() -> Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

func pmsetBatteryMode() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "custom"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    // the "Battery Power:" section, first 3 lines that matter
    var inBattery = false, out: [String] = []
    for line in text.split(separator: "\n") {
        if line.hasPrefix("Battery Power:") { inBattery = true; continue }
        if line.hasPrefix("AC Power:") { break }
        if inBattery, line.contains("lowpowermode") { out.append(line.trimmingCharacters(in: .whitespaces)) }
    }
    return out.first ?? "(no battery lowpowermode line)"
}

guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL),
      let raw = dlsym(h, "IOPMSetEnergyModePreference") else {
    print("VERDICT: INVALIDATED — could not resolve IOPMSetEnergyModePreference"); exit(2)
}
let _setEnergyMode = unsafeBitCast(raw, to: SetEnergyMode.self)
func setEnergyMode(_ mode: String, _ source: String) -> Int32 { _setEnergyMode(mode as CFString, source as CFString) }

print("=== SPIKE 001: live flip test ===")
let originalLPM = lpm()
let originalPMSet = pmsetBatteryMode()
print("before        : isLowPowerModeEnabled=\(originalLPM)   pmset battery \(originalPMSet)")

// 1. rejection test — a wrong string must be refused and change nothing
let bogus = setEnergyMode("Automatic", "No Such Source")
let afterBogus = lpm()
print("reject test   : rc=\(hex(bogus)) (kIOReturnError=\(hex(kIOReturnError)))  lpm=\(afterBogus)  "
      + (bogus != kIOReturnSuccess && afterBogus == originalLPM ? "PASS — invalid input refused, no state change"
                                                                : "UNEXPECTED"))

// 2. flip Low Power Mode ON for the battery power source, then read it back
let rcOn = setEnergyMode("LowPowerMode", "Battery Power")
Thread.sleep(forTimeInterval: 1.2)
let lpmOn = lpm()
print("set LowPower  : rc=\(hex(rcOn))  isLowPowerModeEnabled=\(lpmOn)  "
      + (rcOn == kIOReturnSuccess && lpmOn ? "PASS — LPM now ON" : "FAIL"))

// 3. restore the original mode and verify
let restoreMode: String = originalLPM ? "LowPowerMode" : "Automatic"
let rcOff = setEnergyMode(restoreMode, "Battery Power")
Thread.sleep(forTimeInterval: 1.2)
let lpmAfter = lpm()
let pmsetAfter = pmsetBatteryMode()
print("restore       : mode=\(restoreMode) rc=\(hex(rcOff))  isLowPowerModeEnabled=\(lpmAfter)  pmset battery \(pmsetAfter)")

let ok = (lpmOn == true) && (lpmAfter == originalLPM) && (pmsetAfter == originalPMSet)
let restoredText = (lpmAfter == originalLPM && pmsetAfter == originalPMSet) ? "YES (identical to before)" : "NO — CHECK NOW"
print("state restored: " + restoredText)
let verdict = ok ? "VALIDATED — unprivileged per-source energy mode set works, no root needed"
                 : "PARTIAL — see lines above"
print("VERDICT: " + verdict)
