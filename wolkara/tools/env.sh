# Sourced by the layer's tools: read the repository root's ignored local.env into the
# environment. Values already set win, exactly as the platform's own tools/localenv.sh
# does, so `TOLKARA_MODE=local-signing wolkara/tools/install.sh` works with any
# local.env. The root local.env is the single contract; the prepared tree carries no
# copy of its own.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export ROOT
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
given=$(export -p | sed -n -E 's/^(declare -x|export) ((DEVELOPMENT_TEAM|TOLKARA_[A-Z_]+|DEVICE|SIMULATOR|GUEST_EXE|NATIVE_GUEST_SHIMS|SIGN_IDENTITY)=)/export \2/p')
if [ -f "$ROOT/local.env" ]; then set -a; . "$ROOT/local.env"; set +a; fi
eval "$given"
# The product's display name is the layer's, not the platform's.
export TOLKARA_DISPLAY_NAME=${TOLKARA_DISPLAY_NAME:-Wolkara Forever}
