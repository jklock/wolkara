#!/bin/bash
# Build and install the app on the configured iPad, doing every part of the procedure.
#
#   0. guard     refuse to install while the game is running
#   1. prepare   platform/ + patches + overlay -> build/platform
#   2. build     through the platform's own install script
#   3. enroll    the platform's own enroll.sh, which the install prints as its next step
#   4. verify    the app really is on the device afterwards
#   5. home      relaunch the normal Wolkara launcher and prove it reached home
#
# --build-only stops after step 2 and leaves the iPad alone, so a compile error costs
# nothing: without it, the app has already been stopped by the time the compiler speaks.
#
# Why step 0 exists, in full: on 2026-10-15 this script - with no guard - was run while the
# game was live. Replacing the app underneath a running client left its CASC index update
# slot occupied. The next launch then aborted with
#     BC_ASSERT(targetUpdateSlot.hash == 0)
# and that aborted commit left an index generation the client then refused, so every launch
# afterwards failed with
#     BC_ASSERT(!m_exists)
# A working install had become a wedged game, and the game needed its own rebuild-and-verify
# to recover. It will not happen again: the install stops unless the game is gone.
# --replace-running asks it to stop and waits; it does not escalate to SIGKILL on its own,
# because a client killed mid-write is the other half of that same accident. --force-kill
# is the explicit opt-in for the escalation, and says so when it is used.
#
# Settings come from the repository root's ignored local.env. Installing replaces the app
# under the same bundle ID and keeps the device's data.
set -euo pipefail
cd "$(dirname "$0")/../.."
. wolkara/tools/env.sh

replace_running=0
force_kill=0
build_only=0
args=()
for arg in "$@"; do
    case "$arg" in
        --replace-running) replace_running=1;;
        --force-kill) replace_running=1; force_kill=1;;
        --build-only) build_only=1;;
        *) args+=("$arg");;
    esac
done

step() { printf '\n== %s\n' "$*"; }
total=5
[ "$build_only" = 1 ] && total=2
bundle=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
cleanup_needed=0

# Once an install attempt may have started the app, the only acceptable exit
# state is a plain Wolkara launcher. This trap intentionally does not use any
# app-container query: CoreDevice can hang on enumeration while a direct launch
# remains healthy, as Dadpad demonstrated on 2026-10-19.
finalize_launcher() {
    [ "$cleanup_needed" = 1 ] || return 0
    echo "install: recovering the normal launcher after an incomplete install" >&2
    if ! xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$bundle"; then
        echo "install: recovery launch failed; Device Hub must be checked before retrying." >&2
        return 1
    fi
    echo "install: recovery launched the normal Wolkara launcher" >&2
}

finish_install() {
    local rc=$?
    trap - EXIT
    if [ "$build_only" != 1 ]; then
        finalize_launcher || rc=1
    fi
    exit "$rc"
}
trap finish_install EXIT

# The main app binary, not its extensions: the path of an extension is
# .../Tolkara.app/PlugIns/<Name>.appex/<Name>, which does not contain Tolkara.app/Tolkara.
app_pid() {
    # grep -E, not sed: BSD sed has no \| alternation, and a pattern that silently matches
    # nothing would report "nothing running" for a live game - the case this guard is for.
    xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null |
        grep -E "Tolkara\.app/Tolkara([[:space:]]|$)" | grep -v "\.appex" | awk 'NR==1 { print $1 }'
}

if [ "$build_only" = 1 ]; then
    step "0/$total guard: skipped (build only - the device is not involved)"
else
    step "0/$total guard: is the game running?"
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
        # SIGTERM only. This app does not act on it - measured: the process survived SIGTERM
        # and 30 s - so the escalation is what usually finishes the job; but it is the
        # escalation that can catch a client mid-write, so it is the user's call, not this
        # script's.
        xcrun devicectl device process signal --device "$DEVICE" --pid "$pid" --signal SIGTERM >/dev/null 2>&1 || true
        xcrun devicectl device process awaitTermination --device "$DEVICE" --pid "$pid" --timeout 30 >/dev/null 2>&1 || true
        if [ -n "$(app_pid || true)" ] && [ "$force_kill" != 1 ]; then
            cat >&2 <<MESSAGE
install: the app is still running after SIGTERM and 30 s.
         A client can take a while to finish writing; wait a moment and run this again, or
         pass --force-kill to kill it now. Killing it mid-write is what left an index slot
         occupied on 2026-10-15, so it is not done for you.
