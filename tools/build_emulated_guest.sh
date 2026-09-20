#!/bin/bash
# Build only our runtime into the app. Stage the original as a separate module.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=$1; EXE=${2:-}
mkdir -p "$ROOT/build"
if [ -z "$EXE" ]; then
    EXE="$ROOT/build/TestGuest"
    xcrun --sdk macosx clang -fobjc-arc -arch arm64 -O1 -mmacosx-version-min=14.0 -o "$EXE" \
      "$ROOT/testguest/main.m" -framework Cocoa -framework Metal -framework QuartzCore
fi
mkdir -p "$OUT/Guest"
# Remove resources left by older builds, including the proprietary executable.
rm -f "$OUT/Guest/OriginalExecutable.bin" "$OUT/Guest/manifest.json"
rm -rf "$OUT/Guest/Nibs"
MODULE="$ROOT/build/guest-module"
rm -rf "$MODULE/Nibs"
python3 "$ROOT/tools/package_guest.py" "$EXE" "$MODULE"

# Optional app profile: names the app and its imported file layout. Data only.
rm -f "$OUT/Guest/profile.json"
if [ -z "${TOLKARA_PROFILE:-}" ] && [ -f "$ROOT/local.env" ]; then
    TOLKARA_PROFILE=$(sed -n 's/^TOLKARA_PROFILE=//p' "$ROOT/local.env" | tail -1)
fi
if [ -n "${TOLKARA_PROFILE:-}" ]; then
    case "$TOLKARA_PROFILE" in /*) PROFILE="$TOLKARA_PROFILE";; *) PROFILE="$ROOT/$TOLKARA_PROFILE";; esac
    python3 "$ROOT/tools/check_profile.py" "$PROFILE"
    cp "$PROFILE" "$OUT/Guest/profile.json"
fi

# Build/sign only our compatibility libraries. The original is never patched.
if [ "${NATIVE_GUEST_SHIMS:-NO}" = YES ]; then
    if [ "${PLATFORM_NAME:-iphoneos}" = iphonesimulator ]; then P=iossim; else P=ios; fi
    W="$ROOT/build/native-$P"; mkdir -p "$W" "$OUT/Frameworks"
    python3 "$ROOT/tools/classify.py" "$EXE" --out "$W/SURFACE.md" --map "$W/map.json" --raw "$W/surface.json"
    python3 "$ROOT/tools/build_shims.py" "$P" "$W/surface.json" "$OUT/Frameworks"
    cp "$W/map.json" "$OUT/Guest/libraries.json"
    MACSDK=$(xcrun --sdk macosx --show-sdk-path)
    xcrun --sdk macosx clang -target arm64-apple-macos14.0 -isysroot "$MACSDK" \
      -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework Security \
      "$ROOT/tools/export_system_anchors.m" -o "$ROOT/build/export_system_anchors"
    "$ROOT/build/export_system_anchors" "$OUT/CompatibilityRootCertificates.plist"
    RESOURCES="$(dirname "$(dirname "$EXE")")/Resources"
    if [ -d "$RESOURCES" ]; then
        mkdir -p "$MODULE/Nibs"
        for nib in "$RESOURCES"/*.nib; do
            [ -f "$nib" ] || continue
            python3 "$ROOT/tools/inspect_nib.py" "$nib" --out "$MODULE/Nibs/$(basename "$nib").json"
        done
    fi
    for f in "$OUT/Frameworks"/*.dylib; do codesign -f -s "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$f" 2>/dev/null; done
fi
