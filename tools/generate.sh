#!/bin/bash
# Generate Tolkara.xcodeproj with the builder's own signing team and identifiers.
# Values come from the ignored local.env (see local.env.example); none are committed.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f local.env ] && { set -a; . ./local.env; set +a; }
export DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-}
export TOLKARA_BUNDLE_ID=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
export TOLKARA_KEYCHAIN_GROUP=${TOLKARA_KEYCHAIN_GROUP:-local.tolkara.authorization}
xcodegen generate -q "$@"
