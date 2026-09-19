// ax_probe — proof-of-concept: can the System Settings Charge Limit slider be read AND set via
// the Accessibility API on this macOS build?
//
// Success is measured, not assumed: powerd writes its settings record
// (com.apple.batteryui.charging.mac → ...prior.limit) whenever the slider moves, so a successful
// set must change that record — the tool prints the record's value before and after.
//
// Usage:
//   ax_probe            — open the Battery pane, dump the sliders found (role/title/value)
//   ax_probe --set 90   — ...and set the Charge Limit slider to 90, then verify
//
// Needs Accessibility permission for the process that runs it (Terminal or whatever host); when
// the API is disabled the tool explains instead of failing silently.

import Foundation
import ApplicationServices
import AppKit

setbuf(stdout, nil)

func axError(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .notImplemented: return "notImplemented"
    case .apiDisabled: return "apiDisabled (Accessibility permission missing)"
    case .actionUnsupported: return "actionUnsupported"
    case .attributeUnsupported: return "attributeUnsupported"
    case .cannotComplete: return "cannotComplete"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown(\(error.rawValue))"
    }
}

func valueDescription(_ value: CFTypeRef?) -> String {
    guard let value else { return "(none)" }
    if CFGetTypeID(value) == CFNumberGetTypeID() {
        var d = 0.0
        CFNumberGetValue((value as! CFNumber), .doubleType, &d)
        return String(format: "%.3f (number)", d)
    }
    if CFGetTypeID(value) == AXValueGetTypeID() {
        var d = 0.0 // centre of a CGPoint/float-backed AXValue
        AXValueGetValue(value as! AXValue, .cgPoint, &d)
        return String(format: "%.3f (AXValue)", d)
    }
    if CFGetTypeID(value) == CFStringGetTypeID() { return "\"(value as! String)\"" }
    return "<\(CFGetTypeID(value))>"
}

struct SliderInfo {
    let element: AXUIElement
    let title: String
    let description: String
    var value: Double?
}

func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
    return value as? String
}

func walk(_ element: AXUIElement, depth: Int, into results: inout [SliderInfo], maxDepth: Int = 20) {
    guard depth < maxDepth else { return }
    var roleRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
       let roleRef, CFGetTypeID(roleRef) == CFStringGetTypeID(),
       let role = roleRef as? String, role == kAXSliderRole as String {
        let title = stringAttribute(element, kAXTitleAttribute as CFString) ?? ""
        let desc = stringAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
        var value: CFTypeRef?
        var numeric: Double?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let value {
            if CFGetTypeID(value) == CFNumberGetTypeID() {
                var d = 0.0
                CFNumberGetValue(value as! CFNumber, .doubleType, &d)
                numeric = d
            }
        }
        results.append(SliderInfo(element: element, title: title, description: desc, value: numeric))
    }
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let childrenRef, CFGetTypeID(childrenRef) == CFArrayGetTypeID() {
        let children = childrenRef as! [AXUIElement]
        for child in children { walk(child, depth: depth + 1, into: &results, maxDepth: maxDepth) }
    }
    // sheets and popovers are NOT in the children list — but they are where the controls live
    for attr in ["AXSheets", "AXPopover"] as [CFString] {
        var extraRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attr, &extraRef) == .success, let extraRef {
            if CFGetTypeID(extraRef) == CFArrayGetTypeID() {
                for child in extraRef as! [AXUIElement] { walk(child, depth: depth + 1, into: &results, maxDepth: maxDepth) }
            } else if CFGetTypeID(extraRef) == AXUIElementGetTypeID() {
                walk(extraRef as! AXUIElement, depth: depth + 1, into: &results, maxDepth: maxDepth)
            }
        }
    }
}

// 1. open the Battery pane
let batteryPane = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
NSWorkspace.shared.open(batteryPane)
print("opened the Battery pane; waiting for it to build its UI…")
Thread.sleep(forTimeInterval: 5)

