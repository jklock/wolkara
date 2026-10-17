# Plan: Wolkara as a layer above tolkara

The plan of record for the split. Every step carries its status, so this file is
both the plan and the progress log. Last reviewed 2026-10-15, at commit `e33f3f4`.

Status: **done** / **partial** / **todo**.

## TL;DR

Vendor upstream at `platform/` as a pristine git subtree; re-express everything we
changed as a feature-modular `wolkara/` layer plus a tiny brand-free patch set; give
Wolkara its own XcodeGen project built from a prepared tree; prove parity on the Mac
suites and on Dadpad; then `git subtree pull` is the conflict-free ingest ritual and
the patch set is the upstream-contribution pipeline. Clean-base fixes from the audit
land in the same effort.

## Decisions taken

1. **Structure:** one repository. `platform/` = upstream tolkara, subtree, never
   hand-edited. `wolkara/` = our layer. Ingest = `git subtree pull --prefix=platform
   upstream main --squash`. *Rejected:* plain fork-and-merge (keeps re-hitting the
   ~30-60 contested files, plus branding noise in every diff) and two repositories
   (fights the co-designed build tooling; upstream itself keeps `management/` as a
   second project in one repository, so single-repo multi-project is
   upstream-idiomatic).
2. **Naming:** the platform keeps Tolkara names (targets, `TOLKARA_*`, `TK`/`AK`/`gm_`
   prefixes); the product layer and its internals are Wolkara (error domains, queue
   labels, accessibility ids, docs).
3. **Contribute upstream:** yes. Every platform-side change is a small brand-free
   patch carrying reason and upstream PR status, and the patches double as the PR
   payload.
4. **Clean-base scope:** all audit items, plus test coverage for the add-on
   subsystem. See `AUDIT.md`.
5. **Bundle ID unchanged** (`$(TOLKARA_BUNDLE_ID)`), so the iPad keeps its data and
   installs replace in place.

## Layout target

| Path | Owner | Contents | Exists |
| --- | --- | --- | --- |
| `platform/` | upstream | entire tolkara tree; read-only; ingested by subtree pull | yes |
| `wolkara/Shell/` | us | app shell/home, execution-mode glue, branding plist, distribution | no |
| `wolkara/WoW/` | us | Client, CASC, Updater, Installation, Manifest, UpdateLock, WoWViewController, Addon*, with its tests, tools and profiles | no |
| `wolkara/Touch/` | us | toolbar, trackpad, gamepad, layout, haptics, drafts and dictation, Fonts | no |
| `wolkara/Bridge/` | us | thin adapters from platform APIs to layer features | no |
| `wolkara/patches/` | us | minimal brand-free patches, each an upstream candidate | yes (15 as of 2026-10-17) |
| `wolkara/Tools/`, `wolkara/Tests/` | us | wrapper scripts and per-feature tests | no |
| `wolkara/project.yml` | us | the XcodeGen project for `Wolkara` + `WolkaraDiagnostics` | no |
| root | shared | README, AGENTS.md, `local.env` contract, `docs/`, `development/` | yes |

## Phase 0 - Ground truth and safety net

1. Tag the pre-split state so the mixed layout stays recoverable. **done** -
   `wolkara-pre-layer`.
2. Record the exact contested set into `docs/LAYER_DELTAS.md`. **done** - 29 contested
   paths (24 modified by both, 5 added by both), with pins and quadrants.
3. Capture the baseline into `docs/LAYER_BASELINE.md`. **done** - suite results,
   device checks, and the accepted codesign failure.

## Phase 1 - Vendor the platform

4. `git subtree add --prefix=platform upstream main --squash`; pin the commit.
   **done** - `a413102` (squash) + `c52c1db` (merge), pinned `00a8501`, 513 files.
5. Prove the vendored copy. **done** - the tree hash equals `upstream/main`'s; the
   platform suites run from inside `platform/`.
6. Add `wolkara/tools/check_layers.sh`. **done** (`6de44fd`, hardened in `e33f3f4`) -
   platform pristine, no Wolkara strings under `platform/`, every patch applies and is
   verified to have really changed the tree. **partial** - source coverage and the
   cross-module reach-in check both exist in `check_layers.sh`, which needed no `wolkara/project.yml`
   (Phase 3, step 11).

## Phase 2 - Classify every delta: layer / replace / patch / drop / platform-owned

