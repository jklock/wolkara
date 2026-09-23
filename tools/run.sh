#!/bin/bash
# One-command loop: build, install, launch, collect console + crash logs.
# usage: tools/run.sh sim|device [seconds]      (default 15 s of console capture)
# env:   GUEST_EXE=/path/to/macOS/executable    (default: in-repo test guest)
#        DEVICE=<udid or name>                  (device mode; default: first paired device)
#        TOLKARA_MODE=developer-service|local-signing   (passed to every launch)
# sim + local-signing also builds an ad-hoc page container for the guest, runs
# its first initializer through Local signing and prints the runtime log.
set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
MODE=${1:-sim}; SECS=${2:-15}
. tools/localenv.sh; tolkara_load_env   # ignored builder settings; the environment wins
case "${TOLKARA_MODE:-}" in
    ""|developer-service|local-signing) ;;
    *) echo "TOLKARA_MODE must be empty, developer-service or local-signing (see local.env.example)."; exit 2;;
esac
BUNDLE=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
SIM=${SIMULATOR:-iPad Pro 13-inch (M5)}
TS=$(date +%Y%m%d-%H%M%S); LOG=logs/$TS-$MODE; mkdir -p "$LOG"
MODEARG=(); [ -n "${TOLKARA_MODE:-}" ] && MODEARG=(--execution-mode="$TOLKARA_MODE")
PROV=(); SHIMS=()

if [ "$MODE" = sim ]; then
    # One UDID for every step: several simulators may share a name; prefer the booted one.
    SIM_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
found = [d for devices in json.load(sys.stdin)["devices"].values() for d in devices if name in (d["name"], d["udid"])]
found.sort(key=lambda d: d["state"] != "Booted")
print(found[0]["udid"] if found else "")' "$SIM")
    [ -n "$SIM_ID" ] || { echo "no available simulator named $SIM (set SIMULATOR in local.env)"; exit 2; }
    DEST="platform=iOS Simulator,id=$SIM_ID"; CONF=Debug-iphonesimulator
    # Local signing needs the native loader's compatibility libraries.
    [ "${TOLKARA_MODE:-}" = local-signing ] && SHIMS=(NATIVE_GUEST_SHIMS=YES)
else
    DEVICE=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')}
    [ -z "${DEVICE:-}" ] && { echo "no device: connect the iPad, unlock it, tap Trust"; exit 2; }
    # specific destination + device registration, so the team profile includes this iPad
    DEST="platform=iOS,id=$DEVICE"; CONF=Debug-iphoneos; PROV=(-allowProvisioningDeviceRegistration)
fi

tools/generate.sh || { echo "PROJECT GENERATION FAILED"; exit 1; }
xcodebuild -project Tolkara.xcodeproj -scheme TolkaraDiagnostics -destination "$DEST" -derivedDataPath build/dd \
    -allowProvisioningUpdates ${PROV[@]+"${PROV[@]}"} GUEST_EXE="${GUEST_EXE:-}" TOLKARA_MODE="${TOLKARA_MODE:-}" \
    ${SHIMS[@]+"${SHIMS[@]}"} build > "$LOG/build.log" 2>&1
if ! grep -q "BUILD SUCCEEDED" "$LOG/build.log"; then grep -E "error:|exit" "$LOG/build.log" | head -20; echo "BUILD FAILED -> $LOG/build.log"; exit 1; fi
APP=build/dd/Build/Products/$CONF/TolkaraDiagnostics.app