// 2. find System Settings
guard let settingsApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else {
    print("System Settings is not running — cannot continue")
    exit(1)
}
print("System Settings pid = \(settingsApp.processIdentifier)")

let root = AXUIElementCreateApplication(settingsApp.processIdentifier)

// 3. permission gate first (cheap probe: read the focused window)
var any: CFTypeRef?
let gate = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &any)
if gate == .apiDisabled || gate == .failure {
    print("Accessibility API is DISABLED for this process (error: \(axError(gate))).")
    print("Grant it: System Settings → Privacy & Security → Accessibility → enable Terminal (or the")
    print("host app that launched this tool), then re-run.")
    exit(2)
}
print("Accessibility API gate passed")

// 4. dump what IS there
print("=== window titles ===")
if let windowsRef: CFTypeRef = { var v: CFTypeRef?; _ = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &v); return v }(),
   CFGetTypeID(windowsRef) == CFArrayGetTypeID() {
    for window in windowsRef as! [AXUIElement] {
        let title = stringAttribute(window, kAXTitleAttribute as CFString) ?? "(untitled)"
        print("  window: \(title)")
    }
}

var sliders: [SliderInfo] = []
walk(root, depth: 0, into: &sliders)
print("sliders found: \(sliders.count)")
// also report any element at all whose title/description mentions charge/limit/battery
var mentions: [(role: String, title: String, desc: String)] = []
func walkMentions(_ element: AXUIElement, depth: Int) {
    guard depth < 15 else { return }
    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "?"
    let title = stringAttribute(element, kAXTitleAttribute as CFString) ?? ""
    let desc = stringAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
    let combined = (title + " " + desc).lowercased()
    if combined.contains("charge") || combined.contains("limit") || combined.contains("battery") {
        mentions.append((role, title, desc))
    }
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let childrenRef, CFGetTypeID(childrenRef) == CFArrayGetTypeID() {
        for child in childrenRef as! [AXUIElement] { walkMentions(child, depth: depth + 1) }
    }
}
walkMentions(root, depth: 0)
print("elements mentioning charge/limit/battery: \(mentions.count)")
for m in mentions.prefix(40) {
    print("  role=\(m.role) title=\"\(m.title)\" desc=\"\(m.desc)\"")
}
// role histogram — what kinds of controls does this pane expose at all?
var roles: [String: Int] = [:]
func countRoles(_ element: AXUIElement, depth: Int) {
    guard depth < 15 else { return }
    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "?"
    roles[role, default: 0] += 1
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let childrenRef, CFGetTypeID(childrenRef) == CFArrayGetTypeID() {
        for child in childrenRef as! [AXUIElement] { countRoles(child, depth: depth + 1) }
    }
}
countRoles(root, depth: 0)
print("role histogram: \(roles.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

// the control types that might carry the limit setting — dump them all
let controlRoles: Set<String> = ["AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXOutline",
                                 "AXValueIndicator", "AXTextField", "AXStaticText", "AXDisclosureTriangle"]
func dumpControls(_ element: AXUIElement, depth: Int) {
    guard depth < 15 else { return }
    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "?"
    if controlRoles.contains(role) {
        let title = stringAttribute(element, kAXTitleAttribute as CFString) ?? ""
        let desc = stringAttribute(element, kAXDescriptionAttribute as CFString) ?? ""
        var valueText = ""
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success, let value {
            if CFGetTypeID(value) == CFStringGetTypeID() { valueText = "\"\(value as! String)\"" }
            else if CFGetTypeID(value) == CFNumberGetTypeID() {
                var d = 0.0; CFNumberGetValue(value as! CFNumber, .doubleType, &d); valueText = String(format: "%.0f", d)
            }
        }
        print("  \(role) title=\"\(title)\" desc=\"\(desc)\" value=\(valueText)")
    }
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let childrenRef, CFGetTypeID(childrenRef) == CFArrayGetTypeID() {
        for child in childrenRef as! [AXUIElement] { dumpControls(child, depth: depth + 1) }
    }
}
dumpControls(root, depth: 0)
print("  (end of control dump)")

// find the row(s) mentioning "Charged" / "Limit" and dump their full contents
func dumpRowsMentioningCharged(_ element: AXUIElement, depth: Int) {
    guard depth < 20 else { return }
    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "?"
    if role == "AXRow" {
        var kidsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kidsRef) == .success,
           let kidsRef, CFGetTypeID(kidsRef) == CFArrayGetTypeID() {
            var texts: [String] = []
            func collectTexts(_ e: AXUIElement) {
                if let t = stringAttribute(e, kAXValueAttribute as CFString) { texts.append(t) }
                var cRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &cRef) == .success,
                   let cRef, CFGetTypeID(cRef) == CFArrayGetTypeID() {
                    for c in cRef as! [AXUIElement] { collectTexts(c) }
                }
            }
            collectTexts(element)
            let joined = texts.joined(separator: " ")
            if joined.lowercased().contains("charged") || joined.lowercased().contains("limit") {
                print("ROW TEXT: \(joined)")
                func dumpChild(_ e: AXUIElement, indent: String) {
                    let r = stringAttribute(e, kAXRoleAttribute as CFString) ?? "?"
                    let t = stringAttribute(e, kAXTitleAttribute as CFString) ?? ""
                    let d = stringAttribute(e, kAXDescriptionAttribute as CFString) ?? ""
                    let v = stringAttribute(e, kAXValueAttribute as CFString) ?? ""
                    print("\(indent)\(r) title=\"\(t)\" desc=\"\(d)\" value=\"\(v)\"")
                    var cRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &cRef) == .success,
                       let cRef, CFGetTypeID(cRef) == CFArrayGetTypeID() {
                        for c in cRef as! [AXUIElement] { dumpChild(c, indent: indent + "  ") }
                    }
                }
                for kid in kidsRef as! [AXUIElement] { dumpChild(kid, indent: "    ") }
            }
        }
    }
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let childrenRef, CFGetTypeID(childrenRef) == CFArrayGetTypeID() {
        for child in childrenRef as! [AXUIElement] { dumpRowsMentioningCharged(child, depth: depth + 1) }
    }
}
dumpRowsMentioningCharged(root, depth: 0)
print("  (end of row dump)")

