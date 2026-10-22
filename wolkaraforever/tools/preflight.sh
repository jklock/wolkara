#!/bin/bash
# Preflight: is this Mac ready to build, install, or push to the attached iPad?
#
# Read-only. It changes nothing. It reports what is present, what is missing, and
# whether a push would be safe, so a failure is explained before a long copy.
#
# usage: wolkaraforever/tools/preflight.sh [--source <folder>] [--size] [--require-app]
#
#   --source <folder>  Check a specific Mac game folder (default /Applications/World of Warcraft).
#                      Passing it makes the source a requirement rather than a note.
#   --size             Also measure the source folder (a large tree can take a while).
#   --require-app      Treat a missing app as an error (push uses this).
#   -h, --help         Show this text.
#
# Exit status: 0 ready for the step you asked about; 1 something required is missing.
#
# It checks: local.env and its keys, the device (USB or network), the app on the
# device, the Mac game folder, and free space on the Mac. Device storage and the
# app catalogue are best-effort: a locked or asleep iPad cannot answer them, and
# that is reported as a warning, not a hard failure.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
. wolkaraforever/tools/env.sh

source="/Applications/World of Warcraft"
source_given=0
want_size=0
require_app=0
while [ $# -gt 0 ]; do
    case "$1" in
        --source) shift; source=${1:-}; source_given=1;;
        --size) want_size=1;;
        --require-app) require_app=1;;
        -h|--help) sed -n '2,26p' "$0"; exit 0;;
        *) printf 'preflight: unknown option: %s\n' "$1" >&2; exit 2;;
    esac
    shift
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  OK      %s\n' "$*"; }
warn() { printf '  WARN    %s\n' "$*"; }
bad()  { printf '  MISSING %s\n' "$*"; fail=1; }

fail=0
say "WolkaraForever preflight"
say ""

# 1. Settings file and the keys the tools use.
if [ -f "$ROOT/local.env" ]; then ok "local.env present"; else bad "local.env (run: cp local.env.example local.env)"; fi
[ -n "${DEVICE:-}" ] && ok "DEVICE set" || bad "DEVICE (run: wolkaraforever/tools/device_variables.sh --write)"
[ -n "${TOLKARA_BUNDLE_ID:-}" ] && ok "TOLKARA_BUNDLE_ID set" || bad "TOLKARA_BUNDLE_ID (set your own bundle identifier in local.env)"
[ -n "${DEVELOPMENT_TEAM:-}" ] && ok "DEVELOPMENT_TEAM set" || warn "DEVELOPMENT_TEAM not set (needed to sign/install, not to push)"

# 2. The device, over USB or the network. device_variables.sh does the parsing.
if info=$(wolkaraforever/tools/device_variables.sh --json --device "$DEVICE" 2>/dev/null); then
    printf '%s' "$info" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("  OK      device: %s (%s)" % (d["name"], d["link"]))
print("  OK      iPadOS %s, state %s" % (d["os"], d["state"]))
' || true
    link=$(printf '%s' "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("link",""))')
    [ "$link" = "Network" ] && warn "device is reachable over the network; USB is faster for a large copy"
else
    bad "device '$DEVICE' is not reachable (unlock it, trust this Mac, or connect by USB)"
fi

# 3. Is the app installed on the device? Best-effort; a locked iPad cannot answer.
if [ -n "${DEVICE:-}" ] && [ -n "${TOLKARA_BUNDLE_ID:-}" ]; then
    apps=$(mktemp)
    if xcrun devicectl device info apps --device "$DEVICE" --json-output "$apps" >/dev/null 2>&1; then
        state=$(python3 - "$apps" "$TOLKARA_BUNDLE_ID" <<'PY'
import json, sys
try:
    apps = json.load(open(sys.argv[1])).get("result", {}).get("apps", [])
except Exception:
    print("unknown"); raise SystemExit
print("installed" if any(a.get("bundleIdentifier") == sys.argv[2] for a in apps) else "missing")
PY
)
        case "$state" in
            installed) ok "app installed on the device" ;;
            missing)   if [ "$require_app" = 1 ]; then bad "app not installed (run wolkaraforever/tools/install.sh first)"; else warn "app not installed yet (install.sh installs it; push needs it)"; fi ;;
            *)         warn "could not read the app list" ;;
        esac
    else
        warn "could not read the app list (iPad locked or asleep?)"
    fi
    rm -f "$apps"
