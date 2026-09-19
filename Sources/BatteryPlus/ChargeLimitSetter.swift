// ChargeLimitSetter.swift — sets the system charge limit by driving System Settings' own control.
//
// Why UI automation (spikes/004-charge-limit/README.md has the full search): on this macOS build
// there is no userland write path — no SMC key moves, the settings record is write-only, and the
// system UI talks to powerd over an entitlement-gated private XPC. The one control that genuinely
// changes the setting is the slider behind the round (i) on the Battery pane's "Charging" row, so
// that is what we drive — through the Accessibility API, not pixels: the slider is found by role,
// set by kAXValueAttribute, and its button is pressed by proximity to the "Charging" label, so no
// fixed coordinates and no clicking blind spots.
//
// Verification is deliberate and doubled, because a UI automation that reports success without the
// system agreeing would be a lie in the menu:
//   1. the slider's own value is read back through AX after the set, and
//   2. powerd's settings record (com.apple.batteryui.charging.mac, which the system rewrites on
//      every real limit change) must show the new value.
// Only then is the outcome reported as success.
//
// Requires Accessibility permission (System Settings → Privacy & Security → Accessibility). The
// grant is keyed to the code signature, and this app is ad-hoc signed, so a fresh build asks again.

import AppKit
import ApplicationServices

enum ChargeLimitSetter {
    /// Has this app been granted Accessibility access? Only the fallback route needs it.
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds this app to Privacy & Security → Accessibility.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Fallback route, used only when the direct API reports itself unavailable on this build:
    /// drives the real control in System Settings. Synchronous — call it off the main thread.
    static func performViaUI(_ limit: Int) -> ChargeLimitClient.Outcome {
        guard hasPermission else { return .needsPermission }
        return perform(limit)
    }

    // MARK: - the sequence

    private static func perform(_ target: Int) -> ChargeLimitClient.Outcome {
        guard let app = ensureSystemSettings() else { return .failed("System Settings did not open") }
        let root = AXUIElementCreateApplication(app.processIdentifier)

        // The pane must be showing the battery page. If its "Charging" row is missing, bring the
        // pane up (this is the one step that can put a window in front of the user) and retry.
        var label = findChargingLabel(root)
        if label == nil {
            openBatteryPane()
            label = waitFor(seconds: 4.0) { findChargingLabel(root) }
        }
        guard let chargingLabel = label else { return .failed("the Battery pane is not showing") }

        // Open the (i) sheet only if it is not already open. It is deliberately LEFT OPEN: a parked
        // sheet is what makes every later set silent (no press ⇒ no activation ⇒ nothing moves on
        // screen). Pressing is the one step that puts System Settings in front, and only the first
        // time — so focus is handed straight back, immediately, before the window has a chance to
        // settle in front.
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        var slider = visibleSliders(root).first
        if slider == nil {
            guard let door = infoButton(rightOf: chargingLabel, in: root) else {
                return .failed("the (i) button next to Charging was not found")
            }
            guard AXUIElementPerformAction(door, kAXPressAction as CFString) == .success else {
                return .failed("could not open the charge-limit detail")
            }
            if let previousFrontmost, previousFrontmost.bundleIdentifier != "com.apple.systempreferences" {
                DispatchQueue.main.async { previousFrontmost.activate() }
            }
            slider = waitFor(seconds: 3.0) { visibleSliders(root).first }
        }
        guard let limitSlider = slider else { return .failed("the charge-limit slider did not appear") }

        let before = doubleValue(limitSlider, kAXValueAttribute as CFString)
        if let before, Int(before.rounded()) == target { return .unchanged(target) }

        let setResult = AXUIElementSetAttributeValue(limitSlider, kAXValueAttribute as CFString, target as CFNumber)
        guard setResult == .success else { return .failed("the slider refused the change (\(setResult.rawValue))") }

        // verification 1: the slider reads back what we asked for
        let readBack = waitFor(seconds: 2.0) {
            visibleSliders(root).first.flatMap { doubleValue($0, kAXValueAttribute as CFString) }
        }
        guard let readBack, Int(readBack.rounded()) == target else {
            return .failed("read-back mismatch (\(readBack.map { String(Int($0)) } ?? "nil"))")
        }

        // verification 2: powerd rewrote its record, i.e. the system actually took the setting
        let record = waitFor(seconds: 2.0) { ChargeLimit.read() == target ? ChargeLimit.read() : nil }
        guard record == target else {
            return .failed("the system did not accept the change (its settings record still says \(ChargeLimit.read().map(String.init) ?? "nothing"))")
        }

        return .set(target)
    }

