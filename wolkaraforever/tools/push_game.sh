#!/bin/bash
# Push a WoW Forever installation from this Mac into the app on the iPad, so the
# client does not have to be downloaded on the device.
#
# This is a thin wrapper, not a second installer. The supported copy lives in
# `profiles/wow-forever/install.py`, and it must run from the prepared tree
# (`build/platform`) because that copy can import the platform's `localenv`
# module. Running it from the repository root fails on that import. This script
# exists so the command works from the root, like every other tool here:
#
#     1. make sure `build/platform` exists (prepare it if needed),
#     2. load `local.env` (DEVICE, TOLKARA_BUNDLE_ID),
#     3. run the existing installer from the prepared tree with your arguments.
#
# usage: wolkaraforever/tools/push_game.sh [--prepare] [--dry-run] [install.py options]
#
#   --prepare            Re-export build/platform before copying (otherwise it
#                        is prepared only if missing).
#   --dry-run            Run the preflight with a size estimate; copy nothing.
#   --source <folder>    The Mac game folder (default /Applications/World of Warcraft).
#                        Any volume works, e.g. /Volumes/Storage/World of Warcraft.
#   --skip-data          Copy the client bundle only, not the large Data folder.
#   --device <UDID>      Override DEVICE for this run.
#   --retries <n>        Retry a dropped copy up to n times (default 3); verified
#                        files are reused, so a retry resumes rather than restarts.
#   -h, --help           Show this text.
#
# Before this works:
#   * the app must already be installed (`wolkaraforever/tools/install.sh`),
#   * DEVICE must be set (`wolkaraforever/tools/device_variables.sh --write`),
#   * the Mac game must exist at --source.
#
# The copy is one-way and skips unchanged files on later runs. It never modifies
# the Mac installation and never copies account credentials.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
root=$PWD

# Read the repository's ignored local.env so DEVICE and TOLKARA_BUNDLE_ID are
# available to the installer and to the checks below.
. wolkaraforever/tools/env.sh

prepare=0
dry_run=0
retries=3
source="/Applications/World of Warcraft"
passthrough=()
while [ $# -gt 0 ]; do
    case "$1" in
        --prepare) prepare=1;;
        --dry-run) dry_run=1;;
        --source) shift; source=${1:-}; passthrough+=("--source" "$1");;
        --retries) shift; retries=${1:-3};;
        -h|--help) sed -n '2,40p' "$0"; exit 0;;
        *) passthrough+=("$1");;
    esac
    shift
done

[ -n "${DEVICE:-}" ] || {
    printf '%s\n' "push_game: DEVICE is not set. Run: wolkaraforever/tools/device_variables.sh --write" >&2
    exit 2
}
[ -n "${TOLKARA_BUNDLE_ID:-}" ] || {
    printf '%s\n' "push_game: TOLKARA_BUNDLE_ID is not set in local.env." >&2
    exit 2
}

link=$(wolkaraforever/tools/device_variables.sh --json --device "$DEVICE" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("link",""))' 2>/dev/null || true)
if [ -n "$link" ]; then
    printf '%s\n' "push_game: device link: $link"
    [ "$link" = "Network" ] && printf '%s\n' "push_game: copying over the network; attach USB for a faster transfer"
fi

printf '%s\n' "push_game: checking the device before copying"
if [ -f "$source/_classic_beta_/World of Warcraft Beta.app/Contents/MacOS/World of Warcraft" ]; then
    printf '%s\n' "push_game: source is $(du -sh "$source" 2>/dev/null | awk '{print $1}') at $source"
fi
preflight_args=(--source "$source" --require-app)
[ "$dry_run" = 1 ] && preflight_args+=(--size)
if ! bash wolkaraforever/tools/preflight.sh "${preflight_args[@]}"; then
    printf '%s\n' "push_game: preflight failed; nothing was copied." >&2
    exit 1
fi
if [ "$dry_run" = 1 ]; then
    printf '%s\n' "push_game: dry run complete; nothing was copied."
    exit 0
fi

installer=build/platform/profiles/wow-forever/install.py
if [ "$prepare" = 1 ] || [ ! -f "$installer" ]; then
    printf '%s\n' "push_game: preparing build/platform (this is quick; no device is touched)"
    bash wolkaraforever/tools/prepare.sh || exit 1
fi

[ -f "$installer" ] || {
    printf '%s\n' "push_game: $installer is missing after prepare; run wolkaraforever/tools/prepare.sh and retry" >&2
    exit 1
}

printf '%s\n' "push_game: copying into the app for DEVICE=$DEVICE"
printf '%s\n' "push_game: (install the app first if it is not on the device yet)"
# Run exactly the supported installer, from the prepared tree, with the caller's
# options. --device is passed explicitly so the value from local.env is used even
# though the prepared tree has no local.env of its own.
cd build/platform || exit 1
# bash 3.2 treats an empty "${array[@]}" as unbound under `set -u`, so expand it
# only when it has elements. Retries are safe: devicectl skips unchanged files.
attempt=1
status=1
while [ "$attempt" -le "$retries" ]; do
    [ "$attempt" -gt 1 ] && printf '%s\n' "push_game: retry $attempt/$retries (verified files are reused)"
    if [ "${#passthrough[@]}" -gt 0 ]; then
        python3 profiles/wow-forever/install.py --device "$DEVICE" "${passthrough[@]}"
    else
        python3 profiles/wow-forever/install.py --device "$DEVICE"
    fi
    status=$?
    [ "$status" -eq 0 ] && break
    attempt=$((attempt + 1))
    [ "$attempt" -le "$retries" ] && sleep 5
done
exit "$status"
