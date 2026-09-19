# Security

This is a personal, source-only project. There is no signed binary and no prebuilt download — you build
and install it yourself, so every privileged piece is one you compiled from the code in this repository.

## The privileged piece

Low Power Mode cannot be set without root (`pmset` refuses as an ordinary user: `'pmset' must be run as
root...`), so the Low Power switch needs one privileged component. It is a **setuid-root tool**, built
from `Sources/Privileged/batteryplus-lowpower.c` and installed as
`/usr/local/libexec/batteryplus-lowpower`, mode `4755`, owned `root:wheel`.

What it can do is deliberately the whole story:

* it accepts exactly two arguments, `<battery|ac>` and `<0|1>`, and rejects anything else;
* it `execve`s `/usr/bin/pmset` with those flags and an **empty environment** — no `PATH`, nothing
  inherited that could be used to redirect it;
* it acts only for the user at the console (`getuid() == stat("/dev/console").st_uid`);
* it has no shell, no configuration, no file access, no network, and no other verb.

It is ~40 lines. Read it before installing it.

`install/uninstall-helper.sh` removes it again, along with the LaunchDaemon-era files older versions of
this project installed.

## Why not Apple's mechanisms

`SMJobBless` and `SMAppService.daemon` both require a real Developer ID signature, which this project
does not have. Registering a launchd daemon is refused for an ad-hoc signature (`Operation not
permitted`, measured — see `spikes/007-low-power-daemon/`). A setuid tool was chosen over the daemon
this project used to install because any loaded launchd job adds a row to Login Items → Background App
Activity, and that row cannot be given a proper icon without a real signature either.

## Private API use

The charge limit is set through Apple's private `PowerUISmartChargeClient` in `PowerUI.framework`, the
same client System Settings uses. It is unsupported, may change or disappear in any macOS update, and
makes this app unsuitable for the App Store. Every call is wrapped so a missing API degrades to a
reported failure rather than a crash, and the write is verified by reading the value back. Details and
the raw evidence: `spikes/004-charge-limit/`.

## Reporting

This is a hobby project without a security team. If you find a problem — especially anything that makes
the privileged tool do more than the list above — please open an issue describing the trigger and the
effect.
