// ChargeLimitClient.swift — sets the system charge limit, by the best route available.
//
// Two routes, in this order:
//
//   1. DIRECT (preferred): PowerUI's private client — the same call System Settings' own pane makes,
//      reached through PowerUIChargeLimit.h. Measured to work from an ordinary process: instant,
//      invisible, no permission, no window, no flash. It is an unsupported API, so it can disappear
//      with an OS update — which is exactly why route 2 exists.
//   2. VIA THE UI (fallback, only when route 1 reports "unavailable"): drive the real control in
//      System Settings through the Accessibility API (ChargeLimitSetter). Slower, briefly visible
//      the first time, and needs the grant — but it works with only public surface.
//
// Both routes verify by reading the limit back, and neither reports success unless the system agrees.

import Foundation
import AppKit

enum ChargeLimitClient {
    enum Outcome {
        case set(Int)
        case unchanged(Int)
        case needsPermission
        case failed(String)

        var errorText: String? {
            switch self {
            case .set, .unchanged: return nil
            case .needsPermission: return "Accessibility access needed — grant it to BatteryPlus, then try again"
            case .failed(let detail): return detail
            }
        }
    }

    /// Sets the charge limit. The completion runs on the main queue.
    static func set(_ limit: Int, completion: @escaping (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = perform(limit)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private static func perform(_ limit: Int) -> Outcome {
        if let current = ChargeLimitAPI.read(), current == limit { return .unchanged(limit) }

        switch ChargeLimitAPI.write(limit) {
        case 0:
            // the system took it — confirm by reading it back, never by assuming
            guard let readBack = ChargeLimitAPI.read() else { return .failed("the limit could not be read back") }
            return readBack == limit ? .set(limit) : .failed("read-back says \(readBack)%")
        case 1:
            // no such API on this build → the UI route, if we are allowed to use it
            guard ChargeLimitSetter.hasPermission else { return .needsPermission }
            return ChargeLimitSetter.performViaUI(limit)
        case 3:
            return .failed("\(limit)% is not a value this Mac accepts")
        default:
            return .failed("the system refused the change")
        }
    }
}