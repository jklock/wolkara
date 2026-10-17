#!/bin/bash
# Test the actual classifier with completed, incomplete and mixed failure logs.
set -euo pipefail
cd "$(dirname "$0")/../../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
log=$work/log
known_failures=$work/known
printf '%s\n' tests.known.Case.test_expected > "$known_failures"
scrub() { cat; }
declare -a step_names=() step_results=() step_bodies=()
eval "$(sed -n '/^run_platform_suite() {/,/^}/p' wolkara/tools/validate.sh)"
fixture() { printf '%s\n' "$1"; return "$2"; }
check() {
    local expected=$1 status=$2 output=$3 got=0
    run_platform_suite fixture fixture "$output" "$status" > "$work/output" || got=1
    if [ "$got" != "$expected" ]; then cat "$work/output"; echo 'FAIL validation classification'; exit 1; fi
}
known='FAIL: test_expected (tests.known.Case.test_expected)'
check 0 0 'all passed'
check 0 1 "$known
PLATFORM_EMULATION_COMPLETE"
check 1 1 "$known"
check 1 134 "$known
PLATFORM_EMULATION_COMPLETE"
check 1 1 "$known
FAIL: test_other (tests.other.Case.test_other)
PLATFORM_EMULATION_COMPLETE"
check 1 1 'unknown failure without unittest output'
echo 'VALIDATION CLASSIFIER PASS: 6 checks'
