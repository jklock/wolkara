#!/bin/bash
# pilot.sh, with a fake device.
#
# Two things the audit called out are tested here, because both of them would look
# exactly like success in a log:
#
#   * an inspection that *failed* must never read as "nothing was wrong". A `devicectl`
#     that cannot see the iPad produces no error files, and no error files is what a
#     healthy client looks like.
#   * work files must belong to one run. They used to be fixed names under /tmp, so a
#     second pilot compared against the first one's baseline.
#
#   wolkara/tools/tests/test_pilot.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
pilot="$root/wolkara/tools/pilot.sh"
[ -x "$pilot" ] || { echo "pilot.sh is not executable"; exit 2; }

checks=0
failures=0
check() {
    checks=$((checks + 1))
    if [ "$1" = 0 ]; then return 0; fi
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$2"
}

work=$(mktemp -d -t wolkara-pilot-test)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/sessions"

# A device, faked. WOLKARA_FAKE_BLIND names a subcommand that fails, which is the case
# under test.
cat > "$work/bin/xcrun" <<SH
#!/bin/bash
args="\$*"
case "\$args" in
*"device info processes"*)
    [ "\${WOLKARA_FAKE_BLIND:-}" = processes ] && exit 1
    printf '  1234   /private/var/containers/Bundle/Application/AAA/Tolkara.app/Tolkara\n'
    exit 0;;
*"device info files"*)
    [ "\${WOLKARA_FAKE_BLIND:-}" = files ] && exit 1
    out=""
    previous=""
    for word in \$args; do
        [ "\$previous" = "--json-output" ] && out="\$word"
        previous="\$word"
    done
    [ -n "\$out" ] || exit 1
    case "\$args" in
    *systemCrashLogs*) printf '%s' "\$WOLKARA_FAKE_CRASHES" > "\$out";;
    *) printf '%s' "\$WOLKARA_FAKE_LISTING" > "\$out";;
    esac
    exit 0;;
*"device copy from"*)
    dest=""
    previous=""
    for word in \$args; do
        [ "\$previous" = "--destination" ] && dest="\$word"
        previous="\$word"
    done
    [ -n "\$dest" ] || exit 1
    printf 'guest log line\n' > "\$dest"
    exit 0;;
*"device capture screenshot"*)
    dest=""
    previous=""
    for word in \$args; do
        [ "\$previous" = "--destination" ] && dest="\$word"
        previous="\$word"
    done
    [ -n "\$dest" ] || exit 1
    printf 'not really a png\n' > "\$dest"
    exit 0;;
*"device info apps"*)
    printf 'Wolkara Forever  local.wolkara.johnklock\n'
    exit 0;;
esac
exit 0
SH
chmod +x "$work/bin/xcrun"

listing_with_error() {
    cat <<JSON
{"result":{"files":[
 {"name":"Documents","relativePath":"Documents","metadata":{"lastModDate":"2026-10-16T10:00:00.000Z"},"resources":{"isDirectory":true}},
 {"name":"Documents/World of Warcraft/_classic_beta_/Errors/2026-10-16_09.00.00_Error_1.txt","relativePath":"Documents/World of Warcraft/_classic_beta_/Errors/2026-10-16_09.00.00_Error_1.txt","metadata":{"lastModDate":"2026-10-16T09:00:00.000Z"},"resources":{"isDirectory":false}},
 {"name":"Documents/native-guest.log","relativePath":"Documents/native-guest.log","metadata":{"lastModDate":"2026-10-16T09:00:00.000Z"},"resources":{"isDirectory":false}}
]}}
JSON
}

listing_without_errors() {
    cat <<JSON
{"result":{"files":[
 {"name":"Documents","relativePath":"Documents","metadata":{"lastModDate":"2026-10-16T10:00:00.000Z"},"resources":{"isDirectory":true}}
]}}
JSON
}

run_pilot() {
    local session=$1; shift
    ( cd "$root" && PATH="$work/bin:$PATH" \
        DEVICE=FAKE TOLKARA_BUNDLE_ID=test.bundle \
        WOLKARA_FAKE_LISTING="$WOLKARA_FAKE_LISTING" \
        WOLKARA_FAKE_CRASHES='{"result":{"files":[]}}' \
        PILOT_SESSION="$session" "$pilot" "$@" ) > "$work/out.txt" 2>&1
    return $?
}

# A healthy-looking device with an error file: it must be seen and named.
export WOLKARA_FAKE_LISTING="$(listing_with_error)"
run_pilot "$work/sessions/seen" state
check $? "state should succeed"
grep -q "newest 2026-10-16_09.00.00_Error_1.txt" "$work/out.txt"
check $? "the newest error file should be reported"
grep -q "COULD NOT BE INSPECTED" "$work/out.txt" && check 1 "a healthy inspection must not warn"

# The same device, but devicectl cannot list files. The old script read that as zero
# error files, which is indistinguishable from a clean run.
( export WOLKARA_FAKE_BLIND=files; run_pilot "$work/sessions/blind" state )
check $? "state should still succeed, but say what it could not see"
grep -q "THE DEVICE COULD NOT BE INSPECTED" "$work/out.txt"
check $? "a failed inspection must be reported"

# And a view of a device it cannot see must not claim the client did not assert.
( export WOLKARA_FAKE_BLIND=files; run_pilot "$work/sessions/blind" view )
grep -q "COULD NOT BE INSPECTED" "$work/out.txt"
check $? "view must say the device could not be inspected"
grep -q "the client did not assert" "$work/out.txt" && check 1 "view must not conclude anything from a failed inspection"

# Installing must fail closed when the device cannot be inspected.
( export WOLKARA_FAKE_BLIND=files; run_pilot "$work/sessions/blind" stop )
[ $? -ne 0 ]
check $? "stopping must refuse when the device cannot be inspected"

# A clean device with no error files at all is a real answer, not a failure.
export WOLKARA_FAKE_LISTING="$(listing_without_errors)"
run_pilot "$work/sessions/clean" state
grep -q "error files:    0" "$work/out.txt"
check $? "no error files is reported as none"
grep -q "COULD NOT BE INSPECTED" "$work/out.txt" && check 1 "and is not a warning"

# The running process is found from the listing, and a dry run says what it would do.
run_pilot "$work/sessions/clean" stop --dry-run
grep -q "would ask pid 1234" "$work/out.txt"
check $? "a dry run should name the process it would stop"

# Each run keeps its own work files.
run_pilot "$work/sessions/one" state
run_pilot "$work/sessions/two" state
[ -f "$work/sessions/one/state.txt" ] && [ -f "$work/sessions/two/state.txt" ]
check $? "two runs should have two state files"
[ "$(cat "$work/sessions/one/state.txt")" != "" ]
check $? "and the first run's state should still be there"

# Nothing may be written to the shared /tmp names any more.
before=$(ls /tmp 2>/dev/null | grep -c '^pilot-' || true)
run_pilot "$work/sessions/three" state
after=$(ls /tmp 2>/dev/null | grep -c '^pilot-' || true)
[ "$before" = "$after" ]
check $? "a run must not write to the shared /tmp/pilot-* names"

if [ "$failures" -eq 0 ]; then
    echo "PILOT PASS: $checks checks"
    exit 0
fi
echo "PILOT FAIL: $failures of $checks checks failed"
exit 1
