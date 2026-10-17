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
  **Resolved.** Both fixtures now bound themselves: without `--stay` they close after 60 s
  (`TOUCH_UI_LIFETIME_REACHED` / `TOUCH_GAMEPAD_LIFETIME_REACHED`), and the self-test paths
  keep their own 30 s watchdogs. What remains open by design is the *interactive* path: the
  two wrapper scripts pass `--stay` when you did not ask for `--self-test`, on purpose, so a
  person can look at the fixture - that is a terminal someone is watching, not a headless
  run, and both scripts' comments say so.
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
  **Resolved**, and it found a real bug: `test_wow_launcher_app.m` now covers TOC parsing,
  store import (including a duplicate import, which used to delete the installed add-on), a
  missing TOC, a minus-file, pin, disable, remove and the credentials contract.
- The two touch fixtures had no step that ran them, so their assertions were not evidence
  about anything. Both are steps in `validate.sh` now.
  **Resolved**, and it found a second real bug: the touch-controls fixture had been failing
  at one assertion for a day, because Replace had stopped replacing the game field. See
  `development/NOTES.md`.

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
  `wolkara/tools/prepare.sh`. Both files now say so where the records begin, and the
  records themselves are left as they were written: a validation log rewritten to match
  today's paths is a log of a run that did not happen. What is *not* done is auditing the
  remaining prose for the same thing.
- Everything else in this file is unchanged and still open.

### Answered rather than fixed

- **The trailing whitespace in our patches.** Every hit is a line whose entire content is
  one space - `' '`, checked against three of them - and in a unified diff that is how an
  unchanged *blank* line is written. There are nine, in five patches, and they sit between
  context lines (`...',` then `' int main(void) {'`). Removing the space would truncate the
  context and stop the patch applying, which is the opposite of hygiene. The prose headers
  of those patches have no trailing whitespace at all.
- **The `TouchControls.m:284`/`:288` style items.** Those line numbers are from the layer
  file as it was before the adapter moved behind patch `0009`; in the file that exists now
  both lines are ordinary statements. The file does use single-line accessors
  (`- (void)insertDraft { [_keyboardInput forwardCommittedText]; }`), consistently within
  itself, and the two statements the audit saw on one line are gone.
- **The two touch fixtures hanging**, above: they bound themselves now, and the paths that
  do not are the ones a person is watching.

## Branch-wide audit against upstream (2026-10-15)

Done after a mistake of ours surfaced: three files had been treated as "ours" when we
had never modified them, so overlaying them silently dropped upstream's newer work. The
same mistake could have been made anywhere, so every path this branch touches was
re-checked against upstream by comparing three versions - ours, upstream's, and the
pre-split base - and asking which side actually changed.

| Group | Count | Result |
| --- | --- | --- |
| The vendored platform | 513 files | byte-identical to `upstream/main` today (checked live on every gate run) |
| Our patches | 9 at the time of the split (14 now) | each is a three-way merge of our change onto upstream's current file, and every one merged clean, so no upstream line was dropped |
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

**One deliberate drop, recorded:** our `--trace-appkit-geometry` diagnostic (a function
and three call sites in the adapter) is not carried into patch 0009. It was a development
tool for the layout work, which is finished and tested; if layout work resumes it can be
restored from this branch's history.

## Stale forks, reviewed and decided (upstream's text had moved on and our copy had not
been merged). Each was put through the same three-way merge; nine conflict heavily
because upstream's documents are about *their* product - the launcher folder, Tolkara
Management, iPhone specifics - while ours documents ours:

| File | Decision |
| --- | --- |
| `local.env.example` | **merged** - upstream added one line documenting that `TOLKARA_PROFILE` takes several profiles separated by `:`, which their multi-profile support made true for us too |
| `.github/workflows/release.yml` | **ours kept** - upstream added a Tolkara Management DMG job for a Mac app we do not publish; we publish only the unsigned `.ipa` |
| `AGENTS.md`, `COMPATIBILITY.md`, `NOTICE.md`, `README.md`, `docs/BUILDING.md`, `docs/IPHONE.md`, `docs/TOUCH_INPUT.md`, `profiles/wow-forever/README.md` | **ours kept** - these are our product's documents, and upstream's newer text describes theirs; it stays readable under `platform/` and can be folded in file by file if we want a particular change |

Nothing here changes how the app builds or behaves.

## Found by the live device test (2026-10-15)

Three defects that only building and installing on the iPad could show. All are fixed.

1. **The layer's project settings were never carried over.** `project.yml` had been
   classified "the layer gets its own", and when that plan became the overlay, the
   settings our app needs went missing. The build stopped with `Unable to resolve module
   dependency: 'ZIPFoundation'`. Fixed as patch 0010, which puts on upstream's project the
   package and its dependency (the add-on manager unpacks archives), the licence and
   notice the app carries, this product's icon and display name, and the scheme setting
   that keeps Xcode's Metal debug device from forwarding macOS-only selectors past the
   adapter.

