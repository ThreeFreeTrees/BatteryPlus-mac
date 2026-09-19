# Spike 004 — the battery charge limit (read + write)

**Status: NOT SOLVED.** Everything below is what is *established*, so the next attempt starts from
facts rather than from the same guesses.

## What the charge limit is NOT reachable through (all checked on macOS 27.0, M3 Air)

| Route | Result |
|---|---|
| IOKit `AppleSmartBattery` (all keys enumerated) | no limit key at all |
| `pmset -g` / `-g custom` / `-g ac` / `-g cap` | only `lowpowermode` |
| `system_profiler SPPowerDataType` | shows charge, cycle count, condition — no limit |
| Preferences plists | nothing |
| `BatteryUIKit` / `BatteryCenter` (dlopen + runtime enumeration) | battery device info only: percent, plugged state, LPM. No limit, no OBC |
| `PowerUI` (what Control Center links) | OBC internals only (`PowerUICECAlgoControlManager`, ML predictors); its `chargeLimit` methods are notification-content helpers |

Control Center's own binary contains the real thing:

```
smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:
ManualChargeLimitState / manualChargeLimitState / MockManualChargeLimit
"Charge to Full Now" / "charge to full failed"
```

…implemented by its private `ControlCenterApp.OBCController` (Swift, `_TtC16ControlCenterApp13OBCController`).
The delegate takes a `CBControllerInfo *` — and **no framework on this machine defines `CBController`,
`CBConnection`, `CBClient` or `CBControllerInfo`**, so the provider is a private API without an
identified home. Treat it like the energy-mode entitlement: assumed unreachable until proven.

## The SMC route (what AlDente does)

AlDente's helper imports the classic user-client protocol — `AppleSMC`, `kSMCGetKeyInfo`,
`kSMCReadKey`, `kSMCWriteKey`, `kSMCGetKeyFromIndex`, `kSMCHandleYPCEvent` — and its binary contains
the string `notPrivileged` plus these key names:

```
BCLM BFCL BRSC CHCC CHDB CHIE CHNC CHSC CHTE CHWA
```

`smc_probe.swift` in this directory implements that protocol. What works and what does not:

* **Works:** `IOServiceOpen("AppleSMC")` unprivileged; the 80-byte request struct; GetKeyInfo calls
  are answered (a missing key returns result **132 = kSMCKeyNotFound**, which is a real answer).
* **Fixed bug worth remembering:** the Swift mirror of `SMCKeyData_t` packed to **76 bytes** because
  `keyInfo` needs three trailing padding bytes. Every call then came back
  `0xE00002C2 kIOReturnBadArgument` — which reads like a privilege wall and is not. Print
  `MemoryLayout<…>.size` and the field offsets before believing an IOKit protocol is refused.
* **Not working:** every key read returns "not found", including keys that must exist on this
  hardware (`TB0T`, `SMCV`, `F0Ac` on a fanless Air may legitimately be absent, but not all of
  them), and `#KEY` reads back four zero bytes instead of the key count.

Most likely explanation: **SMC reads require root on Apple Silicon.** AlDente's helper runs as root
and carries a `notPrivileged` code path. Confirming costs one privileged read (see below).

## What is now ESTABLISHED (corrected — the first pass of this README was wrong)

* **The SMC protocol works, unprivileged, for metadata.** `IOServiceOpen("AppleSMC")` succeeds and
  `GetKeyFromIndex` walks **1850 keys** with readable names. My first conclusion ("reads are refused")
  was an artefact of two bugs in the reader:
  1. the Swift mirror of `SMCKeyData_t` packed to **76 bytes** instead of 80 (`keyInfo` needs three
     trailing padding bytes) → every call returned `kIOReturnBadArgument`, which reads like a
     privilege wall;
  2. `GetKeyInfo` must be **primed** by a successful `GetKeyFromIndex` call on the same connection,
     and its `result` field is **not trustworthy** — real keys (`BLCM`, `B0FC`) come back with
     `result=132` (kSMCKeyNotFound) while `keyInfo` is fully populated. Presence is `dataSize != 0
     && dataType != 0`, not the result code.
