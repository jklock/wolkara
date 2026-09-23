# Repository Guidelines

## Project Structure & Module Organization

- `runtime/`: Mach-O loading, guest memory, native execution (Developer service arena or Local signing page container, `SignedImage`), interpreter diagnostics.
- `translation/`: macOS API adapters (AppKit input/windowing, Metal shader handling, audio, Security).
- `authorization/`: Developer service: bundled pairing, transport, tunnel extension and memory-preparation protocol.
- `launcher/`: the iPad app. `profiles/`: data-only descriptions of tested applications.
- `tests/`: C, Objective-C, Swift and Python tests; `testguest/`: our synthetic guest fixture.
- `tools/`: builds, diagnostics and regression scripts. `docs/`: building guide and architecture.
- `build/` and `logs/` are ignored outputs. Third-party applications and assets are never committed.

## Build, Test, and Development Commands

Requires Xcode, XcodeGen and Python 3. Personal settings (team, bundle ID, device) live in ignored `local.env`; see `local.env.example` and `docs/BUILDING.md`.

```sh
tools/test_emulation.sh     # sanitizer regression suite on the Mac
tools/run.sh sim            # loader diagnostics in the simulator (TolkaraDiagnostics scheme)
TOLKARA_MODE=local-signing tools/run.sh sim   # Local signing: first initializer of testguest (or GUEST_EXE) from an ad-hoc page container
tools/install.sh            # build, sign and install the Tolkara app on the configured iPad
tools/probe_guest.sh "/path/to/Executable"   # inspect an unchanged executable
python3 tools/build_signed_container.py       # build and sign the Local signing page container for GUEST_EXE
python3 tools/make_icon.py                    # redraw the app icon at every size and appearance (needs Google Chrome)
```

Device installs replace the app under the same bundle ID and keep its data.

## Coding Style & Naming Conventions

Four-space indentation in source files, two spaces in YAML; match surrounding conventions without unrelated reformatting. Preserve module prefixes such as `gm_`, `AK` and `TK`. Tests are named `test_*.{c,m,swift,py}`. Compiler warnings are errors in the regression scripts.

## Testing Guidelines

Standalone native executables and Python `unittest`, with ASan/UBSan where configured. Add focused coverage for memory bounds, malformed modules, protocol failures and adapter behavior. Simulator success does not prove physical Metal or authorization behavior; record device results in `COMPATIBILITY.md`.

## Runtime & Security Constraints

The original executable is never modified: it is imported as hash-verified data and never patched or re-signed. Two execution modes exist and each user chooses one. **Developer service** never signs application code: the iPad's developer service prepares memory and detaches before any application code runs. **Local signing** signs only a page container derived locally from the application's final code pages, with the user's own developer identity; containers and captures stay in ignored build output or on the user's device and are never committed. Otherwise sign only our runtime and helpers. No application-memory inspection beyond loading and verifying the image, no automation or integrity-check workarounds. Keep credentials, signing teams, device identifiers and pairing records out of commits and logs. Never attach an external debugger after guest entry. Do not uninstall the app from a user's device without coordination.
