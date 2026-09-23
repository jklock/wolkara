# Sourced by the shell tools: read the ignored local.env (KEY=value lines).
# Settings already in the environment win, as in tools/localenv.py, so
# `TOLKARA_MODE=local-signing tools/run.sh sim` works with any local.env.
tolkara_load_env() {
    local given
    # Re-export: 'declare -x', as bash lists it, would be local to this function.
    # POSIX mode lists 'export NAME=' instead; accept both.
    given=$(export -p | sed -n -E 's/^(declare -x|export) ((DEVELOPMENT_TEAM|TOLKARA_[A-Z_]+|DEVICE|SIMULATOR|GUEST_EXE|SIGN_IDENTITY)=)/export \2/p')
    if [ -f local.env ]; then set -a; . ./local.env; set +a; fi
    eval "$given"
}