if [ "$MODE" = sim ]; then
    xcrun simctl boot "$SIM_ID" 2>/dev/null; xcrun simctl bootstatus "$SIM_ID" > /dev/null
    xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null
    xcrun simctl install "$SIM_ID" "$APP"
    CONTAINER=$(xcrun simctl get_app_container "$SIM_ID" "$BUNDLE" data)
    cp build/guest-module/OriginalExecutable.bin "$CONTAINER/Documents/IncomingOriginal.bin"
    xcrun simctl launch --console-pty "$SIM_ID" "$BUNDLE" ${MODEARG[@]+"${MODEARG[@]}"} \
        --import-module="$CONTAINER/Documents/IncomingOriginal.bin" > "$LOG/console.log" 2>&1 & PID=$!
    sleep "$SECS"
    xcrun simctl io "$SIM_ID" screenshot "$LOG/screen.png" > /dev/null 2>&1
    kill "$PID" 2>/dev/null; xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null
    if [ "${TOLKARA_MODE:-}" = local-signing ]; then
        # Every Local signing step must succeed; stop loudly at the first that does not.
        fail() {
            find ~/Library/Logs/DiagnosticReports -name 'TolkaraDiagnostics-*.ips' -newer "$LOG/build.log" -exec cp {} "$LOG/" \; 2>/dev/null
            echo "LOCAL SIGNING FAILED: $* -> $LOG"; exit 4
        }
        [ -n "$CONTAINER" ] && [ -d "$CONTAINER/Documents" ] || fail "no app data container"
        GUEST=${GUEST_EXE:-build/TestGuest}   # build_emulated_guest.sh builds the in-repo guest
        [ -f "$GUEST" ] || fail "guest executable missing"
        # A capture belongs to GUEST_EXE's application, never to the in-repo guest.
        CAPTURE=(); [ -n "${GUEST_EXE:-}" ] && [ -n "${TOLKARA_CAPTURE:-}" ] && CAPTURE=(--capture "$TOLKARA_CAPTURE")
        mkdir -p build/signed-image || fail "cannot create build/signed-image"
        python3 tools/build_signed_container.py --guest "$GUEST" ${CAPTURE[@]+"${CAPTURE[@]}"} --platform iossimulator \
            --sign adhoc --output build/signed-image/page-container-sim.dylib > "$LOG/page-container.log" 2>&1 \
            || { tail -20 "$LOG/page-container.log"; fail "page container build (tools/build_signed_container.py)"; }
        mkdir -p "$CONTAINER/Documents/LocalSigning" \
            && cp build/signed-image/page-container-sim.dylib "$CONTAINER/Documents/LocalSigning/page-container.dylib" \
            || fail "copy of the page container into Documents/LocalSigning"
        rm -f "$CONTAINER/Documents/native-guest.log"
        xcrun simctl launch --console-pty "$SIM_ID" "$BUNDLE" --execution-mode=local-signing --native-initializer \
            > "$LOG/console-local-signing.log" 2>&1 & PID=$!
        sleep "$SECS"
        xcrun simctl io "$SIM_ID" screenshot "$LOG/screen-local-signing.png" > /dev/null 2>&1
        kill "$PID" 2>/dev/null; xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null
        cp "$CONTAINER/Documents/native-guest.log" "$LOG/native-guest.log" 2>/dev/null \
            || fail "no Documents/native-guest.log: the app did not reach native startup (see $LOG/console-local-signing.log)"
        echo "== native-guest.log ($LOG/native-guest.log) =="; grep -vE "^\s*$" "$LOG/native-guest.log" | tail -30
        # Local signing ran only if the runtime matched the container to the guest
        # (it dlopens and validates it in ng_initialize), no signed-image check
        # failed, and the first initializer returned to the host.
        grep -q '^\[signed-image\] container matches the guest' "$LOG/native-guest.log" \
            || fail "the runtime did not match the page container to the guest: no '[signed-image] container matches the guest' (refused, dlopen failed, mismatch or no module imported; see $LOG/native-guest.log)"
        ! grep '^\[signed-image\] FATAL' "$LOG/native-guest.log" \
            || fail "a signed-image verification failed: '[signed-image] FATAL' above (see $LOG/native-guest.log)"
        grep -q '^\[host\] native first initializer returned' "$LOG/native-guest.log" \
            || fail "the first initializer did not return through Local signing within $SECS s: no '[host] native first initializer returned' (see $LOG/native-guest.log)"
        echo "Local signing: container matched the guest and the first initializer returned."
    fi
    find ~/Library/Logs/DiagnosticReports -name 'TolkaraDiagnostics-*.ips' -newer "$LOG/build.log" -exec cp {} "$LOG/" \; 2>/dev/null
else
    xcrun devicectl device install app --device "$DEVICE" "$APP" > "$LOG/install.log" 2>&1 || { tail -5 "$LOG/install.log"; exit 3; }
    xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
        --source build/guest-module/OriginalExecutable.bin --destination Documents/IncomingOriginal.bin > "$LOG/module-transfer.log" 2>&1 || exit 3
    xcrun devicectl device process launch --terminate-existing --console --device "$DEVICE" "$BUNDLE" ${MODEARG[@]+"${MODEARG[@]}"} \
        --import-module=Documents/IncomingOriginal.bin > "$LOG/console.log" 2>&1 & PID=$!
    sleep "$SECS"; kill "$PID" 2>/dev/null
    # crash logs live in the systemCrashLogs domain on the device
    xcrun devicectl device info files --device "$DEVICE" --domain-type systemCrashLogs 2>/dev/null | grep -o 'TolkaraDiagnostics-[^ ]*\.ips' | sort | tail -3 | while read -r f; do
        xcrun devicectl device copy from --device "$DEVICE" --domain-type systemCrashLogs --source "$f" --destination "$LOG/$f" > /dev/null 2>&1
    done
fi
echo "== console ($LOG/console.log) =="; grep -vE "^\s*$" "$LOG/console.log" | tail -40
ls "$LOG"/*.ips 2>/dev/null && echo "^^ CRASH LOGS COLLECTED"
exit 0