* **The charge-limit key on this machine is `BLCM`, type `si16`, size 2.** AlDente's binary lists a
  `BCLM`/`BLCM`-family key; `BCLM` itself does not exist here, `BLCM` does. Nearby keys that exist:
  `BLCC BLTA BLPM B0CT B0CS B0AC B0AV B0FC B0RM CH0D CH0E CH0H CH0R CHBI CHCC CHDB CHIE CHNC CHSC`.
  `CHWA`/`BCLM`/`TB0T`/`F0Ac` do **not** exist on this hardware.
* **Metadata reads; VALUES DO NOT.** Every key — including ones that cannot be zero (`B0FC` full
  charge capacity, `B0RM` remaining) — reads back `[00 00]` when the probe runs as the user. That is
  the signature of a root-gated value read, and it matches AlDente shipping a root helper and
  carrying a `notPrivileged` code path.

## SOLVED — the limit is `BfSC`, and it is readable WITHOUT root

The charge limit is the SMC key **`BfSC`** ("battery full state of charge"), a `ui8` holding the
percentage. On this machine it reads `50` hex = **80**, while the system's own menu says "Charged to
80% Limit". `B0CM` (=100) is battery health, not the limit. **No privileges are needed to read it**,
so the app reads it directly — the privileged helper is not involved in displaying the limit at all.

Three protocol quirks, all of which produced misleading symptoms:

1. The Swift mirror of `SMCKeyData_t` must be exactly **80 bytes** — `keyInfo` needs three trailing
   padding bytes. Without them it packs to 76 and the driver rejects *every* call with
   `kIOReturnBadArgument`, which reads exactly like a privilege wall.
2. `GetKeyInfo` must be **primed** by one successful `GetKeyFromIndex` on the same connection.
3. A value read must use a **fresh request struct**. Reusing the GetKeyInfo response (identical
   fields, only `data8 = 5`) makes the driver answer `kSMCKeyNotFound` for every key — this single
   detail is what made "SMC reads are root-gated" look true for hours. Command `5` is the read;
   sweeping the command byte is what exposed it (`B0FC` → `f7 10` = 4343 mAh, matching ioreg).

Also: the driver's `result` field lies — keys that exist come back `result=132` while `keyInfo` is
populated. Presence is `dataSize > 0 && dataType != 0`.

### Tooling in this directory

| command | what it does |
|---|---|
| `./smc_probe BfSC` | read a key (`type`, `size`, value, bytes) |
| `./smc_probe --list` | enumerate all 1813–1850 key names |
| `./smc_probe --scan` | values for charge-related keys; grep for `value=80` |
| `./smc_probe --snapshot <file>` | dump every key + value, for before/after diffing |
| `./smc_probe --cmd-sweep <KEY>` | try command bytes 1–20 on one key (how read was found) |
| `./smc_probe --debug-read <KEY>` | raw status/result of both calls |

