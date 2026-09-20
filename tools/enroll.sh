#!/bin/bash
# One-time local authorization enrollment, over the Mac's trusted USB session.
# After this, the iPad prepares executable memory by itself; no Mac is needed
# for normal launches. Approve the prompt that appears on the iPad.
# usage: tools/enroll.sh            (DEVICE and TOLKARA_BUNDLE_ID from local.env)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[ -f local.env ] && { set -a; . ./local.env; set +a; }
BUNDLE=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
[ -n "${DEVICE:-}" ] || { echo "Set DEVICE=<iPad UDID> in local.env (xcrun devicectl list devices)."; exit 2; }

mkdir -p build
xcrun clang -fobjc-arc -framework Foundation tools/probe_pairing_enrollment_service.m \
    -o build/probe_pairing_enrollment_service
xcrun swiftc -O -parse-as-library authorization/Pairing/PairingWire.swift authorization/Pairing/PairingCrypto.swift \
    authorization/Pairing/PairingIdentity.swift authorization/Storage/PairingEnrollment.swift \
    tools/enrollment_crypto.swift -o build/enrollment_crypto

# Private 0700 directory; the record is removed whether or not the import succeeds.
PRIVATE=$(mktemp -d "${TMPDIR:-/tmp}/tolkara-enroll.XXXXXX"); chmod 700 "$PRIVATE"
trap 'rm -rf "$PRIVATE"' EXIT
launch() { xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" "$@" > /dev/null; }

echo "Preparing the app's protected import directory…"
launch --prepare-authorization-import; sleep 3
python3 tools/enroll_local_authorization.py --device "$DEVICE" --output "$PRIVATE/Enrollment.pending" | tee "$PRIVATE/enroll.log"
FINGERPRINT=$(sed -n 's/^Public enrollment fingerprint: //p' "$PRIVATE/enroll.log")
[ ${#FINGERPRINT} -eq 64 ] || { echo "Enrollment did not complete."; exit 1; }
xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$PRIVATE/Enrollment.pending" \
    --destination "Library/Application Support/LocalAuthorization/Enrollment.pending" > /dev/null
launch --import-authorization-enrollment --expected-device "$DEVICE" --expected-enrollment-fingerprint "$FINGERPRINT"; sleep 5
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source Documents/authorization-import-result.txt --destination "$PRIVATE/result.txt" > /dev/null
cat "$PRIVATE/result.txt"; echo
grep -q "^Verified enrollment imported" "$PRIVATE/result.txt"