// find the pane-body "Charged to 80% Limit" static text and dump its ancestors + siblings
func findChargedText(_ element: AXUIElement, depth: Int) {
    guard depth < 20 else { return }
    if let value = stringAttribute(element, kAXValueAttribute as CFString),
       value == "Charged to 80% Limit" {
        print("FOUND plain label — climbing to ancestors:")
        var current: AXUIElement? = element
        var chain: [String] = []
        for _ in 0..<6 {
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current!, kAXParentAttribute as CFString, &parentRef) == .success,
               let parentRef {
                let p = parentRef as! AXUIElement
                let r = stringAttribute(p, kAXRoleAttribute as CFString) ?? "?"
                // dump this parent's children
                var kidsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(p, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                   let kidsRef, CFGetTypeID(kidsRef) == CFArrayGetTypeID() {
                    print("  parent <\(r)> children:")
                    for kid in kidsRef as! [AXUIElement] {
                        let kr = stringAttribute(kid, kAXRoleAttribute as CFString) ?? "?"
                        let kt = stringAttribute(kid, kAXTitleAttribute as CFString) ?? ""
                        let kd = stringAttribute(kid, kAXDescriptionAttribute as CFString) ?? ""
                        let kv = stringAttribute(kid, kAXValueAttribute as CFString) ?? ""
                        if kr != "AXStaticText" || !kv.isEmpty || !kt.isEmpty || !kd.isEmpty {
                            print("     \(kr) title=\"\(kt)\" desc=\"\(kd)\" value=\"\(kv)\"")
                        }
                    }
                }
                chain.append(r)
                current = p
            } else { break }
        }
        print("  ancestor chain: \(chain.joined(separator: " → "))")
    }
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let childrenRef, CFGetTypeID(childrenRef) == CFArrayGetTypeID() {
        for child in childrenRef as! [AXUIElement] { findChargedText(child, depth: depth + 1) }
    }
}
findChargedText(root, depth: 0)
print("  (end of label hunt)")