The snapshot mode exists to answer the *write* question without guessing: change the charge limit by
any means (Apple's own "Charge to Full Now" or the System Settings slider), take a second snapshot,
and diff — that shows exactly which key(s) macOS writes to control the limit. Writing an SMC key
blind is not acceptable; the diff is the evidence.

## THE DIRECT PATH EXISTS — PowerUI's client answers an ordinary process (macOS 27)

This is the answer to "can't it be changed directly, without the UI". Yes:

```
dlopen /System/Library/PrivateFrameworks/PowerUI.framework/PowerUI      → loaded
class PowerUISmartChargeClient                                          → FOUND
  -getMCLLimitWithError:            [C24@0:8^@16]   → 80     ← the real limit
  -setMCLLimit:error:               [B28@0:8C16^@20] → ok=1  ← the real setter
  -availableChargeLimitsWithError:  → (80, 85, 90, 95, 100)
  -isOBCEngaged:chargeLimit:chargingOverrideAllowed:withError:  → engaged
```

Measured with `bc_direct.m` (a plain, unentitled, non-root process):

* `initWithClientName:` → `getMCLLimitWithError:` returned **80**, matching the setting exactly.
* `setMCLLimit:85 error:` → **ok=1, no error**, and reading back gave **85**.
* the system *enforces* it: `pmset`/`ioreg` showed `IsCharging = No`, `NotChargingReason = 16777216`,
  and the level settled 91% → 86% toward the new limit.
* `availableChargeLimitsWithError:` returns exactly **{80, 85, 90, 95, 100}** — the five values.

Two corrections this forces on the earlier conclusions:

1. **The record is not the truth and not the gate.** After a direct set, powerd's record
   (`com.apple.batteryui.charging.mac`) still read the old value while the new one was in force — it
   is UI bookkeeping written by the *System Settings* path, not the setting. Read the limit from the
   client, not from the file.
2. **The `com.apple.private.*` entitlements are not the gate for these calls.** The battery pane's
   extension does carry `com.apple.private.iokit.batterydata`, but `getMCLLimitWithError:` and
   `setMCLLimit:error:` answer a process with no entitlements at all. The class is private in the SDK
   sense (undocumented, unsupported), not access-controlled for these two calls. `CBController` /
   `CBControllerInfo` live in the same framework (`BatteryCenter.framework` is only a stub on the SSV;
   the real image is in the dyld shared cache).

Rollout in the app: `Sources/PrivateAPI/PowerUIChargeLimit.{h,m}` (a C shim, because Swift cannot
message undeclared selectors) and `ChargeLimitClient.swift`, which prefers this path, verifies by
read-back, and falls back to the Accessibility route below only if the API reports itself unavailable
on some future build. The `--print-limit` / `--set-limit N` flags on the app binary run exactly the
chips' code path for testing.

Cost, stated honestly: it is an unsupported API. An OS update can remove or change it — hence the
fallback plus plain-language failure codes rather than a silent no-op.

## FALLBACK — driving the real control through the Accessibility API

The pane's "Charging" row has a round **(i)** button whose `AXDescription` is "Show Detail". Pressing
it opens a sheet holding **an actual `AXSlider`, value 80, range 80…100** — the real charge-limit
control. (Sheets are not in the AX children tree; they hang off `AXSheetsAttribute`/`AXPopover`, which
is why every earlier walk reported "0 sliders". That trap cost most of this investigation.)

Measured, on macOS 27, with `ax_limit.swift`:

```
"Charging" label at (636, 331) size 55×16
pressing the (i) button: desc="Show Detail" at 374 px right of the label → success
sliders now visible: 1
  [0] title="" desc="" value=80 range 80…100
setting slider: 80 → 90 → AXUIElementSetAttributeValue → success → AX read-back → 90
powerd's record afterwards:  com.apple.batteryui.charging.mac.prior.limit = 90
```

and back to 80 the same way, sheet closed, record 80. So:

* the set is **accepted by powerd** (its own record rewrites), i.e. it is a real setting change, not
  a UI-only gesture — this is the verification the app uses before claiming success;
* it applies **immediately**, no OK/confirmation needed;
* it works **without the pointer** (AXPress on the button, `kAXValueAttribute` on the slider — no
  pixel clicking anywhere), which is why it survives layout changes.

Requirements and honest caveats:

* **Accessibility permission** for the app doing it (System Settings → Privacy & Security →
  Accessibility). Keyed to the code signature; this app is ad-hoc signed, so **each rebuild asks
  again**. Making the grant permanent requires signing with a self-signed certificate that is trusted
  for code signing — a real trust-settings change, so not done unasked.
* System Settings must be running; if the Battery pane is not showing, it has to be brought up once
  (that is the only step that can put a window in front of the user).
* If the user has the detail sheet open themselves, the setter leaves it open (it only closes a sheet
  it opened).
* It is still UI automation: an OS redesign can move the (i) button or rename "Charging". The
  geometry-based lookup (nearest button right of the "Charging" label) and the doubled verification
  exist to fail loudly in that case rather than lie.

`ax_limit.swift` (probe, with `--set N --close --dump`) and `ax_probe.swift` (tree dumps) are the
tools; the app's copy of the sequence is `Sources/BatteryPlus/ChargeLimitSetter.swift`.

### On not being sloppy — measured behaviour of the app's version

The complaint that matters is UX: driving System Settings visibly is not acceptable. Measured on this
machine:

* **Pressing the (i) is the only act that steals focus**, and the sheet is on screen 483 ms after the
  press (polled; the press itself activates System Settings because that is AppKit's sheet behaviour,
  not something AX can suppress).
* Therefore the **sheet is opened once and then parked** (deliberately left open on a background
  window): later sets find the slider already present, so **no press happens at all** and nothing
  moves — verified twice, with the frontmost app unchanged and the record still rewriting.
* The pane itself is opened with `NSWorkspace.OpenConfiguration.activates = false`, so even the
  first navigation does not put a window in front; and right after the one-time press, focus is
  handed back to whichever app had it.
* **Dead end, recorded so nobody repeats it:** hiding System Settings (`AXHidden`) before driving it
  does not work — a hidden app drops out of the Accessibility window list, so the "Charging" row
  cannot be found. Parking the sheet is the alternative that does work.

Cost of the design, stated honestly: a sheet stays open inside System Settings while the app runs, so
opening Settings manually shows the Charge Limit detail already expanded; and if System Settings
quits, the next chip click pays the 483 ms flash once more.

## CONCLUSION — readable, not writable by the obvious means (macOS 27)

* The limit's only on-disk trace is a record powerd maintains:
  `~/Library/Preferences/com.apple.batteryui.charging.mac.plist` →
  `com.apple.batteryui.charging.mac.prior.limit` (int). It matched the System Settings slider at
  every system-written change observed, so **reading it gives the true setting** (unprivileged).
* Writing it is a no-op for the *setting*: `defaults write … 85` persisted in the file, a fully
  restarted System Settings still showed 80, and 240 s of SMC watching showed nothing else move.
* `BfSC` is the *achieved* charge level, not the setting: writing is silently ignored and the value
  drifts with the battery (100 → 98 → 97 → 96 while the setting stood still).
* No IOKit publication (IOPMrootDomain clean), no other preference key anywhere (user or root
  prefs).
* ⇒ powerd owns the live limit in private state; the system UI talks to it over an
  entitlement-gated private XPC. The only remaining mechanism is UI automation of System Settings
  (Accessibility permission, brittle) — not pursued.

## The five-chip setter (still-born, documented so the work is not lost)

`LimitChipRowView` (80/85/90/95/100 chips, accent-highlighted active value) was implemented and
wired to the helper's `SETLIMIT` verb (v0.2), which wrote `BfSC` with read-back verification. The
write died on the no-op; the chips were removed rather than shipped broken. The helper verb is now
harmless dead capability: the app never calls it, and read-back fails honestly if anything does.
`smc_probe --snapshot` + `watch_smc.py` remain the tooling for any future attempt.

## Next step

~~UI automation of the System Settings slider~~ **DONE — see RESOLVED above**: the (i) button on the
"Charging" row opens a sheet with a real slider (80…100), settable through the Accessibility API, and
powerd accepts the change (its settings record rewrites). The app now drives exactly that
(`ChargeLimitSetter.swift`), verifies the read-back *and* the record before reporting success, and
keeps the five chips as the UI. The remaining cost is the Accessibility grant, which a rebuild
invalidates.

## Fallback that needs no privileges

`ioreg -r -c AppleSmartBattery` exposes `ChargerData.NotChargingReason`. It is `16777216` (0x1000000)
in exactly the state where the machine is holding at the limit. That is enough to say **"charging is
being held"** but not *at what percentage* — so it cannot honestly render "Charged to 80% Limit".

## Also confirmed

* The system draws the **bolt whenever the adapter is connected**, not only while current flows.
  At the limit `pmset` says "AC attached; not charging" and the native icon still shows a bolt.
* AlDente is **not installed** on this machine (only the DMG in `~/Downloads`), so nothing else is
  competing for the SMC.