7. One row per changed path in `docs/LAYER_DELTAS.md`. **done** - and the set is now
   measured by content rather than by commit: of the 455 paths we share with
   `platform/`, only **57 differ** (about 4034 lines; `docs/LAYER_DELTAS.md` has the
   list and the reproduce recipe). The rows that were still unverified are resolved:
   `translation/AKSupport/AKSupport.{h,m}`, `translation/AppKit/AppKit.h`,
   `translation/IOKit/{GPUIdentity.h,Registry.m,ldflags}`, `translation/Metal/MetalTrace.m`
   and `tests/test_gpu_identity.m` are already byte-identical to the pin, so those
   "drop ours" decisions are no-ops. Only `translation/AppKit/ldflags` needs a patch,
   and it is one line.
8. Prefer upstream's newer version where it already covers our intent. **done** - every
   delta was merged onto the pin (base `05035cc`, ours `HEAD`, theirs `HEAD:platform`)
   and the results are in `docs/LAYER_DELTAS.md`: seven patches carry the platform-side
   changes, six paths need nothing at all because our copy is already upstream's, and
   three files (`translation/AppKit/AppKit.m`, `TouchControls.{h,m}`) are re-derived in
   Phase 3. Verified: the platform suite in the prepared tree is 59 PASS plus the one
   accepted codesign failure, and the generic builds link.
9. Delete branding-only deltas instead of carrying them. **todo**.

## Phase 3 - Build the layer onto a prepared tree

**Done, with one design change made on the evidence.** The plan had the layer build from
its own `wolkara/project.yml`. Measuring the platform's build showed why that is the
wrong shape: the adapters are not compiled by the app target at all - `tools/build_shims.py`
builds one `ak<Framework>.dylib` per adapter *from tree paths*, and the test scripts
compile sources the same way. A separate project would have had to re-express all of
that, and would have left every one of the platform's own scripts unable to build our
app. So the layer reaches the build by **overlay** instead: `prepare.sh` puts our files
at the platform's own paths in the prepared tree, and the platform's own `project.yml`,
shim builder and tests build our app without knowing the layer exists. We own no fork of
them, which is exactly what an ingest wants.

10. `wolkara/tools/prepare.sh` - exports the pinned `platform/` to ignored `build/platform/`,
    applies `patches/`, then overlays. **done**. Patches apply with
    `git apply -p1 --directory=<tree>` from the root and each is asserted to have really
    landed (`--check --reverse`). The overlay is checked before anything is copied: a
    `replace` entry must find its platform file, an `add` must not collide with one
    upstream now has, and either mismatch stops the run and names the path.
11. ~~`wolkara/project.yml`~~ - **superseded by the overlay** (see above): there is no layer
    project. The platform's project is the app's project, and `wolkara/tools/generate.sh`
    produces it from the prepared tree. The two build settings it was to carry are
    handled: the `AKFont` alias now lives in the platform's own `ldflags` in the prepared
    tree, and the background pacing install belongs at the layer's startup, which is part
    of the AppKit item below.
12. Move our files into the modules and stop duplicating the platform. **done** - 43 files
    moved into `Shell/`, `WoW/`, `Touch/` and `Bridge/`; 337 byte-identical root copies
    and 23 superseded ones removed, each verified against `platform/` before deletion,
    and anything that differed without being on a list was reported and left alone. The
    unused `AppIcon.appiconset` went with them. The root now holds `platform/`, `wolkara/`,
    `development/`, `docs/`, `profiles/`, `.github/` and the root documents - nothing else.
    `overlay.map` carries all 95 layer files (9 replace, 86 add).
13. Wrapper tooling. **done** - `wolkara/tools/{env,generate,install,run,package_ipa,test_emulation,test_translation_sim}.sh`.
    Each reads the root's ignored `local.env`, prepares the tree, then runs the platform's
    own script against it, so the build logic stays upstream's and `local.env` keys are
    unchanged. The layer's own test scripts prepare and run in the prepared tree too, and
    the UI scripts' simulator default was fixed while there.
14. Module boundaries. **done** - `wolkara/README.md` documents them and
    `check_layers.sh` enforces them: platform pristine, no Wolkara strings under
    `platform/`, every patch applies, every layer file carried by the overlay, every
    overlayed file present, `prepare.sh` accepts the overlay, no cross-module reach-in
    either way, and the root carries no platform path.

**Verified on 2026-10-15**: `check_layers.sh` green on all ten checks;
`wolkara/tools/generate.sh` produces `build/platform/Tolkara.xcodeproj` with our files in
it; all 22 overlaid sources compile against the iOS SDK in the prepared tree; the layer's
WoW suite and its local-service retry suite both run against the prepared tree and pass;
the platform's own suite in the prepared tree is 59 PASS plus the accepted codesign
failure.

