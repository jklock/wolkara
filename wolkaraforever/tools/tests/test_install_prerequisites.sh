#!/bin/bash
# Test install_prerequisites.sh's interface and syntax. It deliberately does not
# run the installer: the machine's real state is not a fixture.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
script="$repo/wolkaraforever/tools/install_prerequisites.sh"

pass=0; fail=0
check() { if [ "$1" = 0 ]; then pass=$((pass+1)); printf 'PASS  %s\n' "$2"; else fail=$((fail+1)); printf 'FAIL  %s\n' "$2"; fi; }

bash -n "$script"; check $? "script parses (bash -n)"

out=$("$script" --help 2>&1); rc=$?
[ "$rc" -eq 0 ]; check $? "--help exits 0"
printf '%s' "$out" | grep -q "usage:"; check $? "--help prints usage"

"$script" --not-an-option >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check $? "unknown option is refused"

# The report-only mode must never install anything, so it may be run anywhere.
out=$("$script" --check 2>&1); rc=$?
printf '%s' "$out" | grep -q "WolkaraForever Mac prerequisites"; check $? "--check prints its report"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
