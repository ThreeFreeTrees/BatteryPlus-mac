# BatteryPlus — build a locally-signed .app; no Xcode project, just swiftc + codesign.
#
#   make            build build/BatteryPlus.app
#   make run        run it (adds the item to the menu bar)
#   make demo       pop the menu open for 7 s so it can be photographed
#   make capture    build, run `demo`, capture the menu region, then stop
#   make stop       kill any running instance
#   make helper     build the privileged helper
#   make clean

APP        := BatteryPlus.app
BUILD      := build
BIN        := $(BUILD)/$(APP)/Contents/MacOS/BatteryPlus
SOURCES    := $(wildcard Sources/BatteryPlus/*.swift)
# Deployment target must be set explicitly: this toolchain's SDK defaults to the *next* macOS
# version, and a binary that declares a minimum OS newer than the running system is refused by
# LaunchServices with kLSIncompatibleSystemVersionErr (-10825) — it runs from the terminal but
# `open` fails. macOS 13 covers every API used here.
ARCH       := $(shell uname -m)
DEPLOY     := 13.0
SWIFTFLAGS := -O -target $(ARCH)-apple-macos$(DEPLOY) -framework AppKit -framework IOKit -framework ApplicationServices -framework Foundation -import-objc-header Sources/PrivateAPI/PrivateAPI.h
# The charge-limit API lives behind Objective-C (Swift cannot message undeclared selectors).
OBJC       := Sources/PrivateAPI/PowerUIChargeLimit.m
OBJC_OBJ   := $(BUILD)/PowerUIChargeLimit.o
C_SRC      := Sources/PrivateAPI/DisplayBrightness.c
C_OBJ      := $(BUILD)/DisplayBrightness.o

.PHONY: build run demo capture stop helper clean

build: $(BIN)

$(OBJC_OBJ): $(OBJC) Sources/PrivateAPI/PowerUIChargeLimit.h
	@mkdir -p "$(BUILD)"
	clang -O2 -fobjc-arc -mmacosx-version-min=13.0 -c "$(OBJC)" -o "$(OBJC_OBJ)"

$(C_OBJ): $(C_SRC) Sources/PrivateAPI/DisplayBrightness.h
	@mkdir -p "$(BUILD)"
	clang -O2 -mmacosx-version-min=13.0 -c "$(C_SRC)" -o "$(C_OBJ)"

$(BIN): $(SOURCES) $(OBJC_OBJ) $(C_OBJ) Info.plist Resources/AppIcon.icns
	@mkdir -p "$(BUILD)/$(APP)/Contents/MacOS" "$(BUILD)/$(APP)/Contents/Resources"
	swiftc $(SWIFTFLAGS) -o "$(BIN)" $(SOURCES) $(OBJC_OBJ) $(C_OBJ)
	@cp Info.plist "$(BUILD)/$(APP)/Contents/Info.plist"
	@cp Resources/AppIcon.icns "$(BUILD)/$(APP)/Contents/Resources/AppIcon.icns"
	@codesign --force --sign - "$(BUILD)/$(APP)" 2>/dev/null || true
	@echo "built $(BUILD)/$(APP)"

icon: $(BUILD)/batteryicon
$(BUILD)/batteryicon: Sources/BatteryPlus/BatteryIcon.swift Sources/BatteryIconCLI/main.swift
	@mkdir -p "$(BUILD)"
	swiftc -O -target $(ARCH)-apple-macos$(DEPLOY) -framework AppKit -o "$(BUILD)/batteryicon" Sources/BatteryPlus/BatteryIcon.swift Sources/BatteryIconCLI/main.swift
	@echo "built $(BUILD)/batteryicon"

# The app icon: the battery glyph's shape, rainbow, shaded, with a "+". Regenerate with `make appicon`.
appicon:
	@mkdir -p "$(BUILD)" Resources
	swiftc -O -target $(ARCH)-apple-macos$(DEPLOY) -framework AppKit -o "$(BUILD)/batteryicon-rainbow" Sources/IconGenerator/main.swift
	@"$(BUILD)/batteryicon-rainbow" "$(BUILD)/AppIcon.iconset"
	iconutil -c icns "$(BUILD)/AppIcon.iconset" -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns — rebuild to put it in the bundle"

run: build stop
	@open "$(BUILD)/$(APP)" || "$(BIN)"
	@echo "running — look for the battery glyph in the menu bar"

# Put a stable copy in /Applications (no sudo needed) so it can be added as a login item.
install: build
	@rm -rf "/Applications/$(APP)"
	@cp -R "$(BUILD)/$(APP)" "/Applications/$(APP)"
	@codesign --force --sign - "/Applications/$(APP)" 2>/dev/null || true
	@echo "installed /Applications/$(APP)"
	@echo "add it at login with: System Settings → General → Login Items → + → /Applications/$(APP)"

demo: build stop
	@"$(BIN)" --demo-menu-at 900,520 &
	@sleep 2
	@echo "menu should be open for ~5 more seconds"

stop:
	@pkill -f "BatteryPlus.app/Contents/MacOS/BatteryPlus" 2>/dev/null || true
	@pkill -x BatteryPlus 2>/dev/null || true

# Photograph the replica for comparison against the native menu.
capture: build stop
	@"$(BIN)" --demo-menu-at 900,520 &
	@sleep 2
	@screencapture -x -R 880,480,360,420 shots/replica_menu.png 2>/dev/null || \
	 screencapture -x shots/replica_menu.png
	@echo "captured shots/replica_menu.png"
	@sleep 5
	@$(MAKE) --no-print-directory stop

# The privileged piece is a setuid-root tool, not a launchd daemon: every loaded launchd job shows up
# in Login Items → Background App Activity, and that row cannot be given a proper icon under an
# ad-hoc signature (SMAppService.daemon → EPERM, measured). A setuid tool leaves no row behind.
helper:
	clang -O2 -Wall -o install/batteryplus-lowpower Sources/Privileged/batteryplus-lowpower.c
	@echo "privileged tool built (install/batteryplus-lowpower) — install with: sudo install/install-helper.sh"

clean:
	rm -rf "$(BUILD)"
