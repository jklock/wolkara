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

The trees as they stand today, before the split moves anything:

| Measure | Count |
| --- | --- |
| Tracked files outside `platform/` | 526 |
| ...path also exists in `platform/` | 455 |
| ...of those, byte-identical to the pin | 398 |
| ...of those, we differ from upstream | 57 |
| ...no counterpart in `platform/` | 71 |

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
