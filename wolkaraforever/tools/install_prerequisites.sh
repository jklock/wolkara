#!/bin/bash
# Install and verify the Mac-side prerequisites for building WolkaraForever.
#
# What this script is for
# -----------------------
# Everything the build needs on the Mac, checked in one place, and installed when
# it is safe to do so. It is deliberately conservative:
#
#   * It never uses sudo, and never accepts a licence on your behalf.
#   * It never installs Xcode (that is the App Store) and never installs Homebrew
#     unless you explicitly pass --install-homebrew.
#   * It installs only the small Homebrew formulae the build needs: xcodegen,
#     git (with subtree), and python only if the system one is too old.
#   * It changes nothing when everything is already present.
#
# usage: wolkaraforever/tools/install_prerequisites.sh [options]
#
#   --check              Report only; install nothing.
#   --yes                Accepted for scripting; the script is non-interactive.
#   --install-homebrew   Run Homebrew's official installer if brew is missing.
#   -h, --help           Show this text.
#
# It cannot do these, and says so at the end:
#   * install Xcode (App Store), accept Xcode's licence (needs sudo),
#   * join the Apple Developer Program (paid membership is required),
#   * enable Developer Mode on the iPad or trust the Mac on it.
# The last two are handled by `wolkaraforever/tools/device_variables.sh`.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
root=$PWD

check=0
allow_brew_install=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) check=1;;
        --yes|-y) : ;;  # non-interactive already; accepted so callers can be uniform
        --install-homebrew) allow_brew_install=1;;
        -h|--help) sed -n '2,33p' "$0"; exit 0;;
        *) printf 'install_prerequisites: unknown option: %s\n' "$1" >&2; exit 2;;
    esac
    shift
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  OK      %s\n' "$*"; }
warn() { printf '  WARN    %s\n' "$*"; }
bad()  { printf '  MISSING %s\n' "$*"; fail=1; }
skip() { printf '  SKIP    %s\n' "$*"; }

fail=0
brew_bin=""

formula_installed() {
    [ -n "$brew_bin" ] && "$brew_bin" list --versions "$1" >/dev/null 2>&1
}

# Install a formula only when we are allowed to change the machine.
install_formula() {
    local name=$1
    if formula_installed "$name"; then return 0; fi
    if [ "$check" = 1 ]; then return 1; fi
    if [ -z "$brew_bin" ]; then return 1; fi
    say "  ... installing $name with Homebrew"
    HOMEBREW_NO_AUTO_UPDATE=1 "$brew_bin" install "$name" >/dev/null 2>&1 || return 1
    formula_installed "$name"
}

python_ok() {
    local py=$1
    [ -n "$py" ] || return 1
    "$py" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,9) else 1)' >/dev/null 2>&1
}

say "WolkaraForever Mac prerequisites"
say ""

# 1. macOS and architecture. The engine and device builds are arm64.
if [ "$(uname -s)" != "Darwin" ]; then
    bad "macOS (this is $(uname -s)); the build targets macOS"
    say "See docs/BUILDING.md for what is supported."
    exit 1
fi
ok "macOS $(sw_vers -productVersion)"
if [ "$(uname -m)" = "arm64" ]; then
    ok "Apple silicon ($(uname -m))"
else
    warn "Intel Mac ($(uname -m)); the documented path and device builds are arm64"
fi

# 2. Full Xcode. Command Line Tools alone cannot build or install the app.
xcode_path=$(xcode-select -p 2>/dev/null || true)
case "$xcode_path" in
    *Xcode*.app/Contents/Developer) xcode_ok=1 ;;
    *) xcode_ok=0 ;;
esac
if [ "$xcode_ok" = 1 ]; then
    if out=$(xcodebuild -version 2>&1); then
        ok "Xcode: $(printf '%s' "$out" | head -1)"
    else
        case "$out" in
            *license*|*License*) bad "Xcode licence not accepted (run: sudo xcodebuild -license accept)" ;;
            *) bad "xcodebuild failed: $(printf '%s' "$out" | head -1)" ;;
        esac
    fi
