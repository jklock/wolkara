#!/bin/bash
# Generate the app's Xcode project from the prepared tree, with the builder's own
# signing team and identifiers from the repository root's ignored local.env.
#
# The layer reaches the build by overlay, so the platform's own project.yml needs no
# knowledge of it: this runs the platform's generate script on the prepared tree.
set -euo pipefail
cd "$(dirname "$0")/../.."
. wolkaraforever/tools/env.sh
wolkaraforever/tools/prepare.sh
cd build/platform
exec tools/generate.sh "$@"
