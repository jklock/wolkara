#!/bin/bash
# The device wrapper is part of the install safety boundary. Exercise the two
# outcomes without a device: prompt exit propagation and a bounded hung call.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
wrapper="$root/wolkaraforever/tools/xcrun_device_timeout.sh"
work=$(mktemp -d -t wolkaraforever-xcrun-timeout)
trap 'rm -rf "$work"' EXIT

cat > "$work/xcrun" <<'SHIM'
#!/bin/bash
case "${2:-}" in
fast) exit 7 ;;
hang) sleep 10 ;;
*) exit 2 ;;
esac
SHIM
chmod +x "$work/xcrun"

checks=0
check() { checks=$((checks + 1)); [ "$1" = 0 ] || { echo "FAIL: $2"; exit 1; }; }

set +e
WOLKAREFOREVER_REAL_XCRUN="$work/xcrun" "$wrapper" devicectl fast
rc=$?
set -e
[ "$rc" = 7 ]; check $? "the wrapper preserves a completed devicectl exit code"

start=$SECONDS
set +e
WOLKAREFOREVER_REAL_XCRUN="$work/xcrun" WOLKAREFOREVER_DEVICE_TIMEOUT=1 "$wrapper" devicectl hang > "$work/out" 2>&1
rc=$?
set -e
elapsed=$((SECONDS - start))
[ "$rc" = 124 ]; check $? "a hung devicectl call exits with the timeout code"
[ "$elapsed" -lt 4 ]; check $? "the timeout is bounded"
grep -q "did not answer" "$work/out"; check $? "the timeout is explained"

echo "XCRUN-TIMEOUT PASS: $checks checks"
