// BatteryModel.swift — live battery state, driven entirely by notifications (no polling).
//
// Sources, all public:
//   * IOPSCopyPowerSourcesInfo / IOPSGetPowerSourceDescription  → percentage, charging, source, time
//   * IOPSNotificationCreateRunLoopSource                        → fires when any of the above changes
//   * ProcessInfo.isLowPowerModeEnabled + NSProcessInfoPowerStateDidChangeNotification → LPM
//
// Apple's own guidance (IOPowerSources.h) is to prefer the narrower notifications over
// kIOPSNotifyAnyPowerSource because they wake the client less often; `IOPSNotificationCreateRunLoopSource`
// is the run-loop variant of kIOPSNotifyTimeRemaining, which is the right granularity for an icon
// that shows time remaining in its menu.

import Foundation
import IOKit.ps

struct BatteryState {
    var percentage: Int = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var powerSourceName: String = "Battery Power"   // "Battery Power" | "AC Power" | "UPS Power"
    var timeToEmptyMinutes: Int = -1                // -1 = unknown
    var timeToFullMinutes: Int = -1
    var lowPowerMode: Bool = false
    var batteryEnergyMode: Int = 0                  // pmset -b lowpowermode
    var adapterEnergyMode: Int = 0                  // pmset -c lowpowermode
    var quality: String = "Normal"                  // battery condition, as the system shows it
    var chargeLimit: Int?                           // settings record, e.g. 80 for "Charged to 80% Limit"
    var chargeLimitError: String?                   // last charge-limit attempt that did not stick

    var isOnBattery: Bool { !isPluggedIn }
}

final class BatteryModel {
    private(set) var state = BatteryState()
    var onChange: ((BatteryState) -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    func start() {
        refresh()

        // power-source changes (level, charging, source, time remaining)
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let model = Unmanaged<BatteryModel>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { model.powerSourceChanged() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, Unmanaged.passUnretained(self).toOpaque())?
            .takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            runLoopSource = source
        }

        // Low Power Mode changes
        let token = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.state.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.energyModesChanged()
            }
        observers.append(token)
    }

    private func powerSourceChanged() {
        // a power-source transition can also flip the effective energy mode
        state.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        refresh()
        energyModesChanged()
    }

    private func energyModesChanged() {
        let modes = EnergyModeClient.shared.readModes()
        if let battery = modes.battery { state.batteryEnergyMode = battery }
        if let adapter = modes.adapter { state.adapterEnergyMode = adapter }
        onChange?(state)
    }

    func refresh() {
        state.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            onChange?(state); return
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard (description[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String) else { continue }

            let current = description[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey as String] as? Int ?? 100
            state.percentage = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            state.isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
            state.isPluggedIn = (description[kIOPSPowerSourceStateKey as String] as? String)
                == (kIOPSACPowerValue as String)
            state.powerSourceName = state.isPluggedIn ? "AC Power" : "Battery Power"
            state.timeToEmptyMinutes = description[kIOPSTimeToEmptyKey as String] as? Int ?? -1
            state.timeToFullMinutes = description[kIOPSTimeToFullChargeKey as String] as? Int ?? -1
            if let condition = description[kIOPSBatteryHealthKey as String] as? String, !condition.isEmpty {
                state.quality = condition
            }
        }
        // the charge limit is not in any IOPS dictionary — it lives in the SMC (read-only, no
        // privileges needed). Reading it costs three IOKit calls, so it happens with the state.
        state.chargeLimit = ChargeLimit.read()
        onChange?(state)
    }

    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Sets the charge limit, by the best route available (see ChargeLimitClient — the direct one is
    /// instant and invisible, the UI one is the fallback). Asynchronous: the completion refreshes the
    /// model, and the refresh re-reads the limit, so an accepted change shows up in the chip highlight
    /// and in the "Charged to N% Limit" line.
    func setChargeLimit(_ value: Int, completion: ((ChargeLimitClient.Outcome) -> Void)? = nil) {
        state.chargeLimitError = nil
        ChargeLimitClient.set(value) { [weak self] outcome in
            guard let self else { return }
            self.state.chargeLimitError = outcome.errorText
            self.refresh()
            completion?(outcome)
        }
    }
}
