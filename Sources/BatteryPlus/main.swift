// main.swift — entry point. A menu bar extra has no window and no Dock icon (LSUIElement in
// Info.plist, .accessory here as a belt-and-braces measure).

import AppKit
import ServiceManagement

// Diagnostic: can this app register a *daemon* via SMAppService? That is the only supported way for
// the helper's row in Login Items → Background App Activity to show our icon instead of the generic
// "exec" glyph. An earlier spike from ~/Applications was refused with EPERM; this runs from wherever
// the app is installed, which is what actually decides it.
if CommandLine.arguments.contains("--test-daemon-register") {
    let service = SMAppService.daemon(plistName: "com.mambo.batteryplus.daemontest.plist")
    print("bundle: \(Bundle.main.bundlePath)")
    print("status before: \(service.status.rawValue)")
    do {
        try service.register()
        print("register() -> OK   status now: \(service.status.rawValue)")
        try? service.unregister()
        print("(unregistered again — diagnostic only)")
    } catch {
        print("register() -> FAILED: \(error.localizedDescription)")
    }
    exit(0)
}

// Diagnostic: the login item, without opening anything.
//   BatteryPlus --login-item status   → is it registered, last route taken
//   BatteryPlus --login-item on|off   → same code path the installer and a Settings deletion produce
if let index = CommandLine.arguments.firstIndex(of: "--login-item") {
    let action = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "status"
    switch action {
    case "on":
        print("login item: on → \(LoginItem.setEnabled(true))   enabled=\(LoginItem.isEnabled)")
    case "off":
        print("login item: off → \(LoginItem.setEnabled(false))   enabled=\(LoginItem.isEnabled)")
    default:
        print("login item: enabled=\(LoginItem.isEnabled) route=\(LoginItem.lastRoute ?? "-")")
    }
    exit(0)
}

// Diagnostic: set Low Power Mode the way the menu switch does — the policy for *both* power sources
// (on = Always, off = Never), verified by reading both scopes back.
if let index = CommandLine.arguments.firstIndex(of: "--low-power") {
    let value = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "status"
    if value == "on" || value == "off" {
        let result = EnergyModeClient.shared.setLowPowerMode(value == "on")
        let modes = EnergyModeClient.shared.readModes()
        print("low power: \(result.ok ? "ok — \(result.detail)" : "FAILED — \(result.detail)")   "
              + "battery=\(modes.battery.map(String.init) ?? "?") ac=\(modes.adapter.map(String.init) ?? "?")")
    } else {
        print("low power: active=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
    }
    exit(0)
}

// Test harness (also handy by hand): the app's own setter and reader, without the menu.
//   BatteryPlus --print-limit          → what the system says the limit is, plus valid values
//   BatteryPlus --set-limit 85         → runs the same code path the chips use, then exits
if CommandLine.arguments.contains("--print-limit") {
    let limit = ChargeLimit.read().map(String.init) ?? "unavailable"
    print("charge limit: \(limit)%   available: \(ChargeLimitAPI.availableValues())")
    exit(0)
}
if CommandLine.arguments.contains("--brightness") {
    let current = DisplayBrightness.current().map { String(format: "%.4f", $0) } ?? "unavailable"
    print("brightness: \(current)")
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--set-limit"), index + 1 < CommandLine.arguments.count,
   let limit = Int(CommandLine.arguments[index + 1]) {
    var finished = false
    var result = "no outcome"
    ChargeLimitClient.set(limit) { outcome in
        switch outcome {
        case .set(let value): result = "set \(value)"
        case .unchanged(let value): result = "unchanged \(value)"
        case .needsPermission: result = "needsPermission"
        case .failed(let detail): result = "failed — \(detail)"
        }
        finished = true
    }
    // spin the run loop rather than blocking: the completion is delivered on the main queue
    while !finished, RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1)) {}
    print("charge limit: \(result)   (now reads \(ChargeLimit.read().map(String.init) ?? "nil")%)")
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
