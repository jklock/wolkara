#!/bin/bash
# Regenerate wolkara/overlay.map from the layer's tracked files.
#
# The map is what prepare.sh copies into the prepared tree: each layer file, the
# platform path it belongs at, and whether it replaces a platform file or adds a new
# one. Run this after adding, moving or removing a layer file; prepare.sh enforces the
# result, so a stale map stops the build instead of dropping a file.
set -eu
cd "$(dirname "$0")/../.." || exit 2

intent() {
    if git cat-file -e "HEAD:platform/$1" 2>/dev/null; then echo replace; else echo add; fi
}

{
    echo "# Wolkara overlay: layer file, path in the prepared tree, and what it means."
    echo "#   replace - the pinned platform has this file and ours takes its place."
    echo "#   add     - the platform has no such path; ours is new."
    echo "# prepare.sh enforces both: a missing 'replace' destination, or an 'add' that"
    echo "# collides with a path upstream now has, stops the build. An ingest therefore"
    echo "# cannot silently drop our file or overwrite one of theirs."
    echo "#"
    echo "# Regenerate with wolkara/tools/overlay_map.sh after changing the layer."
    echo "#"
    echo "# Shell: the app's own shell, branding, icon art and its test"
    git ls-files wolkara/Shell | while read -r f; do
        case "$f" in
            wolkara/Shell/Info.plist) dst=launcher/Info.plist;;
            wolkara/Shell/Integrated-Info.plist) dst=authorization/App/Integrated-Info.plist;;
            wolkara/Shell/Assets.xcassets/*) dst=launcher/${f#wolkara/Shell/};;
            wolkara/Shell/artwork/*) dst=artwork/wolkara/${f#wolkara/Shell/artwork/};;
            wolkara/Shell/tests/*) dst=tests/${f#wolkara/Shell/tests/};;
            *) dst=launcher/App/${f#wolkara/Shell/};;
        esac
        echo "$f $dst $(intent "$dst")"
    done
    echo "#"
    echo "# WoW: the launcher module, its test script source and its tests"
    git ls-files wolkara/WoW | while read -r f; do
        case "$f" in
            wolkara/WoW/wow_cdn.m) dst=tools/wow_cdn.m;;
            wolkara/WoW/tests/*) dst=tests/${f#wolkara/WoW/tests/};;
            *) dst=launcher/WoW/${f#wolkara/WoW/};;
        esac
        echo "$f $dst $(intent "$dst")"
    done
    echo "#"
    echo "# Touch: the on-screen controls, the gamepad, haptics and the adapter's fonts"
    git ls-files wolkara/Touch | while read -r f; do
        case "$f" in
            wolkara/Touch/tests/*) dst=tests/${f#wolkara/Touch/tests/};;
            *) dst=translation/AppKit/${f#wolkara/Touch/};;
        esac
        echo "$f $dst $(intent "$dst")"
    done
    echo "#"
    echo "# Bridge: what the patched platform files and the public APIs call into"
    git ls-files wolkara/Bridge | while read -r f; do
        case "$f" in
            wolkara/Bridge/tests/*) dst=tests/${f#wolkara/Bridge/tests/};;
            wolkara/Bridge/BackgroundPacing.m) dst=translation/Metal/BackgroundPacing.m;;
            wolkara/Bridge/LocalServiceRetry.*) dst=authorization/App/${f#wolkara/Bridge/};;
            *) echo "# not overlaid yet (source of a pending patch): $f"; continue;;
        esac
        echo "$f $dst $(intent "$dst")"
    done
} > wolkara/overlay.map

entries=$(awk '!/^#/ && NF==3' wolkara/overlay.map | wc -l | tr -d ' ')
replaced=$(awk '!/^#/ && $3=="replace"' wolkara/overlay.map | wc -l | tr -d ' ')
added=$(awk '!/^#/ && $3=="add"' wolkara/overlay.map | wc -l | tr -d ' ')
echo "overlay_map: $entries entries ($replaced replace, $added add)"
