#!/bin/bash
# Prove what was tested, and against exactly which commit.
#
# The audit's finding: development/VALIDATION.md was tied to an older commit than the
# work it claimed to cover, and prepare.sh exports HEAD:platform while apply.sh copies
# overlay sources from the working tree - so a dirty checkout can build uncommitted code
# while the evidence names a commit. Evidence that names a commit it did not test is
# worse than no evidence.
#
# So this runs the suites, and writes one file per commit under development/validation/,
# containing the commit, whether the tree was clean, the host and Xcode, each command
# with its exit status, and the tail of what it printed. It refuses to run on a dirty
# worktree unless told to, and says so in the file when it is.
#
#   wolkara/tools/validate.sh [--allow-dirty] [--full] [--device] [--out <path>]
#
#   --full    also run the platform suites (test_emulation.sh, test_translation_sim.sh),
#             which are the slow ones
#   --device  also install and pilot on the connected iPad, and record what came back
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
root=$PWD
. wolkara/tools/env.sh

allow_dirty=0
full=0
device=0
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-dirty) allow_dirty=1;;
        --full) full=1;;
        --device) device=1;;
        --out) shift; out=${1:-};;
        *) echo "unknown option: $1" >&2; exit 2;;
    esac
    shift
done

sha=$(git rev-parse HEAD)
short=$(git rev-parse --short HEAD)
branch=$(git rev-parse --abbrev-ref HEAD)
# The validation record itself is not part of what is being validated, and this run is
# about to write one. Without this the file this script produces would make the tree
# dirty *during* the run, and the build it then ran would say so.
dirty=$(git status --porcelain -- . ':!development/validation')
# A dirty run is named for when it happened, not only for the commit: it is evidence
# about the working tree as much as about the commit, and the two must not be confused
# when someone reads the directory listing.
if [ -z "$out" ]; then
    if [ -n "$dirty" ]; then
        out="development/validation/$short-dirty-$(date -u '+%Y%m%dT%H%M%SZ').md"
    else
        out="development/validation/$short.md"
    fi
fi

if [ -n "$dirty" ] && [ "$allow_dirty" != 1 ]; then
    cat >&2 <<MESSAGE
validate: the working tree is dirty, so anything built now would not be the commit this
          file would name. Commit the work, or run with --allow-dirty and have the
          dirty files recorded as part of the evidence.
MESSAGE
    printf '%s\n' "$dirty" | sed 's/^/          /' >&2
    exit 2
fi

mkdir -p "$(dirname "$out")"
# One pilot session for the whole run. The pilot keeps its work files per run, and a run is
# this script - not each of the commands below. Without this, `pilot.sh cycle` recorded a
# baseline in one directory and `pilot.sh log` looked in another, so the log step could not
# tell a fresh launch from a stale log.
export PILOT_SESSION=${PILOT_SESSION:-$(mktemp -d -t pilot-validation)}
log=$(mktemp)
# Written to a temporary file and moved into place at the end, so a run that is
# interrupted leaves no half-manifest that reads like evidence.
record=$(mktemp)
trap 'rm -f "$log" "$record" "$details" "$known_failures"; rm -rf "$PILOT_SESSION"' EXIT

# What the iPad is, in words that can be committed. `devicectl`'s own summary carries
# the model identifier and the OS version, and the device's UDID as well - which is the
# one part that must not end up in a file in the repository.
details=$(mktemp)
device_description() {
    xcrun devicectl device info details --device "$DEVICE" > "$details" 2>/dev/null || true
    local model os
    model=$(sed -n 's/.*[Mm]odel[^:]*: *//p' "$details" | head -1 | cut -c1-60)
    os=$(sed -n 's/.*OS [Vv]ersion[^:]*: *//p' "$details" | head -1 | cut -c1-40)
    [ -n "$model" ] || model="an iPad"
    [ -n "$os" ] || os="OS unknown"
    printf '%s, %s' "$model" "$os"
}

{
    echo "# Validation: $short"
    echo
    echo "- Commit: \`$sha\` (branch \`$branch\`)"
    echo "- Recorded: $(date -u '+%Y-%m-%d %H:%M:%SZ')"
    if [ -n "$dirty" ]; then
        echo "- **Working tree: dirty** - the results below are not this commit alone:"
        echo
        echo '```'
        printf '%s\n' "$dirty"
        echo '```'
    else
        echo "- Working tree: clean"
    fi
    echo "- Host: $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
    echo "- Xcode: $(xcodebuild -version 2>/dev/null | head -1)"
    if [ "$device" = 1 ]; then
        # The model and the OS, never the device identifier: this file is meant to be
        # committed, and an identifier does not belong in a commit. See AGENTS.md.
        echo "- Device: $(device_description)"
    fi
    echo
    echo "## Results"
    echo
    echo "| Step | Result |"
    echo "| --- | --- |"
} > "$record"

