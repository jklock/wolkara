#!/bin/bash
# Merge a local WoW Forever AddOns folder into Wolkara's selected game container.
# This never deletes iPad add-ons, settings, or game files.
set -euo pipefail
cd "$(dirname "$0")/../.."

. tools/localenv.sh; tolkara_load_env

SOURCE_ROOT="/Volumes/Storage/World of Warcraft"
DEVICE=${DEVICE:-}
BUNDLE=${TOLKARA_BUNDLE_ID:-}

usage() {
    cat <<'EOF'
usage: profiles/wow-forever/sync_addons.sh [--source PATH] [--device UDID]

Merges PATH/_classic_beta_/Interface/AddOns into Wolkara on the paired device.
The default source is /Volumes/Storage/World of Warcraft. Existing files on the
device are not removed. Close Wolkara before running this command.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --source) [ $# -ge 2 ] || { usage >&2; exit 2; }; SOURCE_ROOT=$2; shift 2 ;;
        --device) [ $# -ge 2 ] || { usage >&2; exit 2; }; DEVICE=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[ -n "$DEVICE" ] || { echo "Set DEVICE in local.env or pass --device." >&2; exit 2; }
[ -n "$BUNDLE" ] || { echo "Set TOLKARA_BUNDLE_ID in local.env." >&2; exit 2; }

SOURCE_ROOT=$(cd "$SOURCE_ROOT" && pwd -P)
SOURCE_ADDONS="$SOURCE_ROOT/_classic_beta_/Interface/AddOns"
DESTINATION="Documents/World of Warcraft/_classic_beta_/Interface/AddOns"

[ -d "$SOURCE_ADDONS" ] || { echo "AddOns folder not found: $SOURCE_ADDONS" >&2; exit 2; }

# Do not race the running game or its updater; this script never terminates it.
if xcrun devicectl device info processes --device "$DEVICE" | grep -Fq '/Tolkara.app/Tolkara'; then
    echo "Wolkara is running on the device. Close it before syncing add-ons." >&2
    exit 2
fi

echo "Syncing $(find "$SOURCE_ADDONS" -type f | wc -l | tr -d ' ') add-on files…"
xcrun devicectl device copy to --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$SOURCE_ADDONS" --destination "$DESTINATION"

echo "Add-on sync completed. Wolkara will load them on its next normal game launch."
xcrun devicectl device info files --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --subdirectory "$DESTINATION" --no-recurse
