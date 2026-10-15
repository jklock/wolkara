#!/bin/bash
# Build and install the app on the configured iPad, doing every part of the procedure.
#
#   0. guard     refuse to install while the game is running
#   1. prepare   platform/ + patches + overlay -> build/platform
#   2. build     through the platform's own install script
#   3. enroll    the platform's own enroll.sh, which the install prints as its next step
#   4. verify    the app really is on the device afterwards
#
# Why step 0 exists, in full: on 2026-10-15 this script - with no guard - was run while the
# game was live. Replacing the app underneath a running client left its CASC index update
# slot occupied. The next launch then aborted with
#     BC_ASSERT(targetUpdateSlot.hash == 0)
# and that aborted commit left an index generation the client then refused, so every launch
# afterwards failed with
#     BC_ASSERT(!m_exists)
# A working install had become a wedged game, and the game needed its own rebuild-and-verify
# to recover. It will not happen again: the install stops unless the game is gone, and
# --replace-running stops it cleanly first (SIGTERM, then wait) so the client can close its
# store before the app is replaced.
#
# Settings come from the repository root's ignored local.env. Installing replaces the app
# under the same bundle ID and keeps the device's data.
set -euo pipefail
cd "$(dirname "$0")/../.."
. wolkara/tools/env.sh

replace_running=0
args=()
for arg in "$@"; do
    case "$arg" in
        --replace-running) replace_running=1;;
        *) args+=("$arg");;
    esac
done

step() { printf '\n== %s\n' "$*"; }
bundle=${TOLKARA_BUNDLE_ID:-local.tolkara.app}

# The main app binary, not its extensions: the path of an extension is
# .../Tolkara.app/PlugIns/<Name>.appex/<Name>, which does not contain Tolkara.app/Tolkara.
app_pid() {
    # grep -E, not sed: BSD sed has no \| alternation, and a pattern that silently matches
    # nothing would report "nothing running" for a live game - the case this guard is for.
    xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null |
        grep -E "Tolkara\.app/Tolkara([[:space:]]|$)" | grep -v "\.appex" | awk 'NR==1 { print $1 }'
}

step "0/5 guard: is the game running?"
pid=$(app_pid || true)
if [ -n "${pid:-}" ]; then
    if [ "$replace_running" != 1 ]; then
        cat >&2 <<MESSAGE
install: THE GAME IS RUNNING (pid $pid). Installing now would replace the app underneath
         the live client, which is what corrupted its CASC index on 2026-10-15.
         Quit the game on the iPad, or run this again with --replace-running to stop it
         cleanly first.
MESSAGE
        exit 2
    fi
    echo "   the game is running (pid $pid): stopping it before anything is replaced"
    # SIGTERM first, to give the client the chance to close its stores itself. This app
    # does not act on it - measured: the process survived SIGTERM and 30 s - so SIGKILL
    # follows. Either way the app is gone before the install, which is the point: the
    # 2026-10-15 damage came from replacing the app underneath a client that was still
    # running, not from stopping it first.
    for sig in SIGTERM SIGKILL; do
        xcrun devicectl device process signal --device "$DEVICE" --pid "$pid" --signal "$sig" >/dev/null 2>&1 || true
        xcrun devicectl device process awaitTermination --device "$DEVICE" --pid "$pid" --timeout 20 >/dev/null 2>&1 || true
        [ -z "$(app_pid || true)" ] && break
        echo "   it survived $sig"
    done
    if [ -n "$(app_pid || true)" ]; then
        echo "install: the game would not stop; close it on the iPad and try again" >&2
        exit 2
    fi
    echo "   the game has exited"
else
    echo "   nothing running"
fi

step "1/5 prepare build/platform"
wolkara/tools/prepare.sh

cd build/platform

# The platform's script asks xcodebuild for `-derivedDataPath build/device` and installs
# from `build/device/Build/Products/...`. A machine-wide Xcode build location overrides
# that - this Mac has IDEBuildLocationStyle = Custom with
# IDECustomDerivedDataLocation = /Volumes/Storage/XCode - so the build succeeds and the
# install finds nothing. An xcconfig handed over through XCODE_XCCONFIG_FILE pins the
# layout the platform's script expects, without touching that script. Absolute paths, not
# $(SRCROOT): the Swift package is a project of its own, and a relative path resolves
# differently inside it, leaving its products where the app's compiler cannot find them.
location=$(mktemp -t wolkara-location)
cat > "$location" <<XCCONFIG
SYMROOT = $PWD/build/device/Build/Products
OBJROOT = $PWD/build/device/Build/Intermediates.noindex
XCCONFIG
export XCODE_XCCONFIG_FILE="$location"

step "2/5 build and install (the platform's own script)"
tools/install.sh ${args[@]+"${args[@]}"}

step "3/5 enroll the developer service (the platform's next step)"
# Idempotent: with a valid pin it verifies and refuses to replace it, which is a success,
# so the output decides rather than the exit code alone.
enroll_out=$(tools/enroll.sh 2>&1) && enroll_rc=0 || enroll_rc=$?
printf '%s\n' "$enroll_out"
if [ "${enroll_rc:-0}" -ne 0 ] &&
   ! printf '%s' "$enroll_out" | grep -q "no existing trust pin was replaced"; then
    echo "   enrollment failed (exit $enroll_rc): the app is installed, but the developer" >&2
    echo "   service cannot prepare memory until this succeeds" >&2
    exit 1
fi

step "4/5 verify the app on the device"
installed=$(xcrun devicectl device info apps --device "$DEVICE" 2>/dev/null | grep -i "$bundle" || true)
if [ -n "$installed" ]; then
    echo "   installed: $installed"
else
    echo "   NOT INSTALLED: the device does not list $bundle" >&2
    exit 1
fi

step "5/5 done"
cat <<NEXT
   launch it        xcrun devicectl device process launch --device $DEVICE \
                        --terminate-existing $bundle --local-game-startup
   watch the guest  wolkara/tools/device_log.sh      # Documents/native-guest.log
   judge a launch   a NEW file in Documents/World of Warcraft/_classic_beta_/Errors/
                    means the client asserted; no new file means it did not
NEXT
