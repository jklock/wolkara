#!/bin/bash
# One-command loop: build, install, launch, collect console + crash logs.
# usage: tools/run.sh sim|device [seconds]      (default 15 s of console capture)
# env:   GUEST_EXE=/path/to/macOS/executable    (default: in-repo test guest)
#        DEVICE=<udid or name>                  (device mode; default: first paired device)
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
MODE=${1:-sim}; SECS=${2:-15}
[ -f local.env ] && { set -a; . ./local.env; set +a; }   # ignored builder settings
BUNDLE=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
SIM=${SIMULATOR:-iPad Pro 13-inch (M5)}
TS=$(date +%Y%m%d-%H%M%S); LOG=logs/$TS-$MODE; mkdir -p "$LOG"

if [ "$MODE" = sim ]; then DEST="platform=iOS Simulator,name=$SIM"; CONF=Debug-iphonesimulator
else
    DEVICE=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}
    [ -z "${DEVICE:-}" ] && { echo "no device: connect the iPad, unlock it, tap Trust"; exit 2; }
    # specific destination + device registration, so the team profile includes this iPad
    DEST="platform=iOS,id=$DEVICE"; CONF=Debug-iphoneos; PROV="-allowProvisioningDeviceRegistration"
fi

tools/generate.sh
xcodebuild -project Tolkara.xcodeproj -scheme TolkaraDiagnostics -destination "$DEST" -derivedDataPath build/dd \
    -allowProvisioningUpdates ${PROV:-} GUEST_EXE="${GUEST_EXE:-}" build > "$LOG/build.log" 2>&1
if ! grep -q "BUILD SUCCEEDED" "$LOG/build.log"; then grep -E "error:|exit" "$LOG/build.log" | head -20; echo "BUILD FAILED -> $LOG/build.log"; exit 1; fi
APP=build/dd/Build/Products/$CONF/TolkaraDiagnostics.app

if [ "$MODE" = sim ]; then
    xcrun simctl boot "$SIM" 2>/dev/null; xcrun simctl bootstatus "$SIM" > /dev/null
    xcrun simctl terminate "$SIM" $BUNDLE 2>/dev/null
    xcrun simctl install "$SIM" "$APP"
    CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
    cp build/guest-module/OriginalExecutable.bin "$CONTAINER/Documents/IncomingOriginal.bin"
    xcrun simctl launch --console-pty "$SIM" $BUNDLE --import-module="$CONTAINER/Documents/IncomingOriginal.bin" > "$LOG/console.log" 2>&1 & PID=$!
    sleep "$SECS"
    xcrun simctl io "$SIM" screenshot "$LOG/screen.png" > /dev/null 2>&1
    kill $PID 2>/dev/null; xcrun simctl terminate "$SIM" $BUNDLE 2>/dev/null
    find ~/Library/Logs/DiagnosticReports -name 'TolkaraDiagnostics-*.ips' -newer "$LOG/build.log" -exec cp {} "$LOG/" \; 2>/dev/null
else
    xcrun devicectl device install app --device "$DEVICE" "$APP" > "$LOG/install.log" 2>&1 || { tail -5 "$LOG/install.log"; exit 3; }
    xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
        --source build/guest-module/OriginalExecutable.bin --destination Documents/IncomingOriginal.bin > "$LOG/module-transfer.log" 2>&1 || exit 3
    xcrun devicectl device process launch --terminate-existing --console --device "$DEVICE" $BUNDLE --import-module=Documents/IncomingOriginal.bin > "$LOG/console.log" 2>&1 & PID=$!
    sleep "$SECS"; kill $PID 2>/dev/null
    # crash logs live in the systemCrashLogs domain on the device
    xcrun devicectl device info files --device "$DEVICE" --domain-type systemCrashLogs 2>/dev/null | grep -o 'TolkaraDiagnostics-[^ ]*\.ips' | sort | tail -3 | while read -r f; do
        xcrun devicectl device copy from --device "$DEVICE" --domain-type systemCrashLogs --source "$f" --destination "$LOG/$f" > /dev/null 2>&1
    done
fi
echo "== console ($LOG/console.log) =="; grep -vE "^\s*$" "$LOG/console.log" | tail -40
ls "$LOG"/*.ips 2>/dev/null && echo "^^ CRASH LOGS COLLECTED"
exit 0
