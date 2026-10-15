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
- The three UI scripts' `SIMULATOR` default: fixed to `iPad Pro 13-inch (M5)` when the
  layer's own copies moved to `wolkara/tools/`. The platform's copies are upstream's,
  and their default is upstream's to set.
- `launcher/Assets.xcassets/AppIcon.appiconset` (48 unused PNGs): dropped from the layer
  in Phase 3; the layer ships only `Shell/Assets.xcassets/Wolkara.appiconset`, which is
  what `ASSETCATALOG_COMPILER_APPICON_NAME: Wolkara` asks for.
- `AGENTS.md` still named `make_icon.py` for the app icon: fixed. The layer's icon tool
  is `wolkara/tools/make_wolkara_icon.py`, and the platform's `make_icon.py` stays
  upstream's under `platform/tools/`.

## Still open

- The doc references that point at the pre-split `tools/` paths, for example
  `docs/TOUCH_INPUT.md:192` and `docs/WOW_LAUNCHER.md`; the layer's scripts live at
  `wolkara/tools/` and the platform's at `build/platform/tools/` after
  `wolkara/tools/prepare.sh`.
- The touch and gamepad fixtures still block under `simctl launch --console` without
  `--self-test`, so a headless run of those two can hang.
- Everything else in this file is unchanged and still open.

## Branch-wide audit against upstream (2026-10-15)

Done after a mistake of ours surfaced: three files had been treated as "ours" when we
had never modified them, so overlaying them silently dropped upstream's newer work. The
same mistake could have been made anywhere, so every path this branch touches was
re-checked against upstream by comparing three versions - ours, upstream's, and the
pre-split base - and asking which side actually changed.

| Group | Count | Result |
| --- | --- | --- |
| The vendored platform | 513 files | byte-identical to `upstream/main` today (checked live on every gate run) |
| Our patches | 8 | each is a three-way merge of our change onto upstream's current file, and every one merged clean, so no upstream line was dropped |
| Our replacements | 9 | decided one by one: 3 dropped (we had not changed them), 5 merged with theirs, 2 ours-only (branding plists) |
| Our additions | 52 | upstream has no file at those paths; the overlay refuses an `add` that would collide with one it has |
| Files deleted as superseded | 22 | 7 we had not changed; 9 covered by a patch; 3 tools whose only change was branding and the display name, now the layer's; 2 tests of ours dropped on purpose; **1 real gap** |
| Root documents, docs, profiles, CI | 46 | 10 are stale forks (below); the rest are our product's own text |

**The gap the audit found:** `translation/Metal/Devices.m` was taken as upstream's, and
our copy had also carried the call that installs the background frame pacing. Nothing
installed it after that, so the background-survival feature would have quietly lost its
pacing. Fixed in the layer: `Bridge/BackgroundPacing.m` installs itself from a load-time
constructor, which is the right place anyway - the file is compiled into the Metal
adapter, which the guest loads before it draws, and there is no call site to keep in
step in a platform file.

**Checks that came out clean, for the record:** our `tools/install.sh` change was a
workaround for `SYMROOT`/`OBJROOT` overrides we no longer make, so upstream's script is
self-consistent under our wrapper; `tools/generate.sh` and `tools/package_ipa.sh` only
carried branding, which `wolkara/tools/env.sh` sets; our `test_emulation.sh` change was
additive (the layer's suites have their own entry point) and upstream's version is used;
`tests/test_appkit_views.m` tested the platform's own layout and is superseded by our
fixture in `Touch/tests/`.

**Stale forks to fold in** (upstream's text has moved on and our copy has not been
merged): `.github/workflows/release.yml`, `AGENTS.md`, `COMPATIBILITY.md`, `NOTICE.md`,
`README.md`, `docs/BUILDING.md`, `docs/IPHONE.md`, `docs/TOUCH_INPUT.md`,
`local.env.example`, `profiles/wow-forever/README.md`. These are documentation and
configuration, so nothing here changes how the app builds or behaves; upstream's versions
are readable at any time under `platform/`. Merging them is Phase 6 work.

