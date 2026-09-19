# spike 007 — the Low Power Mode privileged piece, and why it is no longer a daemon

## What changed

The Low Power toggle used to be done by a launchd **LaunchDaemon**
(`/usr/local/libexec/BatteryPlusHelper.app`, label `com.mambo.batteryplus.helper`) that exposed
`PING`/`GET`/`SET` on `/var/run/batteryplus.sock`. It has been replaced by a **setuid-root tool**,
`/usr/local/libexec/batteryplus-lowpower`, which the app runs on demand. The daemon's source, its
property list and its bundle template are kept here for the record.

## Why

Two rows in **System Settings → Login Items → Background App Activity** were worse than one:

| row | source |
|---|---|
| `BatteryPlus.app` | the app's own login item (`SMAppService.mainApp`) |
| `batteryplus-helper` | the LoLaunchDaemon |

Anything registered with launchd shows up in that list, and the row cannot be rebranded:

* a custom `.icns` is ignored — the row of an executable inside a bundle still gets the generic
  `exec` glyph (measured: `NSWorkspace.icon(forFile:)` returns the app icon for the *bundle* and the
  generic glyph for the binary inside it; the pane follows the latter);
* the supported route is `SMAppService.daemon(plistName:)`, which the system **refuses under an
  ad-hoc signature** — `register()` → `Operation not permitted`, measured twice, once from
  `~/Applications` and once from `/Applications` with the real app's own code. The plist is found
  (status `requiresApproval`), the signature is what fails.

`SMAppService.mainApp` behaves the opposite way: it is **accepted** for an ad-hoc signature, which is
why the app's own row exists and works.

A setuid tool registers nothing with launchd, so it produces no row at all — the app is left as the
only entry, carrying its own icon.

## Preconditions, measured on this machine

* `pmset -b|-c lowpowermode 0|1` as an ordinary user: `'pmset' must be run as root...` — so the write
  genuinely needs root, and some privileged piece must exist.
* `PowerUISmartChargeClient` — the class that does the charge limit unprivileged — has 76 methods and
  **none** of them touch Low Power Mode. PowerUI is not a route for it; the charge limit remains the
  only unprivileged private API here.
* `/System/Volumes/Data` is mounted **without** `nosuid`, and `/usr/bin/sudo` is setuid root, so
  setuid binaries are honoured on the volume that holds `/usr/local`.

## The tool

`Sources/Privileged/batteryplus-lowpower.c`, installed root:wheel mode 4755:

* accepts exactly two arguments, `<battery|ac>` and `<0|1>`, and nothing else;
* `execve`s `/usr/bin/pmset` with those flags and an **empty environment** — no `PATH`, nothing
  inherited to smuggle anything through;
* acts only for the user at the console (`getuid() == stat("/dev/console").st_uid`) — the same rule
  the daemon enforced on its socket;
* has no other capability: no shell, no configuration, no file access.

The app still does not trust the exit status: `EnergyModeClient.setEnergyMode` reads `pmset -g custom`
back and only reports success when the read-back agrees (the rule from spike 001).

## Trade-off, stated plainly

A setuid-root binary is a larger security decision than a socket-mediated daemon: anyone able to
execute it could try to abuse it. It is deliberately tiny (fixed program, fixed flags, empty
environment, console-user check), but it is still a setuid-root binary. The Apple-sanctioned
equivalents (`SMJobBless`, `SMAppService.daemon`) both require a real Developer ID signature, which
this project does not have.
