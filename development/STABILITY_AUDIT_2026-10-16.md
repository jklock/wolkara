# Stability audit: main plus controller

**Status: do not release as stable.**

Read-only audit recorded 2026-10-16 and updated after remediation review.
Scope is every committed change from `wolkara-pre-layer` (`02ec787`) through
the current `controller` tip `fe03af0`.

- `main` and `feature/wolkara-above-tolkara` both stop at `1bb8d0f`.
- `controller` adds eleven controller/voice commits through `2190647`, then
  `5b073ee` for the home screen, configuration persistence, pilot tooling, and
  integration, plus remediation commits `1dec7d6` and `fe03af0`.
- Do not silently apply this audit to future uncommitted work.

The layer split is a good structural direction: pristine vendored `platform/`,
small patches, an overlay map, wrappers, and a gate are safer than the prior
fork. That does **not** make the application release-ready. The remediation
adds useful focused fixtures and fixes several original findings, but the
remaining blockers below are sufficient to keep the release status unchanged.

## Remediation review: `1dec7d6` and `fe03af0`

The following original items are materially improved: voice is off by default;
there is no fallback trigger; canonical element IDs replace display text; Share
system gestures are released only for a mapped controller element; mapping
timeout cancels; on-device recognition is required; mode-specific post-install
work is split; and focused voice/config/tooling fixtures were added. The layer
gate passes.

Those changes are not a stable-release pass. The remediation itself leaves the
following blockers.

### P1: a rejected primary config can recurse through a rejected backup and crash

`rejectFileBecause:` copies `.bak` over the primary and calls `importFromFile`
again whenever the backup parses as a dictionary
(`wolkara/Shell/WolkaraConfig.m:266-282`). It does not validate that backup
against the schema first and has no one-attempt guard. A malformed primary plus
an invalid-but-JSON `.bak` repeats this path until stack exhaustion. Both files
are reachable from the user-editable Documents import boundary.

Required fix: validate the backup before restoring it, attempt fallback at most
once, and retain/report invalid snapshots without recursively importing them.
Add a corpus case containing invalid primary and invalid backup; it must launch
without recursion, data loss, or a crash.

### P1: `system.screenshot` remains an untrustworthy voice trigger

The default fallback is gone, but `screenshotTaken:` still reports
`system.screenshot` (`ControllerInspector.m:117-125`) and `markSystemDevice`
attributes it to the first connected controller (`ControllerInspector.m:144-150`).
iPadOS does not reveal whether a controller or the user took the screenshot.
If that system signal is deliberately mapped, an ordinary iPad screenshot can
still start dictation for that controller.

Required fix: do not offer or persist screenshot as a voice trigger unless a
controller-specific event is available. A user mapping a signal does not make
an un-attributable system notification safe.

### P1: timeout delivers partial speech despite the final-transcript promise

After the final-result deadline, `end` calls `finishWithTranscript:nil`
(`wolkara/Voice/Dictation.m:282-294`). That delivers `_transcript`, which holds
the latest partial result (`Dictation.m:309-335`). The focused fixture
explicitly expects this behavior. It contradicts `docs/VOICE.md`'s claim that
voice will not deliver a half transcript and can type/send incomplete chat.

Required fix: on final-result timeout cancel without insertion and show an
actionable error, or introduce an explicit, off-by-default user policy for
partial delivery. Do not describe partial fallback as final recognition.

### P1: audio-session active state is still changed

`AKAudioSessionBridge` snapshots category, mode, and options, but no active
state (`Dictation.m:123-140`). `restore` unconditionally calls
`setActive:YES` (`Dictation.m:143-155`). This is not restoration of the
previous session and can leave game/background audio active when it was not.

Required fix: preserve the actual pre-dictation ownership/activation contract,
including interruptions and route behavior, or use an audio-session policy
whose documented, tested result does not claim exact restoration.

### P1: generated validation falsely combines a failed install with a passing device log

`validate.sh` checks cleanliness, then creates its output under
`development/validation/` before invoking commands that run `prepare.sh`
(`wolkara/tools/validate.sh:43-65,115-134`). It therefore dirties its own
checkout. Its `fe03af0` manifest records a failed device install (`pilot.sh
cycle`, exit 2) but subsequently runs `pilot.sh log` and records that stale log
as PASS. That log contains old unsafe `Share held (screen capture on)` output,
not proof that `fe03af0` ran.

