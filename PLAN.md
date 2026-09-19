# BatteryMenu — plan

## Goal (from user, 2026-09-18)
A menu bar item that renders the **native macOS battery glyph** in the **normal template color**
(white on a dark menu bar, black on light) — *including* while Low Power Mode is on, i.e. it must
**never** show the yellow LPM tint. Clicking it opens a **replica of the system Battery status menu**:
`Battery NN%` header, `Power Source: …`, `Energy Mode` (Low Power / Automatic / High Power with the
active row highlighted), `Using Significant Energy`, `Battery Settings…`.

Constraints: local, personal use on this Mac. No SIP changes, no sealed-volume edits.

## Active-state source (decided — spike 001 partial result)

`NSProcessInfo.isLowPowerModeEnabled` is the authoritative **active** state and agrees with the
per-power-source scoping in pmset:

- `pmset -g custom` → `Battery Power: lowpowermode 0`, `AC Power: lowpowermode 1`
  (i.e. LPM is configured "on power adapter only")
- currently on battery → `isLowPowerModeEnabled == false` — consistent ✔

**Correction:** an earlier reading of `pmset -g | grep lowpowermode` → `1` was the AC-scoped value,
not the live state. The Mac was *not* in Low Power Mode at recon time; the user's screenshot was
taken when LPM was effectively active.
**Consequence:** the icon must key off `isLowPowerModeEnabled` + `NSProcessInfoPowerStateDidChangeNotification`,
never off a `pmset` line.

## Verified constraints (evidence, 2026-09-18)

| Fact | Evidence |
|---|---|
| The yellow LPM tint is drawn by Control Center, not an asset or pref | `defaults -currentHost read com.apple.controlcenter` → only visibility/position keys; system volume is SIP-sealed |
| Public LPM read + change notification (macOS 12+) | SDK `Foundation/NSProcessInfo.h:219-242` → `isLowPowerModeEnabled`, `NSProcessInfoPowerStateDidChangeNotification` |
| Public battery data + event-driven updates (no polling) | SDK `IOKit/ps/IOPowerSources.h` → `IOPSCopyPowerSourcesInfo`, `IOPSGetPowerSourceDescription`, `IOPSNotificationCreateRunLoopSource`; Apple: prefer `kIOPSNotifyPowerSource`/`kIOPSNotifyTimeRemaining`, `kIOPSNotifyAnyPowerSource` uses more energy |
| Setting Energy Mode via `pmset` needs root | `pmset -b lowpowermode 1` → `'pmset' must be run as root...` |
| Control Center (unprivileged) links `_IOPMSetEnergyModePreference` | `nm -u /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter \| grep IOPM` |
| That symbol is exported/linkable | `IOKit.framework/Versions/A/IOKit.tbd:500` lists `_IOPMSetEnergyModePreference`, `_IOPMSetGamingEnergyModePreference`, `_IOPMSetReservePowerMode`, `_IOPMSetPMPreference`, `_IOPMFeatureIsAvailable` |
| Glyph built from SF Symbols | `CoreGlyphs.bundle/symbol_order.plist` contains `battery.0/25/50/75/100percent`, `battery.100percent.bolt` |
| "Using Significant Energy" has no public API | grep of SDK headers: no `significantEnergy`; `top` has no energy column; `powermetrics --show-process-energy` needs a password; `/private/var/db/systemstats/*.stats` are world-readable (candidate, TCC may block) |
| Design rules | Apple HIG "The menu bar": height 24 pt; use a symbol; template/symbol art is black+clear so the system recolors it; "Display a **menu** — not a popover — when people click your menu bar extra" |

## Strategy: spike the unknowns, then build with one owner

Risk-ordered spikes (throwaway, per the `spike` skill):

| # | Spike | Question (Given/When/Then) | Risk | Status |
|---|---|---|---|---|
| 001 | energy-mode-api | Given an unprivileged app, when it calls the IOKit energy-mode setter, then LPM flips and reads back via `NSProcessInfo` | **High** | **done — PARTIAL**, see `spikes/001-energy-mode-api/README.md` |
| 002 | glyph-fidelity | Given SF Symbol `battery.NNpercent` at menu bar metrics, when rendered template-style, then a pixel diff vs. a capture of the native glyph is within antialiasing noise | Medium | **done — VALIDATED**, drawn glyph matches at mean ink diff 1.2 % (`spikes/002-glyph-fidelity/README.md`) |
| 003 | menu-replica | Given an `NSMenu` with custom-view rows, when opened, then its row geometry matches the native menu capture | Medium | **done — VALIDATED**, structure and styling match line for line (`spikes/003-menu-replica/README.md`) |
| 004 | significant-energy | Given `/private/var/db/systemstats`, when parsed, then per-app energy significance is recoverable; else omit the row | Low/unknown | answered: omit (private gate) |

