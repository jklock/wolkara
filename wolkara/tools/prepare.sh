#!/bin/bash
# Prepare the tree we build from: a pristine export of platform/ with the layer's
# patches applied. platform/ itself is never edited - it stays byte-identical to
# upstream, and every Wolkara change to it is a patch under wolkara/patches/.
#
# build/ is ignored output, so the prepared tree can be deleted at any time.
set -eu
cd "$(dirname "$0")/../.." || exit 2
root=$PWD

# Say it out loud when the tree is dirty. platform/ comes from `git archive HEAD`, but
# the overlay files come from the working tree, so a prepared tree can carry uncommitted
# code while the platform half is a commit. That is fine while developing and not fine
# as evidence, so the state is printed here and wolkara/tools/validate.sh - which is
# what produces evidence - refuses to run at all unless the tree is clean.
dirty=$(git status --porcelain)
if [ -n "$dirty" ]; then
    echo "prepare: the working tree is dirty; this tree carries uncommitted layer code" >&2
    printf '%s\n' "$dirty" | head -20 | sed 's/^/         /' >&2
    [ "$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')" -le 20 ] || echo "         (and more)" >&2
fi

dest=build/platform
patches=$(ls wolkara/patches/*.patch 2>/dev/null || true)

# Clearing the previous tree can lose a race with something writing into it - Spotlight,
# or a build that has just finished and is still closing files - and `rm -rf` then fails
# with "Directory not empty". That used to abort the whole install, which is a confusing
# way to fail for a reason that has nothing to do with the app. One retry, then a clear
# message.
if ! rm -rf "$dest" 2>/dev/null; then
    sleep 1
    rm -rf "$dest" 2>/dev/null || { echo "prepare: cannot clear $dest - something is holding it" >&2; exit 1; }
fi
mkdir -p "$dest"
git archive HEAD:platform | tar -x -C "$dest" || {
    echo "prepare: cannot export platform/ - is it vendored?" >&2
    exit 1
}

# The layer is applied by apply.sh, which is also what adopt.sh runs on somebody
# else's tolkara tree: one implementation, so the two can never drift apart.
bash wolkara/tools/apply.sh "$dest"

# And the project is generated *after* the overlay, never before. The overlay carries new layer files
# into the tree, and a project generated from a tree that did not have them yet never compiles them: the
# file is present, the build succeeds, and every call into it resolves to nil at runtime. That is what
# happened with the audio session coordinator - the app shipped without it, with no linker error, and
# the only symptom was that its calls did nothing.
(cd "$dest" && bash tools/generate.sh)

pinned=$(git rev-parse --short upstream/main 2>/dev/null || echo unknown)
echo "prepare: $dest ready (platform $pinned)"
