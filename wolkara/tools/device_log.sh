#!/bin/bash
# Read the app's own log from the iPad, without touching the running app.
#
# usage: wolkara/tools/device_log.sh [lines] [pattern]
#
#   lines    how many of the newest matching lines to print (default 40)
#   pattern  an egrep pattern to filter on (default: everything)
#
# The app keeps everything - its own messages, the runtime's and the guest's - in
# Documents/wolkara.log inside its container (wolkara/Shell/main.m opens it as stderr at
# start). Fetching it is a file copy, so this can be run as often as wanted while the app
# keeps running: it is how a device run is watched, and how a failure is read afterwards
# without attaching a console, which would restart the app and lose the guest's session.
set -eu
cd "$(dirname "$0")/../.." || exit 2

lines=${1:-40}
pattern=${2:-.}

device=${DEVICE:-}
if [ -z "$device" ]; then
    . wolkara/tools/env.sh
    device=${DEVICE:-}
fi
bundle=${TOLKARA_BUNDLE_ID:-}
if [ -z "$bundle" ]; then
    . wolkara/tools/env.sh
    bundle=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
fi
[ -n "$device" ] || { echo "device_log: set DEVICE in local.env (see local.env.example)" >&2; exit 2; }

out=build/device-log
rm -rf "$out"
mkdir -p "$out"
# The source is a single file, so the destination has to name a file too - devicectl
# refuses a directory there.
if ! xcrun devicectl device copy from --device "$device" \
        --domain-type appDataContainer --domain-identifier "$bundle" \
        --source Documents/wolkara.log --destination "$out/wolkara.log" > /dev/null 2>&1; then
    echo "device_log: no log on the device yet - install the app once (wolkara/tools/install.sh),"
    echo "            then launch it, and the file appears"
    exit 1
fi

log="$out/wolkara.log"
[ -f "$log" ] || { echo "device_log: the copy did not produce $log" >&2; exit 1; }
echo "device_log: $log ($(wc -l < "$log" | tr -d ' ') lines)"
grep -E -- "$pattern" "$log" | tail -n "$lines"