else
    bad "full Xcode (install it from the App Store, open it once, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer)"
fi

# 3. The tools Xcode ships that the device workflow uses.
if xcrun --find devicectl >/dev/null 2>&1; then
    ok "devicectl (Xcode device tooling)"
else
    bad "devicectl (comes with a current Xcode)"
fi
ios_sdk=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)
if [ -n "$ios_sdk" ]; then
    ok "iOS SDK $ios_sdk"
else
    bad "iOS SDK (open Xcode > Settings > Components and install the platform)"
fi

# 4. Homebrew, then the two formulae the build needs.
for candidate in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then brew_bin=$candidate; break; fi
done
if [ -z "$brew_bin" ]; then
    if [ "$allow_brew_install" = 1 ] && [ "$check" = 0 ]; then
        say "  ... installing Homebrew (official installer)"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
        for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            [ -x "$candidate" ] && brew_bin=$candidate && break
        done
    fi
fi
if [ -n "$brew_bin" ]; then
    eval "$("$brew_bin" shellenv 2>/dev/null)" || true
    ok "Homebrew ($brew_bin)"
else
    bad "Homebrew (install from https://brew.sh, or rerun with --install-homebrew)"
fi

# xcodegen generates the Xcode project.
if formula_installed xcodegen || command -v xcodegen >/dev/null 2>&1; then
    ok "xcodegen ($(xcodegen --version 2>/dev/null | head -1))"
elif install_formula xcodegen; then
    ok "xcodegen (installed)"
else
    bad "xcodegen (brew install xcodegen)"
fi

# git with subtree: our engine update uses `git subtree`.
if git --version >/dev/null 2>&1; then
    if [ -x "$(git --exec-path)/git-subtree" ] || command -v git-subtree >/dev/null 2>&1; then
        ok "git with subtree ($(git --version))"
    elif install_formula git; then
        if [ -x "$(git --exec-path)/git-subtree" ]; then
            ok "git with subtree (installed)"
        else
            warn "installed Homebrew git, but 'git' still resolves to $(git --version); put Homebrew's bin first in PATH"
        fi
    else
        bad "git with subtree (brew install git)"
    fi
else
    bad "git (brew install git)"
fi

# Python 3.9+ (the scripts use removeprefix and f-strings).
py=$(command -v python3 2>/dev/null || true)
if python_ok "$py"; then
    ok "Python 3 ($("$py" --version 2>&1))"
elif install_formula python; then
    py=$(command -v python3 2>/dev/null || true)
    if python_ok "$py"; then ok "Python 3 (installed)"; else bad "Python 3.9 or newer"; fi
else
    bad "Python 3.9 or newer (brew install python)"
fi

# 5. Local settings file, and disk space for the build.
if [ -f "$root/local.env" ]; then
    ok "local.env present"
else
    warn "no local.env yet; run: cp local.env.example local.env  then fill it in"
fi

free_gb=$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d ' ')
if [ -n "$free_gb" ]; then
    if [ "$free_gb" -lt 15 ]; then
        warn "only ${free_gb} GB free where the build lives; allow more if the build fails for space"
    else
        ok "${free_gb} GB free"
    fi
fi

say ""
if [ "$fail" = 0 ]; then
    say "All Mac prerequisites are present."
    say "Next: cp local.env.example local.env, fill it in, then"
    say "      wolkaraforever/tools/device_variables.sh --write"
    say "      wolkaraforever/tools/install.sh"
    exit 0
fi

say "Some requirements are missing (marked MISSING above)."
say "For what cannot be scripted: install Xcode from the App Store, accept its"
say "licence (sudo), join the Apple Developer Program, then set the iPad's"
say "Developer Mode and trust this Mac."
exit 1
