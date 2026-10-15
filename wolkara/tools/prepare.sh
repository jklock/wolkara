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

# The overlay puts our files at the paths the platform's own build expects, so the
# platform's project, its shim builder and its test scripts all build our app without
# knowing the layer exists. It is checked before anything is copied:
#   replace - the pinned platform must have the path, or upstream has moved the file;
#   add     - the platform must not have it, or upstream has added one of its own and
#             we have to choose: replace it, or take theirs and drop ours.
# Either way the build stops, which is what keeps an ingest from silently losing a file.
overlay=wolkara/overlay.map
problems=""
while read -r src dst intent rest; do
    case "$src" in ''|\#*) continue;; esac
    [ -n "${dst:-}" ] || continue
    exists=no
    [ -e "$dest/$dst" ] && exists=yes
    case "$intent" in
        replace) [ "$exists" = yes ] || problems="$problems
  'replace' but not in the pinned platform (upstream moved it?): $dst";;
        add)     [ "$exists" = no ]  || problems="$problems
  'add' but the platform has a file there (replace it, or take theirs): $dst";;
        *)       problems="$problems
  unknown intent '$intent' for $dst" ;;
    esac
done < "$overlay"
if [ -n "$problems" ]; then
    echo "prepare: the overlay no longer matches the pinned platform:$problems" >&2
    echo "prepare: fix wolkara/overlay.map (or the layer) before building" >&2
    exit 1
fi
overlaid=0
while read -r src dst intent rest; do
    case "$src" in ''|\#*) continue;; esac
    [ -n "${dst:-}" ] || continue
    mkdir -p "$dest/$(dirname "$dst")"
    cp "$src" "$dest/$dst"
    overlaid=$((overlaid + 1))
done < "$overlay"

pinned=$(git rev-parse --short upstream/main 2>/dev/null || echo unknown)
echo "prepare: $dest ready (platform $pinned, $applied patch(es), $overlaid overlaid)"
