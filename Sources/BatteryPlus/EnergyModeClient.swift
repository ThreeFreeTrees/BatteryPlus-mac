// EnergyModeClient.swift — the app side of the privileged Low Power Mode write.
//
// Reading the energy mode is public (`isLowPowerModeEnabled`, and `pmset -g custom` is
// world-readable). Writing it is not: `pmset` refuses as an ordinary user ("'pmset' must be run as
// root", measured) and the IOKit setter is gated by a restricted entitlement we cannot self-sign.
//
// So the write goes through a small setuid-root tool (Sources/Privileged/batteryplus-lowpower.c).
// That tool exists instead of the launchd daemon this used to be, because every loaded launchd job
// appears in System Settings → Login Items → Background App Activity as a second row, and such a row
// cannot be given a proper icon under an ad-hoc signature (SMAppService.daemon → EPERM, measured).
//
// Rule from spike 001: never trust a write's return code. Every set is verified by reading the state
// back, and success is only reported when the read-back agrees with what was asked for.

import Foundation
import Darwin

struct EnergyModes {
    var battery: Int?   // 0 = automatic, 1 = low power  (pmset -b lowpowermode)
    var adapter: Int?   // same, for the AC/adapter scope (pmset -c lowpowermode)

    func value(forBatteryOnBattery: Bool) -> Int? { forBatteryOnBattery ? battery : adapter }
}

final class EnergyModeClient {
    static let shared = EnergyModeClient()

    /// Installed by install/install-helper.sh or the .pkg: root-owned, mode 4755.
    static let toolPath = "/usr/local/libexec/batteryplus-lowpower"

    /// True when the tool is installed *and* actually setuid-root. Without the bit the write cannot
    /// work, and the menu says so rather than failing silently on a click.
    var isAvailable: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: Self.toolPath),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.intValue else { return false }
        let setuid = (mode & 0o4000) != 0
        return setuid && owner == 0 && FileManager.default.isExecutableFile(atPath: Self.toolPath)
    }

    /// Turns Low Power Mode on (policy **Always**) or off (policy **Never**).
    ///
    /// The Battery settings pane's own control is a *policy* covering both power sources, and it only
    /// agrees with our state when both scopes are written: measured on this machine, "Always" is
    /// battery 1 + AC 1 and "Never" is 0 + 0. Writing only the scope matching the current power source —
    /// which is what this did at first, on the theory that it mirrored the system menu — leaves the pane
    /// reading "Never" while Low Power Mode is genuinely on, and silently drops LPM the moment the Mac is
    /// unplugged. So both scopes are written, and both are verified on read-back.
    @discardableResult
    func setLowPowerMode(_ on: Bool) -> (ok: Bool, detail: String) {
        guard isAvailable else {
            return (false, "not installed as setuid-root: \(Self.toolPath) — run install/install-helper.sh")
        }
        let wanted = on ? 1 : 0
        // Battery first: on the adapter that write is invisible, on battery it is the one visible change,
        // so either way the state flips exactly once.
        for scope in ["battery", "ac"] {
            let outcome = run(scope: scope, value: wanted)
            guard outcome.ok else { return outcome }
        }

        // Never trust the exit code: read both scopes back and insist they match.
        let modes = readModes()
        if modes.battery == wanted && modes.adapter == wanted {
            return (true, "lowpowermode \(wanted) for battery and ac")
        }
        return (false, "read-back mismatch: asked \(wanted) for both, system reports battery "
                + "\(modes.battery.map(String.init) ?? "unknown") / ac \(modes.adapter.map(String.init) ?? "unknown")")
    }

    /// Runs the privileged tool once for one scope, reporting the tool's own diagnostics on failure.
    private func run(scope: String, value: Int) -> (ok: Bool, detail: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.toolPath)
        process.arguments = [scope, String(value)]
        let diagnostics = Pipe()
        process.standardError = diagnostics
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return (false, "could not run \(Self.toolPath): \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let message = String(data: diagnostics.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            return (false, message.isEmpty ? "tool exited \(process.terminationStatus)" : message)
        }
        return (true, "set \(scope) lowpowermode \(value)")
    }

    /// Reads both scopes from `pmset -g custom`, which needs no privileges. Returns nil for whichever
    /// scope cannot be parsed.
    func readModes() -> EnergyModes {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return EnergyModes(battery: nil, adapter: nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return EnergyModes(battery: nil, adapter: nil) }

        var battery: Int?, adapter: Int?
        var section = ""
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Battery Power:") { section = "battery"; continue }
            if line.hasPrefix("AC Power:") { section = "ac"; continue }
            guard line.hasPrefix("lowpowermode") else { continue }
            let value = Int(line.split(separator: " ").last.map(String.init) ?? "")
            if section == "battery" { battery = value }
            if section == "ac" { adapter = value }
        }
        return EnergyModes(battery: battery, adapter: adapter)
    }
}