// press "Options…" and see what materializes (the charge limit control is likely in its popover)
func findButton(_ element: AXUIElement, _ desiredDesc: String, depth: Int) -> AXUIElement? {
    guard depth < 20 else { return nil }
    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "?"
    if role == "AXButton", let d = stringAttribute(element, kAXDescriptionAttribute as CFString), d == desiredDesc {
        return element
    }
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let childrenRef, CFGetTypeID(childrenRef) == CFArrayGetTypeID() {
        for child in childrenRef as! [AXUIElement] {
            if let hit = findButton(child, desiredDesc, depth: depth + 1) { return hit }
        }
    }
    return nil
}
if let optionsButton = findButton(root, "Options…", depth: 0) {
    let pressResult = AXUIElementPerformAction(optionsButton, kAXPressAction as CFString)
    print("pressed Options… → \(axError(pressResult)); waiting for its popover/sheet…")
    Thread.sleep(forTimeInterval: 2.5)
    // dump what's new: windows, sliders, and any element mentioning charge/limit/percentages
    var windowsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsRef) == .success,
       let windowsRef, CFGetTypeID(windowsRef) == CFArrayGetTypeID() {
        print("windows now: \((windowsRef as! [AXUIElement]).count)")
        for w in windowsRef as! [AXUIElement] {
            let t = stringAttribute(w, kAXTitleAttribute as CFString) ?? "(untitled)"
            let r = stringAttribute(w, kAXRoleAttribute as CFString) ?? "?"
            print("  \(r): \"\(t)\"")
        }
    }
    var after: [SliderInfo] = []
    walk(root, depth: 0, into: &after)
    print("sliders after Options…: \(after.count)")
    for s in after {
        print("  slider title=\"\(s.title)\" desc=\"\(s.description)\" value=\(s.value.map { String(format: "%.0f", $0) } ?? "?")")
    }
    // any control mentioning charge/limit/percent now?
    func findMentions(_ e: AXUIElement, depth: Int) {
        guard depth < 20 else { return }
        let role = stringAttribute(e, kAXRoleAttribute as CFString) ?? "?"
        let t = stringAttribute(e, kAXTitleAttribute as CFString) ?? ""
        let d = stringAttribute(e, kAXDescriptionAttribute as CFString) ?? ""
        let v = stringAttribute(e, kAXValueAttribute as CFString) ?? ""
        let joined = (t + " " + d + " " + v).lowercased()
        if joined.contains("charge") || joined.contains("limit") || joined.contains("%") {
            if role != "AXStaticText" { print("  \(role) title=\"\(t)\" desc=\"\(d)\" value=\"\(v)\"") }
        }
        var cRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &cRef) == .success,
           let cRef, CFGetTypeID(cRef) == CFArrayGetTypeID() {
            for c in cRef as! [AXUIElement] { findMentions(c, depth: depth + 1) }
        }
    }
    findMentions(root, depth: 0)
    print("  (end of options-dump)")
} else {
    print("no Options… button found")
}

