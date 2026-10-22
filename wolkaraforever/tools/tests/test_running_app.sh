#!/bin/bash
# The live-app guard must target the bundle being installed, not any Tolkara
# process on the device: two builds can be installed side by side.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
helper="$here/../running_app.sh"
work=$(mktemp -d -t running-app-test)
trap 'rm -rf "$work"' EXIT

cat > "$work/xcrun" <<'STUB'
#!/bin/bash
shift                       # devicectl
[ "${1:-}" = "device" ] || exit 9
[ "${2:-}" = "info" ] || exit 9
case "${3:-}" in
apps)
    [ -n "${STUB_APPS_FAIL:-}" ] && exit 1
    cat "$STUB_APPS" ;;
processes)
    cat "$STUB_PROCESSES" ;;
*) exit 9 ;;
esac
STUB
chmod +x "$work/xcrun"
export PATH="$work:$PATH"

cat > "$work/processes" <<'PROCS'
 111   /private/var/containers/Bundle/Application/AAA/Tolkara.app/Tolkara
 112   /private/var/containers/Bundle/Application/AAA/Tolkara.app/PlugIns/LocalAuthorizationTunnel.appex/LocalAuthorizationTunnel
 222   /private/var/containers/Bundle/Application/BBB/Tolkara.app/Tolkara
PROCS
export STUB_PROCESSES="$work/processes"

apps_with() {
    cat > "$work/apps" <<JSON
{"result":{"apps":[
 {"bundleIdentifier":"local.target","url":"$1"},
 {"bundleIdentifier":"local.other","url":"file:///private/var/containers/Bundle/Application/BBB/Tolkara.app/"}
]}}
JSON
    export STUB_APPS="$work/apps"
}

failed=0
expect() {
    local want=$1 name=$2 got
    got=$("$helper" DEVICE local.target)
    if [ "$got" != "$want" ]; then
        printf 'FAIL %s: wanted "%s", got "%s"\n' "$name" "$want" "$got"
        failed=1
    else
        printf 'ok   %s\n' "$name"
    fi
}

apps_with "file:///private/var/containers/Bundle/Application/AAA/Tolkara.app/"
expect 111 "the target bundle's own process is found, and its plugin is not"

apps_with "file:///private/var/containers/Bundle/Application/CCC/Tolkara.app/"
expect "" "another Tolkara build running is not this bundle"

apps_with "file:///private/var/containers/Bundle/Application/AAA/Tolkara.app/"
: > "$work/empty"; export STUB_PROCESSES="$work/empty"
expect "" "nothing running when no Tolkara process is up"
export STUB_PROCESSES="$work/processes"

cat > "$work/apps-none" <<'JSON'
{"result":{"apps":[{"bundleIdentifier":"local.other","url":"file:///private/var/containers/Bundle/Application/BBB/Tolkara.app/"}]}}
JSON
export STUB_APPS="$work/apps-none"
expect "" "a bundle that is not installed has nothing to replace"

export STUB_APPS_FAIL=1
expect 111 "an unreadable catalogue falls back to the conservative match"
unset STUB_APPS_FAIL

cat > "$work/apps-odd" <<'JSON'
{"result":{"apps":[{"bundleIdentifier":"local.target","url":"nowhere"}]}}
JSON
export STUB_APPS="$work/apps-odd"
expect 111 "an unparsable installation path falls back to the conservative match"

[ "$failed" = 0 ] && echo "RUNNING_APP_PASS: bundle-aware guard, side-by-side builds, plugins and conservative fallback."
exit "$failed"