2. **The build location.** The platform's script asks xcodebuild for
   `-derivedDataPath build/device` and installs from `build/device/Build/Products/...`. A
   machine-wide Xcode build location overrides that - this Mac has
   `IDEBuildLocationStyle = Custom` with `IDECustomDerivedDataLocation =
   /Volumes/Storage/XCode` - so the build succeeded and the install found nothing. Fixed
   in our wrapper, not in their script: `wolkara/tools/install.sh` hands xcodebuild an
   xcconfig through `XCODE_XCCONFIG_FILE` that pins `SYMROOT` and `OBJROOT` to the layout
   their script expects. Measured before adopting it: with the xcconfig, `BUILD_DIR`
   becomes `<tree>/build/device/Build/Products`; without it, `/Volumes/Storage/XCode/Build/Products`.

3. **The package was resolved and then thrown away.** Resolving from our wrapper looked
   right and did work - "Resolved source packages: ZIPFoundation @ 22787ff" - but the
   platform's script regenerates the project at the top of its own run, which invalidates
   that resolution, and the build then cannot find the module. Fixed as patch 0011: the
   resolve happens inside their script, right after the regeneration. A project with no
   packages resolves to nothing, so for the platform itself the step costs nothing.

None of the three was visible to the suites: all are properties of the *build*, not of the
code. That is the argument for making the device install part of the phase gate.

## Open audit work: resolved or deferred (2026-10-16)

The stability audit's "open audit work" note asked for each of these to be resolved or
explicitly deferred before a stable release. Here is which, and why.

### Automated coverage

- **The add-on store and the credential store: resolved.** `wolkara/WoW/tests/test_wow_launcher_app.m`
  now drives `TKWoWAddonsAtDirectory` (which folders count, the TOC's title and version, a
  folder with no TOC, a file that is not a folder, a hidden folder) and `TKAddonStore`
  (import, the manifest it keeps, the duplicate refusal, a package with no TOC, an archive
  the extractor cannot read, pinning, disabling and restoring, removal, and the refusal to
  remove a package this store did not install). `TKAddonCredentialStore` is covered on both
  branches: the round trip, and the entitlement failure an unsigned build gets.
  **It found a data-loss bug on its first run**, now fixed in `AddonStore.m`: the failure
  cleanup removed every folder in the import, and the duplicate-package check returns through
  that path - so asking to install an add-on that was already installed deleted the one that
  was already there, leaving the manifest claiming ownership of a folder that no longer
  existed.
- **The archive extractor: deferred.** `wolkara/WoW/AddonArchive.swift` uses **ZIPFoundation**,
  a Swift package resolved at build time, so a fixture would have to fetch and build a
  third-party package to reach it. The fixture stands in for the extractor at exactly that
  boundary and tests everything on the store's side of it. The extractor itself is exercised
  on the device by importing a real add-on - that is in the device matrix.
- **CurseForge: deferred.** Everything interesting needs the network and an API key. The
  client's tests would be tests of a mock; the paths worth having (rate limits, error
  bodies, a rotated key) are only reachable against the real service. The key handling
  itself - which is the part with a security consequence - is covered above.

### Fixtures that can hang

Resolved. Every fixture app now exits by itself and says so if it does not: the launcher and
the two touch fixtures already had a 30-second watchdog, the voice fixture has one now, and
`wolkara/tools/test_voice.sh` bounds the run from outside as well. A hang is a failure with
a line in the log rather than a run that never ends.

### Stale documentation and claims

Resolved. `development/README.md` carries a "Current state" table with the counts that hold
now (platform pin, 14 patches, 91 overlay entries, 11 gate checks) and the command that
checks each one, and says that `wolkara/tools/validate.sh` is where release evidence comes
from. `PLAN.md`, `VALIDATION.md` and this file had their stale counts corrected and the ones
that are facts about the split are marked as of the split. `VALIDATION.md` points at the new
mechanism rather than standing in for it.

What is *not* resolved, and is recorded in `development/NOTES.md`: voice has no test of the
page layout beyond the fixture's screenshots, and input arbitration - what "collision-free"
would actually require - is not started.

The licences are resolved, and finding out what was actually wrong took reading the bundle
rather than the note. The app *did* ship two documents; they were **upstream's**, because
patch `0010` pointed the target's resources at `LICENSE`/`NOTICE.md` and the prepared tree
already has upstream's files by those names. So the About page showed upstream's notice
under our attribution, and this repository's own notice - the one carrying the TACTSharp and
CascLib MIT terms, which say they must accompany the software - never reached the bundle at
all. The layer now overlays ours under names of their own, the app carries all four, the
About page names whose each one is, and `device_matrix.sh` reads the installed app's own log
line back off the iPad to check it. See `development/NOTES.md`.
