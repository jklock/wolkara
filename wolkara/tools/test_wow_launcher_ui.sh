#!/bin/bash
# Our own synthetic UI fixture. No game files, accounts or network requests.
set -euo pipefail
cd "$(dirname "$0")/../.."
. wolkara/tools/env.sh
wolkara/tools/prepare.sh
cd build/platform
SIM=${SIMULATOR:-iPad Pro 13-inch (M5)}
SIM_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group if sys.argv[1] in (d["name"], d["udid"])]
devices.sort(key=lambda d: d["state"] != "Booted")
print(devices[0]["udid"] if devices else "")' "$SIM")
[ -n "$SIM_ID" ] || { echo "No matching simulator; set SIMULATOR."; exit 2; }
xcrun simctl bootstatus "$SIM_ID" -b > /dev/null
APP=build/wow-launcher/WoWFixture.app
mkdir -p "$APP"
# The launcher is not a page on its own: it opens the add-on and voice pages, so the
# fixture has to link them. It did not, and the link had been failing since the voice
# pages were added - the fixture only ever got as far as the missing symbols.
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -fobjc-arc -O1 -g \
    -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -Ilauncher/App -Ilauncher/Voice -Ilauncher/Input -Ilauncher/Controller -Ilauncher/WoW -Itests \
    launcher/WoW/*.m launcher/App/LaunchProgressView.m launcher/App/WolkaraTheme.m \
    launcher/App/WolkaraLog.m launcher/Voice/*.m launcher/Input/*.m \
    launcher/Controller/ControllerInspector.m tests/test_wow_launcher_app.m \
    -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
    -framework Security -framework UniformTypeIdentifiers -framework GameController \
    -framework AVFAudio -framework Speech -lz \
    -o "$APP/WoWFixture"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.tolkara.tests.wow-launcher</string>
<key>CFBundleExecutable</key><string>WoWFixture</string>
<key>CFBundleName</key><string>WoW launcher fixture</string>
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
# The four documents the app's own target bundles, in the same layout and under the same
# names, because the About page reads them by name and by name is how it tells whose is
# whose: the app is a fork, so upstream's stay as LICENSE/NOTICE.md and ours are prefixed.
# A fixture that put them anywhere else would be testing a bundle nobody builds.
#
# This mirrors the app's packaging. That the *real* target carries all four is checked
# against the installed app on the iPad, in wolkara/tools/device_matrix.sh, because a
# fixture that supplies the files can only ever prove how the page composes them.
cp "$ROOT/LICENSE" "$APP/Wolkara-LICENSE"
cp "$ROOT/NOTICE.md" "$APP/Wolkara-NOTICE.md"
cp "$ROOT/platform/LICENSE" "$APP/LICENSE"
cp "$ROOT/platform/NOTICE.md" "$APP/NOTICE.md"
codesign --force --sign - "$APP" > /dev/null
xcrun simctl install "$SIM_ID" "$APP"
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
xcrun simctl launch --terminate-running-process --console "$SIM_ID" org.tolkara.tests.wow-launcher "$@" 2>&1 | tee "$LOG"
# simctl can report success even if an assertion terminated the fixture.
grep -q 'WoW UIKit PASS:' "$LOG"
# The images the fixture drew are in its container, which is where anyone wanting to
# look at the launcher's pages has to go looking.
echo "screenshots: $(xcrun simctl get_app_container "$SIM_ID" org.tolkara.tests.wow-launcher data)/Documents"
