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
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
# A device, faked. Quoted heredoc on purpose: this is plain bash, with no expansion
# happening when the test writes it, so nothing here needs escaping.
#   WOLKARA_FAKE_BLIND      a subcommand that should fail ("processes" or "files")
#   WOLKARA_FAKE_PROCESSES  what `device info processes` lists
#   WOLKARA_FAKE_LISTING    what the app container listing holds
#   WOLKARA_FAKE_CRASHES    what the system crash-log listing holds
#   WOLKARA_FAKE_IPS        the crash report a copy returns
args="$*"
case "$args" in
*"device info processes"*)
    [ "${WOLKARA_FAKE_BLIND:-}" = processes ] && exit 1
    printf '%s\n' "${WOLKARA_FAKE_PROCESSES:-}"
    exit 0;;
*"device info files"*)
    [ "${WOLKARA_FAKE_BLIND:-}" = files ] && exit 1
    out=""
    previous=""
    for word in $args; do
        [ "$previous" = "--json-output" ] && out="$word"
        previous="$word"
    done
    [ -n "$out" ] || exit 1
    case "$args" in
    *systemCrashLogs*) printf '%s' "${WOLKARA_FAKE_CRASHES:-}" > "$out";;
    *) printf '%s' "${WOLKARA_FAKE_LISTING:-}" > "$out";;
    esac
    exit 0;;
*"device copy from"*)
    dest=""
    previous=""
    source=""
    for word in $args; do
        [ "$previous" = "--destination" ] && dest="$word"
        [ "$previous" = "--source" ] && source="$word"
        previous="$word"
    done
    [ -n "$dest" ] || exit 1
    case "$source" in
    *.ips) printf '%s' "${WOLKARA_FAKE_IPS:-}" > "$dest";;
    *native-guest.log) printf '%s' "${WOLKARA_FAKE_GUESTLOG:-guest log line}" > "$dest";;
    *) printf 'guest log line\n' > "$dest";;
    esac
    exit 0;;
*"device capture screenshot"*)
    dest=""
    previous=""
    for word in $args; do
        [ "$previous" = "--destination" ] && dest="$word"
        previous="$word"
    done
    [ -n "$dest" ] || exit 1
    printf 'not really a png\n' > "$dest"
    exit 0;;
*"device info apps"*)
    printf 'Wolkara Forever  local.wolkara.johnklock\n'
    exit 0;;
esac
exit 0
STUB
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

