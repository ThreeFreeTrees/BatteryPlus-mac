// BatteryPlus.swift — builds the replica of the system Battery status menu.
//
// Reference (native menu, macOS 27):
//
//   Battery                                    67%      ← header, percentage right-aligned, monospaced
//   Power Source: Battery                                ← secondary line
//   ─────────────────────────────────────────────────
//   Energy Mode                                          ← grey section header
//   [blue rounded-square icon] Low Power                 ← active row drawn as a selected pill
//   ─────────────────────────────────────────────────
//   Using Significant Energy                             ← only when something qualifies
//   [app icon] Hermes.app
//   ─────────────────────────────────────────────────
//   Battery Settings…                                    ← opens System Settings → Battery
//
// Behaviour rules from the spikes:
//   * the icon is never tinted — the menu carries the Low Power Mode information instead
//   * energy-mode writes go through the helper and are verified by read-back; a failure is shown
//     rather than swallowed
//   * when no app qualifies as significant, the section is omitted entirely (the absence is
//     information, exactly as the system does it)

import AppKit

protocol EnergyUsageProviding {
    /// Apps currently using significant energy, or empty. Empty ⇒ the section is omitted.
    func significantEnergyApps() -> [(name: String, icon: NSImage?)]
}

/// Default provider: no data. The system uses a private framework
/// (`com.apple.private.systemstats.analysis-client`) that we cannot call, so until a public
/// measurement is justified, the section stays absent.
struct NoEnergyData: EnergyUsageProviding {
    func significantEnergyApps() -> [(name: String, icon: NSImage?)] { [] }
}

final class BatteryPlusBuilder: NSObject, NSMenuDelegate {
    private let model: BatteryModel
    private let energyProvider: EnergyUsageProviding
    private(set) var lastError: String?
    /// The Low Power switch row, kept so the interaction test can drive its action.
    private(set) var energyToggleRow: ToggleRowView?
    /// The charge-limit chip row and its "Charged to N% Limit" line — updated in place after a set,
    /// because the menu stays open while the set completes.
    private(set) var chipRow: LimitChipRowView?
    private(set) var limitRow: SecondaryRowView?

    init(model: BatteryModel, energyProvider: EnergyUsageProviding = NoEnergyData()) {
        self.model = model
        self.energyProvider = energyProvider
        super.init()
    }

