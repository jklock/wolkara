# Stability audit: validation method and evidence

This appendix explains how the findings in
`development/STABILITY_AUDIT_2026-10-16.md` were reached. It is a reproducible
review record, not a claim that the listed commands were executed at a clean
release candidate or on physical hardware.

## Scope resolved

The audit used Git object content, rather than the live working tree, for every
controller/voice/config/tooling conclusion:

| Reference | Resolved commit | Purpose |
| --- | --- | --- |
| `wolkara-pre-layer` | `02ec787` | Beginning of the Wolkara layer history |
| `main` / `feature/wolkara-above-tolkara` | `1bb8d0f` | Completed merged layer work |
| `controller` pre-home | `2190647` | Eleven controller/input/voice commits after main |
| `controller` first reviewed tip | `5b073ee` | Home, configuration, pilot, and integration work |
| `controller` remediation tip | `fe03af0` | Remediation, logging, fixtures, validation tooling, and documentation |

The first comparison was `1bb8d0f..5b073ee`, with a history review from
`02ec787..5b073ee`. The remediation review then used `5b073ee..fe03af0` and
the complete current result `main..fe03af0`. This means the conclusions include
all committed work on `main` and all committed `controller` work at the stated
tip.

The audit intentionally excludes uncommitted files and later changes. At the
remediation review, the only observed uncommitted path was
`development/validation/`, created by the candidate's validation command
itself. That self-created dirtiness is a finding, not evidence that the
candidate source was changed.

## Evidence collection

The review was static code/history review plus limited local validation. The
following commands establish the branch graph and change inventory:

```sh
git log --oneline --decorate --all -30
git log --reverse --oneline wolkara-pre-layer..controller
git diff --stat 1bb8d0f..5b073ee
git diff --name-status 1bb8d0f..5b073ee
git show --stat --oneline 5b073ee
git ls-tree -r 2190647 wolkara | rg '(^|/)test_|Tests|test.*\\.(m|swift|py)$'
```

For behavioral conclusions, the reviewer read the exact committed file content
with `git show <commit>:<path>`, then traced the call and persistence paths.
Representative commands:

```sh
git show 2190647:wolkara/Controller/ControllerInspector.m
git show 2190647:wolkara/Input/InputRouter.m
git show 2190647:wolkara/Input/Trigger.m
git show 2190647:wolkara/Voice/Dictation.m
git show 2190647:wolkara/Voice/VoiceSettings.m
git show 2190647:wolkara/Voice/VoiceViewController.m
git show 5b073ee:wolkara/Shell/main.m
git show 5b073ee:wolkara/Shell/WolkaraConfig.m
git show 5b073ee:wolkara/tools/install.sh
git show 5b073ee:wolkara/tools/pilot.sh
git show 5b073ee:development/VALIDATION.md
git show 5b073ee:development/AUDIT.md
git show 5b073ee:wolkara/tools/prepare.sh
git show 5b073ee:wolkara/tools/apply.sh
git diff --check wolkara-pre-layer..2190647
```

The remediation review additionally used:

```sh
git log --oneline --decorate --graph --all -80
git diff --stat 5b073ee..fe03af0
git diff --name-status 5b073ee..fe03af0
git diff --check 5b073ee..fe03af0
git show --format=fuller --stat 1dec7d6
git show --format=fuller --stat fe03af0
sed -n '1,260p' development/validation/fe03af0.md
wolkara/tools/check_layers.sh
```

Focused source review covered `WolkaraConfig.m`, `Dictation.m`,
`ControllerInspector.m`, `InputRouter.m`, `Trigger.m`, `WolkaraLog.m`,
`pilot.sh`, `validate.sh`, the new focused fixtures, and their documentation.

The repository structural gate was also run:

```sh
wolkara/tools/check_layers.sh
```

It passed its layer-integrity checks. That result supports the claim that the
vendored split and overlay structure are intact; it does not validate user
behavior, controller behavior, audio routing, speech recognition, config
input handling, or physical-device stability.

