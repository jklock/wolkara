# Device Hub stability test plan

Use this plan only after remediation is committed. Its purpose is to establish
that the final candidate works on a real iPad, fails safely, remains usable by
another person, and leaves a complete evidence trail when it does not.

This is a release gate, not a demonstration. A happy-path launch is not a pass.

## Preconditions and boundaries

- Test a clean checkout at one recorded candidate SHA. Stop if `git status
  --porcelain` is non-empty; record the SHA in every artifact name.
- Use the physical `Dadpad` iPad visible in Device Hub (iPad Pro 12.9-inch,
  5th generation; iPadOS 27.0.1 at plan creation) and record the actual device
  model, OS, free storage, controller model/firmware, and execution mode.
- Do not attach LLDB, use `--start-stopped`, or attach any external debugger
  after guest entry. `devicectl --console` is allowed only as standard-output
  observation; it is not a debugger attachment.
- Use the desired execution mode deliberately. Do not run Developer Service
  enrollment while validating Local Signing or External JIT.
- Begin with a known data state. Preserve the existing app container unless the
  case explicitly requires a clean-state migration test; never uninstall the
  user’s app to obtain a reset.
- One human or one Computer Use operator controls the iPad at a time. Do not
  mix Device Hub touch input with another input source during an individual
  case, except for the controller being tested.

## Evidence architecture: four concurrent streams

Every case has a case ID (for example `VOICE-07`) and UTC start/end time. Save
all artifacts under one non-shared run directory, e.g.
`build/device-runs/<SHA>/<UTC-run-id>/`. Never use fixed global `/tmp` names.

| Stream | Capture method | Purpose |
| --- | --- | --- |
| Live application events | Launch through `xcrun devicectl device process launch --console`; redirect stdout/stderr through a timestamping logger into `console.log` | Correlates app/guest stdout with the precise action being performed |
| Structured in-app diagnostics | The candidate must emit one redacted, timestamped event record for every state transition described below | Explains decisions that stdout alone cannot prove |
| UI evidence | Drive the physical iPad through Device Hub with Computer Use; capture a screenshot before, after, and on every anomaly | Proves user-visible behavior and enables reproduction |
| Failure/state artifacts | Before/after each case, query process state; copy app log/error files; list and retrieve any new `.ips` crash report; retain install/launch command output | Detects crash, assertion, termination, or guest failure even when the UI freezes |

Use `devicectl --console` only for a newly launched process. It bridges remote
stdout and waits for process termination, so leave it running in a dedicated
terminal session while Device Hub remains the interaction surface. Do not use
it to terminate/relaunch an already-running test session; finish and archive
that case first.

The existing `wolkara/tools/pilot.sh` is useful for snapshots and crash/error
file collection, but it is not sufficient as the real-time collector: it polls
container files and historically used fixed `/tmp/pilot-*` state. Use its
operations only after the remediation has made them run-scoped and fail closed,
or collect equivalent `devicectl` artifacts directly.

## Required in-app log contract

Do not begin feature testing until the final candidate exposes observable
diagnostics. Each record needs UTC timestamp, monotonic sequence number,
candidate SHA/build ID, scene/session ID, event category, and outcome. It must
be written to the live console and a retrievable app-owned log.

Never log recognized speech text, credentials, account identifiers, full file
contents, pairing data, or raw controller serial identifiers. Use explicit
redaction and a per-run opaque device token where correlation is required.

Required categories:

| Category | Minimum fields |
| --- | --- |
| lifecycle | launch, foreground/background, scene connect/disconnect, termination reason if known |
| execution mode | requested mode, selected mode, mode-specific validation, enrollment attempted/skipped and why |
| controller | opaque controller identity, connect/disconnect, stable element ID, event type/pattern, mapping match/no-match, system gesture changed/restored |
| mapping | learn begin/cancel/timeout/commit, reason, persisted schema version, conflict/collision warning |
| voice | explicitly enabled/disabled, permission result, recognizer capability, state transition, final-result/cancel/error, transcript length only, exactly-once delivery ID |
| audio | snapshot before capture, requested capture configuration, restore result, route change/interruption |
| configuration | import discovered, schema/version validation result, rejected field reason without values, atomic write/backup/recovery result |
| guest/runtime | launch request, readiness result, assertion/error file detected, CASC/update result |
| fault | caught exception/error domain/code, recovery action, and whether user-visible error was shown |

