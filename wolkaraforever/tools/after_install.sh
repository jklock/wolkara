#!/bin/bash
# What happens after the app is on the device, decided by the execution mode.
#
# Run from inside the prepared tree (build/platform) with the mode as its argument.
# Split out of install.sh so it can be tested without building anything: the test puts
# a stub `enroll.sh` and a stub `xcrun` in front of it and asserts which of them the
# mode actually reaches for.
#
# Why it is not one unconditional step any more: install.sh used to run the platform's
# enroll.sh after every install. Enrolling is developer-service work - it pairs the
# app with the developer service so that service can prepare memory - and it is wrong
# for the other two modes. Local signing signs page containers with the user's own
# identity and never touches the service; External JIT is prepared by a JIT enabler at
# launch and the runtime refuses to enter the guest while anything is attached. Doing
# it anyway is unrelated work against a service the mode does not use. See
# development/STABILITY_AUDIT_2026-10-16.md.
#
# usage: after_install.sh [developer-service|local-signing|external-jit|""]
set -uo pipefail

mode=${1:-}
bundle=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
device=${DEVICE:-}

step() { printf '\n== %s\n' "$*"; }
die() { printf 'after_install: %s\n' "$*" >&2; exit 2; }

[ -n "$device" ] || die "Set DEVICE=<iPad UDID> in local.env (see local.env.example)."

# The page container for an executable is named after the SHA-256 of that executable,
# because that is what the runtime looks for at launch.
page_container_sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Which page containers the app should be holding for the executables this build was
# made against. Empty in a generic build, where there is nothing to sign for.
expected_containers() {
    local exe
    [ -n "${GUEST_EXE:-}" ] || return 0
    IFS=: read -r -a _exes <<< "$GUEST_EXE"
    for exe in ${_exes[@]+"${_exes[@]}"}; do
        [ -f "$exe" ] || continue
        page_container_sha "$exe"
    done
}

device_has_container() {
    local sha=$1
    xcrun devicectl device info files --device "$device" --domain-type appDataContainer \
        --domain-identifier "$bundle" --username mobile 2>/dev/null | grep -q "$sha"
}

case "$mode" in
developer-service)
    step "after install: enroll the developer service (this mode's own step)"
    # Idempotent: with a valid pin it verifies and refuses to replace it, which is a
    # success, so the output decides rather than the exit code alone.
    enroll_out=$(tools/enroll.sh 2>&1) && enroll_rc=0 || enroll_rc=$?
    printf '%s\n' "$enroll_out"
    if [ "${enroll_rc:-0}" -ne 0 ] &&
       ! printf '%s' "$enroll_out" | grep -q "no existing trust pin was replaced"; then
        # Two different things were being reported as one. "The pairing bridge cannot see
        # this iPad" means the enrollment was never attempted - nothing was measured, and
        # the app on the device keeps the enrollment it already had (the pin lives in the
        # shared Keychain group, so a reinstall does not take it away). "The bridge
        # answered and refused" is a real failure. Measured 2026-22-10: devicectl reaches
        # the iPad over the network while usbmuxd lists no device at all (`idevice_id -l`
        # empty), and the install was being called a failure for it.
        if printf '%s' "$enroll_out" | grep -qE "Selected device unavailable|Enrollment channel closed|trusted USB handshake \(EOFError\)"; then
            echo "   enrollment not attempted: the iPad is not visible to the pairing bridge." >&2
            echo "   That bridge needs a USB link, or Wi-Fi sync enabled in Finder, which needs" >&2
            echo "   USB once. The app is installed and keeps any enrollment it already has;" >&2
            echo "   if this iPad has never been enrolled, connect it by USB and run tools/enroll.sh." >&2
        else
            echo "   enrollment failed (exit $enroll_rc): the app is installed, but the developer" >&2
            echo "   service cannot prepare memory until this succeeds" >&2
            exit 1
        fi
    fi
    ;;

local-signing)
    step "after install: check the page containers (this mode's own step)"
    # No enrollment here: nothing in this mode signs application code, and the service
    # is not involved. What matters is that the container the runtime will ask for is
    # on the device - a container whose SHA does not match this build's executable is
    # the same as no container at all.
    shas=$(expected_containers)
    if [ -z "$shas" ]; then
        echo "   nothing to check: this is a generic build, with no executable to sign for"
    else
        missing=0
        for sha in $shas; do
            if device_has_container "$sha"; then
                echo "   page container present: ${sha:0:16}…"
            else
                echo "   NO PAGE CONTAINER for ${sha:0:16}… - Local signing cannot start that" >&2
                echo "   executable. Build one with TOLKARA_MODE=local-signing tools/install.sh." >&2
                missing=1
            fi
        done
        [ "$missing" = 0 ] || exit 1
    fi
    ;;

external-jit)
    step "after install: nothing (this mode's own step)"
    echo "   External JIT is prepared by a JIT enabler when the app is launched, and the"
    echo "   runtime refuses to enter the guest while anything is attached. Enrolling would"
    echo "   be work against a service this mode does not use, so none is done."
    ;;

"")
    step "after install: nothing yet (no mode chosen)"
    echo "   The app asks for its execution mode on first launch. Nothing is enrolled now,"
    echo "   because enrolling is developer-service work and the choice has not been made."
    echo "   Choose Developer service in the app, then run: tools/enroll.sh"
    ;;

*)
    die "unknown mode '$mode' (developer-service, local-signing, external-jit, or empty)"
    ;;
esac
