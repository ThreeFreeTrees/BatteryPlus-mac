// AppDelegate.swift — the menu bar item itself.
//
// The icon is a template image and is NEVER tinted: that is the whole point of the project, since
// the system's own item turns yellow in Low Power Mode. Low Power Mode is communicated by the menu
// content instead.

import AppKit

/// File logging for the interaction tests. A demo instance's stdout is not visible to the capture
/// harness, and a silent no-op is exactly the failure mode being investigated.
enum DemoLog {
    static func write(_ message: String) {
        let path = "/tmp/batteryplus-demo.log"
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var model: BatteryModel?
    private var builder: BatteryPlusBuilder?
    private var useTemplate = false   // diagnostic (--template): the old, measurably dimmer render
    private var appearanceObservation: NSKeyValueObservation?
    private var buttonObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let printState = CommandLine.arguments.contains("--print-state")
        useTemplate = CommandLine.arguments.contains("--template")
        let model = BatteryModel()
        let builder = BatteryPlusBuilder(model: model)
        self.model = model
        self.builder = builder
        // Low Power Mode dims the display; this remembers the brightness and puts it back across LPM
        // transitions — including ones made in System Settings or Control Center.
        BrightnessKeeper.shared.start()

        // Login Items → "Open at Login". Re-asserted on every launch, because an uninstall/reinstall
        // drops the item while the preferences survive — see LoginItem.swift. Skipped for the
        // demo/diagnostic instances: they run from this same bundle but are not the app the user keeps.
        let isDiagnostic = CommandLine.arguments.contains { $0.hasPrefix("--demo") || $0 == "--print-state" || $0 == "--template" }
        if !isDiagnostic { LoginItem.ensurePresent() }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = useTemplate ? "BatteryPlusStatusItemTemplate" : "BatteryPlusStatusItem"   // ⌘-drag position persists
        item.behavior = [.removalAllowed, .terminationOnRemoval]   // ⌘-dragging it off the bar quits the app
        statusItem = item

        model.onChange = { [weak self] state in
            self?.updateIcon(state)
            self?.statusItem?.button?.toolTip = "Battery \(state.percentage)%"
            if printState {
                let app = NSApp.effectiveAppearance.name.rawValue
                let button = self?.statusItem?.button?.effectiveAppearance.name.rawValue ?? "nil"
                let window = self?.statusItem?.button?.window?.effectiveAppearance.name.rawValue ?? "nil"
                print("state: percentage=\(state.percentage) charging=\(state.isCharging) "
                      + "plugged=\(state.isPluggedIn) lpm=\(state.lowPowerMode) "
                      + "fraction=\(Double(state.percentage) / 100)")
                print("appearance: app=\(app) button=\(button) window=\(window) "
                      + "darkWallpaper=\(NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)")
                fflush(stdout)
            }
        }
        model.start()

        // The icon colour is chosen from the menu bar's appearance, so re-render whenever it may
        // have flipped: the theme notification (which can arrive just before the appearance
        // actually changes, hence the small delay) and the app's own appearance.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil,
            queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.refreshIcon() }
            }
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.refreshIcon()
        }

        // Diagnostic: print the model's own view of the battery so it can be compared with pmset.
        if printState {
            // The status item's appearance may not be final until the item has been laid out, so
            // sample it again a few seconds later — that difference decides whether the item can
            // choose its own colour or has to stay a template image.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                let app = NSApp.effectiveAppearance.name.rawValue
                let button = self?.statusItem?.button?.effectiveAppearance.name.rawValue ?? "nil"
                let window = self?.statusItem?.button?.window?.effectiveAppearance.name.rawValue ?? "nil"
                print("appearance(after 3s): app=\(app) button=\(button) window=\(window)")
                fflush(stdout)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { NSApp.terminate(nil) }
        }

        if let button = item.button {
            updateIcon(model.state)
            button.imagePosition = .imageOnly
            // The status item's effective appearance is NOT final until the item has been laid out:
            // on a dark bar it reports VibrantLight for the first seconds and then settles on
            // VibrantDark. Rendering the colour ourselves means that window would leave a black
            // icon on a dark bar, so re-render when it settles and whenever it changes.
            buttonObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                self?.refreshIcon()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshIcon() }
        }

        // menu, rebuilt on open
        let menu = builder.build()
        menu.delegate = builder
        item.menu = menu

        // Capture harness: `--demo-menu` pops the replica open for a few seconds so an external
        // `screencapture` can photograph it — the one thing an automated test cannot do for a
        // transient menu. `--demo-menu-at x,y` positions it.
        if CommandLine.arguments.contains("--demo-menu") || CommandLine.arguments.contains("--demo-menu-at") {
            var origin = NSPoint(x: 900, y: 500)
            if let index = CommandLine.arguments.firstIndex(of: "--demo-menu-at"), index + 1 < CommandLine.arguments.count {
                let parts = CommandLine.arguments[index + 1].split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 { origin = NSPoint(x: parts[0], y: parts[1]) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, let menu = self.statusItem?.menu else { return }
                print("menu opening at \(origin.x),\(origin.y) — ready to capture")
                fflush(stdout)
                menu.popUp(positioning: nil, at: origin, in: nil)
            }
            // Interaction test: drive the switch's own action a few seconds after the menu opens, so
            // its animation can be sampled without depending on a synthetic mouse event.
            if let index = CommandLine.arguments.firstIndex(of: "--demo-toggle-after"),
               index + 1 < CommandLine.arguments.count,
               let seconds = Double(CommandLine.arguments[index + 1]) {
                DemoLog.write("scheduled toggle action at t+\(seconds)s")
                // NOTE: DispatchQueue.main.asyncAfter does NOT fire while a menu is tracking (the
                // main queue is not drained in that run loop mode) — which is also why the switch's
                // animation has to be driven by a run-loop timer registered for the tracking modes,
                // not by a dispatch block.
                let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    DemoLog.write("firing: builder=\(self.builder == nil ? "nil" : "set") "
                                  + "row=\(self.builder?.energyToggleRow == nil ? "nil" : "set")")
                    self.builder?.energyToggleRow?.activate()
                    DemoLog.write("activate() returned")
                }
                RunLoop.current.add(timer, forMode: .common)
                RunLoop.current.add(timer, forMode: .eventTracking)
            }
            // Chip interaction test: drive a chip's own action while the menu is open — the same path
            // a real click takes — so the in-place update (highlight and wording) can be photographed
            // without a synthetic mouse event.
            if let afterIndex = CommandLine.arguments.firstIndex(of: "--demo-chip-after"),
               afterIndex + 1 < CommandLine.arguments.count,
               let seconds = Double(CommandLine.arguments[afterIndex + 1]),
               let chipIndex = CommandLine.arguments.firstIndex(of: "--demo-chip"),
               chipIndex + 1 < CommandLine.arguments.count,
               let chipValue = Int(CommandLine.arguments[chipIndex + 1]) {
                print("scheduling chip action: \(chipValue)% at t+\(seconds)s")
                fflush(stdout)
                let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                    print("firing chip action: \(chipValue)%  (level \(self?.builder == nil ? "?" : "lv") )")
                    fflush(stdout)
                    self?.builder?.chipRow?.onSelect?(chipValue)
                }
                RunLoop.current.add(timer, forMode: .common)
                RunLoop.current.add(timer, forMode: .eventTracking)
            }
            // How long to leave it open. 7 s is enough for `screencapture`; any interaction test
            // needs longer, so `--demo-menu-for <seconds>` overrides it.
            var lifetime: Double = 7.0
            if let index = CommandLine.arguments.firstIndex(of: "--demo-menu-for"),
               index + 1 < CommandLine.arguments.count,
               let seconds = Double(CommandLine.arguments[index + 1]) {
                lifetime = seconds
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
                self.statusItem?.menu?.cancelTracking()
                NSApp.terminate(nil)
            }
        }
    }

    private func updateIcon(_ state: BatteryState) {
        let fraction = Double(state.percentage) / 100.0
        // NOTE: do not override image.size here. The charging glyph is deliberately taller than the
        // pill (the bolt overflows it, 14 pt vs 12 pt) and forcing a 12 pt box squashed the bolt.
        // The system draws the charging bolt whenever the adapter is connected — NOT only while
        // current is actually flowing. Verified against the native item: with the battery holding at
        // the 80% charge limit (`pmset` says "AC attached; not charging") the system's icon still
        // shows a bolt. Keying on `isCharging` alone was exactly the bug where our icon showed no
        // bolt while the laptop was plugged in.
        let showBolt = state.isCharging || state.isPluggedIn
        let image = BatteryGlyph.image(fraction: fraction, color: menuBarColour(),
                                       charging: showBolt, template: useTemplate)
        statusItem?.button?.image = image
        statusItem?.button?.setAccessibilityLabel("Battery \(state.percentage) percent")
    }

    /// White on a dark menu bar, black on a light one, at the alpha that matches the system's icon.
    ///
    /// Measured in the menu bar: a template image's filled part reaches only ~0.94 luminance where
    /// the system's own battery icon reaches ~0.96 (background 0.29), i.e. the system draws third
    /// party template images at ~0.94 of the requested alpha. Asking for a translucent colour and
    /// rendering non-template reproduces the system's 0.96 exactly. The cost is that the colour has
    /// to be chosen here rather than by the system, so the icon is re-rendered whenever the menu
    /// bar's appearance may have changed (`refreshIcon`).
    private func menuBarColour() -> NSColor {
        let appearance = statusItem?.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        // The item's appearance is the *vibrant* one, which follows the bar's actual tint (a dark
        // desktop picture makes the bar draw white items even in Light mode), so this is the signal
        // that matters — not the app's appearance.
        let match = appearance.bestMatch(from: [.vibrantDark, .darkAqua, .vibrantLight, .aqua])
        let dark = (match == .vibrantDark || match == .darkAqua)
        return (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.92)
    }

    /// Re-renders the icon for the current battery state and the current menu bar appearance.
    private func refreshIcon() {
        if let state = model?.state { updateIcon(state) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
