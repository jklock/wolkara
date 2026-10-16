#!/bin/bash
# What install does after the app is on the device, per execution mode.
#
# The audit's point: install.sh ran the platform's enroll.sh after every install, which
# is developer-service work and is wrong for Local signing and External JIT. This drives
# wolkara/tools/after_install.sh with a stub enroll.sh and a stub xcrun in front of it,
# and asserts which of them each mode actually reaches for. Nothing is built and no
# device is touched.
#
#   wolkara/tools/tests/test_after_install.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
after_install="$root/wolkara/tools/after_install.sh"
[ -x "$after_install" ] || { echo "after_install.sh is not executable"; exit 2; }

checks=0
failures=0
check() {
    checks=$((checks + 1))
    if [ "$1" = 0 ]; then return 0; fi
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$2"
}

work=$(mktemp -d -t wolkara-after-install)
trap 'rm -rf "$work"' EXIT

# A prepared tree with a stub enrollment step that records that it ran.
mkdir -p "$work/tree/tools" "$work/bin"
cat > "$work/tree/tools/enroll.sh" <<SH
#!/bin/bash
echo "enrolled" >> "$work/enroll.log"
echo "Enrollment verified and stored."
SH
chmod +x "$work/tree/tools/enroll.sh"

# A stub xcrun: records every call, and answers the file listing with whatever
# WOLKARA_FAKE_FILES holds.
cat > "$work/bin/xcrun" <<SH
#!/bin/bash
echo "\$*" >> "$work/xcrun.log"
if [ -n "\${WOLKARA_FAKE_FILES:-}" ]; then printf '%s\n' "\$WOLKARA_FAKE_FILES"; fi
exit 0
SH
chmod +x "$work/bin/xcrun"

# An executable to sign for, so Local signing has something to look for.
printf 'not really an executable\n' > "$work/guest"
sha=$(shasum -a 256 "$work/guest" | cut -d' ' -f1)

run_mode() {
    rm -f "$work/enroll.log" "$work/xcrun.log"
    touch "$work/xcrun.log"
    ( cd "$work/tree" && PATH="$work/bin:$PATH" DEVICE=FAKE-DEVICE TOLKARA_BUNDLE_ID=test.bundle \
        GUEST_EXE="$work/guest" "$after_install" "$1" ) > "$work/out.txt" 2>&1
    return $?
}

enrolled() { [ -s "$work/enroll.log" ]; }

# Developer service: enrollment is this mode's own step, and it must run.
run_mode developer-service
check $? "developer-service should succeed"
enrolled
check $? "developer-service should enroll"
grep -q "enroll" "$work/out.txt"
check $? "and should say so"

# Local signing: no enrollment at all, and the page containers are checked instead.
WOLKARA_FAKE_FILES="Documents/LocalSigning/$sha.dylib" run_mode local-signing
check $? "local-signing should succeed when the container is there"
enrolled && check 1 "local-signing must not enroll"
grep -q "device info files" "$work/xcrun.log"
check $? "local-signing should look for the page container"
grep -q "page container present" "$work/out.txt"
check $? "and should report it"

# A container that is not there is a failure, not a shrug: the runtime will refuse to
# start that executable.
WOLKARA_FAKE_FILES="Documents/LocalSigning/somethingelse.dylib" run_mode local-signing
[ $? -ne 0 ]
check $? "local-signing should fail when the container is missing"
grep -q "NO PAGE CONTAINER" "$work/out.txt"
check $? "and should say which one is missing"
enrolled && check 1 "local-signing must still not enroll"

# External JIT: prepared by a JIT enabler at launch. Nothing here, and no enrollment.
run_mode external-jit
check $? "external-jit should succeed"
enrolled && check 1 "external-jit must not enroll"
[ -s "$work/xcrun.log" ] && check 1 "external-jit should not touch the device"

# No mode chosen yet: the app asks on first launch, so nothing is enrolled now.
run_mode ""
check $? "an unset mode should succeed"
enrolled && check 1 "an unset mode must not enroll"

# Anything else is a mistake worth stopping for.
run_mode "local-signing-but-typo"
[ $? -eq 2 ]
check $? "an unknown mode should be refused"

if [ "$failures" -eq 0 ]; then
    echo "AFTER-INSTALL PASS: $checks checks"
    exit 0
fi
echo "AFTER-INSTALL FAIL: $failures of $checks checks failed"
exit 1
