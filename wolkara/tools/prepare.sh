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

applied=0
for patch in $patches; do
    # From the repository root with --directory: `git -C build/platform apply`
    # resolves the patch paths against the repository root and skips the patch
    # silently (exit 0) because build/platform is inside this working tree.
    if ! git apply -p1 --directory="$dest" "$root/$patch"; then
        echo "prepare: FAILED to apply $(basename "$patch")" >&2
        echo "prepare: $dest left half-patched; fix the patch, not platform/" >&2
        exit 1
    fi
    if ! git apply -p1 --check --reverse --directory="$dest" "$root/$patch"; then
        echo "prepare: $(basename "$patch") reported success but changed nothing in $dest" >&2
        exit 1
    fi
    echo "prepare: applied $(basename "$patch")"
    applied=$((applied + 1))
done

pinned=$(git rev-parse --short upstream/main 2>/dev/null || echo unknown)
echo "prepare: $dest ready (platform $pinned, $applied patch(es))"
