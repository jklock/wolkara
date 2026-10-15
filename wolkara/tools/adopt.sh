#!/bin/bash
# Turn somebody's own tolkara tree into Wolkara.
#
# usage: wolkara/tools/adopt.sh /path/to/your/tolkara
#
# This is the same work prepare.sh does to our vendored copy of tolkara, pointed at a
# tree you own instead: the layer's patches applied to the platform's own files, and the
# layer's files copied to the paths the platform's build expects them at. Nothing is
# edited by hand anywhere, so the result is reproducible and an update to tolkara can be
# taken the same way.
#
# Their tree is changed in place, because that is what was asked for: tolkara becomes
# Wolkara. Run it on a copy if you would rather keep the original.
set -eu
cd "$(dirname "$0")/../.." || exit 2
tree=${1:-}
[ -n "$tree" ] || { echo "usage: wolkara/tools/adopt.sh /path/to/your/tolkara" >&2; exit 2; }
[ -d "$tree" ] || { echo "adopt: no such tree: $tree" >&2; exit 2; }
case "$tree" in /*) ;; *) tree="$PWD/$tree";; esac

# It should look like tolkara before anything is written to it.
for want in runtime translation authorization launcher project.yml; do
    [ -e "$tree/$want" ] || {
        echo "adopt: $tree does not look like a tolkara tree (there is no $want)" >&2
        exit 2
    }
done

echo "adopt: applying the layer to $tree"
bash wolkara/tools/apply.sh "$tree"
echo
echo "adopt: $tree is Wolkara now. Build it with its own tools:"
echo "    cd $tree && tools/generate.sh && tools/install.sh"
echo "Its settings come from local.env in that tree (see local.env.example)."
echo "The prepared build tree in this repository is untouched."
