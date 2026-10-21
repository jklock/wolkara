# Report outcome: stability correction plan

Status: **release blocked** until every required device acceptance test below passes on one installed commit.

## Objective

Restore a predictable Wolkara experience:

- A mapped controller reliably starts and stops dictation.
- PTT does not break game audio or leave the microphone active.
- Settings survive ordinary relaunches, updates, recovery, and configuration import.
- Backgrounding and returning is normal app behavior, not a destructive test sequence.
- Add-on import and the normal launcher remain stable.
- Device testing does not alter or discard a user’s live game session.

## Non-negotiable operating rules

1. Do not run `pilot.sh cycle`, `pilot.sh install`, `pilot.sh selftest`, or `--mic-probe` against an iPad with a live game session.
2. Do not claim that a process stop/reinstall restores an in-memory game session. It cannot. Refuse before touching the device when one is live.
3. Do not use a passing simulator test, synthetic input event, session-open check, or log-only check as proof of physical controller, microphone, background, game-input, or add-on behavior.
4. Do not add another direct `AVAudioSession` mutator outside the coordinator introduced in Phase 1.
5. Every device operation leaves the ordinary Wolkara home screen visible and the microphone inactive. A failed operation reports its actual state and does not attempt speculative recovery.

## Phase 0 — Stop the current sources of interference

### Changes

- Disable the `--mic-probe` entry point in the user app immediately, or move it to a distinct diagnostics bundle and app-data container.
- Remove `pilot.sh` commands that stop, install over, or relaunch a running game. Replace them with a preflight that exits non-zero and says that the game must be closed by its user.
- Make `restore` accurately named and scoped: it may restore the launcher only; it must not claim to restore a game session.
- Mark existing validation records before `28c7706` as historical only. They are not release evidence for the current branch.

### Proof

- Unit test: live-session state causes install, cycle, self-test, and probe commands to refuse without launching, stopping, or installing anything.
- Manual device check: invoke each refused command during a game session; verify the game remains running and no microphone indicator appears.

## Phase 1 — Establish one audio-session owner

### Design

Create an `AKAudioSessionCoordinator` owned by the host process. It is the sole code allowed to call:

- `setCategory:mode:options:error:`
- `setActive:options:error:`
- `setPreferredInput:error:`

Represent required behavior as explicit leases/states, rather than saving and replaying arbitrary session state:

| State | Intended policy |
| --- | --- |
| Launcher idle | No recording; coordinator chooses inactive or the documented launcher policy. |
| Game running | Active playback policy required by the game runtime. |
| PTT recording | One coordinator-owned recording policy; use `PlayAndRecord` if game audio must remain audible. |
| Interrupt/route loss | PTT cancelled; game policy restored only when Apple permits it. |
| Background | PTT cancelled; game policy remains only if the active game genuinely needs its audio background mode. |

### Implementation

1. Move the direct session calls from `wolkara/Voice/Dictation.m` into the coordinator.
2. Replace the CoreAudio patch’s `keepSession()` direct category/activation calls with coordinator requests. It must never force `Playback` while a PTT lease is active.
3. Use a serial execution boundary for all coordinator state transitions. Record one transition log containing old state, requested state, category, mode, route, activation result, and error.
4. Handle `AVAudioSessionInterruptionNotification`, media-services reset, route change, and available-input change in the coordinator only.
5. Treat `preferredInput` as a preference, never proof. Clear any temporary preference on PTT completion and verify `currentRoute` after activation. Apple’s API distinguishes preferred input from the actual route.
6. Define the deactivation policy deliberately. If the game owns active playback after PTT, restore its declared game lease; otherwise deactivate with `NotifyOthersOnDeactivation`. Do not blindly call `setActive:YES` after every dictation.
7. Make every coordinator transition return success/failure. Failed restore must leave an explicit recoverable state and user-visible message; it must not schedule unbounded retries or claim success.

### Tests

- Coordinator unit tests for every transition in the table, including interruption while listening, route change while listening, media reset, failed activation, failed restoration, repeated cancel, and background transition.
- A regression test proves no other source file calls session mutation APIs. A repository check may whitelist the coordinator implementation only.
- Simulator test proves PTT restores the declared game policy, not a guessed prior state.

## Phase 2 — Repair microphone diagnostics

### Changes

- If a recorder probe remains useful, make it a coordinator test operation in the diagnostics bundle.
- Capture the coordinator state before the probe, acquire a temporary diagnostic lease, stop the recorder, remove its file, release the lease, and verify the exact prior coordinator state was restored.
- Do not infer hardware health solely because `AVAudioEngine` and `AVAudioRecorder` both receive silence: both use the same process-wide session and route.
- Record route, sample rate, channel count, input availability, actual current route, and activation errors. Never label silence as hardware failure without an independent outside-app control.