Required fix: collect transient validation output outside the checkout; only
publish a manifest after all steps finish. Fail fast after install/launch
failure and mark dependent device checks `NOT RUN`. Bind console/log evidence
to the launched build ID and process launch, not merely to an app container.

### P2: identical controllers still share a mapping identity

`AKControllerIdentity` is vendor plus product category
(`wolkara/Controller/ControllerInspector.m:43-46`). Two identical controllers
therefore share one defaults key, despite the header claiming two pads are
distinct. This can make one user's mapping alter another controller's behavior.

Required fix: use a stable per-device identifier when GameController provides
one; otherwise document and implement a safe per-model policy rather than
claiming per-controller persistence.

### P2: input state has no concurrency boundary

GameController handlers mutate inspector/router state while delayed long-press
work runs on the main queue (`ControllerInspector.m:450-474`,
`Input/InputRouter.m:47-56,255-271`). No serial queue or main-thread assertion
protects `_states`, `_down`, current-device fields, or learning state.

Required fix: funnel every input event and mapping operation through one serial
queue (or the main queue), then add a stress test and physical-controller test
for concurrent/repeated input.

### P2: config write is not atomic

The code writes a temporary file, removes the primary, then moves the temporary
file (`WolkaraConfig.m:359-376`). A termination or move failure between removal
and move leaves no primary config; first-run users have no backup to recover.

Required fix: use an atomic replacement API that preserves the old file until
the new file is committed, fsync as appropriate, and test interruption/failure
recovery.

## Release blockers (P1)

### Voice activates from an unrelated screenshot

`AKControllerInspector` converts every
`UIApplicationUserDidTakeScreenshotNotification` into `Share` whenever a
controller is connected (`wolkara/Controller/ControllerInspector.m:96-104`).
It cannot know whether a controller caused the screenshot. `AKVoiceSettings`
also supplies an active Share fallback even when the user has not mapped or
enabled voice (`wolkara/Voice/VoiceSettings.m:61-71`).

An ordinary iPad screenshot can therefore toggle microphone dictation. This is
a privacy and user-expectation failure.

Required fix:

1. Voice must be disabled until explicit user enablement and mapping.
2. Remove screenshot/screen-capture notifications as automatic triggers.
3. If retained as an optional fallback, require separate disclosure and opt-in.
4. Test that unrelated screenshot/capture notifications never alter dictation.

### Share system behavior is disabled globally at startup

The app starts inspector/router on every scene connection
(`wolkara/Shell/main.m:202-227`). A controller that declares Share has its
preferred system gesture disabled (`ControllerInspector.m:273-279`). There is
no user opt-in, per-device choice, disconnect cleanup, or restoration.

This conflicts with the screenshot fallback and changes expected controller
behavior before the user chose a voice feature.

Required fix: inventory must be read-only. Disable a system gesture only after
the user maps that exact physical element; restore it when mapping/voice is
removed or the controller disconnects. Test unmapped, mapped, disabled,
reconnect, and multi-controller cases.

### Physical Share does not match the default trigger

Physical events use `Button Share`, while the fallback stores `Share`
(`ControllerInspector.m:231-236`, `VoiceSettings.m:68-70`). The default cannot
match a controller that exposes a real Share element; it only works via the
unsafe screenshot workaround.

Required fix: use canonical typed event IDs, e.g. `controller.button.share`
and `system.screenshot`, not display text as match/persistence keys.

### Dictation sends a partial transcript

`stopAndSend` copies the current transcript before ending audio and finishing
the speech task (`wolkara/Voice/Dictation.m:139-154`). It does not wait for a
final recognition result. The last words can arrive after text and optional
Return have already been delivered.

Required fix: explicit `idle`/`authorizing`/`listening`/`finalizing` state;
end audio, await final result or terminal timeout/error, then deliver exactly
once. Cover final-result ordering, denial, cancellation, rapid toggles, and
duplicate triggers.

### On-device recognition is promised but not enforced

The usage string promises recognition runs on the iPad
(`wolkara/Shell/Info.plist`), but the request only requires on-device
recognition when the recognizer already supports it
(`wolkara/Voice/Dictation.m:98-101`). Unsupported devices can fall back rather
than fail closed.