A missing expected log event is a test failure: it makes an apparent success
unverifiable.

## Per-case execution loop

1. Create the run directory and a case sheet containing SHA, device/controller
   facts, mode, initial app-data policy, and expected result.
2. Capture baseline Device Hub screenshot, process list, app log tail, guest
   error-file inventory, and crash-report inventory. Record the last known
   crash/error names rather than assuming an empty device.
3. Launch once with the console collector; wait for a logged ready state or a
   bounded failure. Record the launch command and its exit status.
4. Operate the physical iPad only through Device Hub/Computer Use. After every
   meaningful action, append an action marker (`case ID`, monotonic action
   number, UTC) to the operator timeline and capture the current device screen.
5. Watch the live console and structured event stream while performing the
   action. If a crash, error, unexpected microphone activation, controller
   interception, app exit, stalled UI, or missing expected event occurs, stop
   the case immediately and preserve evidence before attempting recovery.
6. Capture end screen, process status, app/guest logs, new app errors, and new
   system crash reports. Compare with baseline.
7. Mark pass only if the visible result, expected events, and no-new-failure
   artifact all agree. “No crash observed” alone is not a pass.
8. Restart the app between independent cases. For lifecycle-sensitive cases,
   additionally repeat after background/foreground and a cold launch.

## Device Hub operation protocol

At plan creation, Device Hub has the physical `Dadpad` selected and exposes its
screen plus a Reports inspector containing prior Tolkara crash reports. Use it
as follows:

1. Select `Dadpad`, verify it remains the physical iPad rather than a
   simulator, and open the live device screen.
2. Before each case, inspect the Reports view filtered to Tolkara/Crashes and
   record the current newest crash report. Do not delete prior reports.
3. Use Computer Use for taps, navigation, typing, screenshots, and UI-state
   verification. Re-read the current accessibility tree/screenshot after each
   action; never reuse stale coordinates.
4. On an anomaly, take a Device Hub screenshot first, then preserve terminal
   and report artifacts. Do not repeatedly tap through a hung screen.
5. After the case, refresh Reports and retrieve/record any new Tolkara report.
   A report created after the baseline is failure evidence even if the launcher
   appears to recover.

Computer Use is the user-behavior oracle; terminal/device commands are the
state/log oracle. Neither substitutes for the other.

## Test matrix

Run each relevant case in the supported execution mode(s), then repeat the
marked lifecycle cases after cold launch and background/foreground.

### A. Install, launch, and host stability

| ID | Exercise | Pass condition |
| --- | --- | --- |
| BOOT-01 | Install/update with existing app data; launch launcher | Correct mode action only; launcher is responsive; no new error/crash; data survives |
| BOOT-02 | Start guest through normal launcher path | Readiness/guest success is logged; game is responsive; no hidden assertion/error artifact |
| BOOT-03 | Repeat install logic per Developer Service, Local Signing, and External JIT | Developer enrollment occurs only in Developer Service; other modes log an explicit skip and their own validation |
| BOOT-04 | Background/foreground during launcher and during game | No crash/hang; scene and runtime state are restored or clearly recoverable |
| BOOT-05 | Cold launch after prior voice/config/controller use | No stale mapping, audio state, or orphaned gesture setting changes |

### B. Controller safety and interoperability

Test at minimum the target controller, no controller, disconnect/reconnect,
and a second controller of the same vendor where available.

| ID | Exercise | Pass condition |
| --- | --- | --- |
| CTRL-01 | Launch with no controller | No controller feature changes or voice activation; normal touch/game behavior |
| CTRL-02 | Connect controller without enabling/mapping voice | Inventory is read-only; native Share/system behavior remains intact; no mic state changes |
| CTRL-03 | Take a physical iPad screenshot unrelated to controller input | Screenshot succeeds; no voice/mapping action; log attributes it as non-controller |
| CTRL-04 | Explicitly enable voice and map one stable physical element | UI names stable identity; learned event and persisted mapping agree; disclosure/collision warning shown |
| CTRL-05 | Trigger mapped press/hold/double/chord options individually | Only the selected supported pattern matches; game-collision policy is visible and honored; exactly one voice action |
| CTRL-06 | Trigger an unmapped element and native Share | No mapping match; native system behavior works unless the user explicitly disabled it for that mapped element |
| CTRL-07 | Mapping timeout, leave screen, background, disconnect | Learning cancels in each case; later arbitrary input cannot alter saved mapping |
| CTRL-08 | Remove mapping/disable voice/reconnect controller | System gesture is restored, mapping is removed, no stale trigger remains |
| CTRL-09 | Same-vendor second controller and mouse right/middle actions if supported | Events retain the correct device/source identity; no cross-device trigger or stale identity |

