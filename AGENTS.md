# Repository Guidelines

## Project Structure & Module Organization

- `runtime/`: Mach-O loading, guest memory, native execution (Developer service arena, Local signing page container `SignedImage`, or External JIT arena `DebuggerArena`), carried libraries (`GuestLink`), runtime stubs (`GuestStubs`), interpreter diagnostics.
- `translation/`: macOS API adapters (AppKit input/windowing, Metal shader handling, audio, Security).
- `authorization/`: Developer service: bundled pairing, transport, tunnel extension and memory-preparation protocol.
- `launcher/`: the iPad app. `profiles/`: data-only descriptions of tested applications.
- `tests/`: C, Objective-C, Swift and Python tests; `testguest/`: our synthetic guest fixture.
- `wolkara/tools/`: the layer's scripts - prepare, the gate, and the wrappers that run the platform's own build, install, run and test scripts against the prepared tree. The platform's own tools are `platform/tools/` and run inside that tree. `docs/`: building guide and architecture.
- `platform/`: upstream tolkara, vendored byte-identical to `upstream/main` and never edited by hand; `wolkara/`: our layer above it. Start at `development/README.md`.
- `development/`: the split's own record - plan and status, clean-base audit, divergence inventory, operational notes. Update it when a phase moves.
- `build/` and `logs/` are ignored outputs. Third-party applications and assets are never committed.

## Build, Test, and Development Commands

Requires Xcode, XcodeGen and Python 3. Personal settings (team, bundle ID, device) live in ignored `local.env`; see `local.env.example` and `docs/BUILDING.md`.

```sh
# Ours: each prepares build/platform, then runs the platform's own script on it.
wolkara/tools/prepare.sh        # platform/ -> build/platform/, patched and overlaid
wolkara/tools/check_layers.sh   # the gate for the whole split
wolkara/tools/test_emulation.sh # sanitizer regression suite on the Mac, then ours
wolkara/tools/test_translation_sim.sh   # the UIKit-backed adapters' tests, run in the simulator
wolkara/tools/run.sh sim            # loader diagnostics in the simulator (TolkaraDiagnostics scheme)
TOLKARA_MODE=local-signing wolkara/tools/run.sh sim   # Local signing: first initializer of testguest (or GUEST_EXE) from an ad-hoc page container
wolkara/tools/install.sh            # build, sign and install the app on the configured iPad
NATIVE_GUEST_SHIMS=GENERIC wolkara/tools/install.sh   # build for no particular application: one adapter per translation/<Framework>/
wolkara/tools/package_ipa.sh        # unsigned generic TolkaraDiagnostics .ipa for External JIT (sideloaded, e.g. SideStore)
wolkara/tools/make_wolkara_icon.py  # redraw the app icon at every size and appearance (needs Google Chrome)

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

For this branch's Cyberpunk experiment, the user explicitly authorized a rare
exception on 2026-09-26: runtime memory emulation may fetch the faulting
instruction and execute its memory access against software backing. The opt-in
is restricted to Cyberpunk. The general rule below stands for other apps, and
the bans on game-code reverse engineering, binary patches, debugger attachment
after entry, input automation and integrity workarounds still apply. See
`docs/SOFTWARE_MEMORY.md` for the tested scope and current limits.

That ban is about the application, not about our own work. Building, running, testing and
automating *this project* is expected and encouraged: the simulator fixtures, the device matrix,
`pilot.sh`, the in-app self-tests in `wolkara/Shell/SelfTest.m`, and any script that helps. What
is forbidden is automating the *application* - bots, trainers, macros that play it, reading or
changing its memory beyond loading it, and workarounds for its integrity, licence or anti-cheat
checks. A test that feeds Wolkara's own input router or dictation a synthetic event is our code
testing itself; a macro that presses buttons in the game is not.

The original executable is never modified: it is imported as hash-verified data and never patched or re-signed. Three execution modes exist and each user chooses one. **Developer service** never signs application code: the iPad's developer service prepares memory and detaches before any application code runs. **External JIT** (TolkaraDiagnostics only) never signs application code either: a JIT enabler (the user's sideloading tool, or one such as StikDebug) attaches at launch and prepares memory; the runtime asks it to detach and refuses guest entry while any debugger is attached or the arena is not executable. **Local signing** signs only a page container derived locally from the application's final code pages, with the user's own developer identity; containers and captures stay in ignored build output or on the user's device and are never committed. Otherwise sign only our runtime and helpers. Users build Tolkara themselves; docs present that first. As a secondary convenience for External JIT, a `v*` tag publishes one prebuilt app, the unsigned generic `Tolkara-unsigned.ipa` (`.github/workflows/release.yml`): only our own code, never application code, assets, signing material or anything exported from macOS (it is built with `TOLKARA_SYSTEM_ROOTS=NO`, so no system root certificates). Runtime stubs for unresolved imports only where no build-time analysis covered them: in generic builds and for carried libraries' imports; in a build for one executable, that executable's unresolved imports fail. No application-memory inspection beyond loading and verifying the image, no automation or integrity-check workarounds. Keep credentials, signing teams, device identifiers and pairing records out of commits and logs. Never attach an external debugger after guest entry. Do not uninstall the app from a user's device without coordination.