### Device proof

- With the same iPad and a spoken test phrase, capture a successful PTT transcript and a successful external recording control.
- Repeat with no controller, with the mapped controller connected, after controller reconnect, and after returning from background.
- Preserve logs and the installed commit SHA for each result.

## Phase 3 — Make persistence complete and crash-safe

### Changes

1. Add `AKVoiceTakeButtonFromGame` to `TKWolkaraConfigKeys` and its schema.
2. Inventory every user-facing setting and controller mapping. The inventory must match config export, config import, the Settings UI, and persistence tests exactly.
3. Check backup copy success before replacement. If backup creation fails, retain the known-good primary and fail the write; do not replace it without a recovery copy.
4. Use one atomic replacement protocol with explicit temporary-file cleanup and durable error reporting.
5. Keep invalid user-visible config files as rejected evidence, but never let recovery overwrite the last known-good file before validation succeeds.

### Tests

- Exhaustive settings inventory test: every editable setting has export, import, relaunch, and recovery coverage.
- Test that `AKVoiceTakeButtonFromGame` survives config export/import and a cold process relaunch.
- Fault-injection tests for temporary write failure, backup-copy failure, replacement failure, malformed primary plus valid backup, malformed primary plus malformed backup, and termination between write stages.
- On-device test: change every voice/control setting, cold relaunch, update the app without deleting its data, then cold relaunch again; compare all visible values and mapped controller behavior.

## Phase 4 — Replace brittle device automation with a safe validation protocol

### Tool changes

- Split tools into read-only inspection and destructive staging.
- Read-only inspection may collect process state, app logs, audio coordinator state, config checksum, and crash reports.
- Destructive staging requires: unlocked device, no game session, microphone inactive, explicit build SHA, and a baseline captured in the same session.
- A failed inspection is `NOT RUN`, never “no issue found.”
- A new install proves only build/install/launch. It does not prove microphone, controller, backgrounding, persistence, or add-on functionality.
- Remove the artificial requirement that every developer operation ends by relaunching Wolkara. For acceptance runs, leave the app on its ordinary home screen only after the test has deliberately completed; do not disturb an active user game to satisfy a harness convention.

### Tool tests

- Extend `test_pilot.sh` for refusal states, lock-state diagnostics, same-session baselines, and zero mutation on refusal.
- Add a test that no tool reports a restored game session after process termination.
- Add structured per-run evidence: SHA, bundle version, device OS/model, command, start/end state, exact test verdict, and failure reason.

## Phase 5 — Physical acceptance matrix

Run this matrix manually on the acceptance iPad after installing one final SHA. Do not substitute simulator or self-test results.

| Test | Required result |
| --- | --- |
| Cold launch | Launcher is responsive; no crash; saved settings appear unchanged. |
| Controller mapping | Map a real controller button, cold relaunch, and confirm the same button still operates PTT. |
| PTT transcription | Speak a known phrase; it appears once in the game chat target. Verify auto-submit behavior separately. |
| Game audio during PTT | Start PTT while game audio is active; behavior matches the chosen policy and resumes after release. |
| PTT exit paths | Release, toggle-off, cancellation, interruption, route change, and background all end with microphone inactive. |
| Background/return | Background the running game, return, and confirm the game and controller remain usable without a crash. |
| Settings durability | Change all settings, cold relaunch, update without deleting data, relaunch, and verify all values/mappings. |
| Add-on manager | Download/import a real permitted ZIP, verify it appears, cold relaunch, and verify it remains available. |
| Stability | Repeat PTT/background/return at least ten times; no crash, no stuck mic, no missing controller mapping, no silent transcript. |

For each row, record the device, iPadOS version, app SHA, execution mode, exact action, observed result, coordinator transition log, and whether the microphone indicator was inactive at completion.

## Release gate

Release only when all of the following refer to the same final SHA:

1. Focused coordinator, persistence, config-fault, input, and add-on tests pass.
2. Layer integrity passes.
3. A clean install/launch is demonstrated with a safe, non-destructive staging tool.
4. The complete physical acceptance matrix passes on the target iPad.
5. The final record distinguishes device proof from simulator/unit proof and lists any unrun check as `NOT RUN`.

## Explicit non-goals for this correction

- Do not redesign controller mappings or add new controller features.
- Do not change game binaries, game memory, game integrity behavior, or automate gameplay.
- Do not interpret a diagnostic result as a reason to restart, uninstall, or erase user app data without explicit user direction.
