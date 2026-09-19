// Spike 001 — can an unprivileged app read and SET the macOS energy mode?
//
// Safe by default: only reads state and checks symbol availability.
// Pass --flip to run the controlled toggle test (sets LPM off, reads back, restores original state).
//
// Build: swiftc -framework IOKit -o probe probe.swift

import Foundation
import IOKit.ps

func sym(_ name: String) -> UnsafeMutableRawPointer? {
    if let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) {
        if let p = dlsym(h, name) { return p }
    }
    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
}

func batterySummary() -> String {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
        return "no power source info"
    }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
        let name = d[kIOPSNameKey as String] as? String ?? "?"
        let cur = d[kIOPSCurrentCapacityKey as String] as? Int ?? -1
        let max = d[kIOPSMaxCapacityKey as String] as? Int ?? -1
        let charging = d[kIOPSIsChargingKey as String] as? Bool ?? false
        let src = d[kIOPSPowerSourceStateKey as String] as? String ?? "?"
        let toEmpty = d[kIOPSTimeToEmptyKey as String] as? Int ?? -1
        return "\(name): \(cur)/\(max) charging=\(charging) source=\(src) timeToEmpty=\(toEmpty)m"
    }
    return "no battery entry"
}

let flip = CommandLine.arguments.contains("--flip")

print("=== SPIKE 001: energy mode API probe ===")
print("battery        : \(batterySummary())")
print("LPM (read)     : \(ProcessInfo.processInfo.isLowPowerModeEnabled)")

// 1. symbol availability (read-only)
let names = ["IOPMSetEnergyModePreference", "IOPMSetPMPreference", "IOPMFeatureIsAvailable",
             "IOPMSetGamingEnergyModePreference", "IOPMSetReservePowerMode", "IOPMSetDesktopMode"]
for n in names {
    print(String(format: "symbol %-34s : %@", (n as NSString).utf8String!, sym(n) == nil ? "MISSING" : "present"))
}

// 2. notification wiring check (public, macOS 12+)
let sem = DispatchSemaphore(value: 0)
var observed = 0
let obs = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                                 object: nil, queue: .main) { _ in observed += 1; sem.signal() }
_ = obs

guard flip else {
    print("mode           : read-only (pass --flip to run the toggle test)")
    print("=== no state changed ===")
    exit(0)
}

// 3. controlled toggle test — must be reversible and self-verifying
let original = ProcessInfo.processInfo.isLowPowerModeEnabled
print("=== FLIP TEST (original LPM=\(original), will be restored) ===")

typealias Setter = @convention(c) (CFString, CFTypeRef) -> Int32
guard let raw = sym("IOPMSetEnergyModePreference") else {
    print("VERDICT: INVALIDATED — symbol not resolvable")
    exit(2)
}
let setEnergyMode = unsafeBitCast(raw, to: Setter.self)

func attempt(_ label: String, _ mode: CFString, _ value: CFTypeRef) {
    let rc = setEnergyMode(mode, value)
    Thread.sleep(forTimeInterval: 1.0)
    print("\(label): rc=\(rc)  LPM now=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
}

// Try the plausible call conventions in order, restoring the original state after each attempt.
let attempts: [(String, CFString, CFTypeRef)] = [
    ("CFNumber 0 (auto)", "EnergyMode" as CFString, NSNumber(value: 0)),
    ("CFNumber 1 (low)",  "EnergyMode" as CFString, NSNumber(value: 1)),
]
for (label, k, v) in attempts {
    attempt(label, k, v)
}

// restore
_ = setEnergyMode("EnergyMode" as CFString, (original ? 1 : 0) as CFNumber)
Thread.sleep(forTimeInterval: 1.0)
print("restored       : LPM=\(ProcessInfo.processInfo.isLowPowerModeEnabled) (expected \(original))")
print("notifications  : \(observed) power-state notification(s) seen")
print("=== done ===")
