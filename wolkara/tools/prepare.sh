#!/bin/bash
# Prepare the tree we build from: a pristine export of platform/ with the layer's
# patches applied. platform/ itself is never edited - it stays byte-identical to
# upstream, and every Wolkara change to it is a patch under wolkara/patches/.
#
# build/ is ignored output, so the prepared tree can be deleted at any time.
set -eu
cd "$(dirname "$0")/../.." || exit 2
root=$PWD

dest=build/platform
patches=$(ls wolkara/patches/*.patch 2>/dev/null || true)

rm -rf "$dest"
mkdir -p "$dest"
git archive HEAD:platform | tar -x -C "$dest" || {
    echo "prepare: cannot export platform/ - is it vendored?" >&2
    exit 1
}

# The layer is applied by apply.sh, which is also what adopt.sh runs on somebody
# else's tolkara tree: one implementation, so the two can never drift apart.
bash wolkara/tools/apply.sh "$dest"

pinned=$(git rev-parse --short upstream/main 2>/dev/null || echo unknown)
echo "prepare: $dest ready (platform $pinned)"
