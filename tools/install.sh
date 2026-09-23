#!/bin/bash
# Build the Tolkara app with your own signing team and install it on your iPad.
# usage: tools/install.sh            (settings from local.env; see local.env.example)
# Installing replaces the app under the same bundle ID and keeps its data.
# TOLKARA_MODE=local-signing also builds the Local signing page container,
# signed with your developer identity, and copies it into the app's Documents.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
. tools/localenv.sh; tolkara_load_env
[ -n "${DEVELOPMENT_TEAM:-}" ] || { echo "Set DEVELOPMENT_TEAM in local.env (see local.env.example)."; exit 2; }
[ -n "${DEVICE:-}" ] || { echo "Set DEVICE=<iPad UDID> in local.env (xcrun devicectl list devices)."; exit 2; }
[ -f "${GUEST_EXE:-}" ] || { echo "Set GUEST_EXE to the macOS executable you own. It is analysed, never bundled or modified."; exit 2; }
case "${TOLKARA_MODE:-}" in
    ""|developer-service|local-signing) ;;
    *) echo "TOLKARA_MODE must be empty, developer-service or local-signing (see local.env.example)."; exit 2;;
esac
BUNDLE=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
mkdir -p logs; LOG=logs/install-$(date +%Y%m%d-%H%M%S).log
tools/generate.sh
# NATIVE_GUEST_SHIMS=YES builds and signs only Tolkara's translation libraries
# for the API surface that executable imports. The executable stays outside the app.
xcodebuild -project Tolkara.xcodeproj -scheme Tolkara -destination "platform=iOS,id=$DEVICE" \
    -derivedDataPath build/device -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    GUEST_EXE="$GUEST_EXE" NATIVE_GUEST_SHIMS=YES TOLKARA_PROFILE="${TOLKARA_PROFILE:-}" TOLKARA_MODE="${TOLKARA_MODE:-}" \
    build > "$LOG" 2>&1 \
    || { grep -E "error:" "$LOG" | head -20; echo "BUILD FAILED -> $LOG"; exit 1; }
xcrun devicectl device install app --device "$DEVICE" build/device/Build/Products/Debug-iphoneos/Tolkara.app
case "${TOLKARA_MODE:-}" in
local-signing)
    # The container is a copy of the executable's final code pages, signed with
    # your developer identity. It stays on your Mac and your iPad.
    CAPTURE=(); [ -n "${TOLKARA_CAPTURE:-}" ] && CAPTURE=(--capture "$TOLKARA_CAPTURE")
    [ -n "${TOLKARA_CAPTURE:-}" ] || echo "Note: without TOLKARA_CAPTURE the page container only works for applications that do not rewrite their own code at launch."
    mkdir -p build/signed-image
    python3 tools/build_signed_container.py --guest "$GUEST_EXE" ${CAPTURE[@]+"${CAPTURE[@]}"} --platform ios \
        --team "$DEVELOPMENT_TEAM" --output build/signed-image/page-container.dylib \
        || { echo "PAGE CONTAINER BUILD FAILED (tools/build_signed_container.py)"; exit 1; }
    copy_container() {
        xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
            --source build/signed-image/page-container.dylib --destination Documents/LocalSigning/page-container.dylib >> "$LOG" 2>&1
    }
    # A fresh install has no Documents/LocalSigning yet. If the copy cannot create
    # it, one launch in Local signing makes the folder; then copy again.
    if ! copy_container; then
        echo "Launching Tolkara once in Local signing so it creates Documents/LocalSigning…"
        xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" --execution-mode=local-signing >> "$LOG" 2>&1 \
            || { echo "APP LAUNCH FAILED (unlock the iPad; trust the developer in Settings if asked) -> $LOG"; exit 1; }
        sleep 3
        copy_container || { echo "PAGE CONTAINER COPY FAILED -> $LOG"; exit 1; }
    fi
    echo "Installed with Local signing and its page container. Nothing to enrol. Next: copy your app's files (see profiles/).";;
developer-service)
    echo "Installed with Developer service. Next: tools/enroll.sh (once), then copy your app's files (see profiles/).";;
*)
    echo "Installed. The app asks for its execution mode on first launch: Developer service needs tools/enroll.sh (once);"
    echo "Local signing needs a page container (TOLKARA_MODE=local-signing builds and copies it). Then copy your app's files (see profiles/).";;
esac
[ -z "${TOLKARA_MODE:-}" ] || echo "A mode already chosen in the app is kept; change it there with Execution mode…"