fi

# 3b. Device capacity. devicectl reports total storage, not free space, so this
# checks the device is large enough and reminds you of the free-space need.
if [ -n "${DEVICE:-}" ]; then
    details=$(mktemp)
    if xcrun devicectl device info details --device "$DEVICE" --json-output "$details" >/dev/null 2>&1; then
        capacity=$(python3 - "$details" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1])).get("result", {})
    props = d.get("properties", {}).get("hardware", {})
    hw = d.get("hardwareProperties", {})
    value = props.get("internalStorageCapacity") or hw.get("internalStorageCapacity")
    print(int(value // 1_000_000_000) if value else "")
except Exception:
    print("")
PY
)
        if [ -n "$capacity" ]; then
            if [ "$capacity" -lt 70 ]; then
                warn "device capacity ${capacity} GB; a Forever install needs about 70 GB free"
            else
                ok "device capacity ${capacity} GB (free space is not reported; keep about 70 GB free)"
            fi
        else
            warn "device storage was not reported"
        fi
    else
        warn "could not read device storage (iPad locked or asleep?)"
    fi
    rm -f "$details"
fi

# 3c. Free space, when the iPad is reachable over USB. libimobiledevice reports
# it; devicectl does not, and a network-only iPad cannot answer. About 70 GB is
# needed for the tested install plus update headroom.
if [ -n "${DEVICE:-}" ]; then
    if command -v ideviceinfo >/dev/null 2>&1; then
        usage=$(ideviceinfo -u "$DEVICE" -q com.apple.disk_usage 2>/dev/null || true)
        [ -z "$usage" ] && usage=$(ideviceinfo -n -u "$DEVICE" -q com.apple.disk_usage 2>/dev/null || true)
        [ -z "$usage" ] && usage=$(ideviceinfo -n -q com.apple.disk_usage 2>/dev/null || true)
        if [ -n "$usage" ]; then
            free=$(printf '%s' "$usage" | python3 -c '
import plistlib, sys
try:
    d = plistlib.loads(sys.stdin.buffer.read())
    value = d.get("TotalDataAvailable") or d.get("TotalSystemAvailable")
    print(int(value // 1_000_000_000) if value else "")
except Exception:
    print("")
')
            if [ -n "$free" ]; then
                if [ "$free" -lt 70 ]; then
                    bad "only ${free} GB free on the iPad; a Forever install needs about 70 GB"
                else
                    ok "${free} GB free on the iPad"
                fi
            fi
        else
            warn "iPad free space needs a USB connection (or Settings > General > iPad Storage)"
        fi
    else
        warn "no ideviceinfo for iPad free space (brew install libimobiledevice), or check Settings > General > iPad Storage"
    fi
fi

# 4. The Mac game folder, and free space on the Mac.
exe="$source/_classic_beta_/World of Warcraft Beta.app/Contents/MacOS/World of Warcraft"
if [ -f "$exe" ]; then
    ok "game source: $source"
    [ "$want_size" = 1 ] && { say "  ...     measuring $source (this can take a while)"; du -sh "$source" | sed 's/^/  OK      /'; }
elif [ "$source_given" = 1 ]; then
    bad "game source not found at $source"
else
    warn "no game at $source (fine to install; needed to push)"
fi

free_gb=$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d ' ')
if [ -n "$free_gb" ]; then
    if [ "$free_gb" -lt 15 ]; then warn "only ${free_gb} GB free on the Mac"; else ok "${free_gb} GB free on the Mac"; fi
fi

say ""
if [ "$fail" = 0 ]; then
    say "Ready."
    exit 0
fi
say "Not ready (see MISSING above)."
exit 1
