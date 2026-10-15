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
exec tools/install.sh "$@"