    // MARK: - Accessibility plumbing

    /// Opens (or navigates) the Battery pane *without* activating System Settings — a window that
    /// steals focus every time a chip is clicked would be exactly the sloppiness we are avoiding.
    private static func openBatteryPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, _ in }
    }

    private static func ensureSystemSettings() -> NSRunningApplication? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first {
            return app
        }
        openBatteryPane()
        return waitFor(seconds: 6.0) {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
        }
    }

    /// Polls until the closure returns non-nil or the timeout passes. Runs on the caller's thread.
    private static func waitFor<T>(seconds: Double, _ body: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        var result = body()
        while result == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            result = body()
        }
        return result
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: CFString) -> String? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    private static func doubleValue(_ element: AXUIElement, _ name: CFString) -> Double? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var number = 0.0
        CFNumberGetValue((value as! CFNumber), .doubleType, &number)
        return number
    }

    private static func point(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ element: AXUIElement, _ name: CFString) -> CGSize? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// Depth-first walk that also descends into sheets and popovers — the slider lives in a sheet,
    /// and sheets are NOT part of the children tree, which is the trap that hides them.
    private static func each(_ element: AXUIElement, depth: Int = 0, _ body: (AXUIElement) -> Bool) -> Bool {
        guard depth < 25 else { return false }
        if body(element) { return true }
        if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children where each(child, depth: depth + 1, body) { return true }
        }
        for name in ["AXSheets", "AXPopover"] as [CFString] {
            if let extra = attribute(element, name) {
                if CFGetTypeID(extra) == CFArrayGetTypeID() {
                    for child in extra as! [AXUIElement] where each(child, depth: depth + 1, body) { return true }
                } else if CFGetTypeID(extra) == AXUIElementGetTypeID() {
                    if each(extra as! AXUIElement, depth: depth + 1, body) { return true }
                }
            }
        }
        return false
    }

    private static func findChargingLabel(_ root: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        _ = each(root) { element in
            guard string(element, kAXRoleAttribute as CFString) == "AXStaticText",
                  string(element, kAXValueAttribute as CFString) == "Charging" else { return false }
            found = element
            return true
        }
        return found
    }

    private static func visibleSliders(_ root: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        _ = each(root) { element in
            if string(element, kAXRoleAttribute as CFString) == "AXSlider" { found.append(element) }
            return false
        }
        return found
    }

    /// The (i) button is the button on the same row as the label, to its right. It has no title —
    /// only a description ("Show Detail") — so geometry is the reliable identification.
    private static func infoButton(rightOf label: AXUIElement, in root: AXUIElement) -> AXUIElement? {
        guard let labelPoint = point(label, kAXPositionAttribute as CFString),
              let labelSize = size(label, kAXSizeAttribute as CFString) else { return nil }
        let labelMidY = labelPoint.y + labelSize.height / 2
        var best: (element: AXUIElement, distance: CGFloat)?
        _ = each(root) { element in
            guard string(element, kAXRoleAttribute as CFString) == "AXButton",
                  let buttonPoint = point(element, kAXPositionAttribute as CFString),
                  let buttonSize = size(element, kAXSizeAttribute as CFString) else { return false }
            let midY = buttonPoint.y + buttonSize.height / 2
            guard abs(midY - labelMidY) < 12, buttonPoint.x > labelPoint.x + labelSize.width - 5 else { return false }
            let distance = buttonPoint.x - (labelPoint.x + labelSize.width)
            if best == nil || distance < best!.distance { best = (element, distance) }
            return false
        }
        return best?.element
    }
}