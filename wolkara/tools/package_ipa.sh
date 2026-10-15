#!/bin/bash
# Build the unsigned generic TolkaraDiagnostics .ipa for External JIT (sideloaded, for
# example with SideStore): prepare the tree, then run the platform's own packaging
# script against it. Only our own code goes in - never application code.
set -euo pipefail
cd "$(dirname "$0")/../.."
. wolkara/tools/env.sh
wolkara/tools/prepare.sh
cd build/platform
exec tools/package_ipa.sh "$@"
