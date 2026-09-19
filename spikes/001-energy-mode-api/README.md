# Spike 001 — energy mode API

## Question
Given an unprivileged third-party app, can it read and **set** the macOS energy mode
(Low Power Mode) so a replica battery menu can offer a working Energy Mode row?

## Verdict: PARTIAL — read yes (public), write no (restricted entitlement)

### What worked
- **Public read + change notification** (macOS 12+): `NSProcessInfo.isLowPowerModeEnabled` and
  `NSProcessInfoPowerStateDidChangeNotification`. Verified against per-power-source scoping:
  `pmset -g custom` → `Battery Power: lowpowermode 0`, `AC Power: lowpowermode 1` while on battery,
  `isLowPowerModeEnabled == false` — consistent.
- **Public battery data**: `IOPSCopyPowerSourcesInfo` / `IOPSGetPowerSourceDescription`
  → `InternalBattery-0 64/100 discharging 366m`.
- **Signature recovered** for the private setter, by decoding the Swift small-string constants at
  Control Center's call site (`cc` disassembly, address `0x1000296b8`):

  ```c
  IOReturn IOPMSetEnergyModePreference(CFStringRef mode, CFStringRef powerSource);
  // mode        : "Automatic" | "LowPowerMode" | "HighPowerMode"
  // powerSource : "AC Power"  | "Battery Power" | "UPS Power"
  ```
  Corroborated by the function's own body: it validates arg1 against two CFStrings and arg0 against
  three (2 sources / 3 modes), returning `kIOReturnError`-class codes for anything else.
- **Argument validation is a safety net**: `("Automatic", "No Such Source")` → `rc=0xE00002C2`,
  state unchanged. Wrong guesses can never set a wrong mode.
- **Symbol is reachable** unprivileged: `dlsym` finds `IOPMSetEnergyModePreference`,
  `IOPMSetPMPreference`, `IOPMFeatureIsAvailable`, … all present.

### What didn't
- **The write is a silent no-op without the entitlement.** `("LowPowerMode", "Battery Power")`
  returns **`rc=0x00000000`** yet `isLowPowerModeEnabled` stays `false` and
  `pmset -g custom` battery stays `0` — success code, no effect.
- **The gate is `com.apple.private.iokit.updatemodepreference`**, a *restricted* entitlement:
  - present on Control Center (`codesign -d --entitlements :-`),
  - present on Apple's own `BatterySettingsIntentsExtension.appex`,
  - **cannot be self-signed**: ad-hoc signing a probe with that entitlement makes the kernel kill it
    on launch —
    `AMFI: Code has restricted entitlements, but the validation of its code signature failed.`
    → `proc … load code signature error 4` → `Killed: 9`.
- `pmset -b lowpowermode 1` as the user → `'pmset' must be run as root`.

### Surprises
- The setter is **per power source**, which matches the system UI (the mode is remembered separately
  for battery and for the adapter). A replica menu must therefore write the mode for the *current*
  source, not a global flag.
- The failure mode is a **silent success** — no error, no effect. Anything built on this API must
  verify by reading state back, never by trusting the return code.
- `Using Significant Energy` has its own separate private gate on Control Center:
  `com.apple.private.systemstats.analysis-client` — so it is equally out of reach.

### Recommendation for the real build
| Element | Route |
|---|---|
| Icon (white in LPM and out of it) | unblocked — SF Symbol, template rendering, public state APIs |
| Menu replica (header, power source, energy mode, settings link) | unblocked |
| Energy Mode **toggle** | needs privilege: (a) scoped sudoers rule for the four `pmset … lowpowermode` invocations, or (b) a root helper/LaunchDaemon; otherwise (c) read-only row + deep link to System Settings → Battery |
| `Using Significant Energy` | omit, or approximate from public CPU stats and label it honestly |

State was restored and re-verified after every experiment (`Battery Power: 0`, `AC Power: 1`,
`isLowPowerModeEnabled == false`).

## Artifacts
- `flip_test.swift` — the approved live test (reversible, self-verifying, state-restoring)
- `probe.swift` — read-only symbol/state probe
- `ent.plist` — the restricted-entitlement experiment
- `analysis/` — raw disassembly of the setter and the byte-extraction probe