### Spike 001 result — the one thing that changes the design

Signature recovered from Control Center's call site (Swift small-string constants at `0x1000296b8`):

```c
IOReturn IOPMSetEnergyModePreference(CFStringRef mode, CFStringRef powerSource);
// mode: "Automatic" | "LowPowerMode" | "HighPowerMode"
// powerSource: "AC Power" | "Battery Power" | "UPS Power"
```

- **Reading state is public and safe** → icon and menu highlight key off `isLowPowerModeEnabled`.
- **Writing is gated by a restricted entitlement** (`com.apple.private.iokit.updatemodepreference`,
  held by Control Center and Apple's Battery settings extension). Without it the call returns
  `rc=0` and does nothing — a *silent* success. Self-signing that entitlement gets the process
  killed by AMFI. `pmset` needs root.

⇒ Two rules for the build:
1. **Never trust the setter's return code — always read the state back** and reconcile the UI with it.
2. The Energy Mode row's implementation is a product decision, not a technical one:
   `(a)` scoped sudoers rule (one admin prompt at install, no prompts after, real toggle),
   `(b)` root helper/LaunchDaemon, or `(c)` read-only row + deep link to System Settings → Battery.
   "Using Significant Energy" is out of reach for the same reason
   (`com.apple.private.systemstats.analysis-client`) → omit or approximate transparently.

Build only after 001-003 report. Then a single-owner build (me) — the icon, menu and state machine
share one runtime, so parallel builders would collide.

## Helper architecture (from AlDente's own bundle, no install)

Inspected `~/Downloads/AlDente.dmg` read-only (mounted, read, unmounted — AlDente itself was never installed):

| Evidence | What it shows |
|---|---|
| `Contents/Library/LaunchServices/com.apphousekitchen.aldente-pro.helper` | **SMJobBless privileged helper** — Apple's blessed-helper location |
| App `Info.plist` → `SMPrivilegedExecutables` | requirement pinned to `anchor apple generic … OU = "3WVC84GB99"` |
| Helper `Info.plist` → `SMAuthorizedClients` | the mirror requirement, pinning the app's signature |
| Helper strings → `AppleSMC` | it needs privileged SMC access for charge control — the reason it needs root at all |
| `Contents/Library/LoginItems/LaunchAtLoginHelper.app` | separate `SMLoginItemSetEnabled` launch-at-login helper |
| `spctl -a -vv` → `Notarized Developer ID: AppHouseKitchen GmbH (3WVC84GB99)` | their installer machinery depends on Apple-issued signing |

**Our deviation, forced by one fact:** `security find-identity -v -p codesigning` → **0 identities** on this Mac.
SMJobBless requires the helper (and app) to satisfy `anchor apple generic`, and `SMAppService.daemon`
likewise expects a properly signed bundle — neither is available to a self-signed local app. So we keep
**the same architecture** (root helper + launchd job + IPC, installed once with one authorization) and
replace Apple's installer with a small, auditable install script.

```
Library/LaunchDaemons/com.mambo.batterymenu.helper.plist   root:wheel, pinned to the user's uid
/usr/local/libexec/batterymenu-helper                       root:wheel, ad-hoc signed
/var/run/batterymenu.sock                                   owner = user, mode 0600
```

Security model — the operation space is 4 fixed commands (`pmset -b|-c lowpowermode 0|1`):
- socket is 0600 and owned by the user; `getpeereid()` re-verifies the peer uid per connection
- `pmset` is spawned with fixed argv — no shell, no interpolation of request data
- one-line strictly parsed requests, 128-byte cap; `SET` accepted only as `SET <battery|ac> <0|1>`
- every `SET` reads state back and returns it, so the caller never trusts a return code alone
- `install/uninstall-helper.sh` are the entire privileged surface; uninstall is one command

### Verified without privilege (helper run as the user on a scratch socket)

| Test | Result |
|---|---|
| `PING` / `GET` | `OK pong 0.1 uid=501` ; `OK battery=0 ac=1` — matches `pmset -g custom` exactly |
| `SET` while unprivileged | `ERR pmset exit 1 '/usr/bin/pmset' must be run as root…`, state unchanged after — proves the real error propagates instead of a fake success |
| Wrong peer uid (helper allows 9999, client is 501) | `ERR forbidden peer uid 501` — peer check works |
| Malformed/hostile: `SET`, `SET battery`, `SET bogus 1`, `SET battery 2`, `SET battery 1; rm -rf /`, `SET battery 0 && echo pwned` | all refused with the usage error — no shell interpretation |
| Oversize request (400 bytes) | truncated to 128 bytes, refused |
| Socket permissions | `srw-------` owned by the user |

**Still unverified until the one-time install:** `SET` succeeding as root and actually flipping the mode.
That requires the user's authorization — that is the install step, not a code change.



```
BatteryMenu/
├── Sources/BatteryMenu/
│   ├── main.swift          # NSApplication + status item, LSUIElement
│   ├── BatteryModel.swift  # IOPowerSources + ProcessInfo notifications → @Published state
│   ├── BatteryIcon.swift   # SF Symbol glyph, isTemplate = true, width matched to native
│   ├── BatteryMenu.swift   # NSMenu replica, custom-view rows
│   ├── EnergyMode.swift    # energy-mode wrapper: public read, privileged write bridge, or fallback link (see spike 001)
│   ├── StateVerifier.swift # reads state back after any write; UI trusts this, never a return code
│   └── Settings.swift      # energy-mode availability, icon scale
├── Makefile                # swiftc → .app bundle → codesign -s - (ad-hoc, local run)
└── spikes/
```

Key choices: `NSStatusItem(variableLength)`, `LSUIElement=YES`, `isTemplate=true` (this single flag
*is* the "same color in both states" requirement — we never apply a tint), event-driven updates only,
`autosaveName` so ⌘-drag repositioning sticks, menu (not popover) per HIG.

## Verification (objective, not eyeballed)

1. **Icon parity with LPM on vs off** — capture the menu bar region in both states, pixel-diff:
   must be **0 differing pixels**. This is the core requirement, so it is a hard gate.
2. **Icon fidelity vs. native** — capture native glyph at 10/25/50/75/100 % and charging; diff against ours;
   record max channel delta and glyph bounding box (width/height/offset).
3. **Menu geometry** — capture native menu and ours; compare row y-boundaries, separator positions, text baselines.
4. **Idle cost** — CPU ≈ 0 % over 60 s, no `Timer` in the code path; verify updates arrive via notifications by
   unplug/replug, sleep/wake, and changing LPM from System Settings (not through us).
5. **Private API degradation** — if `IOPMSetEnergyModePreference` is unavailable, the row hides and
   "Open Battery Settings" remains (no crash, no dead button).

## Agents / subagents

- **Available:** Hermes `delegate_task` (isolated context + terminal per child, up to 10 parallel).
  **Not available:** Claude Code / Codex / OpenCode CLIs — verified absent (`which` → only `git`), and no Homebrew.
- **Delegate:** spike 001's signature reverse-engineering (read-only disassembly of Control Center's call
  site — context-heavy, self-contained); a final independent code review; a robustness review of the
  notification/state machine.
- **Do not delegate:** the integration build (one owner), icon fidelity judgement (needs the user's eyes),
  and never two GUI tests at once — one menu bar, one screen, one `screencapture`.
- **Trust rule:** subagent claims about system state get re-verified by me (e.g. the LPM flip test I run myself,
  reading state back from `NSProcessInfo`).

## Risks

| Risk | Mitigation |
|---|---|
| Private API changes/breaks on OS update | one small file (`EnergyMode.swift`), runtime feature-detect, graceful row degradation |
| Wrong signature ⇒ crash or wrong setting | probe guarded behind an explicit flag; verify by reading state back; restore original state |
| Duplicate battery icons | instruct hiding the native item (System Settings → Control Center → Battery); document in README |
| Icon width/position drift vs. native | `variableLength` + measured width from `CGWindowListCopyWindowInfo`, `autosaveName` for user placement |
