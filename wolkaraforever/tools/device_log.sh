#!/bin/bash
# Read the app's own log from the iPad, without touching the running app.
#
# usage: wolkaraforever/tools/device_log.sh [lines] [pattern]
#
#   lines    how many of the newest matching lines to print (default 40)
#   pattern  an egrep pattern to filter on (default: everything)
#
# The host opens Documents/native-guest.log and hands it to the runtime as the guest's log
# (platform/launcher/App/main.m, ng_initialize). So that one file carries the host's own
# lines, the runtime's, and everything the guest application prints - which is why it is
# the file to read for a device run. Fetching it is a file copy, so this can be run as
# often as wanted while the app keeps running; it does not attach a console, which would
# restart the app and lose the guest's session.
set -eu
cd "$(dirname "$0")/../.." || exit 2

lines=${1:-40}
pattern=${2:-.}

device=${DEVICE:-}
if [ -z "$device" ]; then
    . wolkaraforever/tools/env.sh
    device=${DEVICE:-}
fi
bundle=${TOLKARA_BUNDLE_ID:-}
if [ -z "$bundle" ]; then
    . wolkaraforever/tools/env.sh
    bundle=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
fi
[ -n "$device" ] || { echo "device_log: set DEVICE in local.env (see local.env.example)" >&2; exit 2; }

logname=native-guest.log
out=build/device-log
rm -rf "$out"
mkdir -p "$out"
# The source is a single file, so the destination has to name a file too - devicectl
# refuses a directory there.
if ! xcrun devicectl device copy from --device "$device" \
        --domain-type appDataContainer --domain-identifier "$bundle" \
        --source "Documents/$logname" --destination "$out/$logname"; then
    echo "device_log: could not fetch Documents/$logname from $device (app $bundle)" >&2
    echo "device_log: the copy above says why - and note the file only exists once the" >&2
    echo "            guest has been started at least once" >&2
    exit 1
fi

log="$out/$logname"
[ -f "$log" ] || { echo "device_log: the copy did not produce $log" >&2; exit 1; }
echo "device_log: $log ($(wc -l < "$log" | tr -d ' ') lines)"
grep -E -- "$pattern" "$log" | tail -n "$lines"
