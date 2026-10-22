# Sourced by the layer's tools: read the repository root's ignored local.env into the
# environment. Values already set win, exactly as the platform's own tools/localenv.sh
# does, so `TOLKARA_MODE=local-signing wolkaraforever/tools/install.sh` works with any
# local.env. The root local.env is the single contract; the prepared tree carries no
# copy of its own.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export ROOT
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
# No match is the normal case - a shell that has not sourced this file before
# exports none of these names - and `grep -v` exits 1 when it filters everything
# away. Under pipefail and `set -e` that killed the caller before it did anything,
# silently: install.sh printed nothing and exited 1. `|| true` makes "nothing
# given" mean nothing given.
given=$(export -p | sed -n -E 's/^(declare -x|export) ((DEVELOPMENT_TEAM|TOLKARA_[A-Z_]+|DEVICE|SIMULATOR|GUEST_EXE|NATIVE_GUEST_SHIMS|SIGN_IDENTITY)=.*)$/export \2/p' | grep -v -E "^export [A-Z_]+=(\"\"|'')?$" || true)
if [ -f "$ROOT/local.env" ]; then set -a; . "$ROOT/local.env"; set +a; fi
eval "$given"
# The product's display name is the layer's, not the platform's.
export TOLKARA_DISPLAY_NAME=${TOLKARA_DISPLAY_NAME:-WolkaraForever}
