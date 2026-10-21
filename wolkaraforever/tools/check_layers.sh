#!/bin/bash
# The gate for the layer split: the platform stays upstream's, our patches apply,
# and the WolkaraForever project does not reach into another module's internals.
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

# 2. Nothing in platform/ mentions WolkaraForever: the platform stays brand-free.
brand=$(git grep -l -I -e WolkaraForever -e wolkaraforever -- platform 2>/dev/null | head -5)
if [ -z "$brand" ]; then
    ok "no WolkaraForever strings under platform/"
else
    bad "WolkaraForever strings under platform/ (must live in the layer):"
    printf '     %s\n' $brand
fi

# 3. Every patch applies to a fresh copy of the platform.
patches=$(ls wolkaraforever/patches/*.patch 2>/dev/null)
if [ -z "$patches" ]; then
    notice "no patches yet (wolkaraforever/patches/): the layer split has not started"
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
map=wolkaraforever/overlay.map
if [ ! -f "$map" ]; then
    bad "no wolkaraforever/overlay.map: the layer would not reach the build at all"
else
    orphans=$(while read -r f; do
                  # A mention anywhere counts, including the map's "not overlaid yet"
                  # line: a file that reaches the build no other way must be named there.
                  grep -q "$f" "$map" || echo "$f"
              done < <(git ls-files 'wolkaraforever/*' | grep -v -e '^wolkaraforever/patches/' -e '^wolkaraforever/tools/' \
                                              -e '^wolkaraforever/README.md' -e '^wolkaraforever/overlay.map') | head -5)
    if [ -n "$orphans" ]; then
        bad "layer files that the overlay does not carry (regenerate wolkaraforever/tools/overlay_map.sh):"
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
    if wolkaraforever/tools/overlay_map.sh "$generated" > /dev/null 2>&1 && [ -s "$generated" ] &&
       diff -q "$map" "$generated" > /dev/null 2>&1; then
        ok "wolkaraforever/overlay.map is what wolkaraforever/tools/overlay_map.sh generates"
    else
        bad "wolkaraforever/overlay.map is stale: regenerate it with wolkaraforever/tools/overlay_map.sh"
        diff "$map" "$generated" 2>/dev/null | head -12 | sed 's/^/     /'
    fi
    rm -f "$generated"
    # prepare.sh has the final say: it refuses a 'replace' without a platform file and
    # an 'add' that collides with a path upstream now has. Running it here proves the
    # overlay still matches the pin without touching the map. Its output is kept, not
    # discarded: on 2026-10-16 this check failed once and passed on the next run with
    # nothing to show for it, and a gate that cannot say why it refused is no gate.
    prepared=$(mktemp)
    if bash wolkaraforever/tools/prepare.sh > "$prepared" 2>&1; then
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
reach=$(grep -REl '#(import|include) +[<"](Touch|Fonts|TouchGamepad|TouchHaptics)' wolkaraforever/WoW 2>/dev/null | head -3)
[ -z "$reach" ] || bad "wolkaraforever/WoW reaches into wolkaraforever/Touch: use wolkaraforever/Bridge"
[ -n "$reach" ] || ok "no cross-module reach-in from WoW into Touch"
reach=$(grep -REl '#(import|include) +[<"](CASC|Client|Updater|Addon|Manifest|Installation|UpdateLock|WoW)' wolkaraforever/Touch 2>/dev/null | head -3)
[ -z "$reach" ] || bad "wolkaraforever/Touch reaches into wolkaraforever/WoW: use wolkaraforever/Bridge"
[ -n "$reach" ] || ok "no cross-module reach-in from Touch into WoW"

# 7. The root does not duplicate the platform any more. Documents, profiles and the
#    layer itself are ours; anything else outside platform/ must have nothing to do
#    with the platform's paths.
dupes=$(git ls-files | grep -v -e '^platform/' -e '^wolkaraforever/' -e '^development/' -e '^docs/' -e '^profiles/' -e '^\.github/' \
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
untracked=$(git ls-files --others --exclude-standard wolkaraforever | head -5)
if [ -z "$untracked" ]; then
    ok "every layer file is tracked, so the overlay map sees all of them"
else
    bad "untracked files under wolkaraforever/ will not reach the build (git add them first):"
    printf '     %s\n' $untracked
fi

# One owner of the audio session. The review outcome's Phase 1: everything else asks the coordinator.
# A second caller of these is how the session ended up somewhere nobody asked for - dictation taking
# it for recording while the CoreAudio adapter forced playback underneath.
# `setMode:` is deliberately not in this first scan: the layer has its own -setMode: for the voice
# mode, which has nothing to do with the audio session, and a gate that cries wolf gets turned off.
# It is checked below, where the only code scanned is the platform's, and a setMode there is one.
#
# Shell/SelfTest.m is the single exemption, and it is named rather than pattern-matched. Its
# --selftest=mic takes the session by hand on purpose: the coordinator has been in the path of every
# measurement made during this fault, and a test that asks the coordinator for the session cannot tell
# whether the coordinator is the reason the microphone arrives silent. The test is unreachable from the
# UI and runs only when the app is launched with --selftest=mic, so it cannot become a second owner in
# the app's own operation.
mutators=$(git grep -l -e 'setCategory:' -e 'setActive:' -e 'setPreferredInput:' -- wolkaraforever 2>/dev/null | grep -E '\.(m|h)$' | grep -v "AudioSessionCoordinator" | grep -v "/tests/" | grep -v "Shell/SelfTest.m" | head -5)
if [ -z "$mutators" ]; then
    ok "the audio session has one owner"
else
    bad "only Voice/AudioSessionCoordinator may mutate the audio session:"
    printf '     %s\n' $mutators
fi

# The scan above only sees wolkaraforever/*.m and *.h, and the session's second owner was in the CoreAudio
# patch: a unified diff, so a grep for source files walked straight past it and "the audio session has
# one owner" passed while the adapter still forced the category. The patch's added lines and the file
# prepare.sh generates from them are both checked now - the review outcome's Phase 1 asks for the gate
# to look at what is built, not only at the layer's sources.
patchMutators=$(grep -hE "^\+.*(setCategory:|setActive:|setMode:|setPreferredInput:)" wolkaraforever/patches/*.patch 2>/dev/null | head -3)
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

# 8. This project supports WoW Forever and nothing else. No other game may be named in
#    anything the repository owns: the layer, the root documents, the profiles, the tools
#    and the tests. The list is deliberately word-matched, so "switcher" is not a Witcher
#    and "HOTAS" is not HotA. platform/ is upstream's pinned mirror, checked byte for byte
#    by check 1, and is the only place another game can still appear until that mirror is
#    forked; everything we write, ship or read is covered here.
otherGames='cyberpunk|hota|h3hota|heroes|homm|megabonk|witcher|diablo|starcraft|overwatch|hearthstone|skyrim|fallout|minecraft|elden|baldur|quake|doom'
# This script is the one exemption: it has to spell the names to forbid them.
named=$(git ls-files | grep -v -e '^platform/' -e '^wolkaraforever/tools/check_layers.sh$' | while IFS= read -r file; do
            [ -f "$file" ] && grep -I -i -q -w -E "$otherGames" "$file" 2>/dev/null && echo "$file"
        done | head -5)
if [ -z "$named" ]; then
    ok "no game other than WoW Forever is named outside platform/ (upstream's mirror)"
else
    bad "this repository is WoW Forever only; these files name another game:"
    printf '     %s\n' $named
fi

if [ "$fail" -eq 0 ]; then
    echo "check_layers: OK"
else
    echo "check_layers: FAILED"
fi
exit "$fail"
