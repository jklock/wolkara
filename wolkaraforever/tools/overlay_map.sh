#!/bin/bash
# Regenerate wolkaraforever/overlay.map from the layer's tracked files.
#
# The map is what prepare.sh copies into the prepared tree: each layer file, the
# platform path it belongs at, and whether it replaces a platform file or adds a new
# one. Run this after adding, moving or removing a layer file; prepare.sh enforces the
# result, so a stale map stops the build instead of dropping a file.
#
# Writes wolkaraforever/overlay.map, or the path given as the first argument. check_layers.sh
# calls it with a temporary path to prove the committed map is exactly what this
# script produces - a hand-edited map is how a layer file silently stops reaching the
# build, which has happened once already.
set -eu
cd "$(dirname "$0")/../.." || exit 2

out=${1:-wolkaraforever/overlay.map}

intent() {
    if git cat-file -e "HEAD:platform/$1" 2>/dev/null; then echo replace; else echo add; fi
}

{
    echo "# WolkaraForever overlay: layer file, path in the prepared tree, and what it means."
    echo "#   replace - the pinned platform has this file and ours takes its place."
    echo "#   add     - the platform has no such path; ours is new."
    echo "# prepare.sh enforces both: a missing 'replace' destination, or an 'add' that"
    echo "# collides with a path upstream now has, stops the build. An ingest therefore"
    echo "# cannot silently drop our file or overwrite one of theirs."
    echo "#"
    echo "# Regenerate with wolkaraforever/tools/overlay_map.sh after changing the layer."
    echo "#"
    echo "# Shell: the app's own shell, branding, icon art and its test"
    git ls-files wolkaraforever/Shell | while read -r f; do
        case "$f" in
            wolkaraforever/Shell/Info.plist) dst=launcher/Info.plist;;
            wolkaraforever/Shell/Integrated-Info.plist) dst=authorization/App/Integrated-Info.plist;;
            wolkaraforever/Shell/Assets.xcassets/*) dst=launcher/${f#wolkaraforever/Shell/};;
            wolkaraforever/Shell/artwork/*) dst=artwork/wolkaraforever/${f#wolkaraforever/Shell/artwork/};;
            wolkaraforever/Shell/tests/*) dst=tests/${f#wolkaraforever/Shell/tests/};;
            *) dst=launcher/App/${f#wolkaraforever/Shell/};;
        esac
        echo "$f $dst $(intent "$dst")"
    done
    echo "#"
    echo "# WoW: the launcher module, its test script source and its tests"
    git ls-files wolkaraforever/WoW | while read -r f; do
        case "$f" in
            wolkaraforever/WoW/wow_cdn.m) dst=tools/wow_cdn.m;;
            wolkaraforever/WoW/tests/*) dst=tests/${f#wolkaraforever/WoW/tests/};;
            *) dst=launcher/WoW/${f#wolkaraforever/WoW/};;
        esac
        echo "$f $dst $(intent "$dst")"
    done
    echo "#"
    echo "# Touch: the on-screen controls, the gamepad, haptics and the adapter's fonts"
    git ls-files wolkaraforever/Touch | while read -r f; do
        case "$f" in
            wolkaraforever/Touch/tests/*) dst=tests/${f#wolkaraforever/Touch/tests/};;
            *) dst=translation/AppKit/${f#wolkaraforever/Touch/};;
        esac
        echo "$f $dst $(intent "$dst")"
    done
    echo "#"
    echo "# Bridge: what the patched platform files and the public APIs call into"
    git ls-files wolkaraforever/Bridge | while read -r f; do
        case "$f" in
            wolkaraforever/Bridge/tests/*) dst=tests/${f#wolkaraforever/Bridge/tests/};;
            wolkaraforever/Bridge/BackgroundPacing.m) dst=translation/Metal/BackgroundPacing.m;;
            wolkaraforever/Bridge/LocalServiceRetry.*) dst=authorization/App/${f#wolkaraforever/Bridge/};;
            *) echo "# not overlaid yet (source of a pending patch): $f"; continue;;
        esac
        echo "$f $dst $(intent "$dst")"
    done
    echo "#"
    echo "# Controller: what the pad reports, and every change to it (diagnostic)"
    git ls-files wolkaraforever/Controller | while read -r f; do
        dst=launcher/Controller/${f#wolkaraforever/Controller/}
        echo "$f $dst $(intent "$dst")"
    done
    echo "#"
    echo "# Voice: what you say, turned into text in the game, and its tests"
    git ls-files wolkaraforever/Voice | while read -r f; do
        case "$f" in
            wolkaraforever/Voice/tests/*) dst=tests/${f#wolkaraforever/Voice/tests/};;
            *) dst=launcher/Voice/${f#wolkaraforever/Voice/};;
        esac
        echo "$f $dst $(intent "$dst")"
    done
    echo "#"
    echo "# Input: any button, on any controller, in one stream (see docs/INPUT_TRIGGERS.md)"
    git ls-files wolkaraforever/Input | while read -r f; do
        case "$f" in
            wolkaraforever/Input/tests/*) dst=tests/${f#wolkaraforever/Input/tests/};;
            *) dst=launcher/Input/${f#wolkaraforever/Input/};;
        esac
        echo "$f $dst $(intent "$dst")"
    done
    echo "#"
    echo "# CoreAudio: the audio adapter's test, which has to supply the host that asks"
    echo "# for the game's playback lease. Patch 0005 stopped the adapter taking the"
    echo "# session itself, so a bare test process has no route to report."
    git ls-files wolkaraforever/CoreAudio | while read -r f; do
        case "$f" in
            wolkaraforever/CoreAudio/tests/*) dst=tests/${f#wolkaraforever/CoreAudio/tests/};;
            *) echo "# not overlaid yet (source of a pending patch): $f"; continue;;
        esac
        echo "$f $dst $(intent "$dst")"
    done
    echo "#"
    echo "# Notices: this repository's own licence and notice, which the packaged app must"
    echo "# carry. The prepared tree already has a LICENSE and a NOTICE.md at its top level,"
    echo "# and those are upstream's, so ours travel under names of their own: both have to"
    echo "# ship, because the app contains upstream's code as well as ours. The app's About"
    echo "# page names all four, which is the only way a reader can tell whose is whose."
    for f in LICENSE NOTICE.md; do
        echo "$f WolkaraForever-$f $(intent "WolkaraForever-$f")"
    done
} > "$out"

entries=$(awk '!/^#/ && NF==3' "$out" | wc -l | tr -d ' ')
replaced=$(awk '!/^#/ && $3=="replace"' "$out" | wc -l | tr -d ' ')
added=$(awk '!/^#/ && $3=="add"' "$out" | wc -l | tr -d ' ')
echo "overlay_map: $out: $entries entries ($replaced replace, $added add)"