MESSAGE
            exit 2
        fi
        if [ -n "$(app_pid || true)" ]; then
            echo "   still running, and --force-kill was given: killing it"
            xcrun devicectl device process signal --device "$DEVICE" --pid "$pid" --signal SIGKILL >/dev/null 2>&1 || true
            xcrun devicectl device process awaitTermination --device "$DEVICE" --pid "$pid" --timeout 20 >/dev/null 2>&1 || true
        fi
        if [ -n "$(app_pid || true)" ]; then
            echo "install: the game would not stop; close it on the iPad and try again" >&2
            exit 2
        fi
        echo "   the game has exited"
    else
        echo "   nothing running"
    fi
fi

step "1/$total prepare build/platform"
wolkara/tools/prepare.sh

cd build/platform

# The platform installer and enrollment helper invoke xcrun themselves. Put a
# bounded devicectl shim in front of them so a locked iPad cannot strand the app
# on an enrollment status screen indefinitely. Xcode and every non-device
# command still execute through the real xcrun unchanged.
if [ "$build_only" != 1 ]; then
    device_shim=$(mktemp -d -t wolkara-device-timeout)
    ln -s "$ROOT/wolkara/tools/xcrun_device_timeout.sh" "$device_shim/xcrun"
    PATH="$device_shim:$PATH"
    export PATH
fi

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

# The platform has no build-without-install script, so in build-only mode its own script
# runs unchanged with `xcrun devicectl` made a no-op. The generate step, the flags and the
# log stay exactly the platform's; only the step that touches the iPad is skipped. The
# shim passes every other xcrun through untouched.
if [ "$build_only" = 1 ]; then
    shim=$(mktemp -d -t wolkara-build-only)
    cat > "$shim/xcrun" <<'SHIM'
#!/bin/bash
for word in "$@"; do
    if [ "$word" = "devicectl" ]; then
        # The device identifier is not printed. This line ends up in build logs and in
        # the validation record, and that record is committed - see AGENTS.md. The
        # subcommand is enough to see what was skipped.
        echo "   build only: not touching the device (xcrun $1 $2 $3 …)"
        exit 0
    fi
done
exec /usr/bin/xcrun "$@"
SHIM
    chmod +x "$shim/xcrun"
    PATH="$shim:$PATH"
    export PATH
fi

step "2/$total build (the platform's own script)"
# From this point the platform installer may deploy and launch a development
# process even when its own command later fails. The EXIT trap owns restoring
# the visible app state in both the success and failure paths.
[ "$build_only" = 1 ] || cleanup_needed=1
tools/install.sh ${args[@]+"${args[@]}"}

if [ "$build_only" = 1 ]; then
    step "2/$total done: built, and the device was left alone"
    cat <<NEXT
   install it       wolkara/tools/pilot.sh install
   the log          build/platform/logs/install-*.log
NEXT
    exit 0
fi

# What happens after the install depends on the execution mode. Enrolling is
# developer-service work and is wrong for the other two modes, so the decision lives in
# one small script that a test can drive with stubs in front of it. See
# wolkara/tools/after_install.sh.
step "3/5 after the install (mode: ${TOLKARA_MODE:-none})"
# $ROOT, from env.sh: this script has already cd'd into the prepared tree, so a relative
# path would look for the layer inside build/platform.
"$ROOT/wolkara/tools/after_install.sh" "${TOLKARA_MODE:-}"

step "4/5 verify the app on the device"
installed=$(xcrun devicectl device info apps --device "$DEVICE" 2>/dev/null | grep -i "$bundle" || true)
if [ -n "$installed" ]; then
    echo "   installed: $installed"
else
    echo "   NOT INSTALLED: the device does not list $bundle" >&2
    exit 1
fi

step "5/5 return the normal launcher"
# Enrollment deliberately uses development arguments and therefore displays a
# status screen. It is never an acceptable final state for an install. This
# launch replaces only that temporary process: the live-game guard ran before
# the install, and a failure here is reported as a failed install rather than a
# misleading successful install with a broken-looking iPad.
if ! xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$bundle"; then
    echo "install: the app was installed but could not be returned to its normal launcher." >&2
    echo "         Unlock the iPad, then run: wolkara/tools/pilot.sh launch" >&2
    exit 1
fi
echo "   plain Wolkara launcher launched"
cleanup_needed=0

step "5/5 done"
cat <<NEXT
   pilot it         wolkara/tools/pilot.sh cycle
                    state, stop, install, launch, wait for a verdict, screenshot
   watch the guest  wolkara/tools/device_log.sh      # Documents/native-guest.log
   judge a launch   a NEW file in Documents/World of Warcraft/_classic_beta_/Errors/
                    means the client asserted; no new file means it did not
NEXT