Required fix: refuse recognition when on-device support is unavailable, or
correct product copy and add an explicit network-recognition setting.

### Dictation does not restore host audio configuration

Dictation sets `AVAudioSessionCategoryRecord` then always leaves the app at
`AVAudioSessionCategoryPlayback` (`Dictation.m:81-89,157-169`). It does not
restore category, mode, options, active state, or route. Game audio, Bluetooth,
mixing, and background behavior can change after first use.

Required fix: snapshot and restore the full prior audio-session configuration
on every success, error, permission-denial, cancellation, and finalization
path. Prove it on speaker, Bluetooth, headphones, and background/foreground.

### “Any button” is neither collision-free nor complete

The router observes input but does not stop the game receiving it
(`wolkara/Input/InputRouter.m:136-215`). A long/double/chord press can still
perform the game action. The UI creates only press or push-to-talk mappings
(`wolkara/Voice/VoiceSettings.m:74-78`); it offers no complete long/double/chord
choice despite partial router code.

Required fix: either limit the product to explicitly mapped inputs with a
collision warning, or implement real input arbitration/ownership. Do not
describe patterns as universally safe until they are.

**Resolved by the first branch, 2026-10-16.** Arbitration is not implemented and
is still not started; instead the product is limited to explicitly mapped inputs
and says what that means. The page that makes the mapping now carries the warning
in those terms - "The button you map still reaches the game. Nothing here takes it
away from the game, so choosing one the game already uses makes it do both things
at once" - the same sentence is written to the log when a mapping is saved, and
`docs/VOICE.md` has a section stating what the feature cannot do: no arbitration,
no ownership, no pattern that makes a shared button safe. The second half of the
finding is answered too: the page offers two modes and no double/long/chord
choice, and both the docs and the fixture say so rather than leaving the trigger
model's five patterns to be mistaken for five options. The fixture asserts the
warning is on the page and that the mode control has two segments, so neither can
disappear silently.

### Mapping timeout leaves the mapper armed

After 20 seconds the UI says nothing arrived, but it never clears
`AKInputRouter.learning` (`wolkara/Voice/VoiceViewController.m:114-125`). The
next arbitrary event silently becomes a saved mapping.

Required fix: implement `cancelLearning`; call it on timeout, view dismissal,
backgrounding, mode change, and controller disconnect. Test that a post-timeout
event cannot modify persistence.

### Installation always enrolls developer service

`wolkara/tools/install.sh` always invokes `tools/enroll.sh` after installation
(`wolkara/tools/install.sh:158-168`). That is developer-service work and is
wrong or unnecessary for Local Signing and External JIT.

Required fix: branch post-install work by `TOLKARA_MODE`: enroll only Developer
Service; validate page containers for Local Signing; never enroll External JIT.
Add mocked shell tests proving each mode avoids unrelated external actions.

## Serious correctness gaps (P2)

### Controller model

- D-pad element names include x/y values and touchpad names include coordinates
  and state (`ControllerInspector.m:246-270`), so learned mappings are unstable.
  Persist a stable identifier; hold values as metadata.
- Mappings are keyed only by `vendorName` (`ControllerInspector.m:225-229`,
  `Input/Trigger.m:63-87`), not by device/product. Controllers of the same
  vendor overwrite each other. Use a versioned composite identity and migrate.
- Right/middle mouse handlers do not mark device/source, so they use stale
  identity from a prior event (`ControllerInspector.m:291-306`). Put identity on
  every event; remove global “current event” fields.
- Controller callbacks mutate mutable state while long-press callbacks run on
  main. Route all events/state through one serial queue and assert confinement.
- Dictation recursively searches every scene/window for a private selector
  (`wolkara/Voice/Dictation.m:173-213`). The active game session should own and
  provide the target. Require explicit game/chat focus before inserting text.

### User-editable configuration added by `5b073ee`

`Documents/wolkara-config.json` is automatically imported on launch and wins
over defaults (`wolkara/Shell/WolkaraConfig.m:47-90`). File sharing is enabled,
making this a user-editable import boundary.

- The advertised version is never read/validated.
- Values are copied into defaults without per-key type, range, enum, or schema
  validation. A malformed `AKInputTrigger.*` dictionary can create an invalid
  trigger pattern; summary code indexes a fixed pattern array. A malformed file
  can crash or corrupt behavior.
