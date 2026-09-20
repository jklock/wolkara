#!/bin/bash
# Build the Tolkara app with your own signing team and install it on your iPad.
# usage: tools/install.sh            (settings from local.env; see local.env.example)
# Installing replaces the app under the same bundle ID and keeps its data.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[ -f local.env ] && { set -a; . ./local.env; set +a; }
[ -n "${DEVELOPMENT_TEAM:-}" ] || { echo "Set DEVELOPMENT_TEAM in local.env (see local.env.example)."; exit 2; }
[ -n "${DEVICE:-}" ] || { echo "Set DEVICE=<iPad UDID> in local.env (xcrun devicectl list devices)."; exit 2; }
[ -f "${GUEST_EXE:-}" ] || { echo "Set GUEST_EXE to the macOS executable you own. It is analysed, never bundled or modified."; exit 2; }
mkdir -p logs; LOG=logs/install-$(date +%Y%m%d-%H%M%S).log
tools/generate.sh
# NATIVE_GUEST_SHIMS=YES builds and signs only Tolkara's translation libraries
# for the API surface that executable imports. The executable stays outside the app.
xcodebuild -project Tolkara.xcodeproj -scheme Tolkara -destination "platform=iOS,id=$DEVICE" \
    -derivedDataPath build/device -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    GUEST_EXE="$GUEST_EXE" NATIVE_GUEST_SHIMS=YES TOLKARA_PROFILE="${TOLKARA_PROFILE:-}" build > "$LOG" 2>&1 \
    || { grep -E "error:" "$LOG" | head -20; echo "BUILD FAILED -> $LOG"; exit 1; }
xcrun devicectl device install app --device "$DEVICE" build/device/Build/Products/Debug-iphoneos/Tolkara.app
echo "Installed. Next: tools/enroll.sh (once), then copy your app's files (see profiles/)."