### C. Voice, privacy, and audio resilience

Use non-sensitive fixed test phrases; record expected character count, not
speech contents, in logs.

| ID | Exercise | Pass condition |
| --- | --- | --- |
| VOICE-01 | Voice disabled; invoke all possible triggers | No permission prompt, microphone use, or state transition |
| VOICE-02 | First enable with deny permission | Clear error; returns idle; later trigger does not loop/promote stale state |
| VOICE-03 | Allow permission with on-device recognition unavailable | Fails closed or follows an explicit user-selected network policy; product copy matches behavior |
| VOICE-04 | Speak phrase and stop; phrase ends immediately before stop | Final result arrives before exactly-once delivery; complete expected text; no duplicate Return |
| VOICE-05 | Rapid repeated mapped triggers / cancellation / recognition error | State machine stays valid; no overlapping task, crash, duplicate insertion, or stuck mic |
| VOICE-06 | Speaker, wired headphones, Bluetooth route, incoming interruption, then background/foreground | Original category/mode/options/active/route are restored; game audio remains correct |
| VOICE-07 | Focus game chat, then non-chat UI/another scene | Insertion occurs only at explicit authorized target; no recursive/private-selector routing; no text leaks elsewhere |
| VOICE-08 | Auto Submit on/off | Visible behavior matches preference and logs exact-once submit decision |

### D. Configuration import/export and recovery

Use copies of only non-sensitive test configuration. Preserve pre-case config
and app-data baseline.

| ID | Exercise | Pass condition |
| --- | --- | --- |
| CFG-01 | Export a valid configuration; relaunch; re-import it | Versioned schema, atomic write, stable mapping, and successful validation logged |
| CFG-02 | Invalid JSON/truncated file | Rejected safely; prior settings remain; visible actionable error; app launches |
| CFG-03 | Unknown version/key/type/enum/pattern/out-of-range/oversized fields | Entire invalid input is rejected or safely ignored per documented schema; no crash/corruption |
| CFG-04 | Interrupted write / backup recovery | Valid previous copy recovers; no partial active configuration |
| CFG-05 | File sharing and privacy check | UI/docs accurately explain what is exported; no secret/recognized-text payload is written |

### E. Failure and repeatability gate

| ID | Exercise | Pass condition |
| --- | --- | --- |
| SOAK-01 | Ten cold launches and ten background/foreground cycles | Zero new crashes/errors; logs complete each cycle |
| SOAK-02 | Twenty controller map/use/unmap cycles | No stale system gesture state, growth/leak symptoms, duplicate routes, or data corruption |
| SOAK-03 | Ten dictation cycles across routes | Zero duplicate/partial deliveries, stuck audio, or crash |
| SOAK-04 | Repeat a clean subset on another supported controller/device | No target-machine path, vendor-name, enrollment, or setup assumption blocks normal use |

## Stop conditions and triage order

Immediately stop the current case for a new Tolkara crash report, app exit,
guest error/assertion, unexpected microphone activation, unexpected controller
gesture suppression, text inserted in the wrong target, missing required event
record, or any unrecoverable UI hang.

Preserve, in order: Device Hub screenshot; live console log; structured app
log; process state; app error files; crash report; precise operator timeline.
Then classify the failure as install/mode, lifecycle, controller mapping,
voice/audio, configuration, guest/runtime, or observability. Do not continue
into another feature area after an unresolved failure.

## Release evidence package

For the final candidate, retain:

- SHA, clean-worktree proof, build/install command and mode;
- device/controller facts and test matrix with pass/fail/blocked outcome;
- action timeline with screenshots;
- full console and redacted structured logs;
- before/after app error/crash inventories and every newly created report;
- exact reproduction steps for each anomaly; and
- a signed-off statement of known limitations, if any.

Stable means every required matrix case passes repeatedly with complete evidence
and no unexplained new crash, error file, data loss, input interception, audio
regression, or privacy violation. Any skipped case is a release blocker unless
explicitly documented as an unsupported configuration.