// last chance: the "Charged to 80% Limit" row may open a popover on click — click its centre
func findLabelElement(_ element: AXUIElement, depth: Int) -> AXUIElement? {
    guard depth < 20 else { return nil }
    if let value = stringAttribute(element, kAXValueAttribute as CFString),
       value == "Charged to 80% Limit" { return element }
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let childrenRef, CFGetTypeID(childrenRef) == CFArrayGetTypeID() {
        for child in childrenRef as! [AXUIElement] {
            if let hit = findLabelElement(child, depth: depth + 1) { return hit }
        }
    }
    return nil
}
if let label = findLabelElement(root, depth: 0) {
    var posRef: CFTypeRef?, sizeRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(label, kAXPositionAttribute as CFString, &posRef) == .success,
       AXUIElementCopyAttributeValue(label, kAXSizeAttribute as CFString, &sizeRef) == .success,
       let posRef, let sizeRef {
        var point = CGPoint.zero; AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        var size = CGSize.zero; AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        let cx = point.x + size.width / 2, cy = point.y + size.height / 2
        print(String(format: "clicking label at (%.0f, %.0f)…", cx, cy))
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 2.5)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windowsRef, CFGetTypeID(windowsRef) == CFArrayGetTypeID() {
            print("windows after row-click: \((windowsRef as! [AXUIElement]).count)")
            for w in windowsRef as! [AXUIElement] {
                let t = stringAttribute(w, kAXTitleAttribute as CFString) ?? "(untitled)"
                print("  \(t)")
            }
        }
        var after: [SliderInfo] = []
        walk(root, depth: 0, into: &after)
        print("sliders after row-click: \(after.count)")
        for s in after {
            print("  slider title=\"\(s.title)\" desc=\"\(s.description)\" value=\(s.value.map { String(format: "%.0f", $0) } ?? "?")")
        }
        var mentionsAfter: [(String, String)] = []
        func collectMentions(_ e: AXUIElement, depth: Int) {
            guard depth < 20 else { return }
            let t = stringAttribute(e, kAXTitleAttribute as CFString) ?? ""
            let d = stringAttribute(e, kAXDescriptionAttribute as CFString) ?? ""
            let v = stringAttribute(e, kAXValueAttribute as CFString) ?? ""
            let r = stringAttribute(e, kAXRoleAttribute as CFString) ?? "?"
            let joined = (t + " " + d + " " + v).lowercased()
            if joined.contains("charge") || joined.contains("limit") || joined.contains("%") {
                if r != "AXStaticText" && !joined.contains("battery level") { mentionsAfter.append((r, "\(t)|\(d)|\(v)")) }
            }
            var cRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &cRef) == .success,
               let cRef, CFGetTypeID(cRef) == CFArrayGetTypeID() {
                for c in cRef as! [AXUIElement] { collectMentions(c, depth: depth + 1) }
            }
        }
        collectMentions(root, depth: 0)
        print("controls mentioning charge/limit/% after row-click: \(mentionsAfter.count)")
        for m in mentionsAfter.prefix(15) { print("  \(m.0): \(m.1)") }
    }
}