    func build() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.minimumWidth = 300
        rebuild(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        var state = model.state
        // Capture harness: `--demo-plugged` renders as if the adapter were connected (the limit rows
        // only show while plugged in), and `--demo-limit <n>` overrides the displayed limit, so the
        // chip row can be photographed without physically plugging anything in.
        if CommandLine.arguments.contains("--demo-plugged") {
            state.isPluggedIn = true
            state.powerSourceName = "AC Power"
        }
        if let index = CommandLine.arguments.firstIndex(of: "--demo-limit"),
           index + 1 < CommandLine.arguments.count,
           let limit = Int(CommandLine.arguments[index + 1]) {
            state.chargeLimit = limit
        }
        let helperReady = EnergyModeClient.shared.isAvailable

        // header: "Battery" + right-aligned percentage
        add(menu, HeaderRowView(title: "Battery", detail: "\(state.percentage)%"))

        // power source line — the native reference shows just the source, with no time suffix,
        // and uses its own wording ("Battery", not "Battery Power")
        let sourceText = state.powerSourceName == "Battery Power" ? "Battery" : "Power Adapter"
        add(menu, SecondaryRowView(text: "Power Source: \(sourceText)"))

        // The charge-limit line and the five chips (only while the adapter is connected). The line's
        // wording follows the state — "Charging to 95% Limit" while it fills, "Charged to 80% Limit"
        // once it holds there. The chips set the limit directly through the system's own client
        // (ChargeLimitClient), and the change is only reported as successful once it reads back.
        if state.isPluggedIn {
            if let limit = state.chargeLimit {
                let limitLine = SecondaryRowView(text: Self.limitLineText(limit: limit, percentage: state.percentage))
                limitRow = limitLine
                add(menu, limitLine)
            }
            let chips = LimitChipRowView(currentLimit: state.chargeLimit, enabled: true)
            chips.onSelect = { [weak self] value in
                guard let self else { return }
                // Repaint in place from a tracking-mode timer (see beginLimitUpdatePolling) — the
                // completion below arrives on the main queue, which is not drained while the menu is
                // open, so it cannot be the only path that moves the highlight.
                self.beginLimitUpdatePolling(target: value)
                self.model.setChargeLimit(value) { [weak self] outcome in
                    guard let self else { return }
                    self.applyLimitUI()
                    if case .needsPermission = outcome { ChargeLimitSetter.requestPermission() }
                }
            }
            let chipItem = NSMenuItem()
            chipItem.view = chips
            chipItem.isEnabled = false
            menu.addItem(chipItem)
            chipRow = chips
        } else {
            limitRow = nil
            chipRow = nil
        }
        if let limitError = state.chargeLimitError {
            add(menu, SecondaryRowView(text: "  \(limitError)"))
        }

        menu.addItem(.separator())

        // Energy Mode — one switch row. The system shows an icon+pill here; we draw a designed
        // toggle on the trailing margin instead (asked for explicitly), so the label keeps the
        // menu's text margin instead of an icon eating the left edge.
        add(menu, SectionHeaderView(title: "Energy Mode"))
        let energyToggle = ToggleRowView(title: "Low Power Mode", isOn: state.lowPowerMode, enabled: helperReady)
        energyToggle.onToggle = { [weak self] wantsLowPower in
            let logging = CommandLine.arguments.contains { $0.hasPrefix("--demo") }
            guard let self else { return }
            if logging { DemoLog.write("LPM toggle fired: wants=\(wantsLowPower) helperReady=\(helperReady)") }
            guard helperReady else { return }
            // Low Power Mode dims the display; start holding the user's brightness *before* the change,
            // since running pmset takes a moment and the dim would otherwise get a head start.
            BrightnessKeeper.shared.beginHolding()
            // Sets the *policy* for both power sources (Always when on, Never when off), so the Battery
            // pane in System Settings agrees and unplugging doesn't quietly drop Low Power Mode.
            let result = EnergyModeClient.shared.setLowPowerMode(wantsLowPower)
            if logging {
                DemoLog.write("LPM toggle write: \(result.ok ? "ok" : "FAILED") — \(result.detail)")
            }
            self.lastError = result.ok ? nil : result.detail
            if result.ok { BrightnessKeeper.shared.beginHolding() }
            self.model.refresh()
        }
        let energyItem = NSMenuItem()
        energyItem.view = energyToggle
        energyItem.isEnabled = false
        menu.addItem(energyItem)
        energyToggleRow = energyToggle

        if !helperReady {
            add(menu, SecondaryRowView(text: "  Low Power Mode tool not installed — run"))
            add(menu, SecondaryRowView(text: "  sudo install/install-helper.sh, or the .pkg"))
        } else if let lastError {
            add(menu, SecondaryRowView(text: "  Last attempt failed: \(lastError)"))
        }

        // Significant energy — omitted entirely when nothing qualifies
        let significant = energyProvider.significantEnergyApps()
        if !significant.isEmpty {
            menu.addItem(.separator())
            add(menu, SectionHeaderView(title: "Using Significant Energy"))
            for app in significant {
                let item = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
                item.image = app.icon
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Battery Settings…", action: #selector(openBatterySettings), keyEquivalent: "")
        settings.target = self
        settings.isEnabled = true
        menu.addItem(settings)

        // A menu-bar extra has no Dock icon and no app menu, so without this row the only way out is
        // killing the process. ⌘Q works while the menu is open.
        let quit = NSMenuItem(title: "Quit BatteryPlus", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
    private func add(_ menu: NSMenu, _ view: NSView) {
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        menu.addItem(item)
    }

    /// The system's wording switches with the state — Control Center carries both keys,
    /// `chargingToLimit` and `chargedToLimit`. "Charged to N% Limit" claims the battery *has reached*
    /// the limit, so below it the line must read "Charging to N% Limit" (e.g. 85% battery with a 95%
    /// limit). The test is the level against the limit, not `IsCharging`: an AC-connected battery
    /// already above the limit still reports `IsCharging = Yes` on this hardware, which would wrongly
    /// produce "Charging to 80% Limit" at an 85% level (measured — and Apple's own pane says
    /// "Charged to 80% Limit" there).
    private static func limitLineText(limit: Int, percentage: Int) -> String {
        percentage < limit ? "Charging to \(limit)% Limit" : "Charged to \(limit)% Limit"
    }

    // MARK: - in-place updates while the menu is open

    private var limitPollTimer: Timer?
    private var pendingLimit: Int?
    private var limitPollTicks = 0

    /// After a chip is clicked, the menu is still open — and the main queue is NOT drained while a
    /// menu tracks, so the set's completion (dispatched to main) cannot move the highlight until the
    /// menu closes. That is exactly the bug where the blue stayed on the old chip until reopening.
    /// This polls from a run-loop timer registered for the tracking modes (the same trick the toggle
    /// animation uses) and repaints the row as soon as the system reports the new value.
    private func beginLimitUpdatePolling(target: Int) {
        pendingLimit = target
        limitPollTicks = 0
        model.refresh()
        applyLimitUI()
        limitPollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.limitPollTicks += 1
            self.model.refresh()
            self.applyLimitUI()
            let settled = ChargeLimit.read() == self.pendingLimit
            if settled || self.limitPollTicks > 40 {          // give it 10 s, then stop quietly
                self.limitPollTimer?.invalidate()
                self.limitPollTimer = nil
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        RunLoop.current.add(timer, forMode: .eventTracking)
        limitPollTimer = timer
    }

    /// Moves the chip highlight and rewrites the limit line from the system's current value.
    private func applyLimitUI() {
        let current = ChargeLimit.read()
        chipRow?.update(currentLimit: current)
        if let current {
            limitRow?.setText(Self.limitLineText(limit: current, percentage: model.state.percentage))
        }
    }

    private func format(minutes: Int) -> String {
        let hours = minutes / 60, mins = minutes % 60
        return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
    }

    @objc private func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
