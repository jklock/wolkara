# Tools reference

Every script that builds, installs, runs, tests or pilots WolkaraForever lives in
[`wolkaraforever/tools/`](../wolkaraforever/tools). Each one that needs a platform step
first prepares the tree, then runs the platform's own script against it - so you rarely
call `build/platform/tools/*` yourself.

> **Paths.** Layer scripts are written here as `wolkaraforever/tools/<script>`, relative
> to the repository root, and are run from there. The platform's own tools are written as
> `platform/tools/<script>` in the source tree, or `build/platform/tools/<script>` once
> `prepare.sh` has exported it. A bare `tools/<script>` in an older document means the
> layer's copy.

All scripts read the repository root's ignored `local.env` through
[`env.sh`](../wolkaraforever/tools/env.sh); a value given on the command line
(`VAR=value wolkaraforever/tools/...`) wins over the file. The variables are listed at the
end of this page.

## Prepare and gate

| Script | What it does |
| --- | --- |
| `prepare.sh` | Exports `platform/` with `git archive HEAD` into `build/platform`, applies every patch in `wolkaraforever/patches/`, then copies the overlay in `wolkaraforever/overlay.map`. A patch that no longer applies, or a `replace`/`add` overlay entry that does not match, stops the run. `build/` is ignored, so the result can be deleted at any time. |
| `check_layers.sh` | The gate. Fails if `platform/` drifted from the pin, if anything in `platform/` names WolkaraForever, if a patch does not apply, if an overlay entry no longer matches, or if one module reaches into another (`WoW/` into `Touch/`, say). Run it before trusting any suite. |
| `overlay_map.sh` | Regenerates `wolkaraforever/overlay.map` from the layer's tracked files. Run it after adding, moving or removing a file under `wolkaraforever/`. |
| `apply.sh <tree>` | Applies the patches, then the overlay, to any tolkara tree - the prepared build tree or someone else's checkout. |
| `adopt.sh <path/to/tolkara>` | Turns someone's own tolkara checkout into WolkaraForever by running `apply.sh` on it, in place. Run it on a copy if you want to keep the original. |
| `check_docs.sh` | Verifies that every relative markdown link and image in the fork's documentation resolves. The vendored `platform/` is skipped. |

## Build, install, run

| Script | What it does |
| --- | --- |
| `generate.sh [args]` | `prepare.sh`, then the platform's project generator, using your signing team and identifiers from `local.env`. The project lands in `build/platform/Tolkara.xcodeproj`. Regenerating replaces manual project edits, so keep personal settings in `local.env`. |
| `install.sh [--build-only] [--replace-running]` | The full device procedure: refuse to install while the game is running; prepare; build through the platform's install script; run the platform's `enroll.sh`; verify the app is on the device; relaunch the normal launcher and prove it reached home. `--build-only` stops after the build and leaves the iPad alone. `NATIVE_GUEST_SHIMS=GENERIC wolkaraforever/tools/install.sh` builds for no particular application. |
| `run.sh [sim|device ...]` | `prepare.sh`, then the platform's run script. `run.sh sim` runs the loader diagnostics in the simulator. |
| `package_ipa.sh [args]` | Builds the unsigned generic `Tolkara-unsigned.ipa` for External JIT (the `TolkaraDiagnostics` target), by preparing the tree and running the platform's packaging script. Only our own code goes in - never application code. |
| `after_install.sh <mode>` | The post-install step, decided by the execution mode. Split out of `install.sh` so it can be tested without building; run from inside `build/platform`. |

## Device pilot (never breaks a session)

Every command here looks at the device first and refuses when the answer is "not now".
Stopping or installing over a running game is what corrupted the client's store before;
refusing is the feature.

| Script / command | What it does |
| --- | --- |
| `pilot.sh state` | What the device is doing right now. |
| `pilot.sh stop [--force]` | Stops the app, asking first and waiting. |
| `pilot.sh install [--force]` | Stops, then builds and installs. |
| `pilot.sh launch` | Launches the launcher so its own checks run. |
| `pilot.sh game` | Goes straight into the game, no checks. |
| `pilot.sh wait [--timeout s]` | Blocks until the app is up, or until it fails. |
| `pilot.sh view` | Screenshot, log and whether it crashed or asserted. |
| `pilot.sh crash` | Reads the newest crash report out loud. |
| `pilot.sh log [lines] [pattern]` | The app's own log, from Documents. |
| `pilot.sh leave [bundle]` / `return` | Puts the app in the background for real / brings it back. |
| `pilot.sh restore` | Starts again whatever an install found running. |
| `pilot.sh selftest <name>` | Runs the app's own device self-test and reads it. |
| `pilot.sh cycle` | `state`, `install`, `launch`, `wait`, `view` in one go. |
| `launch.sh [--restart] [args]` | Launches on the iPad after checking live state; never kills a session. |
| `running_app.sh` | Prints the pid of a process running *this* bundle's installed executable. |
| `device_log.sh [lines] [pattern]` | Reads the app's log from the iPad without touching the running app. |
| `device_matrix.sh` | The Mac-drivable part of the physical-iPad matrix (fresh install, config import/refusal, notices, backgrounding, self-tests, no new crashes or error files). Person-only checks are listed as deferred at the end. |
| `xcrun_device_timeout.sh` | Sourced helper: runs a CoreDevice operation with a bounded wait, so a locked iPad cannot hang a script. |

