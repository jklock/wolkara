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
        # The scratch tree is outside the repository, so paths resolve against it.
        if git -C "$scratch" apply --check "$root/$patch" 2>/dev/null; then
            if git -C "$scratch" apply "$root/$patch" 2>/dev/null &&
               git -C "$scratch" apply --check --reverse "$root/$patch" 2>/dev/null; then
                applied=$((applied + 1))
            else
                bad "$(basename "$patch") applied but changed nothing: does apply silently skip it?"
            fi
        else
            bad "$(basename "$patch") does not apply to platform/ as pinned"
        fi
    done
    [ "$applied" -eq 0 ] || ok "$applied patch(es) apply cleanly"
fi

# 4. The layer reaches the build exactly once, and only through the overlay: every
#    layer file is mapped (or deliberately not), every mapped source exists and is
#    tracked, and nothing in the layer can be silently left out of the build.
map=wolkara/overlay.map
if [ ! -f "$map" ]; then
    bad "no wolkara/overlay.map: the layer would not reach the build at all"
else
    orphans=$(while read -r f; do
                  # A mention anywhere counts, including the map's "not overlaid yet"
                  # line: a file that reaches the build no other way must be named there.
                  grep -q "$f" "$map" || echo "$f"
              done < <(git ls-files 'wolkara/*' | grep -v -e '^wolkara/patches/' -e '^wolkara/tools/' \
                                              -e '^wolkara/README.md' -e '^wolkara/overlay.map') | head -5)
    if [ -n "$orphans" ]; then
        bad "layer files that the overlay does not carry (regenerate wolkara/tools/overlay_map.sh):"
        printf '     %s\n' $orphans
    else
        ok "every layer file is carried by the overlay"
    fi
    gone=$(awk '!/^#/ && NF==3 {print $1}' "$map" | while read -r src; do
               [ -e "$src" ] || echo "$src"
           done | head -5)
    if [ -n "$gone" ]; then
        bad "the overlay names layer files that are not there:"
        printf '     %s\n' $gone
    else
        ok "every overlayed file exists in the layer"
    fi
    # The map is generated, so it must equal what the generator produces now. Without
    # this, a map edited by hand passes the orphan check while a whole module's entries
    # quietly stop existing - which is exactly what happened to Controller, Voice and
    # Input before this check was added.
    generated=$(mktemp)
    if wolkara/tools/overlay_map.sh "$generated" > /dev/null 2>&1 && [ -s "$generated" ] &&
       diff -q "$map" "$generated" > /dev/null 2>&1; then
        ok "wolkara/overlay.map is what wolkara/tools/overlay_map.sh generates"
    else
        bad "wolkara/overlay.map is stale: regenerate it with wolkara/tools/overlay_map.sh"
        diff "$map" "$generated" 2>/dev/null | head -12 | sed 's/^/     /'
    fi
    rm -f "$generated"
    # prepare.sh has the final say: it refuses a 'replace' without a platform file and
    # an 'add' that collides with a path upstream now has. Running it here proves the
    # overlay still matches the pin without touching the map. Its output is kept, not
    # discarded: on 2026-10-16 this check failed once and passed on the next run with
    # nothing to show for it, and a gate that cannot say why it refused is no gate.
    prepared=$(mktemp)
    if bash wolkara/tools/prepare.sh > "$prepared" 2>&1; then
        ok "prepare.sh accepts the overlay against the pinned platform"
    else
        bad "prepare.sh refused the overlay: it no longer matches the pinned platform"
        tail -12 "$prepared" | sed 's/^/     /'
    fi
    rm -f "$prepared"
fi

# 5. Every replacement must really be ours. A file we never changed must not take a
#    platform path: overlaying it would silently drop whatever upstream has done to
#    theirs since the split. This is the mistake this check exists to prevent.
base=$(git merge-base upstream/main HEAD 2>/dev/null)
if [ -z "$base" ]; then
    notice "no merge base with upstream/main: the replacement check cannot run"
else
    unchanged=""
    while read -r src dst intent; do
        [ "$intent" = replace ] || continue
        if git cat-file -e "$base:$dst" 2>/dev/null && cmp -s "$src" <(git show "$base:$dst"); then
            unchanged="$unchanged $dst"
        fi
    done < <(awk '!/^#/ && NF==3' "$map")
    if [ -n "$unchanged" ]; then
        bad "these replacements are identical to the pre-split base, so we never changed them - take upstream's instead:"
        printf '     %s\n' $unchanged
    else
        ok "every replacement is a change of ours"
    fi
fi