// === AX SET PROOF — the decisive experiment: set the slider through AX and verify ===
let proofArgs = CommandLine.arguments
if let proofIndex = proofArgs.firstIndex(of: "--set-proof"), proofIndex + 1 < proofArgs.count,
   let target = Int(proofArgs[proofIndex + 1]), let label = findLabelElement(root, depth: 0) {
    var slider: SliderInfo?
    // put the pane back to the top and make it frontmost — synthetic clicks need both
    settingsApp.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 1.0)
    func clickLabelCentre() {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(label, kAXPositionAttribute as CFString, &posRef) == .success,
           AXUIElementCopyAttributeValue(label, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let posRef, let sizeRef {
            var point = CGPoint.zero; AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
            var size = CGSize.zero; AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            let cx = point.x + size.width / 2, cy = point.y + size.height / 2
            // hit-test: prove we are aiming at the label, not at something else
            var hitRef: AXUIElement?
            if AXUIElementCopyElementAtPosition(root, Float(cx), Float(cy), &hitRef) == .success, let hit = hitRef {
                let hr = stringAttribute(hit, kAXRoleAttribute as CFString) ?? "?"
                let hv = stringAttribute(hit, kAXValueAttribute as CFString) ?? ""
                let hd = stringAttribute(hit, kAXDescriptionAttribute as CFString) ?? ""
                print("PROOF: element under click point (%.0f,%.0f) = \(hr) value=\"\(hv)\" desc=\"\(hd)\"")
            }
            let source = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
    for attempt in 1...5 {
        clickLabelCentre()
        Thread.sleep(forTimeInterval: 1.5)
        var found: [SliderInfo] = []
        walk(root, depth: 0, into: &found)
        print("PROOF: attempt \(attempt) → \(found.count) slider(s)")
        if let s = found.first(where: {
            $0.title.contains("imit") || $0.description.contains("imit") || $0.title.contains("harge") || $0.description.contains("harge")
        }) { slider = s; break }
        if let s = found.first { slider = s; break }
    }
    guard let slider else { print("PROOF: no slider reachable after repeated clicks"); exit(3) }
    print("PROOF: slider found — title=\"\(slider.title)\" desc=\"\(slider.description)\" value=\(slider.value.map { String(format: "%.0f", $0) } ?? "?")")
    var curRef: CFTypeRef?
    var current = 0.0
    if AXUIElementCopyAttributeValue(slider.element, kAXValueAttribute as CFString, &curRef) == .success,
       let curRef, CFGetTypeID(curRef) == CFNumberGetTypeID() {
        CFNumberGetValue(curRef as! CFNumber, .doubleType, &current)
    }
    print("PROOF: slider current value = \(current)")
    let number = target as CFNumber
    let result = AXUIElementSetAttributeValue(slider.element, kAXValueAttribute as CFString, number)
    print("PROOF: set \(target) → \(axError(result))")
    Thread.sleep(forTimeInterval: 1.2)
    var readBackRef: CFTypeRef?
    var readBack = current
    if AXUIElementCopyAttributeValue(slider.element, kAXValueAttribute as CFString, &readBackRef) == .success,
       let readBackRef, CFGetTypeID(readBackRef) == CFNumberGetTypeID() {
        CFNumberGetValue(readBackRef as! CFNumber, .doubleType, &readBack)
    }
    print("PROOF: AX read-back = \(readBack)")
} else {
    print("PROOF: needs --set-proof N and a visible label row")
}

// === SHEET/POPOVER INVENTORY — dump everything in sheets and popovers in full detail ===
if proofArgs.contains("--dump-sheet") {
    func dumpSubtree(_ element: AXUIElement, label: String) {
        print("=== subtree of \(label) ===")
        func rec(_ e: AXUIElement, depth: Int) {
            guard depth < 30 else { return }
            let r = stringAttribute(e, kAXRoleAttribute as CFString) ?? "?"
            let t = stringAttribute(e, kAXTitleAttribute as CFString) ?? ""
            let d = stringAttribute(e, kAXDescriptionAttribute as CFString) ?? ""
            let v = stringAttribute(e, kAXValueAttribute as CFString) ?? ""
            var valueN = ""
            var valRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &valRef) == .success,
               let valRef, CFGetTypeID(valRef) == CFNumberGetTypeID() {
                var num = 0.0; CFNumberGetValue(valRef as! CFNumber, .doubleType, &num); valueN = String(format: " (n=%.0f)", num)
            }
            let indent = String(repeating: "  ", count: depth)
            print("\(indent)\(r) t=\"\(t)\" d=\"\(d)\" v=\"\(v)\"\(valueN)")
            var cRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &cRef) == .success,
               let cRef, CFGetTypeID(cRef) == CFArrayGetTypeID() {
                for c in cRef as! [AXUIElement] { rec(c, depth: depth + 1) }
            }
            for attr in ["AXSheets", "AXPopover"] as [CFString] {
                var extraRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(e, attr, &extraRef) == .success, let extraRef {
                    if CFGetTypeID(extraRef) == CFArrayGetTypeID() {
                        for c in extraRef as! [AXUIElement] { rec(c, depth: depth + 1) }
                    } else if CFGetTypeID(extraRef) == AXUIElementGetTypeID() {
                        rec(extraRef as! AXUIElement, depth: depth + 1)
                    }
                }
            }
        }
        rec(element, depth: 0)
    }
    // window
    var windowsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsRef) == .success,
       let windowsRef, CFGetTypeID(windowsRef) == CFArrayGetTypeID(),
       let win = (windowsRef as! [AXUIElement]).first {
        dumpSubtree(win, label: "window")
    }
}

