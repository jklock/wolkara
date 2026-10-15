#!/bin/bash
# Signed-file probe runner: builds the probe fixtures and the diagnostics app,
# then launches the app once per (variant, mode) with
# --signed-file-probe=<variant> --signed-file-probe-mode=<mode>, collecting the
# probe log and any crash report of that launch only. A code-signing violation
# kills the process, so every risky experiment gets its own launch.
# usage: tools/probe_signed_file.sh sim|device [Debug|Release] [variant:mode[:expect] ...]
# Default cases: testguest-container.dylib:dlopen and :remap, expecting 0x12345678.
# Earlier matrices (edit the arguments to rerun): unsigned-ios.dylib, adhoc-ios.dylib
# and dev-ios.dylib with exec / mprotect / write / dlopen / remap / remapwrite;
# unsigned-exec-ios and dev-exec-ios with exec; unsigned-macos.dylib and
# dev-macos.dylib with exec; self:self. A case counts only if its probe log
# carries this launch's run id and ends in result=PASS; the script exits 1
# otherwise, so expected failures in an experiment matrix show up as FAIL.
# Page containers (*container*.dylib) take only the dlopen and remap modes: the
# other modes call the start of __text, which in a container is the guest's
# Mach-O header, not guest_test. Crash reports are matched by launch time.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
MODE=${1:-}; shift || true
case "$MODE" in sim|device) ;; *) echo "usage: tools/probe_signed_file.sh sim|device [Debug|Release] [variant:mode[:expect] ...]"; exit 2;; esac
CONFIG=Debug
case "${1:-}" in Debug|Release) CONFIG=$1; shift;; esac
CASES=("$@")
[ ${#CASES[@]} -gt 0 ] || CASES=(testguest-container.dylib:dlopen:0x12345678 testguest-container.dylib:remap:0x12345678)
for entry in "${CASES[@]}"; do
    case "$entry" in
        *container*.dylib:dlopen|*container*.dylib:dlopen:*|*container*.dylib:remap|*container*.dylib:remap:*) ;;
        *container*.dylib:*) echo "$entry: page containers take only the dlopen and remap modes"; exit 2;;
    esac
done
. tools/localenv.sh; tolkara_load_env
BUNDLE=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
TS=$(date +%Y%m%d-%H%M%S); LOG=logs/$TS-signedfile-$MODE-$CONFIG; mkdir -p "$LOG"

tools/build_signed_probe_guests.sh "$MODE" > "$LOG/variants.log" 2>&1 || { tail -20 "$LOG/variants.log"; exit 1; }
tools/generate.sh
if [ "$MODE" = sim ]; then
    SIM=${SIMULATOR:-iPad Pro 13-inch (M5)}
    SIM_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
found = [d for ds in json.load(sys.stdin)["devices"].values() for d in ds if sys.argv[1] in (d["name"], d["udid"])]
found.sort(key=lambda d: d["state"] != "Booted")
print(found[0]["udid"] if found else "")' "$SIM")
    [ -n "$SIM_ID" ] || { echo "no available simulator named $SIM"; exit 2; }
    DEST="platform=iOS Simulator,id=$SIM_ID"; PRODUCT=$CONFIG-iphonesimulator; PROV=()
else
    [ -n "${DEVICE:-}" ] || DEVICE=$(xcrun devicectl list devices 2>/dev/null \
        | awk '/physical/ && /connected/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}' || true)
    [ -n "${DEVICE:-}" ] || { echo "no device connected"; exit 2; }
    DEST="platform=iOS,id=$DEVICE"; PRODUCT=$CONFIG-iphoneos; PROV=(-allowProvisioningDeviceRegistration)
fi
xcodebuild -project Tolkara.xcodeproj -scheme TolkaraDiagnostics -destination "$DEST" -configuration "$CONFIG" \
    -derivedDataPath build/dd -allowProvisioningUpdates ${PROV[@]+"${PROV[@]}"} build > "$LOG/build.log" 2>&1 \
    || { grep -E "error:" "$LOG/build.log" | head; echo "BUILD FAILED -> $LOG/build.log"; exit 1; }