`wolkara/tools/generate.sh` and `wolkara/tools/test_emulation.sh` were run
during the broader exploration and completed successfully. They were not run
from a proven-clean checkout pinned to `5b073ee`; accordingly they are not
treated as release evidence in the audit.

## Finding-to-evidence map

### Remediation review: remaining blockers at `fe03af0`

The backup-recursion finding follows directly from `WolkaraConfig.m`:
`rejectFileBecause:` accepts any dictionary-shaped `.bak`, writes it over the
primary, and calls `importFromFile` again. An invalid backup therefore returns
to the same rejection path with no recursion guard. The existing corpus checks
invalid primary data but not invalid-primary plus invalid-backup recovery.

The screenshot finding remains because `screenshotTaken:` emits an input and
`markSystemDevice` assigns it to `GCController.controllers.firstObject`. The
mapping is opt-in, but attribution remains impossible; a physical iPad
screenshot and controller Share are indistinguishable at that API boundary.

The partial-delivery finding follows from the finalization timeout calling
`finishWithTranscript:nil`, which falls through to delivery of `_transcript`.
The fixture's timeout expectation confirms that this is intentional current
behavior, not a hypothetical scheduling race.

The audio finding follows from the absence of an active-state snapshot and the
unconditional `setActive:YES` in restore. It is a direct mismatch with the
header and documentation promise, whether or not a specific route exhibits an
audible fault.

The validation finding is recorded in `development/validation/fe03af0.md`:
the manifest says its initial tree was clean, then its own output directory
makes later prepare/build commands dirty; `pilot.sh cycle` fails; and a later
app-log step passes by reading the already-installed app. That log includes a
screen-capture Share line removed by the reviewed source, proving it is not
evidence of the candidate running. The device result is therefore failed, not
partially passed.

The identical-controller and concurrency findings come from the source-level
identity construction and mutable callback state. They require physical-device
and stress confirmation to quantify impact, but the implementation cannot
deliver its claimed independent identical-controller mappings or prove safe
cross-queue mutation as written.

### P1: screenshot can toggle voice

`ControllerInspector.m` at `2190647` registers
`UIApplicationUserDidTakeScreenshotNotification` and reports a Share event
using the first connected controller's vendor name. `VoiceSettings.m` provides
a default `Share` press trigger. `InputRouter.m` routes observed events to the
saved trigger. The conclusion is not that every screenshot will always start
voice; it is that the code cannot prove the screenshot came from the mapped
controller and an ordinary screenshot is eligible to match the fallback.

### P1: system Share gesture changed without mapping

`main.m` starts the controller inspector/router when each scene connects.
`ControllerInspector.m` sets a controller's preferred system gesture state when
it discovers Share. There is no mapping/voice-enabled condition in that path,
and the reviewed code contains no symmetric restoration path. That is the
basis for the startup/cleanup finding.

### P1: default Share mismatch

`ControllerInspector.m` emits the display string `Button Share` for the
physical control. `VoiceSettings.m` saves the fallback element as `Share`.
`Trigger.m` compares persisted source/element/pattern values. A literal
comparison cannot make those two distinct strings equal. The recommendation
for canonical IDs follows directly from using human display text as a durable
protocol.

### P1: speech completion and audio state

`Dictation.m` copies the current transcript before calling `endAudio` and
finishing the recognition task. The result handler may still receive a final
recognition result after that copy. Therefore the final words have no ordering
guarantee before insertion.

The same file sets the audio session category to Record on start and Playback
in teardown. The reviewed paths did not snapshot the previous category, mode,
options, active flag, or route. The finding is a failure to preserve host audio
state, not a claim that every device will audibly fail.

The speech request sets `requiresOnDeviceRecognition` from the recognizer's
capability rather than requiring the capability or refusing to proceed. The
on-device product-copy mismatch is based on that assignment and the reviewed
Info.plist usage wording.

