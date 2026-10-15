#!/bin/bash
# Local signing smoke test on the iPad: install the diagnostics app built for
# GUEST_EXE, copy a signed page container to Documents/LocalSigning, launch
# with --native-initializer (or --native-startup with 'full'), and check the
# runtime log of that launch. No debugger, no helper, no tunnel.
# usage: tools/probe_signed_image.sh device [full] [container]
#   container: a signed page container (relative to where you run this). By
#   default build/signed-image/page-container.dylib, (re)built with
#   tools/build_signed_container.py (GUEST_EXE, TOLKARA_CAPTURE) when missing or
#   older than the executable or capture. GUEST_EXE's module is imported first,
#   so the initializer run loads the same executable the container was built for.
# The initializer run passes on "result first_initializer=PASS"; 'full' passes
# once original main is entered (the application then keeps running on the
# iPad; the next launch replaces it with --terminate-existing). Simulator:
# TOLKARA_MODE=local-signing tools/run.sh sim.
set -euo pipefail
CALLER=$PWD
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
usage() { echo "usage: tools/probe_signed_image.sh device [full] [container]"; exit 2; }
[ "${1:-}" = device ] || usage; shift
FULL=; [ "${1:-}" = full ] && { FULL=1; shift; }
CONTAINER=; [ $# -gt 0 ] && { CONTAINER=$1; shift; }
[ $# -eq 0 ] || usage
. tools/localenv.sh; tolkara_load_env
[ -f "${GUEST_EXE:-}" ] || { echo "Set GUEST_EXE to the executable the iPad runs (local.env)."; exit 2; }
BUNDLE=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
TS=$(date +%Y%m%d-%H%M%S); LOG=logs/$TS-signedimage-device; mkdir -p "$LOG"
[ -n "${DEVICE:-}" ] || DEVICE=$(xcrun devicectl list devices 2>/dev/null \
    | awk '/physical/ && /connected/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}' || true)
[ -n "${DEVICE:-}" ] || { echo "no device connected"; exit 2; }

if [ -n "$CONTAINER" ]; then
    case "$CONTAINER" in /*) ;; *) CONTAINER=$CALLER/$CONTAINER;; esac
    [ -f "$CONTAINER" ] || { echo "no such container: $CONTAINER"; exit 2; }
else
    CONTAINER=build/signed-image/page-container.dylib
    if [ ! -f "$CONTAINER" ] || [ "$GUEST_EXE" -nt "$CONTAINER" ] || { [ -n "${TOLKARA_CAPTURE:-}" ] && [ "$TOLKARA_CAPTURE" -nt "$CONTAINER" ]; }; then
        python3 tools/build_signed_container.py --platform ios --output "$CONTAINER"   # GUEST_EXE, TOLKARA_CAPTURE
    fi
fi
tools/generate.sh
xcodebuild -project Tolkara.xcodeproj -scheme TolkaraDiagnostics -destination "platform=iOS,id=$DEVICE" \
    -derivedDataPath build/dd -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    NATIVE_GUEST_SHIMS=YES GUEST_EXE="$GUEST_EXE" build > "$LOG/build.log" 2>&1 \
    || { grep -E "error:" "$LOG/build.log" | head; echo "BUILD FAILED -> $LOG/build.log"; exit 1; }
xcrun devicectl device install app --device "$DEVICE" build/dd/Build/Products/Debug-iphoneos/TolkaraDiagnostics.app \
    > "$LOG/install.log" 2>&1 || { tail -5 "$LOG/install.log"; exit 3; }
# Import GUEST_EXE's module (the initializer run loads the imported module) in a
# Local signing launch, which also creates Documents/LocalSigning.
xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source build/guest-module/OriginalExecutable.bin --destination Documents/IncomingOriginal.bin >> "$LOG/install.log" 2>&1 \
    || { echo "module copy failed -> $LOG/install.log"; exit 3; }
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" --execution-mode=local-signing \
    --import-module=Documents/IncomingOriginal.bin >> "$LOG/install.log" 2>&1 \
    || { echo "app launch failed (unlock the iPad) -> $LOG/install.log"; exit 3; }
sleep 10
xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$CONTAINER" --destination Documents/LocalSigning/page-container.dylib >> "$LOG/install.log" 2>&1 \
    || { echo "container copy failed -> $LOG/install.log"; exit 3; }
crashes() {
    xcrun devicectl device info files --device "$DEVICE" --domain-type systemCrashLogs 2>/dev/null \
        | grep -o 'TolkaraDiagnostics-[^ ]*\.ips' | sort || true
}
crashes > "$LOG/crashes-before.txt"

RUNID=$(uuidgen); STARTUP=--native-initializer; SECS=45
[ -n "$FULL" ] && { STARTUP=--native-startup; SECS=300; }
xcrun devicectl device process launch --terminate-existing --console --device "$DEVICE" "$BUNDLE" "$STARTUP" \
    --execution-mode=local-signing --signed-image=Documents/LocalSigning/page-container.dylib --probe-run-id="$RUNID" \
    > "$LOG/console.log" 2>&1 &
PID=$!; sleep "$SECS"; kill "$PID" 2>/dev/null || true
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source Documents/native-guest.log --destination "$LOG/native-guest.log" > /dev/null 2>&1 || true
crashes | comm -13 "$LOG/crashes-before.txt" - | while read -r crash; do
    xcrun devicectl device copy from --device "$DEVICE" --domain-type systemCrashLogs \
        --source "$crash" --destination "$LOG/$crash" > /dev/null 2>&1 || true
done
[ -f "$LOG/native-guest.log" ] && head -1 "$LOG/native-guest.log" | grep -qxF -- "--probe-run-id=$RUNID" \
    || { echo "no runtime log from this launch -> $LOG"; exit 4; }
echo "== native-guest.log =="; grep -vE "^\s*$" "$LOG/native-guest.log" | tail -30
compgen -G "$LOG/*.ips" > /dev/null && { echo "CRASH -> $LOG"; exit 4; }
grep -q '^\[signed-image\] FATAL' "$LOG/native-guest.log" && { echo "FAIL: signed-image check failed -> $LOG"; exit 4; }
if [ -n "$FULL" ]; then PASS='entering original main'; else PASS='result first_initializer=PASS'; fi
grep -q "$PASS" "$LOG/native-guest.log" || { echo "FAIL: no '$PASS' within $SECS s -> $LOG"; exit 4; }
echo "PASS: $PASS -> $LOG"
