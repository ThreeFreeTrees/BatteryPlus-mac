#!/bin/bash
# Removes the BatteryPlus privileged tool, plus anything the daemon-era install left behind.
# Requires root.   Usage:  sudo ./uninstall-helper.sh

set -euo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "This uninstaller must run as root:  sudo $0" >&2
  exit 1
fi

TOOL="/usr/local/libexec/batteryplus-lowpower"

echo "→ removing the setuid tool"
rm -f "${TOOL}"

echo "→ removing anything the daemon-era install left behind"
for OLD_LABEL in com.mambo.batteryplus.helper com.mambo.batterymenu.helper com.mambo.betterplus.helper; do
  launchctl bootout "system/${OLD_LABEL}" 2>/dev/null || true
  rm -f "/Library/LaunchDaemons/${OLD_LABEL}.plist"
done
rm -rf /usr/local/libexec/BatteryPlusHelper.app
rm -f /usr/local/libexec/batteryplus-helper /usr/local/libexec/batterymenu-helper /usr/local/libexec/betterplus-helper
rm -f /var/run/batteryplus.sock /var/run/batterymenu.sock /var/run/betterplus.sock
rm -f /var/log/batteryplus-helper.log /var/log/batterymenu-helper.log /var/log/betterplus-helper.log

echo
echo "Removed. Verify nothing was left behind (\"No such file\" on every line is the expected result):"
ls -l "${TOOL}" \
      /usr/local/libexec/BatteryPlusHelper.app \
      /Library/LaunchDaemons/com.mambo.batteryplus.helper.plist \
      /var/run/batteryplus.sock 2>&1 | sed 's/^/  /' || true

echo
echo "The app keeps working — the Low Power toggle will report that the tool is not installed,"
echo "and Login Items → Background App Activity will show no privileged row at all."