- It automatically exposes custom recognition words, trigger mappings, and
  auto-submit preference in shared Documents. These are not credentials, but
  automatic export needs a clear privacy/lifecycle choice.
- Every defaults notification causes a synchronous file rewrite, including
  unrelated defaults changes.

Required fix: strict versioned JSON schema; validate before commit; reject
unknown/invalid data; write temp+backup; coalesce on a serial queue; show import
errors; make import/export explicit or clearly controllable. Add malformed-file
corpus tests.

### Voice test screen

The test screen globally replaces `AKDictation` handlers. Add tests proving
every navigation/scene/failure path clears handlers and cannot route a late
transcript into the game or retain a dead screen.

### Pilot tooling

`pilot.sh` is a useful safety direction but not a proof system. Fixed global
`/tmp/pilot-*` names collide across runs; inspection failures are commonly
treated as empty/no-event data; “recent staged update” is only a timestamp
heuristic. Use one `mktemp -d` session directory, fail closed on inspection
errors, and test mocked `devicectl` JSON/failure cases.

## Layer and release-integrity gaps (P2)

### Exact-SHA validation is absent

`development/VALIDATION.md` is tied to `738001a`, not `5b073ee`
(`development/VALIDATION.md:1-5`). Later install, CASC, touch/dictation,
controller/voice, config, and pilot changes are not validated by that evidence.
The device-success claim in `5b073ee` is useful observation, not a recorded,
replayable release proof.

Required fix: generated validation manifest per candidate SHA: clean-worktree
state, commands, device/simulator model and OS, timestamps, outputs, logs,
screenshots, and observed result.

### Gate/prepare can validate a hybrid tree

`prepare.sh` exports `HEAD:platform`, but `apply.sh` applies patches and copies
overlay sources from the working tree (`wolkara/tools/prepare.sh:14-23`,
`wolkara/tools/apply.sh:45-97`). A dirty checkout can build uncommitted layer
code while evidence names only a commit SHA.

Required fix: release/validation commands fail on a dirty worktree by default.
Allow explicit `--allow-dirty` only for development and print dirty files.
Materialize every recorded build input from the requested commit.

### Open audit work

`development/AUDIT.md` still records no automated AddonManager/Archive/Credential/
CurseForge coverage, UI fixtures that can hang without `--self-test`, and stale
documentation paths/test claims. Resolve or explicitly defer each before stable
release. A test harness that can hang is not acceptable CI/release tooling.

### Documentation and hygiene

`README.md`, `PLAN.md`, `AUDIT.md`, and `VALIDATION.md` disagree on phase state,
patch counts, overlay counts, and remaining work. Reconcile them into one
SHA-bound source of truth. Wolkara-owned patches also have trailing whitespace;
clean those without changing intentionally byte-identical vendored platform.

## Required verification after remediation

1. Unit/simulator tests for canonical IDs, mapping persistence/migration,
   cancellation, disconnect, screenshot isolation, and all trigger patterns.
2. Dictation tests for permissions, unavailable on-device recognition, final
   result ordering, rapid toggles, target ownership, Auto Submit, and complete
   audio-session restoration.
3. Malformed configuration corpus tests: version, types, enums, trigger values,
   oversized data, partial file, write failure, and backup recovery.
4. Mocked tool tests for all three execution modes, running-game guards,
   inspection failure, crash report, timeout, and concurrent pilot sessions.
5. Clean-SHA gate, generated project, compiler, target suites, and watchdog-bound
   UI tests.
6. Repeated physical-iPad proof: cold install preserving data, launcher/game
   launch, CASC repair, background/foreground, audio before/after dictation,
   controller remapping, Share mapped/unmapped behavior, config import/export,
   and crash/error-file checks.

## Exit criteria

Do not call the app stable until all P1 items are fixed and tested; voice is
explicitly enabled; no ambiguous system notification can start it; dictation
emits exactly one final transcript and preserves the documented audio-session
contract; config rejection/recovery cannot recurse or lose data; install
behavior is correct for every execution mode; release evidence comes from a
clean exact SHA that was actually installed; and the physical-iPad matrix passes
repeatedly without new app crashes, game error files, data loss, or orphaned
input/audio state.
