# Wolkara versus tolkara

What we changed, what upstream changed, and where the two ran over each other.
The pins, the four quadrants and the per-path class table live in
`docs/LAYER_DELTAS.md`; this file is the summary and the inventory behind it.

Recorded 2026-10-15 on `feature/wolkara-above-tolkara`.

## Scale

| | Value |
| --- | --- |
| Merge base with `upstream/main` | `05035cc` *Document confirmed iPhone keyboard and trackpad use* |
| Pinned upstream (vendored at `platform/`) | `00a8501` *Compatibility: WoW Forever water renders on the iPad Pro M5* |
| Our side, since the merge base | 37 commits, 109 files, +9737 / -356 |
| Upstream side, since the merge base | 30 commits, 107 files, +9737 / -580 |
| Upstream commits we lacked | 29 (1 equivalent: upstream `920b4da` == our `579ebef`, the IOKit GPU stand-in) |
| Neither side deletes files | 0 `D` entries on both sides |

Reproduce with `git --no-pager diff --name-status --no-renames 05035cc..main` and the
same with `..upstream/main`.

### After the split (2026-10-15): how far are we from tolkara today?

The base is **to upstream's current release, byte for byte**:

| | Value |
| --- | --- |
| `platform/` tree | `1e8d13f1fe089fa32cd84a6b46fe3692e288aeac` |
| `upstream/main^{tree}` today | `1e8d13f1fe089fa32cd84a6b46fe3692e288aeac` |
| `upstream/main` head | `00a8501` *Compatibility: WoW Forever water renders on the iPad Pro M5* (tag `v0.2.1`) |

`check_layers.sh` compares those two trees on every run, against `upstream/main` itself
and not a stored hash, so the moment tolkara moves the gate says so.

Everything of ours is outside `platform/`, in three forms. **Patches** - our changes to
platform files, applied by `prepare.sh`, each one an upstream candidate:

| Patch | Changes | What it does |
| --- | --- | --- |
| 0001 | 1 file, +8/-5 | the BC test: the reserved mode has no defined decode to compare, and `off` now really measures |
| 0002 | 1 file, +1/-0 | log the host's BC capability once |
| 0003 | 2 files, +60/-3 | runtime: a rebase program may end at `rebase_size` with no DONE; invalid targets name themselves (+ its test) |
| 0004 | 1 file, +6/-0 | runtime: why an existing class wins, and the NSFont trap |
| 0005 | 1 file, +30/-0 | CoreAudio: keep the audio session alive across an app switch |
| 0006 | 2 files, +51/-31 | authorization: retry the local service when its first connection fails |
| 0007 | 2 files, +37/-5 | authorization: retire a failed probe, keeping the old tuple reserved |
| 0008 | 1 file, +1/-1 | AppKit: alias the adapter's own `AKFont` to `NSFont`, so a guest asking for `NSFont` reaches it and not UIKit's private class of the same name |
| 0009 | 1 file, +28/-3 | AppKit: Control+Option+D opens the draft keyboard instead of reaching the game (press and release both swallowed), a window is told when it stops being on screen, and the draft panel's Replace performs one explicit edit |

**Replacements** - 9 of our files take a platform path of the same purpose, so our
version is what the platform's own build compiles. Each one was decided by comparing
ours, theirs and the pre-split base: ours changed only (keep), theirs changed only
(drop ours), or both (merge our change onto theirs):

| Our file | Platform path | Lines apart |
| --- | --- | --- |
| `Touch/TouchControls.m` | `translation/AppKit/TouchControls.m` | 489 |
| `Touch/tests/test_touch_controls_app.m` | `tests/test_touch_controls_app.m` | 332 |
| `Shell/main.m` | `launcher/App/main.m` | 103 |
| `Touch/TouchControls.h` | `translation/AppKit/TouchControls.h` | 29 |
| `Shell/ExecutionMode.m` | `launcher/App/ExecutionMode.m` | 10 |
| `Shell/tests/test_execution_mode.m` | `tests/test_execution_mode.m` | 9 |
| `Shell/Info.plist` | `launcher/Info.plist` | 6 |
| `Shell/ExecutionMode.h` | `launcher/App/ExecutionMode.h` | 4 |
| `Shell/Integrated-Info.plist` | `authorization/App/Integrated-Info.plist` | 2 |

