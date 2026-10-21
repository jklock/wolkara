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
# The platform's suite fails on this machine for one reason that is the platform's and not
# ours (see wolkara/tools/known_platform_failures.txt), so its status must not decide
# whether the layer's own suites run. It used to: `set -e` stopped the script on that exit
# 1, every time, so the loop below had never executed in any recorded run - two of the
# layer's suites were run by nothing at all, and one of them is the only test of a patch we
# carry. Carry the status; do not let it be the gate.
platform_rc=0
tools/test_emulation.sh "$@" || platform_rc=$?

cd "$ROOT"
layer_rc=0
for suite in wolkara/tools/test_*.sh; do
    case "$suite" in
        *ui.sh) continue;;                       # the UI ones need a booted simulator
        # This script. Running it from inside itself re-prepares the tree and runs the
        # platform's suite again, for ever; the loop is for the other suites.
        *test_emulation.sh) continue;;
    esac
    echo "== $suite"
    bash "$suite" || layer_rc=1
done

# A layer suite failing fails the run. Otherwise the platform's status is what is reported,
# and `validate.sh` judges that against the known-failure list rather than trusting it.
[ "$layer_rc" -eq 0 ] || exit 1
exit "$platform_rc"
