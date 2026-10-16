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
log=$(mktemp)
# Written to a temporary file and moved into place at the end, so a run that is
# interrupted leaves no half-manifest that reads like evidence.
record=$(mktemp)
trap 'rm -f "$log" "$record" "$details"' EXIT

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
    sed -E "s/[0-9A-F]{8}-[0-9A-F]{16}/<device>/g" | {
        if [ -n "${DEVICE:-}" ]; then sed "s/${DEVICE}/<device>/g"; else cat; fi
    }
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
    step_bodies+=("$(tail -25 "$log" | scrub)")
    printf '   %s\n' "${step_results[${#step_results[@]}-1]}"
    return $rc
}

failures=0
run_step "layer gate (check_layers.sh)" wolkara/tools/check_layers.sh || failures=$((failures+1))
run_step "install does the right thing per execution mode" wolkara/tools/tests/test_after_install.sh || failures=$((failures+1))
run_step "pilot.sh fails closed and keeps its own session" wolkara/tools/tests/test_pilot.sh || failures=$((failures+1))
run_step "launcher pages (simulator fixture)" wolkara/tools/test_wow_launcher_ui.sh || failures=$((failures+1))
run_step "input, voice and config rules (simulator fixture)" wolkara/tools/test_voice.sh || failures=$((failures+1))
run_step "the app builds for the device" wolkara/tools/install.sh --build-only || failures=$((failures+1))
if [ "$full" = 1 ]; then
    run_step "platform emulation suite" wolkara/tools/test_emulation.sh || failures=$((failures+1))
    run_step "translation adapters (simulator)" wolkara/tools/test_translation_sim.sh || failures=$((failures+1))
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
