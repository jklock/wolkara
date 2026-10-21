#!/bin/bash
# Run the app: prepare the tree, then run the platform's own run script against it.
# `wolkaraforever/tools/run.sh sim` for the loader diagnostics in the simulator, or a device
# as that script documents.
set -euo pipefail
cd "$(dirname "$0")/../.."
. wolkaraforever/tools/env.sh
wolkaraforever/tools/prepare.sh
cd build/platform
exec tools/run.sh "$@"
