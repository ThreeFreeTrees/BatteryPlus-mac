#!/bin/sh
# make-installer.sh — build one .pkg that installs BatteryPlus.
#
# The package carries the app into /Applications and the privileged piece into /usr/local/libexec.
# That piece is a root-owned, setuid-root tool (mode 4755), not a launchd daemon: a loaded launchd job
# always appears in Login Items → Background App Activity, and such a row cannot be given a proper
# icon under an ad-hoc signature (SMAppService.daemon → EPERM, measured). A setuid tool registers
# nothing, so the app is the only row.
#
# The postinstall mirrors install/install-helper.sh: it removes anything the daemon-era install left
# behind, re-asserts ownership and the setuid bit, and starts the app in the console user's session.
#
#   install/make-installer.sh          → dist/BatteryPlus-<version>.pkg
#
# Double-click the .pkg to install (macOS asks for the admin password once).

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || echo 0.1)"
STAGE="$PROJECT_DIR/build/pkg-root"
SCRIPTS="$PROJECT_DIR/build/pkg-scripts"
OUTPUT="$PROJECT_DIR/dist/BatteryPlus-$VERSION.pkg"

rm -rf "$STAGE" "$SCRIPTS"
mkdir -p "$STAGE/Applications" "$STAGE/usr/local/libexec" "$SCRIPTS" "$PROJECT_DIR/dist"

echo "→ building the app and the privileged tool"
make build >/dev/null
make helper >/dev/null

echo "→ staging the payload"
# --norsrc/--noextattr/--noacl, then a sweep: without them pkgbuild carries the source's extended
# attributes as AppleDouble "._" files, which show up as junk in the payload.
ditto --norsrc --noextattr --noacl "$PROJECT_DIR/build/BatteryPlus.app" "$STAGE/Applications/BatteryPlus.app"
install -m 4755 "$PROJECT_DIR/install/batteryplus-lowpower" "$STAGE/usr/local/libexec/batteryplus-lowpower"
xattr -cr "$STAGE" 2>/dev/null || true
find "$STAGE" -name '._*' -delete 2>/dev/null || true

echo "→ writing the postinstall"
cat > "$SCRIPTS/postinstall" <<'POSTINSTALL'
#!/bin/sh
# Runs as root, after the files are in place. Mirrors install/install-helper.sh.
set -e

TOOL="/usr/local/libexec/batteryplus-lowpower"

# Whoever is at the console owns the app after install, so `make install` keeps working for them.
TARGET_UID="$(stat -f%u /dev/console 2>/dev/null || echo 501)"
if [ "$TARGET_UID" = "0" ] || [ -z "$TARGET_UID" ]; then
    TARGET_UID="$(id -u "$(stat -f%Su /dev/console 2>/dev/null)" 2>/dev/null || echo 501)"
fi
[ "$TARGET_UID" = "0" ] && TARGET_UID=501

# Anything the daemon-era install left behind: the launchd job, its socket, the bundle, and the bare
# binaries under the three names this project has had. Removing them is what makes the old second
# Login Items row disappear on an upgrade.
for OLD_LABEL in com.mambo.batteryplus.helper com.mambo.batterymenu.helper com.mambo.betterplus.helper; do
    launchctl bootout "system/${OLD_LABEL}" >/dev/null 2>&1 || true
    rm -f "/Library/LaunchDaemons/${OLD_LABEL}.plist"
done
rm -rf /usr/local/libexec/BatteryPlusHelper.app
rm -f /usr/local/libexec/batteryplus-helper /usr/local/libexec/batterymenu-helper /usr/local/libexec/betterplus-helper
rm -f /var/run/batteryplus.sock /var/run/batterymenu.sock /var/run/betterplus.sock
rm -f /var/log/batteryplus-helper.log /var/log/batterymenu-helper.log /var/log/betterplus-helper.log

# Re-assert what matters about the tool: root-owned, and setuid — without that bit the Low Power
# toggle cannot work, so the package fails loudly rather than installing something inert.
chown root:wheel "$TOOL"
chmod 4755 "$TOOL"
if [ ! -u "$TOOL" ]; then
    echo "batteryplus: the setuid bit did not stick on $TOOL" >&2
    exit 1
fi

if [ -d /Applications/BatteryPlus.app ]; then
    chown -R "${TARGET_UID}:admin" /Applications/BatteryPlus.app 2>/dev/null || true
fi

# Start the app in the console user's session, so it is in the menu bar right after installing rather
# than waiting in /Applications to be found. `launchctl asuser` is what puts it in their GUI session —
# a plain `open` from this root context would not. /usr/bin/open is spelled out because a package
# script runs with a minimal PATH.
if [ -d /Applications/BatteryPlus.app ]; then
    launchctl asuser "$TARGET_UID" /usr/bin/open -a /Applications/BatteryPlus.app >/dev/null 2>&1 || true
fi

exit 0
POSTINSTALL
chmod +x "$SCRIPTS/postinstall"

echo "→ building the package"
pkgbuild --root "$STAGE" \
         --scripts "$SCRIPTS" \
         --identifier "com.mambo.batteryplus.pkg" \
         --version "$VERSION" \
         --install-location "/" \
         "$OUTPUT" >/dev/null

echo
echo "built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo "payload:"
pkgutil --payload-files "$OUTPUT" | sed 's/^/  /'
