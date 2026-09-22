#!/bin/bash
# Builds tools/sign_guest_local.m and checks it end to end on this Mac. The
# unsigned fixture is built here from source; outputs go to build/sign-local/.
#   1. tests/test_sign_guest_local.py: parser rejections, --verify tamper and
#      structure cases, ad-hoc mode, RSA/ECDSA self-tests. No keychain access:
#      the opt-in TOLKARA_SIGN_KEYCHAIN_TESTS is cleared (steps 3-4 cover it).
#   2. --adhoc must be byte-identical to `codesign -s -`; --adhoc, --selftest
#      and --selftest-ec outputs must pass codesign -v --strict and --verify.
#      No keychain access.
#   3. --dry-run with the developer identity reads its certificates from the
#      keychain but never uses the private key. Its output must match a
#      reference that codesign(1) signs with the same certificate (this uses
#      the key through codesign) in every codesign -dv field except path,
#      hashes, time, size and authority; code bytes must be unchanged.
#   4. Real signing: the tool itself uses the private key. The first run shows
#      a keychain approval dialog ("Always Allow"); if the keychain denies
#      access the script stops with exit 2. The result must pass codesign -v
#      --strict and --verify and match the reference's codesign -dv fields.
# Identity: SIGN_IDENTITY (default "Apple Development"), restricted to
# DEVELOPMENT_TEAM from local.env when set. Exit 0 only when every check passed.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[ -f local.env ] && { set -a; . ./local.env; set +a; }
IDENTITY=(-s "${SIGN_IDENTITY:-Apple Development}")
[ -n "${DEVELOPMENT_TEAM:-}" ] && IDENTITY+=(--team "$DEVELOPMENT_TEAM")
OUT=build/sign-local
TOOL=$OUT/sign_guest_local
FIXTURE=$OUT/sgl-fixture.dylib # the file name gives the default identifier
REF=$OUT/ref/sgl-fixture.dylib
mkdir -p "$OUT/ref"

fail() { echo "FAILED: $*" >&2; exit 1; }

# codesign -dv fields that must match a reference: drops the path, hashes,
# signing time, signature size and any extra field pattern given as $2.
fields() {
    codesign -dv --verbose=4 "$1" 2>&1 |
        grep -Ev "^(Executable=|CDHash|CandidateCDHash|CMSDigest|Signed Time|Signature size|Timestamp${2:+|$2})"
}

# Every fixture byte is kept except ncmds/sizeofcmds, the LC_CODE_SIGNATURE
# stamped into the header pad and the __LINKEDIT sizes.
code_unchanged() {
    python3 - "$FIXTURE" "$1" <<'PYEOF'
import struct, sys
u = open(sys.argv[1], 'rb').read()
s = open(sys.argv[2], 'rb').read()
uncmds, ucmds = struct.unpack('<II', u[16:24])
sncmds, scmds = struct.unpack('<II', s[16:24])
assert sncmds == uncmds + 1 and scmds == ucmds + 16, "load command counts"
off, leoff = 32, None
for _ in range(uncmds):
    cmd, cmdsize = struct.unpack('<II', u[off:off + 8])
    if cmd == 0x19 and u[off + 8:off + 24].split(b'\0')[0] == b'__LINKEDIT':
        leoff = off
    off += cmdsize
assert leoff is not None and off == 32 + ucmds
allowed = [(16, 24), (off, off + 16), (leoff + 32, leoff + 40), (leoff + 48, leoff + 56)]
def masked(d):
    b = bytearray(d)
    for lo, hi in allowed:
        b[lo:hi] = b'\0' * (hi - lo)
    return bytes(b)
assert masked(u) == masked(s[:len(u)]), "code bytes differ outside patched fields"
print("   code bytes unchanged (%d bytes; only ncmds/sizeofcmds, LC_CODE_SIGNATURE, __LINKEDIT sizes)" % len(u))
PYEOF
}

xcrun clang -fobjc-arc -O1 -Wall -Wextra -Werror \
    -framework Foundation -framework Security \
    tools/sign_guest_local.m -o "$TOOL"
