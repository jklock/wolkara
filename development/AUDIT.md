# Clean-base audit

Findings that should be fixed as part of the split, so the base we build on going
forward is actually clean. Recorded 2026-10-15. All items are open unless marked.

This is Phase 6 of `PLAN.md`.

## Test harness

- `tools/test_touch_controls_ui.sh:6`, `tools/test_touch_gamepad_ui.sh:6` and
  `tools/test_wow_launcher_ui.sh:5` default `SIMULATOR=iPhone 17 Pro`, which does not
  exist on this Mac and will fail unless `SIMULATOR` is set. The simulators installed
  here (iOS 27.0 only) are: iPad A16, iPad Air 11/13-inch (M4), iPad Pro 11/13-inch
  (M5), iPad mini (A17 Pro), iPhone 17, iPhone 17e, iPhone 18 Pro, iPhone 18 Pro Max,
  and iPhone Air.
- The scripts that already use a real default use `iPad Pro 13-inch (M5)`:
  `tools/test_translation_sim.sh:9`, `tools/run.sh:20`, `tools/probe_signed_file.sh:40`,
  `tools/test_pairing_storage_sim.py:19`. Make the three above match, or make
  `SIMULATOR` mandatory.
- `tests/test_touch_controls_app.m` and `tests/test_touch_gamepad_app.m` also block
  under `simctl launch --console` when run *without* `--self-test`: they only exit in
  self-test mode. Give the non-self-test path a watchdog so a headless run cannot hang.
- `tools/test_launch_progress.sh` needs an already-booted simulator (its argument
  defaults to `booted`); document that or boot one itself.

## Dead weight

- `launcher/Assets.xcassets/AppIcon.appiconset` is unused: `project.yml:73` sets
  `ASSETCATALOG_COMPILER_APPICON_NAME=Wolkara`, which points at `Wolkara.appiconset`
  (drawn by `tools/make_wolkara_icon.py`). The old set still carries 48 PNGs. Delete it,
  and retire or repoint `tools/make_icon.py:29`.
- `AGENTS.md:26` still says `make_icon.py` draws the app icon; it does not any more.
- Stale plan documents: `docs/ADDON_MANAGER_PLAN.md` and
  `docs/TOUCH_CONTROLLER_PROPOSAL.md` describe work that has since landed. Mark them
  done or repoint them.
- `launcher/App/LibraryViewController.m` carries unreachable strings from an old name.

## Layer naming

One prefix per kind, and the layer's prefix throughout its own code:

- error domains: `launcher/WoW/Manifest.m:9` still says `Tolkara.WoW` while other
  places say `Wolkara.*`;
- dispatch queue labels: `tolkara.*` and `org.tolkara.*` alongside `local.wolkara.*`;
- accessibility identifiers: `TouchControls.m:59,259` use `tolkara.*` alongside `wolkara.*`;
- user-visible strings: `launcher/App/DiagnosticsViewController.m:123` and
  `launcher/App/main.m:72`.

Naming entanglement to work through: 436 occurrences of tolkara/Tolkara in 116 files
versus 161 of wolkara/Wolkara in 43. The heaviest are `docs/WINDOWS.md` (31),
`docs/BUILDING.md` (27), `tests/test_execution_mode.m` (22), `docs/IPHONE.md` (17),
`launcher/App/main.m` (13), `LibraryViewController` (11), `docs/ARCHITECTURE.md` (11),
`README` (11), `docs/LOCAL_AUTHORIZATION.md` (10), `ExecutionMode` (8).

## Documentation truth

- Reconcile the contradictory `tools/test_emulation.sh` PASS/FAIL statements in
  `docs/WOW_LAUNCHER.md` and `docs/TOUCH_INPUT.md:319-322`.
- The add-on subsystem (`AddonManager`, `AddonStore`, `CurseForgeClient`,
  `AddonArchive`, `AddonCredentialStore`) has no automated test at all. Either add a
  Mac-level fixture test or soften what `COMPATIBILITY.md` claims about it.

## Style

- `translation/AppKit/TouchControls.m:284` has a comment glued to the line above;
  `:288` puts two statements on one line.

## Already fixed

- `docs/LAYER_BASELINE.md` recorded the platform BC test's native comparison as an
  accepted abort. Diagnosed and fixed by `wolkara/patches/0001`, verified in the
  prepared tree: see `docs/GPU_SUPPORT.md`.
