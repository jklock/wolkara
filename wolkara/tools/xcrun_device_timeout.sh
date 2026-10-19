#!/bin/bash
# Run CoreDevice operations with a bounded wait. A locked iPad can otherwise
# leave an installer stuck forever after it has put the app on a transient
# enrollment screen. Non-device Xcode tools are passed through untouched.
set -u

if [ "${1:-}" != "devicectl" ]; then
    exec /usr/bin/xcrun "$@"
fi

limit=${WOLKARA_DEVICE_TIMEOUT:-8}
/usr/bin/xcrun "$@" &
child=$!
waited=0
while kill -0 "$child" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
        kill "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
        echo "install: devicectl did not answer within ${limit}s (check Device Hub, cable, and iPad state)" >&2
        exit 124
    fi
    sleep 1
    waited=$((waited + 1))
done
wait "$child"