cat > "$OUT/fixture.c" <<'EOF'
__attribute__((visibility("default"))) int guest_test(void) { return 0x12345678; }
EOF
xcrun clang -arch arm64 -target arm64-apple-ios17.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -dynamiclib -fno-stack-protector -Wl,-no_adhoc_codesign "$OUT/fixture.c" -o "$FIXTURE"

echo "== 1. unit tests (no keychain access)"
TOLKARA_SIGN_KEYCHAIN_TESTS= python3 -m unittest tests.test_sign_guest_local

echo "== 2. ad-hoc and self-signed signatures (no keychain access)"
cp "$FIXTURE" "$OUT/ref/adhoc.dylib"
codesign -f -s - -i sgl-fixture "$OUT/ref/adhoc.dylib"
"$TOOL" --adhoc -i sgl-fixture "$FIXTURE" "$OUT/adhoc.dylib"
cmp "$OUT/adhoc.dylib" "$OUT/ref/adhoc.dylib" || fail "--adhoc output differs from codesign -s -"
for mode in adhoc selftest selftest-ec; do
    "$TOOL" --$mode "$FIXTURE" "$OUT/$mode.dylib"
    codesign -v --strict "$OUT/$mode.dylib" || fail "codesign -v rejects the --$mode output"
    "$TOOL" --verify "$OUT/$mode.dylib" | tail -1
    code_unchanged "$OUT/$mode.dylib"
done

echo "== 3. dry run with the developer identity (keychain certificates, no private key)"
"$TOOL" --dry-run "${IDENTITY[@]}" "$FIXTURE" "$OUT/dryrun.dylib" 2> "$OUT/dryrun.log" ||
    { cat "$OUT/dryrun.log" >&2; fail "--dry-run could not select an identity or build the signature"; }
cat "$OUT/dryrun.log"
SHA1=$(sed -n 's/^identity: \([0-9A-F]\{40\}\) .*/\1/p' "$OUT/dryrun.log")
[ -n "$SHA1" ] || fail "--dry-run did not report the selected identity"
# Only the zeroed placeholder signature may fail verification.
if "$TOOL" --verify "$OUT/dryrun.dylib" > "$OUT/dryrun.verify"; then
    fail "--verify accepted a zeroed signature"
fi
grep -q '^CMS messageDigest: OK$' "$OUT/dryrun.verify" &&
    [ "$(grep -c 'FAIL' "$OUT/dryrun.verify")" = 2 ] &&
    grep -q '^CMS signature: FAIL (zeroed placeholder' "$OUT/dryrun.verify" ||
    { cat "$OUT/dryrun.verify" >&2; fail "dry-run output fails more than the placeholder signature"; }
echo "   --verify: hashes and CMS binding OK, signature is the zeroed placeholder"
code_unchanged "$OUT/dryrun.dylib"
cp "$FIXTURE" "$REF"
codesign -f -s "$SHA1" -i sgl-fixture "$REF" ||
    fail "codesign could not sign the reference with $SHA1 (keychain access to the key?)"
diff <(fields "$REF" Authority) <(fields "$OUT/dryrun.dylib" Authority) ||
    fail "dry-run codesign -dv fields differ from the codesign reference"
echo "   codesign -dv fields identical to the reference (except path/hashes/time/size/authority)"

echo "== 4. real signature with the developer identity (private key; approval dialog on first use)"
rc=0
"$TOOL" -i sgl-fixture -s "$SHA1" "$FIXTURE" "$OUT/signed.dylib" || rc=$?
if [ "$rc" = 3 ]; then
    echo >&2
    echo "The keychain denied access to the signing key. Rerun this script from" >&2
    echo "a terminal and choose \"Always Allow\" in the approval dialog." >&2
    echo "Steps 1-3 passed." >&2
    exit 2
fi
[ "$rc" = 0 ] || fail "signing with the developer identity failed (exit $rc)"
codesign -v --strict "$OUT/signed.dylib" || fail "codesign -v rejects the signed output"
"$TOOL" --verify "$OUT/signed.dylib" | tail -1
code_unchanged "$OUT/signed.dylib"
diff <(fields "$REF") <(fields "$OUT/signed.dylib") || fail "codesign -dv fields differ from the codesign reference"
echo "   codesign -dv fields identical to the reference (except path/hashes/time/size)"

echo "ALL SIGN-LOCAL CHECKS PASSED"
