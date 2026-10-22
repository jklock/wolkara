#!/bin/bash
# Test push_game.sh: it must use the prepared installer, pass arguments through,
# include --device from local.env, and run the preflight without copying on --dry-run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/wf-push-game.XXXXXX")
trap 'rm -rf "$work"' EXIT

tools="$work/wolkaraforever/tools"
mkdir -p "$tools" "$work/build/platform/profiles/wow-forever"
cp "$repo/wolkaraforever/tools/push_game.sh" "$tools/"
cp "$repo/wolkaraforever/tools/env.sh" "$tools/"
cat > "$work/local.env" <<'ENV'
DEVICE=UDID-TEST
TOLKARA_BUNDLE_ID=local.test.app
ENV
cat > "$work/build/platform/profiles/wow-forever/install.py" <<'PY'
#!/usr/bin/env python3
import sys
print("INSTALLER " + " ".join(sys.argv[1:]))
PY
chmod +x "$work/build/platform/profiles/wow-forever/install.py"

# The wrapper asks the device script for the link and the preflight for a dry run.
cat > "$tools/device_variables.sh" <<'STUB'
#!/bin/bash
printf '%s\n' '{"link":"USB"}'
STUB
cat > "$tools/preflight.sh" <<'STUB'
#!/bin/bash
echo "PREFLIGHT $*"
STUB
chmod +x "$tools/device_variables.sh" "$tools/preflight.sh"

pass=0; fail=0
check() { if [ "$1" = 0 ]; then pass=$((pass+1)); printf 'PASS  %s\n' "$2"; else fail=$((fail+1)); printf 'FAIL  %s\n' "$2"; fi; }

out=$(bash "$tools/push_game.sh" 2>&1); rc=$?
printf '%s' "$out" | grep -q "PREFLIGHT"; check $? "runs the preflight before copying"
printf '%s' "$out" | grep -q "INSTALLER --device UDID-TEST"; check $? "runs the prepared installer with DEVICE"
printf '%s' "$out" | grep -q "device link: USB"; check $? "reports the device link"
[ "$rc" -eq 0 ]; check $? "exits 0 on success"

out=$(bash "$tools/push_game.sh" --skip-data 2>&1); rc=$?
printf '%s' "$out" | grep -q -- "--skip-data"; check $? "passes installer options through"

out=$(bash "$tools/push_game.sh" --dry-run --source /tmp/somewhere 2>&1); rc=$?
printf '%s' "$out" | grep -q "PREFLIGHT --source /tmp/somewhere"; check $? "--dry-run runs the preflight"
printf '%s' "$out" | grep -q "INSTALLER"; [ $? -ne 0 ]; check $? "--dry-run copies nothing"

# Missing DEVICE must stop before anything else.
cat > "$work/local.env" <<'ENV'
TOLKARA_BUNDLE_ID=local.test.app
ENV
bash "$tools/push_game.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check $? "refuses when DEVICE is not set"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
