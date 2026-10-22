#!/bin/bash
# Prints the pid of a process running THIS bundle's installed executable.
#
# A device can hold more than one Tolkara build side by side: the pre-rename
# bundle (`local.wolkara.johnklock`) may be the one that carries the game, while
# a newer bundle is installed and running too. Stopping or replacing by the
# executable's name alone would target the wrong app - and refusing an install
# because a *different* Tolkara app is up is just as wrong.
#
# The bundle's current installation path comes from devicectl's app catalogue,
# so only a process whose executable sits in that container counts. When the
# catalogue cannot be read, the answer stays conservative and matches any
# Tolkara process: a guard must not report "nothing running" on a guess.
#
# usage: running_app.sh <device> <bundle-id>
# exit:   0 with a pid on stdout, or 0 with nothing when that bundle is not
#         installed or not running.
set -uo pipefail

device=${1:-}
bundle=${2:-}
[ -n "$device" ] && [ -n "$bundle" ] || { echo "usage: running_app.sh <device> <bundle-id>" >&2; exit 2; }

generic='Tolkara\.app/Tolkara([[:space:]]|$)'
pattern=$generic

catalogue=$(xcrun devicectl device info apps --device "$device" --json-output - 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ -n "$catalogue" ]; then
    url=$(printf '%s' "$catalogue" | python3 -c '
import json, sys
try:
    apps = json.load(sys.stdin)["result"]["apps"]
except Exception:
    sys.exit(3)
for app in apps:
    if app.get("bundleIdentifier") == sys.argv[1]:
        url = app.get("url") or ""
        if not url:
            sys.exit(4)          # installed, but the catalogue gave no path
        print(url)
        break
' "$bundle") && parse=0 || parse=$?
    if [ "$parse" -ne 0 ]; then
        # Includes "installed, but no path": never conclude "nothing running"
        # from a catalogue that did not answer the question.
        pattern=$generic
    elif [ -z "$url" ]; then
        # The catalogue was read and this bundle is not in it: this install has
        # nothing to replace, so nothing running belongs to it.
        exit 0
    else
        container=$(printf '%s' "$url" | sed -n 's|.*Bundle/Application/\([^/]*\)/.*|\1|p')
        [ -n "$container" ] && pattern="Bundle/Application/$container/Tolkara\.app/Tolkara([[:space:]]|$)"
    fi
fi

xcrun devicectl device info processes --device "$device" 2>/dev/null |
    grep -E "$pattern" | grep -v '\.appex' | awk 'NR==1 { print $1 }'
