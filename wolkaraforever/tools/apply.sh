#!/bin/bash
# Apply the layer to a tolkara tree: the patches, then the overlay.
#
# usage: wolkaraforever/tools/apply.sh <tree>
#
# The tree may be our prepared build tree (inside this repository) or anybody's own
# tolkara checkout (a repository of its own, or not a repository at all). The patches
# are applied with git, which resolves their paths against the enclosing repository's
# root - so a tree that is a *subdirectory* of a repository needs the --directory form,
# or the patch is silently skipped. Both cases are handled here.
set -eu
cd "$(dirname "$0")/../.." || exit 2
root=$PWD
tree=${1:-}
[ -n "$tree" ] || { echo "usage: wolkaraforever/tools/apply.sh <tree>" >&2; exit 2; }
[ -d "$tree" ] || { echo "apply: no such tree: $tree" >&2; exit 2; }
case "$tree" in /*) ;; *) tree="$root/$tree";; esac
# git reports resolved paths and /tmp is a symlink to /private/tmp on macOS, so resolve
# ours the same way before comparing the two.
tree=$(cd "$tree" && pwd -P)

apply_patch() {
    local patch=$1 top
    top=$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -z "$top" ] || [ "$top" = "$tree" ]; then
        # Not in a repository, or the tree is the root of its own: paths resolve
        # against the tree itself.
        (cd "$tree" && git apply -p1 "$patch")
    else
        git -C "$top" apply -p1 --directory="${tree#"$top"/}" "$patch"
    fi
}

# The same resolution, asked to check the patch in reverse: that proves it really
# landed rather than being skipped.
check_patch_reversed() {
    local patch=$1 top
    top=$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -z "$top" ] || [ "$top" = "$tree" ]; then
        (cd "$tree" && git apply -p1 --check --reverse "$patch")
    else
        git -C "$top" apply -p1 --check --reverse --directory="${tree#"$top"/}" "$patch"
    fi
}

applied=0
for patch in wolkaraforever/patches/*.patch; do
    [ -e "$patch" ] || continue
    if ! apply_patch "$root/$patch"; then
        echo "apply: FAILED to apply $(basename "$patch") to $tree" >&2
        echo "apply: the tree is left half-patched; fix the patch, not the platform" >&2
        exit 1
    fi
    if ! check_patch_reversed "$root/$patch"; then
        echo "apply: $(basename "$patch") reported success but changed nothing" >&2
        exit 1
    fi
    echo "apply: applied $(basename "$patch")"
    applied=$((applied + 1))
done

# The overlay puts our files at the paths the platform's own build expects, so the
# platform's project, its shim builder and its test scripts build our app without
# knowing the layer exists. It is checked before anything is copied:
#   replace - the platform must have the path, or upstream has moved the file;
#   add     - the platform must not have it, or upstream has added one of its own and
#             we have to choose: replace it, or take theirs and drop ours.
# Either way this stops, which is what keeps an update from silently losing a file.
problems=""
while read -r src dst intent rest; do
    case "$src" in ''|\#*) continue;; esac
    [ -n "${dst:-}" ] || continue
    exists=no
    [ -e "$tree/$dst" ] && exists=yes
    case "$intent" in
        replace) [ "$exists" = yes ] || problems="$problems
  'replace' but not in the tree (upstream moved it?): $dst";;
        add)     [ "$exists" = no ]  || problems="$problems
  'add' but the tree has a file there (replace it, or take theirs): $dst";;
        *)       problems="$problems
  unknown intent '$intent' for $dst" ;;
    esac
done < wolkaraforever/overlay.map
if [ -n "$problems" ]; then
    echo "apply: the overlay does not match this tree:$problems" >&2
    echo "apply: fix wolkaraforever/overlay.map (or the layer) first" >&2
    exit 1
fi

overlaid=0
while read -r src dst intent rest; do
    case "$src" in ''|\#*) continue;; esac
    [ -n "${dst:-}" ] || continue
    mkdir -p "$tree/$(dirname "$dst")"
    cp "$src" "$tree/$dst"
    overlaid=$((overlaid + 1))
done < wolkaraforever/overlay.map

echo "apply: $tree now carries the layer ($applied patch(es), $overlaid file(s) overlaid)"