// 5. scroll to expose lazily-built content, then re-walk
func scrollAreas(_ element: AXUIElement, depth: Int, into areas: inout [AXUIElement]) {
    guard depth < 15 else { return }
    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "?"
    if role == "AXScrollArea" { areas.append(element) }
    var childrenRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
       let childrenRef, CFGetTypeID(childrenRef) == CFArrayGetTypeID() {
        for child in childrenRef as! [AXUIElement] { scrollAreas(child, depth: depth + 1, into: &areas) }
    }
}
var knownSliders: [String] = []
for scrollPass in 1...4 {
    var areas: [AXUIElement] = []
    scrollAreas(root, depth: 0, into: &areas)
    guard !areas.isEmpty else { break }
    var acted = false
    for area in areas {
        if AXUIElementPerformAction(area, "AXScrollDown" as CFString) == .success { acted = true }
    }
    guard acted else { break }
    Thread.sleep(forTimeInterval: 0.8)
    var fresh: [SliderInfo] = []
    walk(root, depth: 0, into: &fresh)
    let newSliders = fresh.filter { !knownSliders.contains($0.title + $0.description) }
    if !newSliders.isEmpty {
        print("scroll pass \(scrollPass): +\(newSliders.count) new slider(s)")
        for s in newSliders { print("  NEW slider title=\"\(s.title)\" desc=\"\(s.description)\" value=\(s.value.map { String(format: "%.0f", $0) } ?? "?")") }
        sliders = fresh
        knownSliders = fresh.map { $0.title + $0.description }
        if fresh.contains(where: { $0.title.lowercased().contains("charge") || $0.description.lowercased().contains("limit") }) { break }
    }
}
let interesting = sliders.filter { $0.title.lowercased().contains("charge") || $0.description.lowercased().contains("limit")
    || $0.title.lowercased().contains("limit") || $0.description.lowercased().contains("charge") }
for slider in sliders {
    let flag = interesting.contains(where: { $0.element === slider.element }) ? "  <-- candidate" : ""
    print(String(format: "  slider title=%@ desc=%@ value=%@%@",
                 slider.title, slider.description,
                 slider.value.map { String(format: "%.0f", $0) } ?? "?", flag))
}

// 5. set it?
if let setIndex = CommandLine.arguments.firstIndex(of: "--set"), setIndex + 1 < CommandLine.arguments.count,
   let target = Double(CommandLine.arguments[setIndex + 1]),
   let candidate = interesting.first {

    let number = target as CFNumber
    let result = AXUIElementSetAttributeValue(candidate.element, kAXValueAttribute as CFString, number)
    print("set attempt (CFNumber \(target)): \(axError(result))")

    // read back through AX
    var readBack: CFTypeRef?
    if AXUIElementCopyAttributeValue(candidate.element, kAXValueAttribute as CFString, &readBack) == .success,
       let readBack, CFGetTypeID(readBack) == CFNumberGetTypeID() {
        var d = 0.0
        CFNumberGetValue(readBack as! CFNumber, .doubleType, &d)
        print("AX read-back after set: \(d)")
    }
} else if CommandLine.arguments.contains("--set") {
    print("no candidate slider found — nothing to set")
}