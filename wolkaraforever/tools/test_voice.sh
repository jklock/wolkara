#!/bin/bash
# The input, voice and configuration rules, tested.
#
# Runs the focused suite in wolkaraforever/Voice/tests/test_voice_app.m as a tiny app in the
# simulator, because UIKit and GameController are what the code under test is made of.
# The recogniser and the audio session are faked through the protocols in Dictation.h,
# which is the only way to test final-result ordering, permission refusal and
# audio-session restoration without a microphone.
#
#   wolkaraforever/tools/test_voice.sh
#
# Exit status is the suite's: 0 all checks passed, 1 at least one failed (the failing
# checks are printed), 2 nothing could be run.
set -euo pipefail
cd "$(dirname "$0")/../.."
. wolkaraforever/tools/env.sh
wolkaraforever/tools/prepare.sh
cd build/platform
SIM=${SIMULATOR:-iPad Pro 13-inch (M5)}
SIM_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group if sys.argv[1] in (d["name"], d["udid"])]
devices.sort(key=lambda d: d["state"] != "Booted")
print(devices[0]["udid"] if devices else "")' "$SIM")
[ -n "$SIM_ID" ] || { echo "No matching simulator; set SIMULATOR."; exit 2; }
xcrun simctl bootstatus "$SIM_ID" -b > /dev/null

APP=build/voice-tests/VoiceTests.app
mkdir -p "$APP"
# The sources under test, and only those: the view controllers are exercised by the
# launcher fixture instead, and pulling them in would drag WolkaraForeverTheme along for
# nothing.
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc -O1 -g \
    -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -Ilauncher/Input -Ilauncher/Voice -Ilauncher/Controller -Ilauncher/App -Itests \
    launcher/Input/*.m launcher/Voice/Dictation.m launcher/Voice/VoiceSettings.m \
    launcher/Voice/AudioSessionCoordinator.m \
    launcher/Voice/VoiceViewController.m launcher/Voice/VoiceTestViewController.m \
    launcher/App/WolkaraForeverTheme.m \
    launcher/Controller/ControllerInspector.m launcher/App/WolkaraForeverLog.m \
    launcher/App/WolkaraForeverConfig.m tests/test_voice_app.m \
    -framework Foundation -framework UIKit -framework QuartzCore -framework GameController \
    -framework AVFAudio -framework Speech -framework CoreGraphics -lz \
    -o "$APP/VoiceTests"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.tolkara.tests.voice</string>
<key>CFBundleExecutable</key><string>VoiceTests</string>
<key>CFBundleName</key><string>WolkaraForever voice tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/><key>UISceneConfigurations</key><dict/></dict>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP" > /dev/null
xcrun simctl install "$SIM_ID" "$APP"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
# The suite exits by itself; the timeout is only so a hang cannot look like a pass.
xcrun simctl launch --terminate-running-process --console "$SIM_ID" org.tolkara.tests.voice 2>&1 | tee "$LOG" &
LAUNCH=$!
for _ in $(seq 1 60); do
    if grep -qE 'VOICE (PASS|FAIL)' "$LOG"; then break; fi
    sleep 1
done
kill "$LAUNCH" 2>/dev/null || true
grep -E '^FAIL' "$LOG" | head -40 || true
if grep -q 'VOICE PASS' "$LOG"; then
    grep 'VOICE PASS' "$LOG"
    exit 0
fi
if grep -q 'VOICE FAIL' "$LOG"; then
    grep 'VOICE FAIL' "$LOG"
    exit 1
fi
echo "the suite did not finish; its output is above"
exit 2