Three files that used to be here - `AppLibrary.h`, `AppLibrary.m` and
`LibraryViewController.m` - were dropped: they were byte-identical to the pre-split
base, so their only difference from the pin was upstream's newer work. The platform's
own `test_app_library.m` caught it by failing to compile.

**Additions** - 52 files upstream has no counterpart for, mostly one module's worth at a
time: 23 in `launcher/WoW/` (the WoW launcher), 10 tests, 8 in `translation/AppKit/`
(the gamepad, its layout, haptics and the adapter's fonts), 4 the Wolkara icon set, 3
icon art, 2 `authorization/App/LocalServiceRetry.*`, 1 `translation/Metal/BackgroundPacing.m`,
1 `tools/wow_cdn.m`.

We own no fork of the platform's build: its own `project.yml`, `build_shims.py`, and its
test scripts build our app from the prepared tree.

**Where we were before the split** (the reason it is now only the above): 526 tracked
files outside `platform/`, of which 455 were platform paths - 398 of them byte-identical
copies - and 71 were ours. Those copies are gone; the layer is what remains.


`0e244e1` ("primary commits and updates") is **ours**, not upstream work: a squash of
24 files covering the add-on manager plus that session's AppKit and Metal device
changes. It is not a rebase hazard.

## Where our changes are

Share of our changed files: `launcher/WoW` 21%, `tests` 13.7%, `translation/AppKit`
11.9%, `tools` 10%, `docs` 8.2%, assets 3.6%, `launcher/App` 2.7%, `translation/Metal`
2.7%, `translation/IOKit` 2.7%, `runtime` 1.8%, `AKSupport` 1.8%,
`profiles/wow-forever` 1.8%, `CoreAudio` 0.9%.

By theme:

- **WoW launcher app layer** (entirely ours): Client, CASC, Updater, Installation,
  Manifest, UpdateLock, WoWViewController; AddonManager, AddonStore, AddonArchive,
  AddonCredentialStore, CurseForgeClient; verified resumable staging; verified-object
  cache with revalidation; truncated index repair; themed home; one English interface;
  channel comparison; `profiles/wow-forever` and `sync_addons.sh`; launcher tests.
- **Touch, keyboard, dictation**: touch toolbar, trackpad, gamepad, layout editor,
  haptics, opacity; native text input with drafts and Replace and dictation focus;
  Metal child view, autoresizing and pointer confinement; dictation keeps the draft;
  Control+Option+D trigger; hardware-keyboard diagnosis.
- **GPU identity**: Mac-with-Apple-silicon identity, registry traces, stand-in GPU entry.
- **Background**: audio background mode plus session keep-alive, Metal background pacing
  (our own file), occlusion notifications.
- **Runtime**: only `GuestFixups`/`GuestStubs`, about 15 lines.
- **Branding and identity**: Wolkara rename with saved-state migration, WK monogram, one
  installation for testing, source-release setup, artwork and `Wolkara.appiconset`.
- **Authorization**: `LocalServiceRetry` (cellular).

## What upstream has and we did not

Verified absent here, so it arrives with the vendored platform: the BC texture fallback
(CPU decoders BC1-BC7, uncompressed storage, simulator build, `tests/bc_gpu_reference.h`,
`test_bc_decode.c`, `test_bc_textures.m`); Steam Cloud (`launcher/Cloud/*`,
`test_steam_cloud.m`); Tolkara Management (`management/*`, `docs/MANAGEMENT.md`,
`tools/embed_management_source.sh`, release DMG); the iPad Pro M5 water fix; AppKit
pointer and touch fixes (pointer stays put, natural scrolling, captured-touch
confinement, controls optional or iPhone-only); launcher folder removal and
`--save-execution-mode`; runtime buffered writes and memory-operation logging; build
adapter dependencies, typed stubs and MoltenVK; profiles region note and setup block;
MegaBonk compatibility (no MegaBonk profile here).

## Pairs to expect conflicts on

Same title, different patch - comparing these is part of Phase 2:

| Upstream | Ours |
| --- | --- |
| `f54662e` | `ad3f6c5` |
| `f9d1f8b` | `c19dbc4` |
| `920b4da` | `579ebef` (already equivalent) |
