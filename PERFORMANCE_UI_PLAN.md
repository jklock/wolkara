# Performance & UI implementation plan

## Objective

Create branch `PerformanceUI` from the current `main` checkout. Update the
WolkaraForever home page and integrate the Metal performance-overlay pull request
([fJavierLasso/wolkaraforever#2](https://github.com/fJavierLasso/wolkaraforever/pull/2)).

The homepage is the control surface, but four of its rows are deliberately
**WoW Forever file operations**, not WolkaraForever settings:

- `Backup WoW UI Configuration`
- `Reset to Default Graphical Settings`
- `Restore WoW UI Configuration`
- `Enable Gamepad UI`
- `Open Settings Folder`

They operate only on the installed Forever edition at
`_classic_beta_/WTF`. They must never read or write another edition's files,
WolkaraForever configuration, controller-layout preferences, account state, add-ons,
or the game's `GamePadConfig_*.json` and `gamecontrollerdb.txt` files.

## Homepage changes

Edit `wolkaraforever/WoW/WoWViewController.m` and its UIKit fixture as follows.

1. Create `PerformanceUI` from the current `main` commit before making any
   source changes. Do not edit `platform/`.
2. Rename the existing add-on heading to `Add-On Manager`. Rename its existing
   management row to `Install Addons (Curse & Direct)` in both its initial
   title and every state rendered after installation checks.
   Keep its action, availability rule, accessibility identifier, and
   `Open Add-on Directory` row unchanged.
   Add a `Download Mac-Ever` row beneath the installer. It opens
   `https://www.curseforge.com/wow/addons/mac-ever` externally through
   `UIApplication openURL`, so the user downloads the Forever-compatible
   Mac-Ever ZIP in Safari/the device's configured browser, then returns to
   `Install Addons (Curse & Direct)` to select and install that downloaded ZIP.
   Do not scrape CurseForge, embed a download URL, or claim installation
   succeeded when the browser opens; the existing archive-import validation is
   the sole installation proof.
3. Rename the Voice heading to `Voice Manager` and present these rows in
   this exact order:
   1. `Toggle Permissions (Mic & Speech)` -> the existing app Settings action.
   2. `Key / Button Configuration` -> the existing voice configuration page.
   3. `Test Voice & Dictation` -> the existing voice test page.
   Preserve the current permission rule: it remains enabled even while the
   game is unavailable or busy.
4. Add a fourth, final left-column heading, `Performance & UI Manager`, after all
   existing homepage content (including the compatibility message). Its rows,
   in this exact order, are:
   1. `Backup WoW UI Configuration`
   2. `Reset to Default Graphical Settings`
   3. `Restore WoW UI Configuration`
   4. `Enable Gamepad UI`
   5. `Enable Performance Overlay`
   6. `Open Settings Folder`
5. Give every row a stable `wow.performance.*` accessibility identifier.
   The four Forever configuration rows and folder row are enabled only when
   Forever is installed, ready, and no download/start/session is active.
   Overlay is a WolkaraForever runtime feature and follows the non-busy launcher
   availability rule. Render enabled state explicitly: use `Enabled` for an
   active gamepad/overlay row and `Enable ...` when inactive; never perform a
   destructive reset without a confirmation sheet.

## WoW Forever UI backup, reset, and restore

All paths below are resolved from the inspected Forever installation's working
directory. Canonicalize every path and reject a path that is outside that root.
Use existing bounded file-error patterns from the WoW module. The game must be
closed: disable these actions for `_busy`, `_starting`, or `_sessionUsed`, and
recheck that guard inside every handler.

### Archive contract and safety rules

- Live UI roots: `_classic_beta_/WTF/` and `_classic_beta_/Interface/`.
- Backup directory: `_classic_beta_/WTF/Backups/`.
- Backup name: `WoW-UI-YYYY-MM-DDTHH-mm-ssZ.zip`; generate a collision-safe
  suffix if two snapshots are made within one second.
- Each archive contains exactly `WTF/`, `Interface/`, and a versioned manifest
  that identifies the Forever edition, creation time, entry count, and SHA-256
  of every archived regular file. Exclude `WTF/Backups/` itself, caches, logs,
  errors, executables, and all other game data.
- Add a dedicated Swift `ForeverUIArchive` writer/restorer using the project's
  pinned ZIPFoundation, rather than repurposing the add-on importer. It accepts
  regular files and directories only; rejects symlinks, special files,
  absolute/traversal paths, duplicate paths, malformed manifests, oversized
  entries, and archives with a mismatched edition or digest.
- Create archives in a temporary sibling, validate by reopening and checking
  every manifest digest, then atomically rename to the final ZIP name. Failed
  backup leaves the live UI untouched and no partial ZIP visible.
- Do not log config, account, bindings, or SavedVariables content; only a
  relative archive name and concise error reason.

### Backup WoW UI Configuration

Create a ZIP snapshot of the complete Forever UI state: all of `WTF/` except
its `Backups/` directory, and all of `Interface/` including installed add-ons.
Show the relative ZIP name and leave it in `WTF/Backups/` for the Restore row.
This is an explicit user action and is also run automatically before a reset or
restore, so either destructive action always has a current rollback point.

### Reset to Default Graphical Settings

1. Create and verify the complete UI ZIP backup above; abort reset if backup
   creation fails.
2. Present a destructive confirmation explaining that Forever will regenerate
   graphics defaults on the next launch while the complete UI backup remains
   available for one-click restore.
3. Remove only graphics settings from `WTF/Config.wtf`, using a tested,
   explicit Forever graphics-CVar allowlist. Preserve account/login, locale,
   audio, UI, input, gamepad, cache, bindings, SavedVariables, Interface, and
   all other files. Write the modified config atomically.
4. Report the backup ZIP name and that the default graphics settings take effect
   when Forever next launches.

The graphics allowlist must contain only measured Forever graphics/display
CVars. It must exclude every `GamePad*`, account, locale, audio, cache, input,
and UI CVar; unknown settings are preserved rather than guessed.

### Restore WoW UI Configuration

1. Select the newest valid `WoW-UI-*.zip` in `WTF/Backups/`; this is a
   one-click restore, not a file-picker workflow. If no valid backup exists,
   explain that Backup must run first.
2. Create and verify a fresh complete UI ZIP of the current state before
   restoring, so Restore itself can be undone.
3. Fully validate the selected ZIP and extract it into a new sibling staging
   directory. Verify its manifest, every digest, and that the staged tree
   contains only `WTF/` and `Interface/` before touching live files.
4. Copy the live `WTF/Backups/` directory into staged `WTF/Backups/` so all
   snapshots survive the restore. Swap staged `WTF` and `Interface` into place
   using a journaled two-directory transaction: persist a recovery journal,
   move live roots to recovery names, move both staged roots live, remove the
   journal only after both succeed, and roll back both roots on any failure.
   On the next launcher start, detect and finish or roll back an interrupted
   journal before exposing the home page.
5. Confirm the restored archive name and state that the complete Forever UI—
   settings, bindings, SavedVariables, gamepad configuration, and add-ons—will
   apply on the next launch.

### Enable Gamepad UI

1. Read and validate the active Forever `Config.wtf`; create a new bounded
   UTF-8 config only if it is absent.
2. Parse by lines, remove every existing `SET GamePadEnable ...` assignment,
   preserve all other lines byte-for-byte where possible, then append exactly
   `SET GamePadEnable "1"` followed by a newline.
3. Atomically replace the active config. Re-read it and assert exactly one
   `GamePadEnable` assignment with value `1` before showing success.
4. Do not modify the existing `GamePadConfig_Default.json`,
   `GamePadConfig_Addons.json`, or `gamecontrollerdb.txt` files. Change the row
   to `Gamepad UI Enabled`; it is not a WolkaraForever touch-gamepad preference and it
   does not alter any bindings. It takes effect when Forever next starts.

### Open Settings Folder

Open the platform document picker at the Forever `WTF` directory. Create that
directory only when a ready Forever installation exists and the directory is
missing; do not create an add-on folder or a WolkaraForever folder as a side effect.
The picker is navigation only and makes no configuration change.

## Performance-overlay PR integration

PR #2 is a useful starting point, but it must be incorporated through the
WolkaraForever layer, not merged or copied into `platform/`.

1. Review the PR's ten changed files against the pinned upstream tree, then
   port only the required behavior:
   - presentation-time FPS and frame-duration collection in Metal;
   - a movable, expandable, safe-area-clamped HUD with metrics for FPS,
     frame time, thermal state, battery, charging, memory footprint/headroom,
     and Low Power Mode;
   - persisted overlay enabled state, position, and expanded state;
   - the existing in-game touch-controller settings toggle and reset behavior;
   - host-view attachment and lifecycle-driven start/stop monitoring.
2. Put new AppKit/touch sources and fixture tests in the appropriate
   `wolkaraforever/` layer directories. Regenerate `wolkaraforever/overlay.map`; every new
   overlay file must be tracked and carried into the prepared tree.
3. Express changes to existing upstream `translation/AppKit/AppKit.m` and
   `translation/Metal/Presentation.m` as ordered files in `wolkaraforever/patches/`.
   Patches must apply cleanly to the pinned platform with no direct platform
   modifications.
4. Keep performance collection observational: use Metal presentation timestamps
   and public iOS system APIs only. Do not inspect guest memory, alter guest
   code, enable frame capture/readback for the HUD, or add game automation.
5. Preserve the PR's default-off setting. Make the homepage overlay row update
   that same persisted preference with a read-modify-write operation that
   preserves existing touch-layout values and posts the layout-change
   notification. Do not import Touch from WoW; the existing layer gate
   prohibits that cross-module dependency.
6. Before accepting the port, correct any integration defects found in review:
   HUD timers/display links must run only while the overlay is visible and in a
   window, position restoration must be clamped after layout changes, and all
   preference writes must remain compatible with existing layout data.

## Tests and acceptance evidence

### Focused automated coverage

- Extend `test_wow_launcher_app.m` to assert every exact homepage heading,
  label, ordering, identifier, enabled/disabled state, confirmation flow, and
  page destination. Inject/spy on the external-URL opener so `Download
  Mac-Ever` is proven to request exactly the CurseForge project URL without
  opening a browser during the fixture.
- Add focused Forever UI-archive tests using temporary `_classic_beta_/WTF`
  and `Interface` fixtures: deterministic archive contents, manifest/digest
  verification, backup-directory exclusion, symlink/path-traversal/special-file
  rejection, malformed and oversized ZIP rejection, latest-valid-backup choice,
  restore staging, journal recovery, two-root rollback, and backup retention.
- Add config tests that prove graphics reset preserves account, locale, audio,
  UI, input, gamepad, bindings, and unknown settings; also cover duplicate
  `GamePadEnable` normalization and missing-config creation.
- Port and expand the PR's touch/host tests to prove preference persistence,
  reset-to-off, host visibility, HUD expand/collapse, safe-area clamping, and
  monitoring lifecycle.
- Update the existing simulator scripts only for new source/link inputs;
  preserve their synthetic/no-network nature.

### Required verification order

1. Run the new targeted Forever-config test and homepage fixture.
2. Run `wolkaraforever/tools/check_layers.sh`; it must confirm platform identity,
   patches, generated overlay map, and prepared-tree integration.
3. Run the relevant translation/touch simulator suite and launcher UI fixture.
4. Build and install the exact candidate SHA on the iPad. Verify on that build:
   backup creates a verified Forever UI ZIP and leaves the app on its normal
   home; reset preserves non-graphics state; Restore returns the full UI from
   the newest ZIP; gamepad config survives a launch;
   Files opens Forever `WTF`; and the overlay displays live metrics, can be
   moved/expanded, persists, and remains off after its reset action.
5. Record the exact SHA, commands, concise results, and device observations in
   the existing compatibility/release evidence. Do not call simulator or
   structural success physical-game proof.

## Non-goals

- No changes to a game executable, signing, or other editions. Add-ons,
  SavedVariables, bindings, and account/UI state are changed only by the
  explicitly requested full-UI backup and restore transaction.
- No modification of `platform/`.
- No generic CVar-tuning preset, performance benchmark claim, controller
  automation, or guest-memory inspection.
