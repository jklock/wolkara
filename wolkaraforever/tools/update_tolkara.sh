#!/bin/bash
# Update the vendored Tolkara engine (platform/) from its source repository.
#
# WolkaraForever uses the most current Tolkara. The engine is a git subtree of
# the Tolkara repository at platform/, kept byte-identical to upstream/main and
# never edited by hand. This script fetches the source repo, reports what is new,
# pulls it in with `git subtree pull --squash`, and then proves the layer still
# fits with check_layers.sh (patches apply, overlay matches, no cross-module
# reach-in).
#
# usage: wolkaraforever/tools/update_tolkara.sh [options]
#
#   --check, --dry-run   Report only: is platform/ current, and what changed.
#                        Changes nothing and does not require a clean tree.
#   --test               Run test_emulation.sh after the gate passes.
#   --install            Run install.sh after the gate (and tests) pass.
#   --allow-dirty        Proceed even with uncommitted changes (risky: the pull
#                        commits the subtree merge, but your other edits stay
#                        uncommitted and can conflict).
#   --remote NAME        Git remote for Tolkara   (default: upstream)
#   --branch NAME        Branch to take           (default: main)
#
# Environment: TOLKARA_REMOTE, TOLKARA_URL, TOLKARA_BRANCH.
#
# Exit status: 0 current/updated; 1 updated but the layer no longer fits; 2 error.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
root=$PWD

remote=${TOLKARA_REMOTE:-upstream}
url=${TOLKARA_URL:-https://github.com/tolkara/tolkara.git}
branch=${TOLKARA_BRANCH:-main}
check=0; tests=0; install=0; allow_dirty=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check|--dry-run) check=1;;
        --test) tests=1;;
        --install) install=1;;
        --allow-dirty) allow_dirty=1;;
        --remote) shift; remote=${1:?--remote needs a name};;
        --branch) shift; branch=${1:?--branch needs a name};;
        -h|--help) sed -n '2,30p' "$0"; exit 0;;
        *) printf 'update_tolkara: unknown option: %s\n' "$1" >&2; exit 2;;
    esac
    shift
done

say() { printf '%s\n' "$*"; }
die() { printf 'update_tolkara: %s\n' "$*" >&2; exit 2; }

# 1. git subtree must exist; it is a contributed git command.
if [ ! -x "$(git --exec-path)/git-subtree" ] && ! command -v git-subtree >/dev/null 2>&1; then
    die "git-subtree is not available. Install Git with subtree support (brew install git) and retry."
fi

# 2. The remote may not exist in a fresh clone; add it, but never overwrite one.
if ! git remote get-url "$remote" >/dev/null 2>&1; then
    say "no '$remote' remote; adding $url"
    git remote add "$remote" "$url" || die "cannot add remote '$remote'"
fi

# 3. Fetch the source repository.
say "fetching $remote ($(git remote get-url "$remote"))"
git fetch "$remote" || die "cannot fetch '$remote'"
if ! git rev-parse --quiet --verify "$remote/$branch" >/dev/null; then
    die "'$remote/$branch' does not exist after fetch"
fi

# 4. Compare the vendored tree with the source branch. Trees, not commit
#    histories: a subtree squash drops the upstream history, so the tree is the
#    honest comparison, and check_layers.sh uses the same one.
old_tree=$(git rev-parse "HEAD:platform" 2>/dev/null) || die "platform/ is not vendored; run git subtree add --prefix=platform $remote $branch --squash"
new_tree=$(git rev-parse "$remote/$branch^{tree}")
new_commit=$(git rev-parse --short "$remote/$branch")
say "platform/ tree:     ${old_tree:0:12}"
say "$remote/$branch: ${new_commit}  $(git log -1 --format='%s' "$remote/$branch")"

# 5. Say how far behind the vendored copy is, when the history is available.
#    The vendored upstream commit is named in the newest subtree squash message.
#    Path-filtered `git log -- platform` hides it behind the merge, so walk the
#    full history instead.
vendored=$(git log --format=%s HEAD 2>/dev/null \
    | sed -n "s/^Squashed 'platform\/' content from commit \([0-9a-f][0-9a-f]*\).*/\1/p" \
    | head -1)
if [ -n "$vendored" ]; then
    if git cat-file -e "${vendored}^{commit}" 2>/dev/null; then
        behind=$(git rev-list --count "$vendored..$remote/$branch" 2>/dev/null || echo "?")
        if [ "$behind" = "0" ]; then
            say "vendored upstream commit: $vendored (current)"
        else
            say "vendored upstream commit: $vendored ($behind new commit(s) on $remote/$branch)"
            git --no-pager log --oneline "$vendored..$remote/$branch" | sed 's/^/  /'
        fi
    else
        say "vendored upstream commit: $vendored (not in this clone; fetch to see its history)"
    fi
fi

# 6. Already current: nothing to do.
if [ "$old_tree" = "$new_tree" ]; then
    say "platform/ is the most current Tolkara ($new_commit). Nothing to update."
    exit 0
fi

# 7. Report-only mode.
if [ "$check" = 1 ]; then
    say "update available: $new_commit"
    say "engine files that would change:"
    git --no-pager diff --stat "$old_tree" "$new_tree" | sed 's/^/  /'
    exit 0
fi

# 8. Refuse to pull onto uncommitted work that could conflict.
dirty=$(git status --porcelain -- . ':!build' ':!logs')
if [ -n "$dirty" ] && [ "$allow_dirty" != 1 ]; then
    printf '%s\n' "update_tolkara: the working tree has uncommitted changes. Commit them, or pass --allow-dirty:" >&2
    printf '%s\n' "$dirty" | head -20 | sed 's/^/  /' >&2
    exit 2
fi

# 9. Pull the engine in. --squash keeps our single-vendored-copy shape; the
#    pull creates its own merge commit, so platform/ ends up at the new tree.
say "pulling $remote/$branch into platform/ (git subtree pull --squash)"
if ! git subtree pull --prefix=platform "$remote" "$branch" --squash; then
    die "subtree pull failed; platform/ was not updated. Resolve the conflict and retry."
fi

# 10. Prove the layer still fits. A failure here means the engine moved under a
#     patch or an overlay entry; the engine is not edited by hand to fix it.
if ! bash wolkaraforever/tools/check_layers.sh; then
    cat >&2 <<'MSG'
update_tolkara: platform/ is updated, but the layer no longer fits (see the FAIL lines above).
  - Fix the named patch in wolkaraforever/patches/ so it applies to the new platform.
  - Fix any overlay mismatch: regenerate with wolkaraforever/tools/overlay_map.sh,
    then correct wolkaraforever/overlay.map.
  - Re-run: wolkaraforever/tools/check_layers.sh
  - To undo this update: git reset --hard HEAD^   (only if you have no other uncommitted work)
MSG
    exit 1
fi
say "check_layers: PASS"

# 11. Optional follow-through.
if [ "$tests" = 1 ]; then
    say "running the suites (test_emulation.sh)"
    bash wolkaraforever/tools/test_emulation.sh || die "test_emulation.sh failed"
fi
if [ "$install" = 1 ]; then
    say "building and installing (install.sh)"
    bash wolkaraforever/tools/install.sh || die "install.sh failed"
fi

say "done: platform/ is now $remote/$branch ($new_commit)"
