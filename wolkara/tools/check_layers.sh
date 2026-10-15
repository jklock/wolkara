#!/bin/bash
# The gate for the layer split: the platform stays upstream's, our patches apply,
# and the Wolkara project does not reach into another module's internals.
#
# Run from anywhere; it works on the repository root.
set -u
cd "$(dirname "$0")/../.." || exit 2
root=$PWD

fail=0
report() { printf '%s %s\n' "$1" "$2"; }
ok()     { report "PASS" "$1"; }
bad()    { report "FAIL" "$1"; fail=1; }
notice() { report "TODO" "$1"; }

# 1. platform/ is exactly the pinned upstream tree.
pinned=$(git rev-parse --short upstream/main 2>/dev/null)
if [ -z "$pinned" ]; then
    bad "no upstream/main ref: fetch it before running this check"
else
    upstream_tree=$(git rev-parse "upstream/main^{tree}" 2>/dev/null)
    platform_tree=$(git rev-parse "HEAD:platform" 2>/dev/null)
    if [ -z "$platform_tree" ]; then
        bad "platform/ is not vendored yet (git subtree add --prefix=platform upstream main --squash)"
    elif [ "$platform_tree" = "$upstream_tree" ]; then
        ok "platform/ is byte-identical to upstream/main ($pinned, $platform_tree)"
    else
        bad "platform/ differs from upstream/main ($pinned): expected $upstream_tree, found $platform_tree"
    fi
fi

# 2. Nothing in platform/ mentions Wolkara: the platform stays brand-free.
brand=$(git grep -l -I -e Wolkara -e wolkara -- platform 2>/dev/null | head -5)
if [ -z "$brand" ]; then
    ok "no Wolkara strings under platform/"
else
    bad "Wolkara strings under platform/ (must live in the layer):"
    printf '     %s\n' $brand
fi

# 3. Every patch applies to a fresh copy of the platform.
patches=$(ls wolkara/patches/*.patch 2>/dev/null)
if [ -z "$patches" ]; then
    notice "no patches yet (wolkara/patches/): the layer split has not started"
else
    scratch=$(mktemp -d) || exit 2
    trap 'rm -rf "$scratch"' EXIT
    git archive HEAD:platform | tar -x -C "$scratch" || bad "cannot export platform/ for the patch check"
    applied=0
    for patch in $patches; do
        if git -C "$scratch" apply --check "$root/$patch" 2>/dev/null; then
            git -C "$scratch" apply "$root/$patch" 2>/dev/null && applied=$((applied + 1))
        else
            bad "$(basename "$patch") does not apply to platform/ as pinned"
        fi
    done
    [ "$applied" -eq 0 ] || ok "$applied patch(es) apply cleanly"
fi

# 4. The layer's project builds from the prepared tree, and the modules stay
#    independent: WoW must not reach into Touch, and both go through Bridge.
if [ ! -f wolkara/project.yml ]; then
    notice "no wolkara/project.yml yet: source coverage and module boundaries unchecked"
else
    if grep -q "build/platform" wolkara/project.yml; then
        ok "the layer project builds from the prepared tree"
    else
        bad "wolkara/project.yml does not reference build/platform: sources must come from the prepared tree"
    fi
    reach=$(grep -REl "wolkara/Touch/|wolkara/Touch\"" wolkara/WoW 2>/dev/null | head -3)
    [ -z "$reach" ] || bad "wolkara/WoW reaches into wolkara/Touch: use wolkara/Bridge"
    [ -n "$reach" ] || ok "no cross-module reach-in from WoW into Touch"
fi

if [ "$fail" -eq 0 ]; then
    echo "check_layers: OK"
else
    echo "check_layers: FAILED"
fi
exit "$fail"
