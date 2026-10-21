#!/bin/bash
# Launch the app on the iPad, checking the live state first and never killing a session.
#
# usage: wolkaraforever/tools/launch.sh [--restart] [extra launch arguments...]
#
# Why this exists: on 2026-10-15 a launch command carrying --terminate-existing was run
# while a session was live, and it killed it. Nobody should have to remember that. The
# check is made here, every time, against the device as it is right now:
#
#   * nothing running      -> launch
#   * a session is running -> refuse, and say so. --restart stops it cleanly first
#                             (SIGTERM, then wait) so the client can close its stores.
#
# It also prints what to compare afterwards to judge the run, because a single launch
# proves nothing: on that day one launch came back clean and the next one asserted.
set -euo pipefail
cd "$(dirname "$0")/../.."
. wolkaraforever/tools/env.sh

restart=0
args=()
for arg in "$@"; do
    case "$arg" in
        --restart) restart=1;;
        *) args+=("$arg");;
    esac
done
[ ${#args[@]} -eq 0 ] && args=(--local-game-startup)

bundle=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
errors_dir="Documents/World of Warcraft/_classic_beta_/Errors"

# The main app binary, deliberately not its extensions: an extension lives at
# .../Tolkara.app/PlugIns/<Name>.appex/<Name>, which is not the app.
app_pid() {
    xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null |
        grep -E "Tolkara\.app/Tolkara([[:space:]]|$)" | grep -v "\.appex" | awk 'NR==1 { print $1 }'
}

pid=$(app_pid || true)
if [ -n "${pid:-}" ]; then
    if [ "$restart" != 1 ]; then
        cat >&2 <<MESSAGE
launch: THE APP IS ALREADY RUNNING (pid $pid). Not launching, and not killing it.
        Use --restart to stop it cleanly first, or just use the app on the iPad.
MESSAGE
        exit 2
    fi
    echo "== stopping the running app (pid $pid)"
    # SIGTERM first so the client can close its own stores; this app does not act on it,
    # so SIGKILL follows.
    for sig in SIGTERM SIGKILL; do
        xcrun devicectl device process signal --device "$DEVICE" --pid "$pid" --signal "$sig" >/dev/null 2>&1 || true
        xcrun devicectl device process awaitTermination --device "$DEVICE" --pid "$pid" --timeout 20 >/dev/null 2>&1 || true
        [ -z "$(app_pid || true)" ] && break
        echo "   it survived $sig"
    done
    [ -z "$(app_pid || true)" ] || { echo "launch: it would not stop; nothing was launched" >&2; exit 2; }
    echo "   it has exited"
fi

# The baseline for judging the run: the newest error file before this launch.
rm -rf build/launch-baseline
mkdir -p build/launch-baseline
xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$bundle" \
    --source "$errors_dir" --destination build/launch-baseline >/dev/null 2>&1 || true
before=$(ls -t build/launch-baseline/*.txt 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null || true)
echo "== launching (baseline error file: ${before:-none})"
xcrun devicectl device process launch --device "$DEVICE" "$bundle" ${args[@]+"${args[@]}"}

cat <<NEXT

Judging this run, once the game has had time to start (about 90-100 s):
  wolkaraforever/tools/device_log.sh            # the guest's and runtime's own log
  and check for a NEW file in Documents/World of Warcraft/_classic_beta_/Errors/:
    a new file            -> the client asserted; this launch failed
    no new file           -> this launch did not assert
  One clean launch is not proof. Compare several.
NEXT
