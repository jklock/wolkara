#!/bin/bash
# Builds the Local signing probe fixtures in build/signed-probe/ for
# tools/probe_signed_file.sh: tiny arm64 Mach-O variants whose guest_test
# returns 0x12345678 and which differ only in platform, file type and signature
# (so each outcome on the iPad has one cause), plus a page container of the
# in-repo TestGuest that exports its probe leaf as guest_test. To probe another
# application, build its container into build/signed-probe/ with
# tools/build_signed_container.py --probe-offset or --probe-symbol.
# usage: tools/build_signed_probe_guests.sh device|sim
#   device: iOS platform; "dev" variants and the container are signed with
#           SIGN_IDENTITY (default "Apple Development"), bound to DEVELOPMENT_TEAM
#           when local.env sets it. The first signature may ask for keychain access.
#   sim:    iOS-simulator platform; everything signed ad hoc (no keychain).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
. tools/localenv.sh; tolkara_load_env
TARGET=${1:-}
case "$TARGET" in
    device) SDK=iphoneos; TRIPLE=arm64-apple-ios17.0; PLATFORM=ios;;
    sim) SDK=iphonesimulator; TRIPLE=arm64-apple-ios17.0-simulator; PLATFORM=iossimulator;;
    *) echo "usage: tools/build_signed_probe_guests.sh device|sim"; exit 2;;
esac
OUT=build/signed-probe
# Replace only our own fixtures: a container you put here yourself stays, and
# tools/probe_signed_file.sh copies it too.
mkdir -p "$OUT" build/sign-local
rm -f "$OUT"/{unsigned,adhoc,dev}-ios.dylib "$OUT"/{unsigned,dev}-exec-ios "$OUT"/{unsigned,dev}-macos.dylib \
    "$OUT"/testguest-container.dylib "$OUT"/probe_guest.c
SIGNER=build/sign-local/sign_guest_local
if [ ! -x "$SIGNER" ] || [ tools/sign_guest_local.m -nt "$SIGNER" ]; then
    xcrun clang -fobjc-arc -O1 -Wall -Wextra -Werror -framework Foundation -framework Security \
        tools/sign_guest_local.m -o "$SIGNER"
fi
sign() { # adhoc|identity in out
    local status=0
    if [ "$1" = adhoc ]; then "$SIGNER" --adhoc -i tolkara.probe "$2" "$3" || status=$?
    else "$SIGNER" -s "${SIGN_IDENTITY:-Apple Development}" ${DEVELOPMENT_TEAM:+--team "$DEVELOPMENT_TEAM"} \
        -i tolkara.probe "$2" "$3" || status=$?; fi
    [ "$status" = 3 ] && { echo "The keychain denied the signing key: rerun from a terminal and choose \"Always Allow\"."; exit 3; }
    [ "$status" = 0 ] || exit "$status"
}
DEV=identity; [ "$TARGET" = sim ] && DEV=adhoc

cat > "$OUT/probe_guest.c" <<'EOF'
__attribute__((used, section("__TEXT,__text")))
int guest_test(void) { return 0x12345678; }
EOF
SDKPATH=$(xcrun --sdk "$SDK" --show-sdk-path)
MACSDK=$(xcrun --sdk macosx --show-sdk-path)
dylib() { # output target sdk
    xcrun clang -arch arm64 -target "$2" -isysroot "$3" -dynamiclib -fno-stack-protector -Wl,-no_adhoc_codesign \
        -Wl,-headerpad,0x1000 -Wl,-exported_symbol,_guest_test "$OUT/probe_guest.c" -o "$OUT/$1"
}
dylib unsigned-ios.dylib "$TRIPLE" "$SDKPATH"
sign adhoc "$OUT/unsigned-ios.dylib" "$OUT/adhoc-ios.dylib"
sign "$DEV" "$OUT/unsigned-ios.dylib" "$OUT/dev-ios.dylib"
# MH_EXECUTE variant: identical code, different file type and load commands.
xcrun clang -arch arm64 -target "$TRIPLE" -isysroot "$SDKPATH" -nostdlib -static -fno-stack-protector \
    -Wl,-no_adhoc_codesign -Wl,-headerpad,0x1000 -Wl,-e,_guest_test "$OUT/probe_guest.c" -o "$OUT/unsigned-exec-ios"
sign "$DEV" "$OUT/unsigned-exec-ios" "$OUT/dev-exec-ios"
# macOS-platform variant: is the platform relevant to a mapping dyld never sees?
dylib unsigned-macos.dylib arm64-apple-macos14.0 "$MACSDK"
sign "$DEV" "$OUT/unsigned-macos.dylib" "$OUT/dev-macos.dylib"

# Page container of the in-repo TestGuest, the same way Local signing builds one.
xcrun --sdk macosx clang -fobjc-arc -arch arm64 -O1 -mmacosx-version-min=14.0 -Wl,-no_fixup_chains \
    -o "$OUT/TestGuest" testguest/main.m -framework Cocoa -framework Metal -framework QuartzCore
python3 tools/build_signed_container.py --guest "$OUT/TestGuest" --platform "$PLATFORM" --sign "$DEV" \
    --identity "${SIGN_IDENTITY:-Apple Development}" --probe-symbol _tolkara_probe_leaf \
    --output "$OUT/testguest-container.dylib"
rm -f "$OUT/TestGuest"

# Our unsigned-* fixtures must stay unsigned; everything else must verify.
for variant in "$OUT"/*.dylib "$OUT"/*-exec-ios; do
    name=$(basename "$variant")
    case "$name" in
        unsigned-*) echo "== $name: unsigned";;
        *) result=$("$SIGNER" --verify "$variant" 2>&1) || { echo "== $name: VERIFICATION FAILED"; echo "$result" | tail -3; exit 1; }
           echo "== $name: $(echo "$result" | tail -1)";;
    esac
done
