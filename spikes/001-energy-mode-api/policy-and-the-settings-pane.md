# The Battery pane's picker and the values behind it (measured)

Written after a report that looked like a contradiction:

> "Changing low power mode doesn't change the setting in the battery settings from apple. If LPM is
> activated, i could still see LPM set to 'never' in the settings."

## What the picker is

The Battery pane's **Low Power Mode** row is a picker over the same per-power-source values `pmset`
reports — not a separate setting. On this machine, measured:

| picker | Battery Power | AC Power |
|---|---|---|
| Never | 0 | 0 |
| Always | 1 | 1 |

Both were confirmed by observation rather than inference: the user set the picker to Never and the values
read `0 / 0`; the app then wrote `1 / 1` and a freshly opened pane showed **Always**.

Persistence: `/Library/Preferences/com.apple.PowerManagement.<machine-UUID>.plist`, key `LowPowerMode`
per source. The generic `/Library/Preferences/com.apple.PowerManagement.plist` carries **no** LPM key at
all — looking there finds nothing and proves nothing.

## Why the report looked like a contradiction

Two separate things, and a stale UI:

1. The app used to write only the scope matching the current power source (`ac` while on the adapter),
   leaving Battery Power at `0`. That is a perfectly valid policy — the picker's own "Only on Power
   Adapter" option is exactly `battery 0 / ac 1` — but it means Low Power Mode silently drops the moment
   the Mac is unplugged.
2. The pane reads that value **when the pane is created** and, measured, never re-reads it while it is
   open. Everything that plausibly could have nudged it was tried and failed:
   * notifyd posts of `com.apple.system.powersources.source` / `.percent` / `.attach` — the names the
     pane's own binary contains — no effect;
   * the same names posted as **distributed** notifications — no effect;
   * activating System Settings — no effect;
   * and the pane's displayed value is a local view-model value, so a write from *any* other process
     (including `sudo pmset -a lowpowermode 1`) cannot update it.

   Only recreating the pane (⌘W then reopen, or quit and reopen Settings) makes it re-read; a freshly
   opened pane showed `Always` on the very values the stale one was calling `Never`.

The read-out was measured with the Accessibility API rather than screenshots after this: the stale pane's
`AXPopUpButton` value was `Never` while `pmset -g custom`, the plist and `ProcessInfo` all said Low Power
Mode was on. A settings pane is not an oracle about a value another process owns.

## What the app does now

The menu switch sets the picker's two unambiguous states, writing **both** scopes and verifying both on
read-back:

* turning Low Power Mode on ⇒ `lowpowermode 1` for battery and AC ⇒ pane reads **Always**
* turning it off ⇒ `lowpowermode 0` for battery and AC ⇒ pane reads **Never**

Battery is written first: on the adapter that write is invisible, on battery it is the one visible
change, so either way the state flips exactly once and there is no intermediate flicker.

Verified: `--low-power off` → `battery=0 ac=0`; `--low-power on` → `battery=1 ac=1`; a freshly opened
pane showing **Always**; `ProcessInfo.isLowPowerModeEnabled` true.
