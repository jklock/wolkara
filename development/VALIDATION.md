# Validation

> **Superseded mechanism.** Evidence now comes from `wolkara/tools/validate.sh`, which
> writes one file per commit under `development/validation/`. This page is the record of
> the split itself and is bound to the commit it names; it does not cover later work.
: every phase against the design

Each claim below has the evidence that produced it, gathered on 2026-10-15 at commit
`738001a`. Re-run the gate and the suites with the commands in `wolkara/README.md`; the
numbers here are what they print.

## The design, in one paragraph

Tolkara is vendored at `platform/`, byte-identical to `upstream/main` and never edited.
Our work lives beside it in `wolkara/` and reaches the build in exactly two ways: as a
**patch** against a platform file, or as an **overlay** of one of our files onto the
platform path it belongs at. `prepare.sh` builds the tree we compile - a pristine export,
the patches applied, the overlay copied - and the platform's own project, shim builder and
test scripts build our app from it. We own no fork of their build.

## Per phase

| Phase | What it had to deliver | Evidence | Verdict |
| --- | --- | --- | --- |
| 0 | Ground truth, pre-split tag, baseline | tag `wolkara-pre-layer`; `docs/LAYER_DELTAS.md` pins the base and upstream; `docs/LAYER_BASELINE.md` holds the suite results and device checks | **met** |
| 1 | `platform/` vendored, and a gate | 513 files; the gate compares `HEAD:platform` to `upstream/main^{tree}` live and they are equal (`1e8d13f1...`, head `00a8501`, tag `v0.2.1`); no Wolkara strings under `platform/` | **met** |
| 2 | Every delta classified | 14 patches as of 2026-10-16 (9 at the time of the split, each a three-way merge of our change onto upstream's current file, every one merged clean), 9 replacements decided by the ours/theirs/base rule, the rest additions with no upstream counterpart; the branch-wide audit in `AUDIT.md` | **met** |
| 3 | Modules, overlay, wrappers | the layer's files moved into `Shell/`, `WoW/`, `Touch/`, `Bridge/`, `Voice/`, `Input/`, `Controller/`; 91 overlay entries (9 replace, 82 add) with intent enforced; the wrappers prepare and then run the platform's own scripts; `overlay_map.sh` regenerates the map | **met** |
| 4 | Parity on the Mac suites and on the device | suites: platform 59 PASS plus the one accepted codesign failure, WoW PASS, local-service retry PASS; all overlaid sources compile against the iOS SDK; the project generates | **partial** - see below |
| 5 | Ingest upstream through the ritual | the pin *is* current upstream, so nothing was pending; the aliases are `platform/`, `upstream/main`, `git subtree`; a patch that no longer applies and an overlay that no longer matches both stop the build and name the path (proved by feeding it a bad entry) | **met** |
| 6 | Clean base from the audit | the audit's fixes are in `AUDIT.md`: the UI scripts' simulator default, the unused `AppIcon.appiconset`, `AGENTS.md`'s icon reference, the two stale forks reviewed and decided; the two remaining fixtures are now bounded | **met** |
| 7 | Contribution pipeline | 9 patches, each brand-free with a header carrying why and its upstream status | **met** (nothing submitted yet, which is a decision, not a gap) |

### Phase 4: what is missing

The suites, the compile checks and the project generation all pass, and the code that ran
on the device before the split is unchanged in behaviour - but **the app has not been
installed and run on the iPad since the split**. That is the one check this validation
cannot claim: it needs a device build and an install

```sh
wolkara/tools/install.sh            # build, sign and install on the configured iPad
```

which signs with the builder's own team and may prompt for keychain access, so it was left
for a person to run rather than attempted unattended. Everything the split changed is in
the build inputs, not the runtime, so the risk is low - but "low" is not "checked", and it
is recorded as open rather than assumed.

## Design invariants

| Invariant | How it is held |
| --- | --- |
| The platform is upstream's, exactly | gate check 1, live against `upstream/main` |
| The platform stays brand-free, so our patches stay acceptable upstream | gate check 2 |
| Every patch applies, and really changed something | `prepare.sh` asserts each with `git apply --check --reverse` |
| The overlay cannot silently drop or overwrite | a `replace` must find its platform file, an `add` must not collide; either stops the build |
| We never overlay a file we did not change | gate check "every replacement is a change of ours" |
| The modules stay independent | gate checks both directions WoW <-> Touch |
| The root is not a second copy of the platform | gate check "the root carries no platform path" |
| An ingest fails loudly rather than quietly | the two overlay rules and the patch application above |
| The bundle ID is unchanged, so installs replace in place | `$(TOLKARA_BUNDLE_ID)` throughout; `docs/GATE`-checked by the same settings files as before |
| Credentials, team ids, device identifiers stay out | `local.env` is ignored and untracked; a scan of all tracked files finds no UDID, team id, personal email or personal bundle id - only placeholders like `local.wolkara.yourname`, a keychain service name, and the device nickname `Dadpad` that `COMPATIBILITY.md` is *for* (the guidelines ask for device results there) |
| The original executable is never modified | nothing in the layer writes to an application's executable; the CASC repair rewrites the game's own index files, which is its data, not its code |
| No reverse engineering, no binary patches, no debugger after entry, no input automation | the layer adds user-driven input (toolbar, gamepad, dictation trigger) and file repair; it contains no macro, patch or attach path |

## Accepted exceptions, recorded

1. `tests/test_sign_guest_local.py::test_matches_codesign_byte_for_byte` fails on this host
   (a byte mismatch against `codesign -s -`); upstream's file, untouched by us, recorded in
   `docs/LAYER_BASELINE.md` since the baseline.
2. The platform test that aborts on `platform/` alone, at BC7's reserved mode, is fixed by
   patch 0001; the pristine tree still aborts there by design, and the prepared tree passes.
3. Our `--trace-appkit-geometry` diagnostic is not carried into patch 0009 (a deliberate
   drop, restorable from history).
4. Eight root documents stay as ours rather than merged with upstream's newer text
   (decisions and reasons in `AUDIT.md`); upstream's versions remain readable under
   `platform/`.
