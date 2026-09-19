// ax_limit — drive the real charge-limit slider in System Settings through the Accessibility API.
//
// The door on this macOS build is NOT a slider in the pane: it is the round (i) button on the
// "Charging" row, which opens a sheet holding the actual control. This tool:
//   1. opens the Battery pane,
//   2. finds the "Charging" row's (i) button by geometry (nearest button to the right of the label),
//   3. presses it,
//   4. dumps the sheet's subtree (sheets are not in the normal children tree) and reports sliders,
//   5. with --set N, sets the slider and reads the value back through AX.
//
// Verification of a successful change is done OUTSIDE this tool: powerd rewrites its settings
// record (com.apple.batteryui.charging.mac) whenever the limit changes, so compare that before/after.
//
// Usage: ax_limit [--set N] [--dump]

import Foundation
import ApplicationServices
import AppKit

setbuf(stdout, nil)

func axError(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .notImplemented: return "notImplemented"
    case .apiDisabled: return "apiDisabled (Accessibility permission missing)"
    case .actionUnsupported: return "actionUnsupported"
    case .attributeUnsupported: return "attributeUnsupported"
    case .cannotComplete: return "cannotComplete"
    @unknown default: return "unknown(\(e.rawValue))"
    }
}

func attr(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

func stringAttr(_ element: AXUIElement, _ name: CFString) -> String? {
    guard let v = attr(element, name), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
    return v as? String
}

func doubleAttr(_ element: AXUIElement, _ name: CFString) -> Double? {
    guard let v = attr(element, name), CFGetTypeID(v) == CFNumberGetTypeID() else { return nil }
    var d = 0.0
    CFNumberGetValue((v as! CFNumber), .doubleType, &d)
    return d
}

func pointAttr(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
    guard let v = attr(element, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
    return p
}

func sizeAttr(_ element: AXUIElement, _ name: CFString) -> CGSize? {
    guard let v = attr(element, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
    return s
}

/// Depth-first walk including sheets and popovers (which are NOT in the children list).
func eachElement(_ element: AXUIElement, depth: Int = 0, _ body: (AXUIElement, Int) -> Void) {
    guard depth < 25 else { return }
    body(element, depth)
    if let children = attr(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
        for child in children { eachElement(child, depth: depth + 1, body) }
    }
    for name in ["AXSheets", "AXPopover"] as [CFString] {
        if let extra = attr(element, name) {
            if CFGetTypeID(extra) == CFArrayGetTypeID() {
                for child in extra as! [AXUIElement] { eachElement(child, depth: depth + 1, body) }
            } else if CFGetTypeID(extra) == AXUIElementGetTypeID() {
                eachElement(extra as! AXUIElement, depth: depth + 1, body)
            }
        }
    }
}

// --- 1. open the Battery pane and find System Settings ------------------------------------------
NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
Thread.sleep(forTimeInterval: 4.0)
guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else {
    print("System Settings is not running"); exit(1)
}
let root = AXUIElementCreateApplication(settings.processIdentifier)
// NOTE: deliberately NOT activating System Settings — the test is whether a background window can
// be driven silently, which is what the app wants to do.

var probeRef: CFTypeRef?
let gate = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &probeRef)
if gate == .apiDisabled || gate == .failure {
    print("Accessibility API disabled for this process (\(axError(gate))) — grant it in System Settings → Privacy & Security → Accessibility")
    exit(2)
}

func frontmostName() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }
let startApp = NSWorkspace.shared.frontmostApplication
print("frontmost at start: \(frontmostName())")

// --hide: park System Settings off-screen (hidden) so driving it never steals focus
if CommandLine.arguments.contains("--hide") {
    let hideResult = AXUIElementSetAttributeValue(root, "AXHidden" as CFString, kCFBooleanTrue)
    print("hiding System Settings → \(axError(hideResult))")
    Thread.sleep(forTimeInterval: 1.0)
    print("  frontmost after hide: \(frontmostName())")
}

// --- 2. the "Charging" row's (i) button ----------------------------------------------------------
var chargingLabel: (point: CGPoint, size: CGSize)?
eachElement(root) { element, _ in
    if chargingLabel == nil, stringAttr(element, kAXRoleAttribute as CFString) == "AXStaticText",
       stringAttr(element, kAXValueAttribute as CFString) == "Charging",
       let p = pointAttr(element, kAXPositionAttribute as CFString),
       let s = sizeAttr(element, kAXSizeAttribute as CFString) {
        chargingLabel = (p, s)
    }
}

guard let label = chargingLabel else {
    print("could not find the \"Charging\" label — is the Battery pane showing?")
    exit(3)
}
print(String(format: "\"Charging\" label at (%.0f, %.0f) size %.0f×%.0f", label.point.x, label.point.y, label.size.width, label.size.height))

var infoButton: (element: AXUIElement, desc: String, distance: CGFloat)?
let labelMidY = label.point.y + label.size.height / 2
eachElement(root) { element, _ in
    guard stringAttr(element, kAXRoleAttribute as CFString) == "AXButton",
          let p = pointAttr(element, kAXPositionAttribute as CFString),
          let s = sizeAttr(element, kAXSizeAttribute as CFString) else { return }
    let midY = p.y + s.height / 2
    guard abs(midY - labelMidY) < 12, p.x > label.point.x + label.size.width - 5 else { return }
    let distance = p.x - (label.point.x + label.size.width)
    let desc = stringAttr(element, kAXDescriptionAttribute as CFString) ?? stringAttr(element, kAXTitleAttribute as CFString) ?? "(no desc)"
    if infoButton == nil || distance < infoButton!.distance {
        infoButton = (element, desc, distance)
    }
}

guard let door = infoButton else {
    print("no button found to the right of \"Charging\"")
    exit(4)
}

// the sheet may already be open — only press if no slider is visible yet
func visibleSliders() -> [AXUIElement] {
    var found: [AXUIElement] = []
    eachElement(root) { element, _ in
        if stringAttr(element, kAXRoleAttribute as CFString) == "AXSlider" { found.append(element) }
    }
    return found
}
if visibleSliders().isEmpty {
    print("frontmost before press: \(frontmostName())")
    let pressStart = Date()
    _ = AXUIElementPerformAction(door.element, kAXPressAction as CFString)
    // poll for the sheet instead of sleeping a fixed 2 s: every 100 ms is flash time on screen
    var appeared = false
    for _ in 0..<40 {
        Thread.sleep(forTimeInterval: 0.1)
        if !visibleSliders().isEmpty { appeared = true; break }
    }
    print("  sheet appeared: \(appeared) after \(Int(Date().timeIntervalSince(pressStart) * 1000)) ms; frontmost now: \(frontmostName())")
    // hand focus straight back to whichever app had it — the sheet stays open behind it
    if CommandLine.arguments.contains("--restore"), let startApp, startApp.bundleIdentifier != "com.apple.systempreferences" {
        let restoreStart = Date()
        startApp.activate()
        Thread.sleep(forTimeInterval: 0.25)
        print("  frontmost after restoring \(startApp.localizedName ?? "?"): \(frontmostName()) (+\(Int(Date().timeIntervalSince(restoreStart) * 1000)) ms)")
    }
} else {
    print("the detail sheet is already open")
}

// --- 3. what appeared --------------------------------------------------------------------------
let sliders = visibleSliders()
print("sliders now visible: \(sliders.count)")
for (index, slider) in sliders.enumerated() {
    let title = stringAttr(slider, kAXTitleAttribute as CFString) ?? ""
    let desc = stringAttr(slider, kAXDescriptionAttribute as CFString) ?? ""
    let value = doubleAttr(slider, kAXValueAttribute as CFString)
    var range = ""
    if let min = doubleAttr(slider, kAXMinValueAttribute as CFString),
       let max = doubleAttr(slider, kAXMaxValueAttribute as CFString) { range = String(format: " range %.0f…%.0f", min, max) }
    print(String(format: "  [%d] title=\"%@\" desc=\"%@\" value=%@%@", index, title, desc,
                 value.map { String(format: "%.0f", $0) } ?? "?", range))
}

if CommandLine.arguments.contains("--dump") {
    print("=== full subtree (sheets included) ===")
    eachElement(root) { element, depth in
        let role = stringAttr(element, kAXRoleAttribute as CFString) ?? "?"
        let title = stringAttr(element, kAXTitleAttribute as CFString) ?? ""
        let desc = stringAttr(element, kAXDescriptionAttribute as CFString) ?? ""
        let value = stringAttr(element, kAXValueAttribute as CFString) ?? ""
        var numeric = ""
        if let d = doubleAttr(element, kAXValueAttribute as CFString) { numeric = String(format: " (n=%.0f)", d) }
        if role != "AXStaticText" || !value.isEmpty {
            print("\(String(repeating: "  ", count: depth))\(role) t=\"\(title)\" d=\"\(desc)\" v=\"\(value)\"\(numeric)")
        }
    }
}

// --- 4. set it ---------------------------------------------------------------------------------
if let index = CommandLine.arguments.firstIndex(of: "--set"), index + 1 < CommandLine.arguments.count,
   let target = Double(CommandLine.arguments[index + 1]) {
    guard let slider = sliders.first else { print("no slider to set"); exit(5) }
    let before = doubleAttr(slider, kAXValueAttribute as CFString)
    print(String(format: "setting slider: %.0f → %.0f", before ?? -1, target))
    let result = AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, target as CFNumber)
    print("  AXUIElementSetAttributeValue → \(axError(result))")
    Thread.sleep(forTimeInterval: 1.5)
    // re-find it: SwiftUI may rebuild the element
    var after: Double?
    eachElement(root) { element, _ in
        if after == nil, stringAttr(element, kAXRoleAttribute as CFString) == "AXSlider" {
            after = doubleAttr(element, kAXValueAttribute as CFString)
        }
    }
    print(String(format: "  AX read-back → %.0f", after ?? -1))
}

// --- 5. close the detail sheet (only when asked: leaving it open is what makes later sets silent) --
if CommandLine.arguments.contains("--close") {
    var doneButton: AXUIElement?
    var buttonDescs: [String] = []
    eachElement(root) { element, _ in
        guard stringAttr(element, kAXRoleAttribute as CFString) == "AXButton" else { return }
        let title = stringAttr(element, kAXTitleAttribute as CFString) ?? ""
        let desc = stringAttr(element, kAXDescriptionAttribute as CFString) ?? ""
        if !title.isEmpty || !desc.isEmpty { buttonDescs.append("\(title)/\(desc)") }
        guard doneButton == nil else { return }
        let lowered = (title + " " + desc).lowercased()
        if lowered.contains("done") || lowered.contains("ok") { doneButton = element }
    }
    if let doneButton {
        print("closing the sheet → \(axError(AXUIElementPerformAction(doneButton, kAXPressAction as CFString)))")
    } else {
        print("no Done/OK button found; buttons seen: \(buttonDescs.joined(separator: ", "))")
    }
}