# Anything a step printed goes through this before it reaches the record. The commands
# themselves can print the device they were given - `install.sh --build-only` prints the
# `devicectl` line it would have run, device identifier and all - and this file is meant
# to be committed. AGENTS.md is explicit that device identifiers stay out of commits.
scrub() {
    python3 -c '
import os, re, sys
text = sys.stdin.read()
for key in ("DEVICE", "DEVELOPMENT_TEAM", "SIGN_IDENTITY"):
    value = os.environ.get(key)
    if value:
        text = text.replace(value, "<redacted-" + key.lower() + ">")
text = re.sub(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}", "<device>", text)
text = re.sub(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", "<identifier>", text)
sys.stdout.write(text)
'
}

# Each step is a command line and a name; the exit status decides the result, and the
# tail of the output is kept so a failure can be read without re-running it.
declare -a step_names=()
declare -a step_results=()
declare -a step_bodies=()

run_step() {
    local name=$1; shift
    printf '\n== %s\n' "$name"
    : > "$log"
    "$@" >> "$log" 2>&1
    local rc=$?
    step_names+=("$name")
    if [ $rc -eq 0 ]; then step_results+=("PASS"); else step_results+=("FAIL (exit $rc)"); fi
    step_bodies+=("$( { printf 'Command: %s\n' "$*"; tail -25 "$log"; } | scrub)")
    printf '   %s\n' "${step_results[${#step_results[@]}-1]}"
    return $rc
}

# A platform suite, judged against the list of failures that are the platform's own.
#
#   run_platform_suite <name> <command...>
#
# The suite prints its failures in unittest's form, and the list at
# wolkara/tools/known_platform_failures.txt says which of them are not the layer's doing.
# Everything else still fails the run.
known_failures=$(mktemp)
# A line is a test id, optionally commented out, then a dash and the reason. Commented
# entries count: this list is meant to be readable as a document, and the first version of
# it had the only real entry behind a `#`, so nothing matched and the platform's known
# failure read as ours.
sed -E 's/^[[:space:]]*#?[[:space:]]*//; s/[[:space:]]+(-|—).*$//' wolkara/tools/known_platform_failures.txt \
    | grep -E '^[a-zA-Z_][a-zA-Z0-9_.]*$' | sort -u > "$known_failures"
run_platform_suite() {
    local name=$1; shift
    printf '\n== %s\n' "$name"
    : > "$log"
    "$@" >> "$log" 2>&1
    local rc=$?
    local mine=0 theirs=0
    local line id
    while IFS= read -r line; do
        case "$line" in
        *"FAIL: "*|*"ERROR: "*)
            id=$(printf '%s' "$line" | sed -E 's/.*(FAIL|ERROR): [^(]*\(([^)]*)\).*/\2/')
            if [ -n "$id" ] && grep -qxF "$id" "$known_failures"; then
                theirs=$((theirs + 1))
            else
                mine=$((mine + 1))
                printf '  %s\n' "$line"
            fi
            ;;
        esac
    done < <(grep -E "^(FAIL|ERROR): " "$log")
    step_names+=("$name")
    if [ "$rc" -eq 0 ]; then
        step_results+=("PASS")
    elif [ "$rc" -eq 1 ] && [ "$mine" -eq 0 ] && [ "$theirs" -gt 0 ] &&
         grep -qx PLATFORM_EMULATION_COMPLETE "$log"; then
        # Only known platform failures: say so, name them, and do not hide them.
        step_results+=("PASS ($theirs known platform failure(s))")
    else
        step_results+=("FAIL (exit $rc, $mine failure(s) not known to be the platform's)")
    fi
    step_bodies+=("$( { printf 'Command: %s\n' "$*"; printf '%s\n' "known platform failures in this run: $theirs"; \
        [ "$theirs" -gt 0 ] && sed -E 's/^([[:space:]]*#?[[:space:]]*)/  \1/' wolkara/tools/known_platform_failures.txt | grep -E "^  [a-zA-Z_]"; \
        [ "$mine" -gt 0 ] && echo "failures that are not on that list:" && grep -E "^(FAIL|ERROR): " "$log"; \
        tail -18 "$log"; } 2>/dev/null | scrub)")
    printf '   %s\n' "${step_results[${#step_results[@]}-1]}"
    if [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && [ "$mine" -eq 0 ] && [ "$theirs" -gt 0 ] &&
         grep -qx PLATFORM_EMULATION_COMPLETE "$log"; }; then return 0; fi
    return 1
}

