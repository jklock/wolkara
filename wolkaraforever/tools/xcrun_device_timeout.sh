#!/bin/bash
# Run CoreDevice operations with a bounded wait. A locked iPad can otherwise
# leave an installer stuck forever after it has put the app on a transient
# enrollment screen. Non-device Xcode tools are passed through untouched.
set -u

if [ "${1:-}" != "devicectl" ]; then
    exec /usr/bin/xcrun "$@"
fi

# CoreDevice file enumeration can legitimately take longer than a launch. Thirty
# seconds is bounded, but does not turn a slow connected device into a fake lock.
# The override is intentionally available to the script tests; production always
# defaults to the system xcrun.
limit=${WOLKAREFOREVER_DEVICE_TIMEOUT:-30}
real_xcrun=${WOLKAREFOREVER_REAL_XCRUN:-/usr/bin/xcrun}
"$real_xcrun" "$@" &
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