**Closed on 2026-10-15:** the three adapter features - the Control+Option+D dictation
trigger, the occlusion a guest window is told about, and the draft panel's Replace - are
delivered as patch 0009 (one file, +28/-3), built by porting just those changes onto the
platform's current `AppKit.m` with asserted single-occurrence edits. Everything else our
adapter file used to hold turned out to be upstream's own work already (the NSView
emulation: autoresizing, subview ordering, `setHidden:`), or to live in the Touch module
now, so the file is retired and its changes exist only as the patch.

**Nothing from Phase 3 is open.** The two UI fixtures now close themselves after a
minute unless `--stay` is passed, and the ten root documents were reviewed and decided
(one merged, nine kept as ours; `AUDIT.md`). One deliberate drop is recorded there: our
`--trace-appkit-geometry` diagnostic, which served the layout work and is no longer
carried. `VALIDATION.md` checks this phase, and every other one, against the design.


## Phase 4 - Prove parity

15. Re-run the Phase 0 baseline through `wolkara/tools/*` and compare one-to-one.
    **done** - the platform suite, the layer's own suites, the compile checks and the
    project generation all re-run through `wolkara/tools/*`; the results are in
    `VALIDATION.md`.
16. Device parity on Dadpad: install (same bundle id, data preserved), game reaches the
    login screen, CASC repair line for a planted truncated index, keyboard request plus
    hardware-keyboard diagnosis, switch away to Messages and back with `arena result`
    still 1, screenshot. **partial** - post-split builds, installs and scripted device
    checks are recorded under `validation/`. The remaining physical microphone,
    controller and live-game observations must be recorded for the installed candidate;
    simulator results do not establish them.
17. Wire `check_layers.sh` into the test entry point and CI. **done locally** -
    `wolkara/tools/test_emulation.sh` now runs the gate before the suites. There is no
    pull-request CI in this repository to wire into: the only workflow is the tagged
    release build.

## Phase 5 - Ingest upstream for real

18. Ingest the 29 commits we lacked. **done** - satisfied by construction, because
    `platform/` starts at current `upstream/main` and our changes were re-expressed
    against it in Phase 2.
19. Verify the arrivals that matter here. **done, with two caveats** - BC textures pass
    (patches 0001/0002, all three runs); Steam Cloud's test is part of the platform suite
    that passes (59 PASS); the iPad Pro M5 water fix is present in `platform/` but cannot
    be checked on this M1 hardware; `management/` is deliberately not built, being the
    platform's own Mac setup app for their product rather than ours.
20. Document the ritual in `BUILDING.md`: subtree pull, `prepare.sh`, Phase 4 checks.
    **todo**.

## Phase 6 - Clean base

See `AUDIT.md` for the findings. Steps 21-25 are all **done** or **decided**: test-harness defaults and
watchdogs, dead weight, layer naming, docs truth, and style.

## Phase 7 - Contribution pipeline

26. Patch headers carry why, upstream issue or PR, and status; add
    `wolkara/tools/upstream_status.sh` to print the table. **partial** - both existing
    patches state why and are brand-free, but neither carries an issue or PR number, and
    the status script does not exist.
27. Candidates: CASC index repair, background pacing plus audio keep-alive plus occlusion,
    hardware-keyboard and dictation focus fixes, and the platform-side audit fixes. Upstream
    accepts outside PRs - `58ce3e2` arrived via tolkara/tolkara#2. **partial** - the list is
    recorded here, nothing submitted.

## Verification

1. `check_layers.sh` green: platform pristine, patches apply, coverage complete, no
   cross-module reach-in. *(both reach-in checks exist in `check_layers.sh` now)*
2. Platform suites in the prepared tree: `tools/test_emulation.sh`,
   `tools/test_translation_sim.sh`, and all three `tests/test_bc_textures` runs.
3. Layer suites through `wolkara/tools/*`, matching the Phase 0 baseline exactly.
4. Device: same bundle id with data preserved; game reaches the login screen; a planted
   truncated index is repaired and logged; the keyboard request and the hardware-keyboard
   diagnosis behave; switching away and back keeps one `arena result` and the game stays
   interactive.
5. Upstream arrivals verified: BC textures, M5 water, Steam Cloud, Management status.

## Further considerations

1. **Subtree versus submodule:** subtree is self-contained and conflict-free given a
   pristine `platform/`; a submodule keeps history lean and pins by SHA but needs
   recursive clones. Subtree now, revisit if the doubled tree becomes a problem.
2. **Patch budget:** hard rule - beyond roughly 5 files or 150 lines, move the behaviour
   behind a layer hook or land the platform change upstream first.
3. **Ingest cadence:** ingest before each work phase, gated by `check_layers.sh` and the
   device checks; do not drift another 29 commits.

## Out of scope

No change to the execution-mode security model or to AGENTS.md's compliance stance; no
renaming of platform internals; no Swift package migration; no customisation of upstream's
`management/` app.
