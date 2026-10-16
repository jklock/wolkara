# Stability audit: main plus controller

**Status: do not release as stable.**

Read-only audit recorded 2026-10-16 for the next implementation agent.
Scope is every committed change from `wolkara-pre-layer` (`02ec787`) through
the `controller` tip `5b073ee`.

- `main` and `feature/wolkara-above-tolkara` both stop at `1bb8d0f`.
- `controller` adds eleven controller/voice commits through `2190647`, then
  `5b073ee` for the home screen, configuration persistence, pilot tooling, and
  integration.
- Do not silently apply this audit to future uncommitted work.

The layer split is a good structural direction: pristine vendored `platform/`,
small patches, an overlay map, wrappers, and a gate are safer than the prior
fork. That does **not** make the application release-ready. The new
controller/voice path can activate unexpectedly, lacks focused test coverage,
and has no final exact-SHA validation.

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
explicitly enabled; system/controller behavior is never changed without a user
choice; dictation emits exactly one final transcript and restores audio state;
install behavior is correct for every execution mode; release evidence comes
from a clean exact SHA; and the physical-iPad matrix passes repeatedly without
new app crashes, game error files, data loss, or orphaned input/audio state.
