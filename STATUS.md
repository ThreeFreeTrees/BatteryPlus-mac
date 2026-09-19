# BatteryPlus — status

A replacement for the macOS menu bar battery item that keeps the native glyph in the normal
template colour **at all times**, including in Low Power Mode, where the system turns its own item
yellow. Same menu contents otherwise.

## Where it stands

| Piece | State |
|---|---|
| Glyph | done — drawn, calibrated to the native capture at mean ink diff 1.2 % (non-charging) / 8.7 % (charging, where the bolt silhouette is approximated) — `spikes/002-glyph-fidelity/` |
| Menu bar item | done — template image, never tinted; verified white next to the system's yellow item (`shots/menubar_final.png`). Renders at the native size: both items measure 51x28 px while charging, 51x24 px idle |
| Menu — charge limit | done — set **directly** via PowerUI's private `PowerUISmartChargeClient` (`setMCLLimit:error:`), the same call System Settings makes: instant, invisible, no permissions, no helper, no SMC, no UI automation. Read via `getMCLLimitWithError:`; valid values come from the system itself (80/85/90/95/100). Verified by read-back before success is reported. The line's wording follows the state — "Charging to 95% Limit" while the battery is below the limit, "Charged to 80% Limit" once it has reached it (level-vs-limit, not `IsCharging`: an AC-connected battery above the limit still reports `IsCharging = Yes` on this hardware). If a future macOS drops the API, the app falls back to driving the real control through Accessibility (`ChargeLimitSetter.swift`). Evidence: `spikes/004-charge-limit/README.md` |
| Menu — Low Power switch | done — drawn 34x20 switch on the trailing margin, animated; replaces the system's icon+pill row. It sets the **policy** for both power sources (on ⇒ `lowpowermode 1` for battery and AC, i.e. the Battery pane's "Always"; off ⇒ `0`, "Never"), verified by reading both scopes back — so System Settings agrees with the menu and unplugging no longer drops Low Power Mode. Low Power Mode ramps the display brightness (≈30 % down on enabling, ≈20 % up on disabling), so the app holds the user's brightness across transitions: sampled every 0.25 s, held by an 8 ms background thread started *before* the toggle, and also across changes made outside the app. **The Battery pane is a snapshot**: it re-reads only when the pane is recreated, and no notification we can post (notifyd `com.apple.system.powersources.*`, the same names distributed, nor activating the app) makes an open pane re-read — measured, three ways. So it can display a stale option while the value underneath is correct; the menu and `pmset -g` are the live truth. Trajectories, the two bugs found in real use, and the numbers: `spikes/006-low-power-brightness/`; the picker/values mapping and the stale-pane boundary: `spikes/001-energy-mode-api/policy-and-the-settings-pane.md` |
| Menu — left margin | fixed — every row on the menu's 20 pt text margin (the energy row's icon used to sit at 8 pt) |
| Menu — hover highlighting | fixed — a row's highlight is cleared by asking the pointer (`NSEvent.mouseLocation`) from a tracking-mode timer instead of waiting for `mouseExited`, which is the event that goes missing on a fast sweep (two rows used to stay lit with the cursor elsewhere; user-reported). The chip row's per-chip hover never worked at all before this, because `mouseMoved:` is unreliable in a popup menu owned by a non-active app. Reproduction, the failed `.inVisibleRect` attempt, and the harness: `spikes/008-menu-row-hover/` |
| Charge to Full Now + revert on unplug | **not built, but now cheap** — it needs no SMC write and no privileges: `setMCLLimit:error:` sets 100 and a power-source notification restores the chosen limit on unplug (and it only reverts while the app runs). Apple's own button still does the un-reverting version |
| App icon | done — the battery glyph's own shape at icon scale (same 23:12 body, 1 pt gap, 1.5×4 nub, 4 pt radius), filled with a rainbow gradient, glossy shading, a white "+" centred in the body, on a graphite tile. Regenerate with `make appicon` (renderer: `Sources/IconGenerator/main.swift`); the tile has to be drawn *into* the artwork because macOS composites a custom `.icns` onto its own generic grey squircle otherwise. Small sizes (≤32 px) render a bold variant |
| Menu replica | done — matches the native menu line for line (`spikes/003-menu-replica/`) |
| Battery state | done — public IOKit + `NSProcessInfo`, notification-driven, no polling |
| Energy Mode toggle | done — via the installed setuid-root tool (`/usr/local/libexec/batteryplus-lowpower`, root:wheel 4755), verified by read-back. It is a tool and not a daemon on purpose: a launchd job always adds a second row to Login Items → Background App Activity, and such a row cannot be given an icon under an ad-hoc signature (`SMAppService.daemon` → EPERM, measured from `~/Applications` and from `/Applications`). `PowerUISmartChargeClient`, the class that does the charge limit unprivileged, has no Low Power Mode method at all. Evidence: `spikes/007-low-power-daemon/`, `spikes/001-energy-mode-api/` |
| Login Items row | done — **on by default at installation**: `SMAppService.mainApp` (accepted for an ad-hoc signature, unlike the daemon variant) registers the item when the app is installed, keyed on the bundle's modification date. After that the app keeps its hands off, so deleting the row in System Settings sticks (`route=left-removed-by-user`, measured); a reinstall changes the bundle's date and starts from "on" again (`route=registered-on-install:smappservice`, measured). No switch for it in the menu — by request, removal is done in System Settings |
| `Using Significant Energy` | **not implemented** — the system's data needs `com.apple.private.systemstats.analysis-client` |
| Hiding the system's own battery item | manual (System Settings → Control Center → Battery) |

## Use

```sh
make build      # build build/BatteryPlus.app
make run        # start it — the glyph appears at the left end of the status area
make stop       # quit it
make capture    # pop the menu open and photograph it (development aid)

sudo install/install-helper.sh    # one-time: installs the setuid tool that enables the Low Power toggle
sudo install/uninstall-helper.sh  # undo (also clears any daemon-era leftovers)
```

To finish the swap: System Settings → Control Center → Battery → *Don't Show in Menu Bar*, then
⌘-drag our item to where the battery icon used to sit (the position is remembered).

## Layout

```
Sources/BatteryPlus/      the app: model, icon, menu, rows, privileged-tool client
Sources/Privileged/       the setuid-root tool (C): `pmset`, fixed args, console user only, empty env
Sources/BatteryIconCLI/   calibration tool: renders the glyph to PNG for pixel diffs
install/                  install/uninstall scripts + package builder
spikes/                   the throwaway investigations, each with a verdict
shots/                    captured comparisons (replica menu, menu bar)
```