APP=build/dd/Build/Products/$PRODUCT/TolkaraDiagnostics.app
FIXTURES=(build/signed-probe/*.dylib build/signed-probe/*-exec-ios)

if [ "$MODE" = sim ]; then
    xcrun simctl boot "$SIM_ID" 2>/dev/null || true; xcrun simctl bootstatus "$SIM_ID" > /dev/null
    xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null || true
    xcrun simctl install "$SIM_ID" "$APP"
    CONTAINER=$(xcrun simctl get_app_container "$SIM_ID" "$BUNDLE" data)
    mkdir -p "$CONTAINER/Documents/SignedProbe"
    cp "${FIXTURES[@]}" "$CONTAINER/Documents/SignedProbe/"
else
    xcrun devicectl device install app --device "$DEVICE" "$APP" > "$LOG/install.log" 2>&1 || { tail -5 "$LOG/install.log"; exit 3; }
    for f in "${FIXTURES[@]}"; do
        xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
            --source "$f" --destination "Documents/SignedProbe/$(basename "$f")" >> "$LOG/install.log" 2>&1 \
            || { echo "copy of $(basename "$f") failed -> $LOG/install.log"; exit 3; }
    done
fi

device_crashes() {
    xcrun devicectl device info files --device "$DEVICE" --domain-type systemCrashLogs 2>/dev/null \
        | grep -o 'TolkaraDiagnostics-[^ ]*\.ips' | sort || true
}
failed=0
run_case() { # index variant mode [expect]; tolerant: a crash is a result, not a script error
    local variant=$2 mode=$3 expect=${4:-} runid name verdict crashed=""
    runid=$(uuidgen); name="$1.${variant%.dylib}.$mode"
    local args=(--signed-file-probe="Documents/SignedProbe/$variant" --signed-file-probe-mode="$mode" --probe-run-id="$runid")
    [ -n "$expect" ] && args+=(--signed-file-probe-expect="$expect")
    rm -f "$LOG/$name.probe.log"; touch "$LOG/$name.start"
    if [ "$MODE" = sim ]; then
        rm -f "$CONTAINER/Documents/signed-file-probe.log"
        xcrun simctl launch --console-pty "$SIM_ID" "$BUNDLE" "${args[@]}" > "$LOG/$name.console.log" 2>&1 &
        local pid=$!; sleep 6; kill "$pid" 2>/dev/null || true; xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null || true
        cp "$CONTAINER/Documents/signed-file-probe.log" "$LOG/$name.probe.log" 2>/dev/null || true
        sleep 2   # let a crash report of this launch land before the next case starts
        find ~/Library/Logs/DiagnosticReports -name 'TolkaraDiagnostics-*.ips' -newer "$LOG/$name.start" 2>/dev/null \
            | while read -r crash; do cp "$crash" "$LOG/$name.$(basename "$crash")" || true; done || true
    else
        device_crashes > "$LOG/$name.crashes-before.txt"
        xcrun devicectl device process launch --terminate-existing --console --device "$DEVICE" "$BUNDLE" "${args[@]}" \
            > "$LOG/$name.console.log" 2>&1 &
        local pid=$!; sleep 6; kill "$pid" 2>/dev/null || true; sleep 2
        xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
            --source Documents/signed-file-probe.log --destination "$LOG/$name.probe.log" > /dev/null 2>&1 || true
        device_crashes | comm -13 "$LOG/$name.crashes-before.txt" - | while read -r crash; do
            xcrun devicectl device copy from --device "$DEVICE" --domain-type systemCrashLogs \
                --source "$crash" --destination "$LOG/$name.$crash" > /dev/null 2>&1 || true
        done
    fi
    if [ ! -f "$LOG/$name.probe.log" ]; then verdict=NO-LOG
    elif ! head -1 "$LOG/$name.probe.log" | grep -qxF -- "--probe-run-id=$runid"; then
        verdict=STALE-LOG; mv "$LOG/$name.probe.log" "$LOG/$name.stale.log"
    else verdict=$(grep -o '\[signed-file\] result=[A-Z]*' "$LOG/$name.probe.log" | tail -1 | sed 's/.*result=//' || true); fi
    compgen -G "$LOG/$name.*.ips" > /dev/null && crashed=" CRASH"
    echo "$name: ${verdict:-NO-RESULT}$crashed" | tee -a "$LOG/summary.txt"
    [ "$verdict" = PASS ] && [ -z "$crashed" ] || failed=1
}

index=0
for entry in "${CASES[@]}"; do
    IFS=: read -r variant mode expect <<< "$entry"
    index=$((index + 1)); run_case "$index" "$variant" "$mode" "${expect:-}"
done
echo "== evidence in $LOG =="
exit "$failed"
