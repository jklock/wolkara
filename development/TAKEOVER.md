# Takeover note: layer and controller work

Recorded 2026-10-16 from the current local checkout. This is an inventory and
handoff, not a new device-validation claim.

## Branches

- `main` and `feature/wolkara-above-tolkara` are both at `1bb8d0f` (`notes: the
  dictation selector trap, and the enrolment screen the install leaves behind`).
  That branch completed the structural split: pristine `platform/`, the
  `wolkara/` overlay layer, 14 patches, wrappers, and the recorded validation
  and device-work notes in this directory.
- `controller` is checked out, tracks `origin/controller`, and is 11 commits
  ahead of that base, ending at `2190647` (`Voice: a Voice row in the launcher,
  and Handy's options on it`). It adds controller inspection, a generic input
  router/trigger model, and voice dictation/settings/launcher UI.
- Do not treat the device observations committed on `controller` as rerun in
  this takeover. The evidence is recorded in `docs/CONTROLLER_INPUT.md`; this
  review only confirmed the source, history, layer gate, and generated project.

## `wolkara-above-tolkara` state

The layer is built by exporting `platform/` to ignored `build/platform/`,
applying patches, and overlaying files at the platform paths. It deliberately
does not build from a separate Wolkara Xcode project. `check_layers.sh` checks
the upstream pin, patches, overlay completeness, replacement intent, module
boundaries, and a prepared-tree dry run.

The plan still records Phase 4 (post-split device install/run), Phase 5
(upstream ingestion ritual), and Phase 7 (submitting the patch set) as partial.
Phase 2's branding-only deletion remains todo. `development/PLAN.md` was last
reviewed before the controller commits, so its summary counts/status must not be
used to describe the controller additions without refreshing it.

## Controller and voice implementation

Committed controller scope is 24 files / 2,199 added lines relative to the
layer base:

- `ControllerInspector` inventories Game Controller, keyboard, mouse, and the
  Share-derived system notifications; `ControllerWindow` records host presses.
- `InputRouter` normalizes inspector events and matches press, double, long,
  chord, and push-to-talk patterns. `Trigger` persists a mapping under
  `AKInputTrigger.<vendor>`.
- `Dictation` uses `AVAudioEngine` plus `SFSpeechRecognizer`, then inserts text
  through the existing game input path and can optionally send Return. Settings
  cover hold/toggle, auto-submit, trailing space, and contextual words.
- The launcher exposes a Voice settings screen. Documentation is in
  `docs/CONTROLLER_INPUT.md`, `docs/INPUT_TRIGGERS.md`, and `docs/VOICE.md`.
- Patches `0012` and `0013` add guest-input and host-key boundary diagnostics to
  the prepared platform tree.

No focused unit or simulator tests for the new Controller/Input/Voice modules
are present. Existing Touch tests are not coverage for this code. Treat device
input, Speech authorization/recognition, text insertion, and auto-submit as
unverified by this takeover until exercised in the intended app/device flow.

## Current dirty worktree: preserve and finish deliberately

The checkout has uncommitted/staged work after `2190647`; it is not part of the
reviewed controller branch tip:

- Staged: a large Wolkara logo image set and source artwork.
- Modified: file-sharing plist keys; dictation callbacks for a launcher test
  screen; launcher layout/add-on-directory UI; overlay-generator and layer-gate
  hardening.
- Untracked: `WolkaraConfig.{h,m}`, `VoiceTestViewController.{h,m}`, and
  `wolkara/tools/pilot.sh`.

Important integration gap: `overlay_map.sh` discovers only tracked files via
`git ls-files`. Therefore the untracked `VoiceTestViewController` is not in
`overlay.map`, is not copied into `build/platform`, and cannot yet be compiled
by the generated app. The strengthened gate passes because it likewise sees
tracked files only. Add/track the intended files, regenerate the map, then run
the targeted build or simulator path before considering this UI usable.

## Checks run for this handoff

| Check | Result |
| --- | --- |
| `git diff --check` and `git diff --cached --check` | pass |
| `wolkara/tools/check_layers.sh` | pass: 11 checks, platform pin `00a8501`, 14 patches, prepared overlay accepted |
| `wolkara/tools/generate.sh` | pass: prepared `build/platform` and generated the platform project |

Neither command compiled nor installed the current untracked voice-test UI, and
neither is device proof.

## Recommended resumption order

1. Reconcile the dirty launcher/logo/voice-test work into a coherent tracked
   change; regenerate `overlay.map` and rerun the gate.
2. Add focused tests for trigger matching/persistence and dictation routing;
   run the narrowest simulator or compile target that includes the new files.
3. On the iPad, re-run the documented controller matrix and voice paths,
   including permissions, hold/toggle, text delivery, and auto-submit; record
   outcomes separately from the prior measurement.
4. Refresh `development/PLAN.md`, `VALIDATION.md`, and this note when a phase
   or the above evidence changes.
