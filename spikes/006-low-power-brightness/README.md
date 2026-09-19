# Spike 006 — Low Power Mode must not change the brightness

**Reported:** switching Low Power Mode on drops the display brightness by one step. **Wanted:** the
brightness stays exactly as the user set it.

## Measured (MacBook Air M3, macOS 27, built-in display)

Brightness is `DisplayServicesGetBrightness`/`SetBrightness` (private `DisplayServices`, cache-only
binary, dlopen by path), display `CGMainDisplayID()` = 1. Both work **unprivileged**:

| step | brightness |
|---|---|
| before Low Power Mode | 0.3659 … 0.3713 |
| Low Power Mode **on** (no fix) | **0.3134** — the reported drop, 0.054 ≈ one 1/16 step |
| Low Power Mode **off** again (no fix) | 0.3550 — the system does *not* restore the original either |

So the dim is real, it is about one step, and the switch-off direction is also imperfect. Readings
drift by ~0.005 between samples because the display is on "automatically adjust brightness" — that is
ambient compensation, not the app.

## Fix

`Sources/BatteryPlus/BrightnessKeeper.swift` + `Sources/PrivateAPI/DisplayBrightness.{h,c}`:

* keeps a `remembered` value — the brightness the user last left the display at — sampled every
  **0.25 s** (a 2 s poll was the first version, and it restored a value from seconds earlier: reported
  from real use as "change the brightness, toggle LPM, and it goes back to the old level");
* before a change this app makes, it starts holding *before* pmset runs (pmset itself takes a moment,
  and the system's dim otherwise gets a head start);
* the hold is a **background thread writing every 8 ms**, not a run-loop timer: measured, a 20 ms timer
  is coalesced while our menu is tracking and left the system free to ramp 0.73 → 0.83 over 240 ms;
* it writes only while the reading deviates by more than 0.008, and stops once the value holds still
  for 0.6 s (or after 3 s);
* reacts to LPM changes made *outside* the app too, via `NSProcessInfoPowerStateDidChange`;
* readings taken while holding are not recorded as the user's choice, so the app's own writes and the
  system's dim can never become the remembered value.

## Verified

Trajectories from `brightness_trace` (80 ms samples) across a toggle:

| version | trajectory |
|---|---|
| first (fixed-delay writes) | 0.687 → 0.693 → 0.736 → 0.778 → 0.820 → 0.822 → **0.687** — the visible bounce |
| settle-then-correct | 0.732 → 0.705 → 0.610 → 0.515 → **0.732** — a deep 240 ms dip |
| 20 ms run-loop timer, pre-armed | 0.747 → 0.790 → 0.833 → **0.732** — ramp still got through |
| **8 ms thread, pre-armed (shipped)** | …0.713 → **0.690 → 0.711** — one sample of 3 %, then flat |
| **8 ms thread, external toggle** | flat: no deviation visible at 80 ms sampling |

The stale-value bug: brightness set to 0.6875 and LPM toggled 0.8 s later → the display stayed at
**0.6875** (before the fix it restored the previously remembered value).

`brightness_probe.c` reads/writes brightness and `brightness_trace.c` samples it for testing; the app
exposes `--brightness` and reuses `--demo-toggle-after` to drive the real toggle.

