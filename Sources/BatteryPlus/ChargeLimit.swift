// ChargeLimit.swift — reads the system's battery charge limit ("Charged to 80% Limit").
//
// Where the truth lives (evidence in spikes/004-charge-limit/README.md):
//
//   1. PowerUI's private client — the same API System Settings' own pane calls. Measured on macOS 27
//      to answer an ordinary, unentitled process: reading returns the real limit, and this is what the
//      app's setter writes through. Unsupported, hence the fallback below.
//   2. powerd's settings record (`com.apple.batteryui.charging.mac`) — written by the *UI* path only,
//      so it lags: after a direct set it still showed the old value while the new one was in force.
//      Fine as a coarse fallback; never the source of truth.
//   3. The SMC's `BfSC` is NOT the limit. It is the *achieved* charge level — writing it is a silent
//      no-op and the value drifts with the battery. The reader and the full story live in the spike.
//
// The app therefore carries no SMC code at all: displaying and setting the limit needs no helper, no
// privileges and no SMC access.

import Foundation

/// The limit, through the system's own client (private API — see PowerUIChargeLimit.h).
enum ChargeLimitAPI {
    /// The current manual charge limit, or nil when the API is unavailable on this build.
    static func read() -> Int? {
        var value: Int32 = 0
        guard bm_charge_limit_read(&value) == 0 else { return nil }
        return (50...100).contains(Int(value)) ? Int(value) : nil
    }

    /// The values this Mac accepts, straight from the system — here 80, 85, 90, 95, 100.
    static func availableValues() -> [Int] {
        var values = [Int32](repeating: 0, count: 16)
        var count: Int32 = 0
        guard bm_charge_limit_available(&values, Int32(values.count), &count) == 0, count > 0 else { return [] }
        return values.prefix(Int(count)).map { Int($0) }
    }

    /// Writes the limit. Returns the C API's code: 0 ok, 1 unavailable, 2 failed, 3 invalid.
    @discardableResult
    static func write(_ limit: Int) -> Int32 {
        bm_charge_limit_write(Int32(limit))
    }
}

/// Reads the limit, preferring the system's own client and falling back to the UI's record.
enum ChargeLimit {
    private static let domain = "com.apple.batteryui.charging.mac"
    private static let key = "com.apple.batteryui.charging.mac.prior.limit"

    /// e.g. 80 for "Charged to 80% Limit".
    static func read() -> Int? {
        if let value = ChargeLimitAPI.read() { return value }
        return recordValue()
    }

    /// The UI's bookkeeping record — a lagging fallback, deliberately second choice.
    private static func recordValue() -> Int? {
        guard let defaults = UserDefaults(suiteName: domain) else { return nil }
        let value = defaults.integer(forKey: key)
        return (50...100).contains(value) ? value : nil
    }
}