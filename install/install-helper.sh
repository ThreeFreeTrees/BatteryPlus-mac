#!/bin/bash
# Installs the privileged piece that lets BatteryPlus set Low Power Mode.
#
# This is the ONE step that needs your authorization. It is deliberately small and reversible: it
# copies one root-owned, setuid-root tool to /usr/local/libexec/batteryplus-lowpower.
#
# Why a setuid tool and not a launchd daemon (the daemon this replaced is kept for the record in
# spikes/007-low-power-daemon): every loaded launchd job appears in System Settings → Login Items →
# Background App Activity, and that row cannot be given a proper icon under an ad-hoc signature
# (SMAppService.daemon → EPERM, measured). A setuid tool registers nothing, so the app stays the only
# row — with its own icon.
#
# The tool does exactly one thing: `pmset -b|-c lowpowermode 0|1`, with fixed flags, an empty
# environment, and only for the user at the console. Nothing about it is configurable at runtime.
#
# Undo at any time with ./uninstall-helper.sh
#
# Usage:  sudo ./install-helper.sh [path-to-batteryplus-lowpower]

set -euo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "This installer must run as root:  sudo $0" >&2
  exit 1
fi

TARGET_UID="$(stat -f%u /dev/console 2>/dev/null || echo 501)"
if [ "${TARGET_UID}" = "0" ] || [ -z "${TARGET_UID}" ]; then
  TARGET_UID="${SUDO_UID:-501}"
  [ "${TARGET_UID}" = "0" ] && TARGET_UID=501
fi
TARGET_USER="$(id -un "${TARGET_UID}" 2>/dev/null || echo "uid ${TARGET_UID}")"

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_SRC="${1:-${SOURCE_DIR}/batteryplus-lowpower}"
TOOL_DST="/usr/local/libexec/batteryplus-lowpower"

[ -f "${TOOL_SRC}" ] || { echo "tool not found: ${TOOL_SRC} — run 'make helper' first" >&2; exit 1; }

# Everything the daemon-era install left behind — the launchd job, its socket, the bundle, and the bare
# binaries under all three names. Removing them is what makes the second Login Items row disappear.
echo "→ removing the daemon-era install (launchd job, socket, bundle)"
for OLD_LABEL in com.mambo.batteryplus.helper com.mambo.batterymenu.helper com.mambo.betterplus.helper; do
  launchctl bootout "system/${OLD_LABEL}" 2>/dev/null || true
  rm -f "/Library/LaunchDaemons/${OLD_LABEL}.plist"
done
rm -rf /usr/local/libexec/BatteryPlusHelper.app
rm -f /usr/local/libexec/batteryplus-helper /usr/local/libexec/batterymenu-helper /usr/local/libexec/betterplus-helper
rm -f /var/run/batteryplus.sock /var/run/batterymenu.sock /var/run/betterplus.sock
rm -f /var/log/batteryplus-helper.log /var/log/batterymenu-helper.log /var/log/betterplus-helper.log

echo "→ installing the setuid tool"
mkdir -p /usr/local/libexec
install -o root -g wheel -m 4755 "${TOOL_SRC}" "${TOOL_DST}"
# Belt and braces: install(1) sets both, but the setuid bit is the entire point — verify it landed.
[ -u "${TOOL_DST}" ] || { echo "the setuid bit did not stick on ${TOOL_DST}" >&2; exit 1; }

echo
echo "→ status"
ls -l "${TOOL_DST}" | awk '{print "  "$1, $3, $4, $9}'
echo "  invocable only by the user at the console; it runs only: pmset -b|-c lowpowermode 0|1"

# If the app is installed, start it in the target user's GUI session — the same thing the .pkg's
# postinstall does, so installing this also leaves the menu bar item already running.
if [ -d /Applications/BatteryPlus.app ]; then
  echo "→ starting the app in ${TARGET_USER}'s session"
  launchctl asuser "${TARGET_UID}" /usr/bin/open -a /Applications/BatteryPlus.app 2>/dev/null || true
fi

echo
echo "Verify with:   ls -l ${TOOL_DST}      # expect -rwsr-xr-x root wheel"
echo "               then toggle Low Power Mode from the app's menu"
echo "Uninstall with: sudo ${SOURCE_DIR}/uninstall-helper.sh"