# A device in the middle of an update: files under the staged-update directory, written
# just now.
listing_with_update_writing() {
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
    cat <<JSON
{"result":{"files":[
 {"name":"Documents","relativePath":"Documents","metadata":{"lastModDate":"$now"},"resources":{"isDirectory":true}},
 {"name":"Documents/.tolkara-updates/partial","relativePath":"Documents/.tolkara-updates/partial","metadata":{"lastModDate":"$now"},"resources":{"isDirectory":false}}
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

# A device with a game session live: the app running, and a guest log written just now. The state
# that makes every mutating command refuse, and that the stub's guest-log copy fills with a PASS.
listing_with_a_live_session() {
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
    cat <<JSON
{"result":{"files":[
 {"name":"Documents","relativePath":"Documents","metadata":{"lastModDate":"$now"},"resources":{"isDirectory":true}},
 {"name":"Documents/native-guest.log","relativePath":"Documents/native-guest.log","metadata":{"lastModDate":"$now"},"resources":{"isDirectory":false}}
]}}
JSON
}

# The stub has a default for everything it is not told, so a run only has to set what it
# cares about - which is exported by the test and inherited here.
run_pilot() {
    local session=$1; shift
    ( cd "$root" && PATH="$work/bin:$PATH" DEVICE=FAKE TOLKARA_BUNDLE_ID=test.bundle \
        PILOT_SESSION="$session" "$pilot" "$@" ) > "$work/out.txt" 2>&1
    return $?
}

# What the fake device answers with. Everything the stub reads is exported here, once,
# so a case only has to change what it is about.
export WOLKARA_FAKE_PROCESSES="  1234   /private/var/containers/Bundle/Application/AAA/Tolkara.app/Tolkara"
export WOLKARA_FAKE_LISTING="$(listing_with_error)"
export WOLKARA_FAKE_CRASHES='{"result":{"files":[]}}'
export WOLKARA_FAKE_IPS=""
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

# An install owes the operator the state it found. A game session that was live goes back into
# the game, not onto the launcher; an app that was merely up goes back up; and nothing is started
# when nothing was running. On 2026-10-17 an install left the launcher up while a session was
# being tested and said nothing about it - the same fault as a false PASS, because the device was
# changed and the tool did not mention it.
export WOLKARA_FAKE_PROCESSES=""
mkdir -p "$work/sessions/found"
printf '1234\n' > "$work/sessions/found/was-running"
printf '1\n' > "$work/sessions/found/was-live"
run_pilot "$work/sessions/found" restore
check $? "restore must start the app again when the session recorded one running"
grep -q "home" "$work/out.txt"
check $? "and must leave the app on its home screen, saying what it found"
# And it must not claim to put a game session back. Nothing can: the state is memory in the process
# that a stop kills. The review outcome calls this out, so the check is that the claim is absent.
grep -qE "press Play|game session was live" "$work/out.txt" && check 1 "and must not claim a game session can be restored"

mkdir -p "$work/sessions/stopped"
printf '\n' > "$work/sessions/stopped/was-running"
printf '0\n' > "$work/sessions/stopped/was-live"
run_pilot "$work/sessions/stopped" restore
check $? "restore must succeed when nothing was running"
grep -q "left stopped" "$work/out.txt"
check $? "and must leave it stopped rather than starting something nobody asked for"

mkdir -p "$work/sessions/norecord"
run_pilot "$work/sessions/norecord" restore
check $? "restore must not fail when the session holds no record"
grep -q "no record of anything running" "$work/out.txt"
check $? "and must say it has no record rather than guessing"

export WOLKARA_FAKE_PROCESSES="  1234   /private/var/containers/Bundle/Application/AAA/Tolkara.app/Tolkara"

# A live game session is never touched. This is the first operating rule in the review outcome, and
# the proof it asks for: every command that stops, installs over or relaunches the app refuses, and
# does nothing at all while refusing. A running game's state is memory in the process that would be
# killed, so no command here can put it back, and none of them may try.
export WOLKARA_FAKE_LISTING="$(listing_with_a_live_session)"
export WOLKARA_FAKE_GUESTLOG=$'startup_return=PASS\n'
run_pilot "$work/sessions/live" state
grep -q "a game session is live" "$work/out.txt"
check $? "the fixture really is a live game session"
run_pilot "$work/sessions/live" install
[ $? -ne 0 ]
check $? "install must refuse while a game session is live"
grep -q "game session is live" "$work/out.txt"
check $? "and must say that is why"
if grep -qE "launching|stopped" "$work/out.txt"; then
    check 1 "and must not have touched the app"
    echo "--- install printed: ---"; sed 's/^/    /' "$work/out.txt"; echo "--- end ---"
fi
run_pilot "$work/sessions/live" stop
[ $? -ne 0 ]
check $? "stop must refuse while a game session is live"
if grep -qE "launching|stopped" "$work/out.txt"; then
    check 1 "and must not have touched the app"
    echo "--- stop printed: ---"; sed 's/^/    /' "$work/out.txt"; echo "--- end ---"
fi
run_pilot "$work/sessions/live" cycle
[ $? -ne 0 ]
check $? "cycle must refuse while a game session is live"
if grep -qE "launching|stopped" "$work/out.txt"; then
    check 1 "and must not have touched the app"
    echo "--- cycle printed: ---"; sed 's/^/    /' "$work/out.txt"; echo "--- end ---"
fi
run_pilot "$work/sessions/live" selftest voice
[ $? -ne 0 ]
check $? "selftest must refuse while a game session is live"
if grep -qE "launching|stopped" "$work/out.txt"; then
    check 1 "and must not have touched the app"
    echo "--- selftest printed: ---"; sed 's/^/    /' "$work/out.txt"; echo "--- end ---"
fi
unset WOLKARA_FAKE_GUESTLOG
export WOLKARA_FAKE_LISTING="$(listing_without_errors)"

# And with no game live, the same commands still work: the guard must not have broken the ordinary
# path. This is the check that keeps the refusal honest.
run_pilot "$work/sessions/quiet" stop --dry-run
check $? "with nothing live, stop still works"
grep -q "dry run" "$work/out.txt"
check $? "and says what it would do"

# Each run keeps its own work files.
run_pilot "$work/sessions/one" state
run_pilot "$work/sessions/two" state
[ -f "$work/sessions/one/state.txt" ] && [ -f "$work/sessions/two/state.txt" ]
check $? "two runs should have two state files"
[ "$(cat "$work/sessions/one/state.txt")" != "" ]
check $? "and the first run's state should still be there"

# An update being written right now must stop an install before it builds anything.
export WOLKARA_FAKE_LISTING="$(listing_with_update_writing)"
run_pilot "$work/sessions/writing" install
[ $? -ne 0 ]
check $? "install must refuse while an update is being written"
grep -q "an update is writing" "$work/out.txt"
check $? "and must say why it refused"

# A crash report is read out, frames and all, not just named.
export WOLKARA_FAKE_LISTING="$(listing_without_errors)"
export WOLKARA_FAKE_CRASHES='{"result":{"files":[{"name":"Tolkara-2026-10-16-120000.ips","relativePath":"Tolkara-2026-10-16-120000.ips","metadata":{"lastModDate":"2026-10-16T12:00:00.000Z"}}]}}'
export WOLKARA_FAKE_IPS='{"app_name":"Tolkara"}
{"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"termination":{"indicator":"Abort trap: 6"},"usedImages":[{"name":"Tolkara.debug.dylib"}],"threads":[{"triggered":true,"frames":[{"imageIndex":0,"symbol":"-[AKVoiceViewController done]"}]}]}'
run_pilot "$work/sessions/crash" crash
crash_rc=$?
crash_ok=0
grep -q "AKVoiceViewController done" "$work/out.txt" || crash_ok=1
if [ "$crash_ok" != 0 ]; then
    echo "--- crash (exit $crash_rc) printed: ---"
    sed 's/^/    /' "$work/out.txt"
    echo "--- end ---"
fi
check "$crash_ok" "the crash report is read out with its frames"
unset WOLKARA_FAKE_IPS

# A crash report that appears while waiting is the answer, and is reported as one: the
# process is already gone by then, so it beats anything the log would say. The session carries
# the baseline a launch would have written, because that is the flow this is about: launch, then
# wait. Waiting with no baseline at all is the case below, and that is the one that used to lie.
mkdir -p "$work/sessions/timeout"
printf 'Tolkara-2026-10-15-090000.ips\n' > "$work/sessions/timeout/crash-baseline.txt"
printf '2026-10-15_09.00.00_Error_1.txt\n' > "$work/sessions/timeout/baseline.txt"
printf '0\n' > "$work/sessions/timeout/starts-baseline.txt"
run_pilot "$work/sessions/timeout" wait --timeout 8
[ $? -ne 0 ]
check $? "wait must fail when a new crash report appears"
grep -q "CRASHED" "$work/out.txt"
check $? "and must say it crashed rather than waiting out the clock"

# The other side of it: a report that was already on the device, with no baseline to compare it
# against, is not this run's crash. On 2026-10-17 a standalone wait printed CRASHED for an app
# that was running, because the newest report was a day old and the session had nothing to
# compare it with. Nothing may be concluded from a comparison that was never made.
mkdir -p "$work/sessions/nobaseline"
run_pilot "$work/sessions/nobaseline" wait --timeout 4
[ $? -eq 0 ]
check $? "an old crash report with no baseline is not a crash"
grep -q "CRASHED" "$work/out.txt" && check 1 "and CRASHED must not be printed at all"
grep -q "cannot be judged" "$work/out.txt"
check $? "and it must say that is why"

# Nothing crashing, and nothing changing: a run that produces nothing conclusive must say
# so rather than claiming success.
export WOLKARA_FAKE_CRASHES='{"result":{"files":[]}}' 
# Nothing runs and nothing changes, so there is nothing to conclude.
export WOLKARA_FAKE_PROCESSES=""
mkdir -p "$work/sessions/timeout"
# Looking for the guest, not for the launcher: with a launcher wait and nothing running,
# the honest answer is "the app is gone", which is a different path.
echo game > "$work/sessions/timeout/mode.txt"
run_pilot "$work/sessions/timeout" wait --timeout 4
wait_rc=$?
[ "$wait_rc" -ne 0 ]
check $? "wait must not call an inconclusive run a success (exit $wait_rc)"
wait_ok=0
grep -q "nothing conclusive" "$work/out.txt" || wait_ok=1
if [ "$wait_ok" != 0 ]; then
    echo "--- wait printed: ---"
    sed 's/^/    /' "$work/out.txt"
    echo "--- end ---"
fi
check "$wait_ok" "and must say that instead"
unset WOLKARA_FAKE_PROCESSES

# Two runs with no session given must not share one. They are named in the output so a run
# can be found afterwards. PILOT_SESSION is cleared for these two: a caller that hands one
# over - validate.sh does, so its steps are one run - is a different case from the default.
( cd "$root" && PATH="$work/bin:$PATH" DEVICE=FAKE TOLKARA_BUNDLE_ID=test.bundle \
    env -u PILOT_SESSION "$pilot" state ) > "$work/out.txt" 2>&1
first=$(sed -n 's/^  session: *//p' "$work/out.txt" | head -1)
( cd "$root" && PATH="$work/bin:$PATH" DEVICE=FAKE TOLKARA_BUNDLE_ID=test.bundle \
    env -u PILOT_SESSION "$pilot" state ) > "$work/out.txt" 2>&1
second=$(sed -n 's/^  session: *//p' "$work/out.txt" | head -1)
[ -n "$first" ] && [ -n "$second" ] && [ "$first" != "$second" ]
check $? "two runs must not share a session directory (got '$first' and '$second')"
[ -d "$first" ] && [ -d "$second" ]
check $? "and both directories should exist"
rm -rf "$first" "$second"

# A launch while the app is up is refused: it is not this script's job to decide that a
# running session should end, and not launching is the safe answer.
# The stub's own default is "nothing running", so this case states what it is about.
export WOLKARA_FAKE_PROCESSES="  1234   /private/var/containers/Bundle/Application/AAA/Tolkara.app/Tolkara"
run_pilot "$work/sessions/running" launch
[ $? -eq 2 ]
check $? "launch must refuse while the app is running"
grep -q "the app is already running" "$work/out.txt"
check $? "and must say so rather than replacing it"

# Two runs at once. The work files are per run, so neither can read the other's baseline -
# and each writes its own verdict rather than clobbering the other's.
export WOLKARA_FAKE_PROCESSES=""
mkdir -p "$work/sessions/par-a" "$work/sessions/par-b"
# Looking for the guest, not the launcher: with nothing running and a launcher wait, the
# honest answer is "the app is gone", which is a different conclusion from a timeout.
echo game > "$work/sessions/par-a/mode.txt"
echo game > "$work/sessions/par-b/mode.txt"
( cd "$root" && PATH="$work/bin:$PATH" DEVICE=FAKE TOLKARA_BUNDLE_ID=test.bundle \
    PILOT_SESSION="$work/sessions/par-a" "$pilot" wait --timeout 4 ) > "$work/par-a.txt" 2>&1 &
pid_a=$!
( cd "$root" && PATH="$work/bin:$PATH" DEVICE=FAKE TOLKARA_BUNDLE_ID=test.bundle \
    PILOT_SESSION="$work/sessions/par-b" "$pilot" wait --timeout 4 ) > "$work/par-b.txt" 2>&1 &
pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
[ "$rc_a" = "$rc_b" ]
check $? "two runs at once should reach the same verdict ($rc_a, $rc_b)"
grep -q "nothing conclusive" "$work/par-a.txt" && grep -q "nothing conclusive" "$work/par-b.txt"
check $? "and each should have concluded for itself"
[ -f "$work/sessions/par-a/state.txt" ] && [ -f "$work/sessions/par-b/state.txt" ]
check $? "with a state file of its own"
export WOLKARA_FAKE_PROCESSES="  1234   /private/var/containers/Bundle/Application/AAA/Tolkara.app/Tolkara"

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
