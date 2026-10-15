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
| `wolkara/patches/` | us | minimal brand-free patches, each an upstream candidate | yes (2) |
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
   cross-module reach-in check are still `TODO` because they need `wolkara/project.yml`
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

## Phase 3 - Build the Wolkara project on a prepared tree

10. `wolkara/tools/prepare.sh`: copy `platform/` to ignored `build/platform/`, apply
    `wolkara/patches/*.patch`, fail loudly naming a conflicting patch. **done**
    (`e33f3f4`). It applies with `git apply -p1 --directory=<tree>` from the repository
    root and asserts each patch really landed with `--check --reverse`.
11. `wolkara/project.yml`: target `Wolkara` (developer service: `TOLKARA_INTEGRATED_AUTH=1`,
    authorization sources, embedded `LocalAuthorizationTunnel`, NetworkExtension and
    memory entitlements) and target `WolkaraDiagnostics` (External JIT). Sources =
    `wolkara/{Shell,WoW,Touch,Bridge}` plus `build/platform/{runtime,translation,authorization,support}`
    minus replaced files. `PRODUCT_NAME: Wolkara`, bundle id unchanged,
    `INFOPLIST_FILE: wolkara/Shell/Info.plist` (Wolkara display name,
    `UIBackgroundModes: [audio]`, microphone usage), icon `Wolkara`, `NATIVE_GUEST_SHIMS`
    only where needed, headers into the prepared tree, guest-runtime post-build calling
    the prepared `build_emulated_guest.sh`. **todo**.

   Two build settings the patches expect, so they are not forgotten:
   - the AppKit framework must alias the adapter's `AKFont` to `NSFont` at link time
     (patch 0004 says why this cannot live in the platform's own `ldflags`);
   - the layer's startup must call `AKInstallMetalBackgroundPacing()` itself: upstream's
     `Devices.m` is taken as-is and no longer carries that call.
12. Move our files into the modules; class names unchanged, only imports and paths adapt.
    Modules stay independent: `WoW` must not import `Touch` internals, shared needs go
    through `Bridge`. **todo** - 71 layer-candidate paths are still at the root, and 455
    upstream duplicates are still present (398 of them byte-identical).
13. Wrapper tooling `wolkara/tools/{generate,install,run,package_ipa,test_*}.sh`: prepare,
    then drive xcodegen, xcodebuild and devicectl as today's scripts do. `local.env` keys
    unchanged. **todo**.
14. Document the module boundaries in `wolkara/README.md`, and let `check_layers.sh`
    enforce no cross-module reach-in. **todo**.

## Phase 4 - Prove parity

15. Re-run the Phase 0 baseline through `wolkara/tools/*` and compare one-to-one.
    **todo** (blocked by Phase 3).
16. Device parity on Dadpad: install (same bundle id, data preserved), game reaches the
    login screen, CASC repair line for a planted truncated index, keyboard request plus
    hardware-keyboard diagnosis, switch away to Messages and back with `arena result`
    still 1, screenshot. **todo**.
17. Wire `check_layers.sh` into the test entry point and CI. **todo**.

## Phase 5 - Ingest upstream for real

18. Ingest the 29 commits we lacked. **partial** - satisfied by construction, because
    `platform/` starts at current `upstream/main`; what remains is re-expressing the
    contested deltas against that newer code (Phase 2).
19. Verify the arrivals that matter here. **partial** - BC textures: **done**, and it
    turned out to need a patch (`docs/GPU_SUPPORT.md`, patches 0001/0002). iPad Pro M5
    water rendering: **todo**. Steam Cloud suite: **todo**. Whether `management/` builds
    or is deliberately unbuilt: **todo**.
20. Document the ritual in `BUILDING.md`: subtree pull, `prepare.sh`, Phase 4 checks.
    **todo**.

## Phase 6 - Clean base

See `AUDIT.md` for the findings. Steps 21-25 are all **todo**: test-harness defaults and
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
   cross-module reach-in. *(complete except the two checks blocked on step 11)*
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
