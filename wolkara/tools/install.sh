#!/bin/bash
# Build and install the app on the configured iPad: prepare the tree, then run the
# platform's own install script against it. Everything it documents still applies -
# TOLKARA_MODE, GUEST_EXE, NATIVE_GUEST_SHIMS, the page containers - and it takes its
# settings from the repository root's ignored local.env. Installing replaces the app
# under the same bundle ID and keeps the device's data.
set -euo pipefail
cd "$(dirname "$0")/../.."
. wolkara/tools/env.sh
wolkara/tools/prepare.sh
cd build/platform
# The platform's script asks xcodebuild for `-derivedDataPath build/device` and then
# installs from `build/device/Build/Products/Debug-iphoneos/Tolkara.app`. A machine-wide
# Xcode build location overrides that: this Mac has IDEBuildLocationStyle = Custom with
# IDECustomDerivedDataLocation = /Volumes/Storage/XCode, so products land there, the build
# succeeds and the install step finds nothing. An xcconfig handed over through
# XCODE_XCCONFIG_FILE pins the layout the platform's script expects without touching that
# script, and does the same on a machine with no such override.
location=$(mktemp -t wolkara-location)
# Absolute, not $(SRCROOT): the Swift package is a project of its own, so a path relative
# to the source root resolves differently inside it and its products end up in its own
# checkout, where the app's compiler cannot find them. One shared products directory is
# also the layout Xcode uses by default.
cat > "$location" <<XCCONFIG
SYMROOT = $PWD/build/device/Build/Products
OBJROOT = $PWD/build/device/Build/Intermediates.noindex
XCCONFIG
export XCODE_XCCONFIG_FILE="$location"

# Fetching the Swift package the layer's add-on manager needs happens inside the
# platform's own script, as patch 0011: it regenerates the project, so a resolution done
# out here would be stale before the build looked for it.
exec tools/install.sh "$@"
