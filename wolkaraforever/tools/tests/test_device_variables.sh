#!/bin/bash
# Test device_variables.sh against synthetic devicectl JSON.
# No device, no Xcode and no network are needed: a stub xcrun writes the fixture.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/wf-device-vars.XXXXXX")
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/wolkaraforever/tools" "$work/bin"
cp "$repo/wolkaraforever/tools/device_variables.sh" "$work/wolkaraforever/tools/"
script="$work/wolkaraforever/tools/device_variables.sh"

# A stub xcrun: when asked for --json-output, copy the current fixture there.
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
prev=""
for a in "$@"; do
    if [ "$prev" = "--json-output" ]; then cp "$XFIXTURE" "$a"; exit 0; fi
    prev="$a"
done
exit 0
STUB
chmod +x "$work/bin/xcrun"

physical() { # name udid transport
    cat <<JSON
{"identifier":"id-$3","visibilityClass":"default","properties":{
 "hardware":{"deviceType":"iPad","platform":"iOS","reality":"physical","udid":"$2","marketingName":"iPad Pro","productType":"iPad13,9"},
 "software":{"osVersionNumber":{"stringValue":"27.0"}},
 "connection":{"state":"connected","pairingState":"paired","transportType":"$3"},
 "state":{"name":"$1"}}}
JSON
}
simulator='{"identifier":"sim","visibilityClass":"simulators","properties":{"hardware":{"deviceType":"iPad","platform":"iOS","reality":"simulated","udid":"SIM-UDID","marketingName":"iPad Sim"},"software":{"osVersionNumber":{"stringValue":"27.0"}},"connection":{"state":"connected","transportType":"sameMachine"},"state":{"name":"SimPad"}}}'

printf '{"result":{"devices":[%s,%s]}}' "$(physical TestPad UDID-1 wired)" "$simulator" > "$work/one.json"
printf '{"result":{"devices":[%s,%s]}}' "$(physical TestPad UDID-1 wired)" "$(physical OtherPad UDID-2 localNetwork)" > "$work/two.json"
printf '{"result":{"devices":[%s]}}' "$simulator" > "$work/none.json"

cat > "$work/local.env" <<'ENV'
DEVICE=OLD-DEVICE
TOLKARA_BUNDLE_ID=local.test.app
ENV

pass=0; fail=0
check() { if [ "$1" = 0 ]; then pass=$((pass+1)); printf 'PASS  %s\n' "$2"; else fail=$((fail+1)); printf 'FAIL  %s\n' "$2"; fi; }

run() { PATH="$work/bin:$PATH" XFIXTURE="$1" bash "$script" "${@:2}"; }

out=$(run "$work/one.json" 2>&1); rc=$?
printf '%s' "$out" | grep -q "Device: TestPad"; check $? "finds the single physical iPad"
printf '%s' "$out" | grep -q "Link:.*USB"; check $? "reports USB for a wired device"
printf '%s' "$out" | grep -q "UDID-1"; check $? "prints the UDID"
printf '%s' "$out" | grep -q "SimPad"; [ $? -ne 0 ]; check $? "excludes simulators by default"

out=$(run "$work/one.json" --export 2>&1); rc=$?
printf '%s' "$out" | grep -q "DEVICE='UDID-1'"; check $? "--export prints an eval-able DEVICE"
printf '%s' "$out" | grep -q "TOLKARA_BUNDLE_ID='local.test.app'"; check $? "--export reads the bundle id from local.env"

out=$(run "$work/two.json" 2>&1); rc=$?
[ "$rc" -ne 0 ]; check $? "refuses to guess between two connected iPads"

out=$(run "$work/two.json" --device OtherPad 2>&1); rc=$?
printf '%s' "$out" | grep -q "Device: OtherPad"; check $? "--device selects by name"
printf '%s' "$out" | grep -q "Link:.*Network"; check $? "reports Network for a paired device"

out=$(run "$work/none.json" 2>&1); rc=$?
[ "$rc" -ne 0 ]; check $? "fails when no physical iPad is present"

# --write refuses to replace a different DEVICE without --force.
out=$(run "$work/one.json" --write 2>&1); rc=$?
[ "$rc" -ne 0 ]; check $? "--write refuses a different DEVICE without --force"

# --force replaces it; the rest of local.env must be untouched.
run "$work/one.json" --write --force >/dev/null 2>&1; rc=$?
grep -q '^DEVICE=UDID-1$' "$work/local.env"; check $? "--write --force records DEVICE"
grep -q '^TOLKARA_BUNDLE_ID=local.test.app$' "$work/local.env"; check $? "--write leaves other keys alone"

# With no local.env, --write seeds one from local.env.example.
rm -f "$work/local.env"
printf 'DEVELOPMENT_TEAM=TEAMTEST\n#DEVICE=\n' > "$work/local.env.example"
run "$work/one.json" --write >/dev/null 2>&1; rc=$?
grep -q '^DEVICE=UDID-1$' "$work/local.env"; check $? "--write creates local.env with DEVICE"
grep -q '^DEVELOPMENT_TEAM=TEAMTEST$' "$work/local.env"; check $? "--write seeds from local.env.example"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