## Validation and evidence

| Script | What it does |
| --- | --- |
| `validate.sh [--allow-dirty] [--full] [--device] [--out <path>]` | Runs the suites and writes one record per commit under `development/validation/`: the commit, whether the tree was clean, host and Xcode, each command with its exit status, and the tail of its output. Refuses a dirty tree unless `--allow-dirty`. `--full` adds the slow platform suites; `--device` also installs and pilots on the connected iPad. Device identifiers are scrubbed from what it writes. |

## Tests

`test_emulation.sh` is the umbrella: it runs the gate, the platform's suite against the
prepared tree, then every `wolkaraforever/tools/test_*.sh` except the UI fixtures and
itself. The UI fixtures need a booted simulator and are run directly.

| Script | What it covers |
| --- | --- |
| `test_emulation.sh [args]` | Gate, then the platform suite, then the layer's suites. |
| `test_translation_sim.sh [args]` | The UIKit-backed adapters' tests in the simulator (touch controls, gamepad, haptics, fonts). |
| `test_wow_launcher.sh` | The WoW launcher's suites against the prepared tree. |
| `test_wow_launcher_ui.sh` | Our own synthetic launcher UI fixture. Set `SIMULATOR`. |
| `test_touch_controls_ui.sh` | The touch-controls UI fixture. |
| `test_touch_gamepad_ui.sh` | The gamepad UI fixture. |
| `test_voice.sh` | The input, voice and configuration rules, as a tiny app in the simulator. |
| `test_forever_ui.sh` | The Forever UI operations: the `Config.wtf` rules and the archive. |
| `test_addon_archive.sh` | The production Swift extractor and the app's pinned ZIPFoundation. |
| `test_curseforge.sh` | The CurseForge client. |
| `test_icon_assets.sh` | The generated app icon: square, opaque, non-empty, catalog matches the files. |
| `test_local_service_retry.sh` | The local-service retry and packet-service probe suites. |

`wolkaraforever/tools/tests/` holds tests of the tools themselves -
`test_after_install.sh`, `test_pilot.sh`, `test_running_app.sh`, `test_validate.sh`,
`test_xcrun_device_timeout.sh` - and `make_addon_archives.py`, which builds the add-on
fixtures.

## Platform tools you may run directly

After `prepare.sh`, the platform's tools are in `build/platform/tools/`. The ones a user
may want:

| Tool | What it does |
| --- | --- |
| `probe_guest.sh /path/to/Executable` | Inspects an unchanged executable: its Mach-O layout and imported symbols, and which are missing. |
| `probe_captured_shaders.py` | Compiles every shader library a game left on the iPad with the iPad's own Metal, without running application code. |
| `build_signed_container.py` | Builds and signs the Local signing page container for `GUEST_EXE`. |
| `test_launch_progress.sh [--dark] [simulator-id]` | Runs the standalone launch-progress fixture in a simulator and saves screenshots. |

## Environment variables

Set in the ignored `local.env` at the repository root. `env.sh` sources it and lets any
value already in the environment win.

| Variable | Meaning |
| --- | --- |
| `DEVELOPMENT_TEAM` | Your 10-character Apple team ID. Not needed for simulator builds. |
| `TOLKARA_BUNDLE_ID` | Your own bundle identifier. Keep it stable so updates replace the app in place. |
| `TOLKARA_KEYCHAIN_GROUP` | The device-only Keychain group for authorization. Changing it needs re-enrolling. |
| `TOLKARA_DISPLAY_NAME` | The app's display name. Defaults to `WolkaraForever`. |
| `DEVICE` | The connected iPhone/iPad identifier (`xcrun devicectl list devices`). |
| `SIMULATOR` | The simulator to use for simulator runs and the UI fixtures. |
| `GUEST_EXE` | The macOS executable you own. Several apps: separate with `:` (like `PATH`). |
| `NATIVE_GUEST_SHIMS` | `GENERIC` builds for no particular application: one adapter per `translation/<Framework>/`. |
| `TOLKARA_PROFILE` | Your own profile JSON outside `profiles/`. Several: separate with `:`. |
| `TOLKARA_EXPERIMENTAL_ADAPTERS` | Experimental adapters to include, separated by `:`. None is on by default. |
| `TOLKARA_MODE` | `developer-service` (integrated default) or `local-signing`. External JIT is preselected by `package_ipa.sh`. |
| `TOLKARA_CAPTURE` | For Local signing: a capture of the final code pages, one entry per `GUEST_EXE`. |
| `SIGN_IDENTITY` | For Local signing: the identity that signs the page container. |

Internal variables you may see: `PILOT_SESSION` (one pilot run's work directory; shared by
`validate.sh` and `device_matrix.sh` so their steps form one run), `TOLKARA_VM_BUDGET_MB`
(a launch-environment budget for large virtual-memory reservations), and
`ZIPFOUNDATION_SOURCE` (the checkout `test_addon_archive.sh` uses).
