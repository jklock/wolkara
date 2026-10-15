#!/bin/bash
# The regression suite: prepare the tree, run the platform's own suite against it, then
# the layer's own suites.
#
# Our files are in the prepared tree by overlay, so the platform's suite covers the
# runtime and the adapters as we ship them - including the patches this layer carries.
# The layer's suites are the ones written for our features and live with them.
set -euo pipefail
cd "$(dirname "$0")/../.."
. wolkara/tools/env.sh
wolkara/tools/prepare.sh

# The gate first: if the split itself is out of shape, the suites below prove nothing.
wolkara/tools/check_layers.sh

cd build/platform
tools/test_emulation.sh "$@"

cd "$ROOT"
for suite in wolkara/tools/test_*.sh; do
    case "$suite" in
        *ui.sh) continue;;                       # the UI ones need a booted simulator
    esac
    echo "== $suite"
    bash "$suite"
done