### P1: mapping interaction and lifecycle

`InputRouter.m` observes controller input; it does not provide input
suppression/arbitration. The settings surface persists press or push-to-talk
mappings while router code has partial long/double/chord support. The audit
therefore calls out both action collision risk and the product/UI mismatch.

`VoiceViewController.m`'s twenty-second timeout updates presentation state but
does not clear the router learning state. A subsequent event can still be
accepted by the active learner. The required cancellation lifecycle is the
direct corrective measure.

### P1: installation crosses execution-mode boundaries

`install.sh` at `5b073ee` invokes `tools/enroll.sh` after install without a
`TOLKARA_MODE` branch. Repository mode documentation distinguishes Developer
Service, Local Signing, and External JIT. Enrollment is developer-service
setup, so unconditional enrollment is not mode-correct.

### P2: controller identity, event identity, and concurrency

The inspected controller code builds D-pad/touch element strings from current
axis/touch state, persists mappings by `vendorName`, and has right/middle mouse
paths that omit the routine used to set current device/source state. These are
direct code observations. The race warning is derived from controller callback
mutation paired with main-queue delayed long-press work in the same mutable
router state; it needs Thread Sanitizer/device reproduction to establish an
actual race, so it is correctly categorized as a risk requiring confinement
and tests, not a reproduced crash.

### P2: configuration import boundary

`WolkaraConfig.m` automatically reads `Documents/wolkara-config.json` during
load, extracts `settings`, and writes recognized key values directly to user
defaults. It does not validate the advertised version, key value types, enum
values, or trigger dictionary shape/ranges before writing. It also observes
every defaults change and rewrites the export file. The review traced trigger
pattern use to fixed pattern-summary indexing, which makes invalid imported
trigger data a crash/corruption risk. The recommendation is strict schema
validation before an atomic commit.

### P2: pilot and release evidence

`pilot.sh` uses fixed `/tmp/pilot-*` paths and timestamp-based staged-update
detection. Its several inspection command fallbacks can turn failures into
empty output. Those facts support the isolation/fail-closed recommendations.

`development/VALIDATION.md` identifies validation at `738001a`, while the
reviewed branch tip is `5b073ee`; the later committed changes are consequently
not covered by that record. `prepare.sh` takes `platform/` from `HEAD`, while
`apply.sh` consumes patch/overlay content from the checkout, establishing the
hybrid-tree warning when the checkout is dirty.

### P2: missing test and documentation coverage

The committed Wolkara tree inventory did not contain dedicated Controller,
Input, or Voice test files for these paths. `development/AUDIT.md` itself
records remaining AddonManager/Archive/Credential/CurseForge coverage and
fixture-hang work. Cross-reading README/plan/audit/validation files found
different phase/count/status claims. These are documentation and verification
gaps, not an assertion that no unrelated tests exist anywhere in the platform.

## Interpretation rules

- P1 means an unsafe default, privacy/user-expectation violation, a directly
  demonstrable correctness failure, or a mode-boundary violation that should
  block a stable release until fixed and tested.
- P2 means an evidenced correctness, resilience, release-integrity, or
  maintainability risk that should be remediated before calling the application
  stable.
- Recommendations prescribe a safe target behavior. They are not evidence that
  the code already implements it.
- “No focused tests found” means no dedicated tests were found in the committed
  Wolkara test inventory; it never means code was executed exhaustively.

## What remains to validate empirically

The static review cannot establish physical-controller event delivery,
GameController/iPadOS version behavior, speech service final-result timing,
actual audio routing, game input collisions, or device-side install/enrollment
results. The audit's physical-iPad matrix remains required after fixes. Run it
from a clean checkout at the candidate SHA, retain raw logs/artifacts, and
record device model, iPadOS version, controller model/firmware, execution mode,
and each pass/fail outcome in a SHA-bound validation manifest.
