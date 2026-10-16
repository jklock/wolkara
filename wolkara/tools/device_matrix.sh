#!/bin/bash
# The parts of the physical-iPad matrix that a Mac can drive on its own.
#
# The audit's exit criteria ask for a device matrix that passes repeatedly without new
# crashes, game error files, data loss, or orphaned input/audio state. Some of that needs a
# person - speaking into the iPad, pressing a button on a pad, tapping Home - and those are
# listed as deferred at the end of this script rather than pretended. What is here is what a
# script can honestly check:
#
#   1. the device can be inspected at all (otherwise nothing below means anything)
#   2. a fresh install, and the user's file surviving it
#   3. a config file the user edited being *imported*
#   4. a config file that is malformed being refused, kept, and survived
#   5. no new crash report and no new game error file for the launches above
#
#   wolkara/tools/device_matrix.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
root=$PWD
. wolkara/tools/env.sh

device=${DEVICE:-}
bundle=${TOLKARA_BUNDLE_ID:-}
[ -n "$device" ] || { echo "device_matrix: set DEVICE in local.env" >&2; exit 2; }
[ -n "$bundle" ] || { echo "device_matrix: set TOLKARA_BUNDLE_ID in local.env" >&2; exit 2; }

work=$(mktemp -d -t wolkara-device-matrix)
# One pilot session for the whole matrix: the launch baseline recorded in one step is what
# the log and verdict steps compare against, and they only see it if they are the same run.
export PILOT_SESSION=$(mktemp -d -t pilot-device-matrix)
trap 'rm -rf "$work" "$PILOT_SESSION"' EXIT

checks=0
failures=0
check() {
    checks=$((checks + 1))
    if [ "$1" = 0 ]; then
        printf '  ok   %s\n' "$2"
        return 0
    fi
    failures=$((failures + 1))
    printf '  FAIL %s\n' "$2"
}
step() { printf '\n== %s\n' "$*"; }

# The app's own file, either way.
fetch_config() {
    local destination=$1
    rm -f "$destination"
    xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
        --domain-identifier "$bundle" --source "Documents/wolkara-config.json" \
        --destination "$destination" >/dev/null 2>&1
}
push_file() {
    xcrun devicectl device copy to --device "$device" --domain-type appDataContainer \
        --domain-identifier "$bundle" --source "$1" --destination "$2" >/dev/null 2>&1
}

