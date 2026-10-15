# Development tracking

This folder is the repository's own record of the Wolkara-above-tolkara split, so
nothing about it lives only in a chat session or an agent's memory. `docs/`
describes how the software works; `development/` describes how the split is going
and what is still outstanding.

Start with `PLAN.md` for the end-to-end plan and its per-step status.

## The split in one page

| Path | Owner | Notes |
| --- | --- | --- |
| `platform/` | upstream | The whole tolkara tree, vendored, byte-identical to `upstream/main` (`00a8501`). Never edited by hand - a change here is a patch instead. |
| `wolkara/patches/` | us | Small brand-free patches against `platform/`. Each one is an upstream candidate and carries why it exists. |
| `wolkara/tools/` | us | `prepare.sh` builds the tree we compile; `check_layers.sh` is the gate for the whole split. |
| `wolkara/{Shell,WoW,Touch,Bridge}/` | us | Our features, one module per feature. **Not created yet** (Phase 3). |
| `wolkara/project.yml` | us | The `Wolkara` / `WolkaraDiagnostics` project. **Not created yet** (Phase 3). |
| the rest of the root | us | Our tools, docs, profiles, `local.env` contract. Currently still holds all of our sources *and* upstream's duplicates. |

Never build from `platform/` directly. Build from the prepared tree, which is a
pristine export of `platform/` with our patches applied:

```sh
wolkara/tools/prepare.sh          # platform/ -> build/platform/, patches applied
wolkara/tools/check_layers.sh     # the gate: run this before and after any change
```

`build/` is ignored output, so the prepared tree can be deleted at any time.

## Status at a glance

| Phase | What it delivers | Status |
| --- | --- | --- |
| 0 | Ground truth, pre-split tag, baseline | **done** |
| 1 | `platform/` vendored + the gate | **done** |
| 2 | Every delta classified layer / replace / patch / drop | **partial** - 29 contested paths listed, several rows still unverified |
| 3 | `wolkara/project.yml`, the modules, the wrappers | **partial** - only `prepare.sh` exists |
| 4 | Parity on the Mac suites and on Dadpad | **todo** (blocked by 3) |
| 5 | Ingest upstream through the ritual | **partial** - the pin is already current upstream; arrivals partly verified |
| 6 | Clean base from the audit | **todo** |
| 7 | Upstream contribution pipeline | **partial** - 2 patches ready, none submitted |

**Is Wolkara modularised on top of tolkara yet? No.** The substrate exists (pinned
platform, patches, gate, prepare step) but not one of our source files has moved
into a layer module, and the root project still builds `Tolkara` from the root
sources. Measured on 2026-10-15:

| Measure | Count |
| --- | --- |
| Tracked files outside `platform/` | 526 |
| ...whose path also exists in `platform/` (upstream's copies we still carry) | 455 |
| ...of those, byte-identical to the pinned platform (pure dead weight today) | 398 |
| ...of those, we actually differ from upstream on | 57 |
| ...with no counterpart in `platform/` (layer candidates) | 71 |
| Files under `wolkara/` | 4 (2 patches, 2 tools) |
| References to `build/platform` in the root `project.yml` | 0 |

So the split has established *where* our code will live but has not moved it there,
and it has not yet deleted a single one of the 455 upstream duplicates.

## Files here

| File | Contents |
| --- | --- |
| `PLAN.md` | The full end-to-end plan, every phase and step, with status and the decisions taken. |
| `AUDIT.md` | The clean-base findings (Phase 6) - quality problems to fix, with status. |
| `DIVERGENCE.md` | What we changed versus upstream: statistics, themes, and where the two ran over each other. |
| `NOTES.md` | Operational knowledge that is easy to lose: the CASC index repair, background survival, dictation, and tool gotchas. |

Related repository docs, kept as the single source of truth for their subject:

| Doc | Subject |
| --- | --- |
| `docs/LAYER_DELTAS.md` | The per-path class table for the 29 contested files, and the pins. |
| `docs/LAYER_BASELINE.md` | The recorded baseline: suite results, device checks, and the gate for every later phase. |
| `docs/GPU_SUPPORT.md` | Supporting every M-series GPU, with the measurements behind it. |
