# Development tracking

This folder is the repository's own record of the Wolkara-above-tolkara split, so
nothing about it lives only in a chat session or an agent's memory. `docs/`
describes how the software works; `development/` describes how the split is going
and what is still outstanding.

Start with `PLAN.md` for the end-to-end plan and its per-step status.

## Current state

The numbers in the older notes below were written at different times and disagree with
each other. These are the ones that hold now, and each can be checked in one command:

| Thing | Now | Check it with |
| --- | --- | --- |
| Platform pin | `00a8501` | `wolkara/tools/check_layers.sh` |
| Our patches | 13 | `ls wolkara/patches/*.patch \| wc -l` |
| Overlay entries | 89 (9 replace, 80 add) | `wolkara/tools/overlay_map.sh` |
| Layer files carried | every file under `wolkara/` | `check_layers.sh` |
| Gate | 11 checks | `wolkara/tools/check_layers.sh` |

Evidence for a release comes from `wolkara/tools/validate.sh`, which runs the suites and
writes one file per commit under `development/validation/`, naming the commit, whether
the tree was clean, every command it ran and what each printed. It refuses to run on a
dirty worktree unless told to. `VALIDATION.md` is the older, hand-written record and is
tied to the commit it names, not to the work after it.

## The split in one page

| Path | Owner | Notes |
| --- | --- | --- |
| `platform/` | upstream | The whole tolkara tree, vendored, byte-identical to `upstream/main` (`00a8501`). Never edited by hand - a change here is a patch instead. |
| `wolkara/patches/` | us | Small brand-free patches against `platform/`. Each one is an upstream candidate and carries why it exists. |
| `wolkara/overlay.map` | us | Which layer file takes which path in the prepared tree, and whether it replaces a platform file or adds a new one. |
| `wolkara/tools/` | us | `prepare.sh` builds the tree we compile, `check_layers.sh` is the gate, `overlay_map.sh` regenerates the map, and the rest prepare and then run the platform's own build, install, run and test scripts. |
| `wolkara/{Shell,WoW,Touch,Bridge}/` | us | Our features, one module per feature, reaching the build by overlay. `wolkara/README.md` documents the boundaries. |
| the rest of the root | us | Our docs, profiles, the `local.env` contract and this `development/` record. No platform source lives here any more. |

Never build from `platform/` directly. Build from the prepared tree: a pristine export
of `platform/`, with our patches applied and our files overlaid at the platform's own
paths, so the platform's own project, shim builder and tests build our app.

```sh
wolkara/tools/prepare.sh          # platform/ -> build/platform/, patched and overlaid
wolkara/tools/check_layers.sh     # the gate: run this before and after any change
wolkara/tools/generate.sh         # the app's Xcode project, in build/platform
```

`build/` is ignored output, so the prepared tree can be deleted at any time.

## Scope and naming

The product is a WoW Forever client: WoW Forever (and the classic-era profiles) are
what we ship for. The display name is moving to **Wolkara Forever**; the bundle ID
stays as it is (`$(TOLKARA_BUNDLE_ID)`), so installs replace in place and the device
keeps its data. The platform keeps its own Tolkara names - only the product layer and
its internals are Wolkara.

## Status at a glance

| Phase | What it delivers | Status |
| --- | --- | --- |
| 0 | Ground truth, pre-split tag, baseline | **done** |
| 1 | `platform/` vendored + the gate | **done** |
| 2 | Every delta classified layer / replace / patch / drop | **partial** - classification done and measured; seven patches now carry the platform-side changes and six paths need nothing, so what remains is the branding-delta deletions and the three Phase 3 files |
| 3 | The modules, the overlay, the wrappers | **done** - by overlay onto the prepared tree rather than a layer project; `PLAN.md` says why |
| 4 | Parity on the Mac suites and on Dadpad | **partial** - the suites, the compile checks and the project generation pass; the one check left is installing and running the app on the device since the split |
| 5 | Ingest upstream through the ritual | **partial** - the pin is already current upstream; arrivals partly verified |
| 6 | Clean base from the audit | **done** - every audit item is fixed or decided; see `AUDIT.md` |
| 7 | Upstream contribution pipeline | **partial** - 7 patches ready, none submitted |

**Is Wolkara modularised on top of tolkara? Yes, as of 2026-10-15.** Our sources live
in `wolkara/{Shell,WoW,Touch,Bridge}`, no platform source is duplicated at the root,
and the platform's own project, shim builder and tests build our app from the prepared
tree. The one piece still open is the AppKit adapter patch, recorded in
`wolkara/README.md`. Measured on 2026-10-15, after the move:

| Measure | Count |
| --- | --- |
| Files under `wolkara/` | 80 |
| Layer files carried by `overlay.map` (12 replace, 52 add) | 64 |
| Root copies of a platform path (455 before the split; 398 of them byte-identical) | 0 |
| Patches against the platform | 7 |
| Tracked files at the root outside `platform/` and `wolkara/` | 46 - `docs/`, `profiles/`, `development/`, `.github/` and the root documents |

## Files here

| File | Contents |
| --- | --- |
| `PLAN.md` | The full end-to-end plan, every phase and step, with status and the decisions taken. |
| `VALIDATION.md` | Every phase checked against the design, with the evidence for each claim and the exceptions that are accepted. |
| `AUDIT.md` | The clean-base findings (Phase 6) - quality problems to fix, with status. |
| `DIVERGENCE.md` | What we changed versus upstream: statistics, themes, and where the two ran over each other. |
| `NOTES.md` | Operational knowledge that is easy to lose: the CASC index repair, background survival, dictation, and tool gotchas. |
| `TAKEOVER.md` | Current branch inventory, uncommitted-work boundary, and evidence needed to resume the controller/voice work. |

Related repository docs, kept as the single source of truth for their subject:

| Doc | Subject |
| --- | --- |
| `docs/LAYER_DELTAS.md` | The per-path class table for the 29 contested files, and the pins. |
| `docs/LAYER_BASELINE.md` | The recorded baseline: suite results, device checks, and the gate for every later phase. |
| `docs/GPU_SUPPORT.md` | Supporting every M-series GPU, with the measurements behind it. |
