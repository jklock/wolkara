# Repository Guidelines

## Project Structure & Module Organization

- `runtime/`: Mach-O loading, guest memory, native execution (Developer service arena, Local signing page container `SignedImage`, or External JIT arena `DebuggerArena`), carried libraries (`GuestLink`), runtime stubs (`GuestStubs`), interpreter diagnostics.
- `translation/`: macOS API adapters (AppKit input/windowing, Metal shader handling, audio, Security).
- `authorization/`: Developer service: bundled pairing, transport, tunnel extension and memory-preparation protocol.
- `launcher/`: the iPad app. `profiles/`: data-only descriptions of tested applications.
- `tests/`: C, Objective-C, Swift and Python tests; `testguest/`: our synthetic guest fixture.
- `wolkaraforever/tools/`: the layer's scripts - prepare, the gate, and the wrappers that run the platform's own build, install, run and test scripts against the prepared tree. The platform's own tools are `platform/tools/` and run inside that tree. `docs/`: building guide and architecture.
- `platform/`: upstream tolkara, vendored byte-identical to `upstream/main` and never edited by hand; `wolkaraforever/`: our layer above it. Start at `docs/ARCHITECTURE.md`.
- `build/` and `logs/` are ignored outputs. Third-party applications and assets are never committed.

## Build, Test, and Development Commands

Requires Xcode, XcodeGen and Python 3. Personal settings (team, bundle ID, device) live in ignored `local.env`; see `local.env.example` and `docs/BUILDING.md`.

```sh
# Ours: each prepares build/platform, then runs the platform's own script on it.
wolkaraforever/tools/prepare.sh        # platform/ -> build/platform/, patched and overlaid
wolkaraforever/tools/check_layers.sh   # the gate for the whole split
wolkaraforever/tools/update_tolkara.sh --check   # is platform/ the most current Tolkara
wolkaraforever/tools/check_docs.sh     # every fork doc link and image resolves
wolkaraforever/tools/install_prerequisites.sh --check   # Mac prerequisites (report only)
wolkaraforever/tools/device_variables.sh --write        # DEVICE from the attached iPad (USB or network)
wolkaraforever/tools/preflight.sh                       # read-only: is Mac/device/app ready?
wolkaraforever/tools/test_emulation.sh # sanitizer regression suite on the Mac, then ours
wolkaraforever/tools/test_translation_sim.sh   # the UIKit-backed adapters' tests, run in the simulator
wolkaraforever/tools/run.sh sim            # loader diagnostics in the simulator (TolkaraDiagnostics scheme)
TOLKARA_MODE=local-signing wolkaraforever/tools/run.sh sim   # Local signing: first initializer of testguest (or GUEST_EXE) from an ad-hoc page container
wolkaraforever/tools/install.sh            # build, sign and install the app on the configured iPad
wolkaraforever/tools/push_game.sh --source "/Applications/World of Warcraft"   # copy the Mac game to the iPad
NATIVE_GUEST_SHIMS=GENERIC wolkaraforever/tools/install.sh   # build for no particular application: one adapter per translation/<Framework>/
wolkaraforever/tools/package_ipa.sh        # unsigned generic TolkaraDiagnostics .ipa for External JIT (sideloaded, e.g. SideStore)
wolkaraforever/tools/make_wolkaraforever_icon.py  # redraw the app icon at every size and appearance (needs Google Chrome)

# The platform's own tools, run inside the prepared tree after prepare.sh.
build/platform/tools/probe_guest.sh "/path/to/Executable"   # inspect an unchanged executable
python3 build/platform/tools/probe_captured_shaders.py   # compile every shader library a game left on the iPad with the iPad's own Metal (no app code runs)
python3 build/platform/tools/build_signed_container.py   # build and sign the Local signing page container for GUEST_EXE
```

Device installs replace the app under the same bundle ID and keep its data.

## Coding Style & Naming Conventions

Four-space indentation in source files, two spaces in YAML; match surrounding conventions without unrelated reformatting. Preserve module prefixes such as `gm_`, `AK` and `TK`. Tests are named `test_*.{c,m,swift,py}`. Compiler warnings are errors in the regression scripts.

## Testing Guidelines

Standalone native executables and Python `unittest`, with ASan/UBSan where configured. Add focused coverage for memory bounds, malformed modules, protocol failures and adapter behavior. Simulator success does not prove physical Metal or authorization behavior; record device results in `COMPATIBILITY.md`.

## Runtime & Security Constraints

No game-code reverse engineering, binary patches, debugger attachment after
entry, input automation or integrity workarounds. That ban is about the
application, not about our own work. Building, running, testing and
automating *this project* is expected and encouraged: the simulator fixtures, the device matrix,
`pilot.sh`, the in-app self-tests in `wolkaraforever/Shell/SelfTest.m`, and any script that helps. What
is forbidden is automating the *application* - bots, trainers, macros that play it, reading or
changing its memory beyond loading it, and workarounds for its integrity, licence or anti-cheat
checks. A test that feeds WolkaraForever's own input router or dictation a synthetic event is our code
testing itself; a macro that presses buttons in the game is not.

## How to work here (standing instruction, 2026-10-17)

Iterate until the work is finished: implemented, built, installed, and tested on the device where
the device is the test. Do not hand back a partial result and do not stop to ask when the answer
is to keep going. Ask only when a decision is genuinely the user's - scope, product behaviour, or
anything that touches their data or their device in a way they must agree to.

Three rules learned the hard way, all of them by being wrong first:

- Never report a finding without having measured it. "The tap delivers nothing" was a check that
  asked 60 milliseconds after the session opened; the tap was fine.
- Never report a fix without the evidence that it works. The check that found the fault is the
  check that has to pass afterwards, on the device.
- Leave the device in no state other than the normal home screen, with the app running. Any
  operation against the app that leaves anything else up is a failure, whatever its verdict said.

The original executable is never modified: it is imported as hash-verified data and never patched or re-signed. Three execution modes exist and each user chooses one. **Developer service** never signs application code: the iPad's developer service prepares memory and detaches before any application code runs. **External JIT** (TolkaraDiagnostics only) never signs application code either: a JIT enabler (the user's sideloading tool, or one such as StikDebug) attaches at launch and prepares memory; the runtime asks it to detach and refuses guest entry while any debugger is attached or the arena is not executable. **Local signing** signs only a page container derived locally from the application's final code pages, with the user's own developer identity; containers and captures stay in ignored build output or on the user's device and are never committed. Otherwise sign only our runtime and helpers. Users build Tolkara themselves; docs present that first. As a secondary convenience for External JIT, a `v*` tag publishes one prebuilt app, the unsigned generic `Tolkara-unsigned.ipa` (`.github/workflows/release.yml`): only our own code, never application code, assets, signing material or anything exported from macOS (it is built with `TOLKARA_SYSTEM_ROOTS=NO`, so no system root certificates). Runtime stubs for unresolved imports only where no build-time analysis covered them: in generic builds and for carried libraries' imports; in a build for one executable, that executable's unresolved imports fail. No application-memory inspection beyond loading and verifying the image, no automation or integrity-check workarounds. Keep credentials, signing teams, device identifiers and pairing records out of commits and logs. Never attach an external debugger after guest entry. Do not uninstall the app from a user's device without coordination.