failures=0
run_step "layer gate (check_layers.sh)" wolkara/tools/check_layers.sh || failures=$((failures+1))
run_step "validation distinguishes known failures from incomplete suites" wolkara/tools/tests/test_validate.sh || failures=$((failures+1))
run_step "install does the right thing per execution mode" wolkara/tools/tests/test_after_install.sh || failures=$((failures+1))
run_step "pilot.sh fails closed and keeps its own session" wolkara/tools/tests/test_pilot.sh || failures=$((failures+1))
run_step "launcher pages (simulator fixture)" wolkara/tools/test_wow_launcher_ui.sh || failures=$((failures+1))
run_step "input, voice and config rules (simulator fixture)" wolkara/tools/test_voice.sh || failures=$((failures+1))
# The two touch fixtures are ours and nothing ran them: not this script, and not either
# platform suite. That is how a fixture asserting whole-field replacement sat failing for a
# day while every recorded run said PASS - the assertions were about behaviour the adapter
# had stopped having, and no step asked. They are bounded (a 30 s watchdog in self-test
# mode), so they belong here.
run_step "on-screen controls and the game text field (simulator fixture)" wolkara/tools/test_touch_controls_ui.sh --self-test || failures=$((failures+1))
run_step "the on-screen gamepad (simulator fixture)" wolkara/tools/test_touch_gamepad_ui.sh --self-test || failures=$((failures+1))
# And these two were run by nothing either, for the same kind of reason: they were only ever
# reached through the loop at the end of test_emulation.sh, and that loop never ran, because
# the platform's suite exits 1 on its one known failure and `set -e` stopped the script
# there. One of them is the only test of a patch we carry. Every suite the layer owns now
# has a row of its own, so coverage does not depend on a wrapper's loop being reached.
run_step "local service retry (patch 0006)" wolkara/tools/test_local_service_retry.sh || failures=$((failures+1))
run_step "CurseForge response and request contracts" wolkara/tools/test_curseforge.sh || failures=$((failures+1))
run_step "real ZIP extraction (Swift and pinned ZIPFoundation)" wolkara/tools/test_addon_archive.sh || failures=$((failures+1))
run_step "the app icon's assets and catalog" wolkara/tools/test_icon_assets.sh || failures=$((failures+1))
run_step "game file verification and repair (CASC)" wolkara/tools/test_wow_launcher.sh || failures=$((failures+1))
run_step "the app builds for the device" wolkara/tools/install.sh --build-only || failures=$((failures+1))
if [ "$full" = 1 ]; then
    # The platform's suites, with its known failures told apart from ours. A failure the
    # layer causes must fail the run; a failure that reproduces in a pristine checkout of
    # the platform must not, and must still be printed every time so it stays visible.
    # Layer suites already have explicit rows; the wrapper would run them again and
    # could misclassify a layer failure alongside the known platform failure.
    run_platform_suite "platform emulation suite" bash build/platform/tools/test_emulation.sh || failures=$((failures+1))
    run_platform_suite "translation adapters (simulator)" wolkara/tools/test_translation_sim.sh || failures=$((failures+1))
else
    step_names+=("platform emulation suite (--full)")
    step_results+=("NOT RUN")
    step_bodies+=("Not run: the sanitizer suite takes minutes. Pass --full to include it.")
    step_names+=("translation adapters (--full)")
    step_results+=("NOT RUN")
    step_bodies+=("Not run. Pass --full to include it.")
fi
if [ "$device" = 1 ]; then
    # A failed install means anything read afterwards is from a *different* build. The
    # first version ran the log step anyway and recorded a stale log as PASS, which is
    # worse than recording nothing: it is evidence for a commit that never ran.
    if run_step "install and launch on the iPad" wolkara/tools/pilot.sh cycle; then
        run_step "the app's own log, from the launch above" wolkara/tools/pilot.sh log 40 || failures=$((failures+1))
        # The parts of the device matrix a Mac can drive by itself. What needs a person is
        # listed inside the step's own output rather than left unsaid.
        run_step "the device matrix, so far as a script can go" wolkara/tools/device_matrix.sh || failures=$((failures+1))
    else
        failures=$((failures+1))
        step_names+=("the app's own log, from the launch above")
        step_results+=("NOT RUN")
        step_bodies+=("Not run: the install or launch above failed, so a log read now would be written by an older build. Nothing here is evidence about this commit.")
    fi
else
    step_names+=("device run (--device)")
    step_results+=("NOT RUN")
    step_bodies+=("Not run: pass --device with an iPad connected.")
fi

{
    for index in "${!step_names[@]}"; do
        printf '| %s | %s |\n' "${step_names[$index]}" "${step_results[$index]}"
    done
    echo
    echo "## What each step printed"
    for index in "${!step_names[@]}"; do
        echo
        echo "### ${step_names[$index]} - ${step_results[$index]}"
        echo
        echo '```'
        printf '%s\n' "${step_bodies[$index]}"
        echo '```'
    done
    echo
    echo "## Read this as"
    echo
    if [ "$failures" -eq 0 ]; then
        echo "Every step that ran passed, on the commit named above."
    else
        echo "**$failures step(s) failed.** The failures are above, with what they printed."
    fi
    echo
    echo "A step marked NOT RUN is not evidence. Anything the audit asked for that is not"
    echo "listed as PASS here has not been shown for this commit."
} >> "$record"

mv "$record" "$out"
echo
echo "validation: $out"
[ "$failures" -eq 0 ] || exit 1
