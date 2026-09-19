// BrightnessKeeper.swift — Low Power Mode dims the display; this keeps the brightness where you set it.
//
// Measured (spikes/006-low-power-brightness): switching Low Power Mode on drops the built-in display by
// about one step (0.3671 → 0.3134), and switching it off again does not restore the original value
// (0.3550). The system animates that change over a few hundred milliseconds.
//
// Two mistakes the first version of this made, both reported from real use:
//
//  1. It sampled the remembered brightness only every 2 s, so changing the brightness and toggling LPM
//     within a few seconds brought the OLD value back. Now it samples every 0.25 s.
//  2. It re-asserted the value on a fixed schedule (0.15/0.5/1.1 s), which fought the system's own
//     animation — the screen visibly bounced. Now it WAITS for the animation to settle (the reading
//     holds still for ~0.25 s) and then corrects once.
//
// Readings taken during a transition are deliberately not recorded as the user's choice, and sampling
// stays suppressed briefly after our own correction, so the app can never mistake its own write — or
// the system's dim — for the brightness the user wants.
//
// The timers run in .common *and* .eventTracking: the toggle is clicked while our menu is tracking, and
// main-queue work is not drained in that mode (the trap that also delayed the charge-limit highlight).

import AppKit

/// The DisplayServices shim in Swift-friendly clothing (see DisplayBrightness.h).
enum DisplayBrightness {
    static func current() -> Float? {
        let value = bm_display_brightness()
        return value < 0 ? nil : value
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        bm_set_display_brightness(value) == 0
    }
}

final class BrightnessKeeper {
    static let shared = BrightnessKeeper()

    /// The brightness to come back to: the last value the user left the display at.
    private(set) var remembered: Float?
    private var pollTimer: Timer?
    private var observer: NSObjectProtocol?
    private var suppressSamplesUntil: Date?
    private var correcting = false

    func start() {
        guard pollTimer == nil else { return }

        // 0.25 s: fast enough that a toggle right after a manual change still restores the new value.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.current.add(timer, forMode: .common)
        pollTimer = timer

        // Catches Low Power Mode switched outside this app (System Settings, Control Center, pmset).
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.handleLowPowerTransition()
        }
    }

    /// Records the current brightness as the user's choice, unless a transition is in progress.
    private func sample() {
        if let until = suppressSamplesUntil, Date() < until { return }
        if let current = DisplayBrightness.current() { remembered = current }
    }

    /// Call right after a Low Power Mode change made outside this app (the notification path).
    /// For changes this app makes, call `beginHolding()` *before* the toggle instead.
    func handleLowPowerTransition() {
        beginHolding()
    }

    /// Holds the remembered brightness for a few seconds. Start it *before* changing Low Power Mode when
    /// possible: running pmset takes a moment, and being on guard already means the system's dim is
    /// corrected from its first frame.
    ///
    /// The loop runs on a background thread writing every 8 ms. A run-loop Timer is not enough here —
    /// measured: a 20 ms timer left the system's ramp free for ~240 ms (0.73 → 0.83), because timers are
    /// coalesced while a menu is tracking. A thread is immune to that, and DisplayServices is safe to call
    /// off the main thread.
    func beginHolding(seconds: Double = 3.0) {
        if remembered == nil { remembered = DisplayBrightness.current() }
        guard let target = remembered else { return }
        suppressSamplesUntil = Date().addingTimeInterval(seconds + 0.5)
        guard !correcting else { return }
        correcting = true

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let deadline = Date().addingTimeInterval(seconds)
            var settledSince: Date?
            while Date() < deadline {
                guard let self else { break }
                if let current = DisplayBrightness.current(), abs(current - target) > 0.008 {
                    _ = DisplayBrightness.set(target)
                    settledSince = nil
                } else if settledSince == nil {
                    settledSince = Date()
                }
                if let settledSince, Date().timeIntervalSince(settledSince) > 0.6 { break }
                usleep(8_000)
            }
            self?.correcting = false
            self?.suppressSamplesUntil = Date().addingTimeInterval(0.5)
        }
    }
}