# 6. The layer's modules stay independent: WoW must not reach into Touch, or the other
#    way round. Shared needs go through Bridge.
reach=$(grep -REl '#(import|include) +[<"](Touch|Fonts|TouchGamepad|TouchHaptics)' wolkara/WoW 2>/dev/null | head -3)
[ -z "$reach" ] || bad "wolkara/WoW reaches into wolkara/Touch: use wolkara/Bridge"
[ -n "$reach" ] || ok "no cross-module reach-in from WoW into Touch"
reach=$(grep -REl '#(import|include) +[<"](CASC|Client|Updater|Addon|Manifest|Installation|UpdateLock|WoW)' wolkara/Touch 2>/dev/null | head -3)
[ -z "$reach" ] || bad "wolkara/Touch reaches into wolkara/WoW: use wolkara/Bridge"
[ -n "$reach" ] || ok "no cross-module reach-in from Touch into WoW"

# 7. The root does not duplicate the platform any more. Documents, profiles and the
#    layer itself are ours; anything else outside platform/ must have nothing to do
#    with the platform's paths.
dupes=$(git ls-files | grep -v -e '^platform/' -e '^wolkara/' -e '^development/' -e '^docs/' -e '^profiles/' -e '^\.github/' \
                          | grep '/' | while read -r f; do
            [ -e "platform/$f" ] && echo "$f"
        done | head -5)
if [ -n "$dupes" ]; then
    bad "the root still carries platform paths:"
    printf '     %s\n' $dupes
else
    ok "the root carries no platform path"
fi

# A new layer file that has not been added to git never reaches the prepared tree: the overlay map is
# generated from git's tracked files, so the file is not in the map, and the build then fails with a
# missing header rather than with the real problem. This happened while the audio session coordinator
# was added, and the check above could not catch it because the map and the check ignored the same
# file. The review outcome's Phase 4 asks for the tooling to fail on its own mistakes.
untracked=$(git ls-files --others --exclude-standard wolkara | head -5)
if [ -z "$untracked" ]; then
    ok "every layer file is tracked, so the overlay map sees all of them"
else
    bad "untracked files under wolkara/ will not reach the build (git add them first):"
    printf '     %s\n' $untracked
fi

# One owner of the audio session. The review outcome's Phase 1: everything else asks the coordinator.
# A second caller of these is how the session ended up somewhere nobody asked for - dictation taking
# it for recording while the CoreAudio adapter forced playback underneath.
# `setMode:` is deliberately not in this first scan: the layer has its own -setMode: for the voice
# mode, which has nothing to do with the audio session, and a gate that cries wolf gets turned off.
# It is checked below, where the only code scanned is the platform's, and a setMode there is one.
mutators=$(git grep -l -e 'setCategory:' -e 'setActive:' -e 'setPreferredInput:' -- wolkara 2>/dev/null | grep -E '\.(m|h)$' | grep -v "AudioSessionCoordinator" | grep -v "/tests/" | head -5)
if [ -z "$mutators" ]; then
    ok "the audio session has one owner"
else
    bad "only Voice/AudioSessionCoordinator may mutate the audio session:"
    printf '     %s\n' $mutators
fi

# The scan above only sees wolkara/*.m and *.h, and the session's second owner was in the CoreAudio
# patch: a unified diff, so a grep for source files walked straight past it and "the audio session has
# one owner" passed while the adapter still forced the category. The patch's added lines and the file
# prepare.sh generates from them are both checked now - the review outcome's Phase 1 asks for the gate
# to look at what is built, not only at the layer's sources.
patchMutators=$(grep -hE "^\+.*(setCategory:|setActive:|setMode:|setPreferredInput:)" wolkara/patches/*.patch 2>/dev/null | head -3)
# Every prepared platform file that has ever taken the session, not only the first one found. The
# second owner was AudioToolbox, and a gate that watches one file passes for as long as the leak is in
# the other - which is exactly how it was missed.
preparedMutators=$(for prepared in build/platform/translation/CoreAudio/Hardware.m \
                                build/platform/translation/AudioToolbox/Output.m; do
    [ -f "$prepared" ] || continue
    grep -hE "setCategory:|setActive:|setMode:|setPreferredInput:" "$prepared" 2>/dev/null | head -3
done)
if [ -z "$patchMutators" ] && [ -z "$preparedMutators" ]; then
    ok "no patch and no prepared platform file mutates the audio session"
else
    bad "the audio session has more than one owner (patch or prepared tree):"
    printf '     %s\n' $patchMutators $preparedMutators
fi

if [ "$fail" -eq 0 ]; then
    echo "check_layers: OK"
else
    echo "check_layers: FAILED"
fi
exit "$fail"