# Copy, then read it back and compare. `devicectl copy to` skips files it thinks are
# unmodified, so "I pushed it" is not the same as "the device holds what I pushed", and a
# matrix step that assumes otherwise tests the previous step's file.
push_file_verified() {
    local source=$1 destination=$2 back
    back=$(mktemp)
    push_file "$source" "$destination"
    xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
        --domain-identifier "$bundle" --source "$destination" --destination "$back" >/dev/null 2>&1
    if cmp -s "$source" "$back"; then
        rm -f "$back"
        return 0
    fi
    rm -f "$back"
    return 1
}
# The client has a mind of its own: it checks for and stages its own updates, and while it
# writes to its store nothing else may touch that store. `pilot.sh stop` therefore refuses
# and says so - "try again when it stops". So the matrix tries again. Waiting is the
# difference between a check that reads the client's own work as our failure and one that
# simply comes back when the device is free.
stop_when_quiet() {
    local deadline=$(( $(date +%s) + 300 ))
    local waited=0
    while :; do
        if wolkara/tools/pilot.sh stop > "$work/stop.log" 2>&1; then
            [ "$waited" -gt 0 ] && printf '  (waited %ss for the client to finish its own update)\n' "$waited"
            return 0
        fi
        # Only "an update is writing" is worth waiting out. Anything else - a device that
        # cannot be inspected, an app that will not die - is a real answer, so report it.
        if ! grep -q "an update is writing" "$work/stop.log"; then
            return 1
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            printf '  (the client is still updating its own files after %ss; not waiting longer)\n' "$waited" >> "$work/stop.log"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

app_value() {
    # The value of one key in the file the app has written, or "missing".
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    body = json.load(open(sys.argv[1]))
except Exception:
    print("unreadable"); raise SystemExit(0)
print(body.get("settings", {}).get(sys.argv[2], "missing"))
PY
}

step "1. the device can be inspected"
state=$(wolkara/tools/pilot.sh state 2>&1)
printf '%s\n' "$state" | sed 's/^/  /'
printf '%s' "$state" | grep -q "COULD NOT BE INSPECTED" && blind=1 || blind=0
check "$blind" "the device answers (nothing below means anything if it does not)"
[ "$blind" = 0 ] || exit 1

step "2. install, and the user's file surviving it"
# Something recognisable in the file, so "survived" is a fact rather than a hope.
[ -f "$work/before.json" ] || printf '{"version": 1, "settings": {"WoWRegion": "eu"}}' > "$work/before.json"
push_file "$work/before.json" "Documents/wolkara-config.json" \
    && printf '  (placed a known file on the device)\n'

if stop_when_quiet; then
    check 0 "the app stops when asked"
else
    # Nothing below is meaningful if the app is still up: a launch would be refused and
    # every check after it would be about the previous run's process.
    check 1 "the app stops when asked (see $work/stop.log)"
    sed 's/^/  /' "$work/stop.log" | tail -5
    exit 1
fi
if wolkara/tools/pilot.sh install > "$work/install.log" 2>&1; then
    check 0 "the app installs"
else
    check 1 "the app installs (see $work/install.log)"
fi
wolkara/tools/pilot.sh launch > "$work/launch.log" 2>&1
wolkara/tools/pilot.sh wait --timeout 60 > "$work/wait.log" 2>&1
wait_rc=$?
check "$wait_rc" "it launches and stays up (no new error file, no new crash report)"
sed 's/^/  /' "$work/wait.log" | tail -4

fetch_config "$work/after-install.json"
check "$([ "$(app_value "$work/after-install.json" WoWRegion)" = "eu" ] && echo 0 || echo 1)" \
      "the file survived the install and is still the app's"
printf '  the file on the device: %s\n' "$(cat "$work/after-install.json" 2>/dev/null | tr -d '\n' | cut -c1-140)"

step "3. a file the user edited is imported"
# A value that is *different* from what is there now, whichever that is: a check that
# asserts a fixed value passes or fails depending on what the previous run left behind,
# which is how this step reported a failure while behaving perfectly.
fetch_config "$work/before-edit.json"
current=$(app_value "$work/before-edit.json" WoWRegion)
if [ "$current" = "eu" ]; then wanted=us; else wanted=eu; fi
printf '{"version": 1, "settings": {"WoWRegion": "%s", "AKVoiceAutoSubmit": true}}' "$wanted" > "$work/edited.json"
stop_when_quiet || {
    check 1 "the app stops before the file is replaced (see $work/stop.log)"
    exit 1
}
check "$(push_file_verified "$work/edited.json" "Documents/wolkara-config.json" && echo 0 || echo 1)" \
      "the edited file is on the device"
wolkara/tools/pilot.sh launch >/dev/null 2>&1
wolkara/tools/pilot.sh wait --timeout 60 >/dev/null 2>&1
fetch_config "$work/after-import.json"
check "$([ "$(app_value "$work/after-import.json" WoWRegion)" = "$wanted" ] && echo 0 || echo 1)" \
      "the edited value was adopted (WoWRegion=$wanted, was $current)"
wolkara/tools/pilot.sh log 40 > "$work/log-import.log" 2>&1
# At least one choice taken from the file. Not an exact count: a value that was already
# what the file says is not a change, and the previous run may have left one there.
grep -qE "restored [1-9][0-9]* choice" "$work/log-import.log" && rc=0 || rc=1
check "$rc" "and the log says it took settings from the file"
grep -q "this log holds the launch from this run" "$work/log-import.log" && rc=0 || rc=1
check "$rc" "with the log bound to the launch this run performed"

step "4. a malformed file is refused, kept, and survived"
# A file cut off halfway, and a previous copy that is no better. This is the shape that
# used to send the recovery path round in circles.
printf '{"version": 1, "settings": {"WoWRegion": "e' > "$work/broken.json"
stop_when_quiet || {
    check 1 "the app stops before the malformed file is placed (see $work/stop.log)"
    exit 1
}
check "$(push_file_verified "$work/broken.json" "Documents/wolkara-config.json" && echo 0 || echo 1)" \
      "the malformed file is on the device"
push_file "$work/broken.json" "Documents/wolkara-config.json.bak"
wolkara/tools/pilot.sh launch >/dev/null 2>&1
wolkara/tools/pilot.sh wait --timeout 60 > "$work/wait-broken.log" 2>&1
check $? "the app still launches with a malformed file and a malformed copy"
wolkara/tools/pilot.sh log 60 > "$work/log-broken.log" 2>&1
grep -q "was not used" "$work/log-broken.log" && rc=0 || rc=1
check "$rc" "and says the file was refused"
grep -q "previous copy is not usable either" "$work/log-broken.log" && rc=0 || rc=1
check "$rc" "and that the previous copy was no better, rather than looping"
fetch_config "$work/after-broken.json"
check "$([ "$(app_value "$work/after-broken.json" WoWRegion)" != "unreadable" ] && echo 0 || echo 1)" \
      "and it wrote itself a usable file again"
printf '  the file on the device now: %s\n' "$(cat "$work/after-broken.json" 2>/dev/null | tr -d '\n' | cut -c1-140)"

step "5. nothing crashed and the client did not assert"
wolkara/tools/pilot.sh view > "$work/view.log" 2>&1
grep -q "no new crash report" "$work/view.log" && rc=0 || rc=1
check "$rc" "no new crash report for any launch above"
grep -q "no new error file" "$work/view.log" && rc=0 || rc=1
check "$rc" "no new game error file for any launch above"

cat <<'DEFERRED'

== deferred, and why

  background/foreground      needs a person tapping Home or locking the iPad; nothing on
                             this Mac can do it, and a simulator is not the same thing.
  audio before/after         needs someone to speak into the iPad, so the microphone is
                             really opened and the session really handed back.
  a controller button        mapping is arm-then-press: it needs a hand on a pad. What is
                             checked without one is that nothing fires while nothing is
                             mapped, and that no system signal can be mapped at all.
  the game itself            a live session touches the client's own store; the CASC and
                             in-game checks stay in COMPATIBILITY.md and are done by hand.
  a real add-on import       the extractor is the Swift/ZIPFoundation path the fixture
                             stands in for; it is exercised by importing an archive here.
DEFERRED

printf '\n'
if [ "$failures" -eq 0 ]; then
    echo "DEVICE MATRIX PASS: $checks checks"
    exit 0
fi
echo "DEVICE MATRIX FAIL: $failures of $checks checks failed"
exit 1
