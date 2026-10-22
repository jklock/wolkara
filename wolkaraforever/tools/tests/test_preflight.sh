#!/bin/bash
# Test preflight.sh with stubbed device and app data: ready, missing DEVICE, and
# a missing --source each produce the documented result.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/wf-preflight.XXXXXX")
trap 'rm -rf "$work"' EXIT

tools="$work/wolkaraforever/tools"
mkdir -p "$tools" "$work/bin" "$work/game"
cp "$repo/wolkaraforever/tools/preflight.sh" "$tools/"
cp "$repo/wolkaraforever/tools/env.sh" "$tools/"
cat > "$work/local.env" <<'ENV'
DEVICE=UDID-TEST
TOLKARA_BUNDLE_ID=local.test.app
DEVELOPMENT_TEAM=TEAMTEST
ENV

# A device that is present, and an app catalogue that contains the bundle.
cat > "$tools/device_variables.sh" <<'STUB'
#!/bin/bash
printf '%s\n' '{"name":"TestPad","link":"USB","os":"27.0","state":"connected"}'
STUB
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
prev=""
for a in "$@"; do
    if [ "$prev" = "--json-output" ]; then
        if [ "${APPS_EMPTY:-0}" = 1 ]; then
            printf '%s\n' '{"result":{"apps":[]}}' > "$a"
        else
            printf '%s\n' '{"result":{"apps":[{"bundleIdentifier":"local.test.app"}]}}' > "$a"
        fi
        exit 0
    fi
    prev="$a"
done
exit 0
STUB
chmod +x "$tools/device_variables.sh" "$work/bin/xcrun"

# USB free-space query (libimobiledevice). 200 GB available is plenty.
cat > "$work/bin/ideviceinfo" <<'STUB'
#!/bin/bash
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
printf '%s\n' '<plist version="1.0"><dict><key>TotalDataAvailable</key><integer>'"${IDEVI_AVAILABLE:-200000000000}"'</integer></dict></plist>'
STUB
chmod +x "$work/bin/ideviceinfo"

# A minimal game tree at the path preflight expects.
mkdir -p "$work/game/_classic_beta_/World of Warcraft Beta.app/Contents/MacOS"
: > "$work/game/_classic_beta_/World of Warcraft Beta.app/Contents/MacOS/World of Warcraft"

pass=0; fail=0
check() { if [ "$1" = 0 ]; then pass=$((pass+1)); printf 'PASS  %s\n' "$2"; else fail=$((fail+1)); printf 'FAIL  %s\n' "$2"; fi; }

out=$(PATH="$work/bin:$PATH" bash "$tools/preflight.sh" --source "$work/game" 2>&1); rc=$?
printf '%s' "$out" | grep -q "app installed"; check $? "sees the installed app"
printf '%s' "$out" | grep -q "game source"; check $? "sees the game source"
printf '%s' "$out" | grep -q "200 GB free on the iPad"; check $? "reports free space when USB is available"
printf '%s' "$out" | grep -q "Ready."; check $? "reports Ready when everything is present"
[ "$rc" -eq 0 ]; check $? "exits 0 when ready"

printf 'TOLKARA_BUNDLE_ID=local.test.app\n' > "$work/local.env"
PATH="$work/bin:$PATH" bash "$tools/preflight.sh" --source "$work/game" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check $? "fails when DEVICE is missing"

printf 'DEVICE=UDID-TEST\nTOLKARA_BUNDLE_ID=local.test.app\n' > "$work/local.env"
PATH="$work/bin:$PATH" bash "$tools/preflight.sh" --source "$work/nope" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ]; check $? "fails when an explicit source is missing"

out=$(PATH="$work/bin:$PATH" IDEVI_AVAILABLE=10000000000 bash "$tools/preflight.sh" --source "$work/game" 2>&1); rc=$?
printf '%s' "$out" | grep -q "only 10 GB free"; check $? "reports low iPad space"
[ "$rc" -ne 0 ]; check $? "fails on low iPad space"

out=$(PATH="$work/bin:$PATH" APPS_EMPTY=1 bash "$tools/preflight.sh" --source "$work/game" --require-app 2>&1); rc=$?
[ "$rc" -ne 0 ]; check $? "--require-app fails when the app is missing"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
