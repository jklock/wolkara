#!/bin/bash
# The unsigned .ipa a sideloader signs with your Apple ID.
# usage: tools/package_ipa.sh [output.ipa]        (default: Tolkara-unsigned.ipa)
# Applications are added and started on the iPad in External JIT, preselected:
# the tool that sideloads it (SideStore, StikDebug and similar) enables JIT.
# Build from source instead: tools/install.sh.
set -euo pipefail
OUT=${1:-Tolkara-unsigned.ipa}
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT";; esac
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p logs build
LOG=logs/ipa-$(date +%Y%m%d-%H%M%S).log
tools/generate.sh
# No extension: a free Apple ID cannot sign one.
# GENERIC: one adapter per framework, no executable.
# Its one way to run code, chosen already.
# By target: schemes need a destination the SDK alone lacks.
xcodebuild -project Tolkara.xcodeproj -target TolkaraDiagnostics -configuration Release \
    -sdk iphoneos -arch arm64 SYMROOT=build/unsigned NATIVE_GUEST_SHIMS=GENERIC TOLKARA_MODE=external-jit \
    INFOPLIST_KEY_CFBundleDisplayName=Tolkara \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build > "$LOG" 2>&1 \
    || { grep -E "error:" "$LOG" | head -20; echo "BUILD FAILED -> $LOG"; exit 1; }

APP=build/unsigned/Release-iphoneos/TolkaraDiagnostics.app
[ -d "$APP" ] || { echo "Build did not produce $APP -> $LOG"; exit 1; }
# No identity of ours: unsigned, no profile embedded.
# No pipe: an early reader would hide the answer.
PROFILE=$(find "$APP" -name embedded.mobileprovision -print -quit)
[ -z "$PROFILE" ] || { echo "Refusing to package: the build embeds a provisioning profile."; exit 1; }
for bundle in "$APP" "$APP"/PlugIns/*.appex; do
    [ -d "$bundle" ] || continue
    # Unsigned, or ad hoc with no team; nothing else.
    if SIGNATURE=$(codesign -dvv "$bundle" 2>&1); then
        TEAM=$(printf '%s\n' "$SIGNATURE" | sed -n 's/^TeamIdentifier=//p')
        case "$TEAM" in
            "not set") ;;
            "") echo "Refusing to package: cannot tell who signed $(basename "$bundle")."; exit 1;;
            *) echo "Refusing to package: $(basename "$bundle") is signed with team $TEAM."; exit 1;;
        esac
    else
        case "$SIGNATURE" in
            *"code object is not signed at all"*) ;;
            *) echo "Refusing to package: cannot tell whether $(basename "$bundle") is signed: $SIGNATURE"; exit 1;;
        esac
    fi
done

# An .ipa is a zip with Payload/.
rm -rf build/Payload "$OUT"
mkdir build/Payload
cp -R "$APP" build/Payload/
( cd build && zip -qry "$OUT" Payload )
rm -rf build/Payload
echo "Unsigned build: $OUT"
echo "Sideload it, open it with JIT enabled by your sideloader (or a tool like StikDebug),"
echo "then add your application in the app and start it."
