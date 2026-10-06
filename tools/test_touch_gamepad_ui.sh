#!/bin/bash
# Builds/opens our own input fixture, never an imported application.
# Optional --self-test covers gamepad connection/cancellation with fake devices.
set -euo pipefail
cd "$(dirname "$0")/.."
SIM=${SIMULATOR:-iPhone 17 Pro}
SIM_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group if sys.argv[1] in (d["name"], d["udid"])]
devices.sort(key=lambda d: d["state"] != "Booted")
print(devices[0]["udid"] if devices else "")' "$SIM")
[ -n "$SIM_ID" ] || { echo "No matching simulator; set SIMULATOR."; exit 2; }
xcrun simctl bootstatus "$SIM_ID" -b > /dev/null
APP=build/touch-gamepad-fixture/TouchGamepad.app
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$SDK" -fobjc-arc -O1 -g \
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations \
    translation/AppKit/TouchGamepad.m translation/AppKit/TouchGamepadLayout.m translation/AppKit/TouchHaptics.m tests/test_touch_gamepad_app.m \
    -framework Foundation -framework UIKit -framework GameController -framework CoreGraphics -framework QuartzCore -o "$APP/TouchGamepadFixture"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.tolkara.tests.touch-gamepad</string>
<key>CFBundleExecutable</key><string>TouchGamepadFixture</string>
<key>CFBundleName</key><string>Touch gamepad fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/><key>UISceneConfigurations</key><dict/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP" > /dev/null
xcrun simctl install "$SIM_ID" "$APP"
if [[ " $* " == *" --self-test "* || " $* " == *" --self-test-input "* ]]; then
    # simctl may report success even when the app aborts an assertion.
    LOG=build/touch-gamepad-fixture/self-test.log
    xcrun simctl launch --terminate-running-process --console "$SIM_ID" org.tolkara.tests.touch-gamepad "$@" 2>&1 | tee "$LOG"
    grep -Eq 'TOUCH_GAMEPAD_(LIFECYCLE|INPUT)_PASS:' "$LOG"
else
    xcrun simctl launch --terminate-running-process --console "$SIM_ID" org.tolkara.tests.touch-gamepad "$@"
fi
