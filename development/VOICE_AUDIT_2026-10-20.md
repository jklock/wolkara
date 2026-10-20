# Voice audit, 2026-10-20

Dictation does not work. This is a complete account of what is known, what has been ruled out by
measurement, what each commit since midnight on Sunday 18 October changed, and what is still open. It
exists because the same ground has been covered several times from memory and reasoning, and that has
been the problem: conclusions were drawn from the shape of the code rather than from a number measured
at the moment of a real press.

Nothing in this document is a claim that the feature works.

---

## 1. What is measured, on the device, with the current build

```
[audio] microphone permission: granted
[audio] session: idle -> push-to-talk (AVAudioSessionCategoryRecord/AVAudioSessionModeDefault
                 MicrophoneBuiltIn 48000Hz 1ch in=1) ok
[voice] dictation: recorder started, 48000Hz 1 channel(s); the session is
                   AVAudioSessionCategoryRecord; app active
[voice] dictation: recorded 1.54s, peak -120.0 dBFS (0.00000 linear), session
                   AVAudioSessionCategoryRecord, other audio playing 0, app active
```

- `-120 dBFS` is the floor of a metre measuring digital silence. A room is -50 to -70 dBFS.
- The app is the foreground app when it captures.
- The permission is granted.
- No other app is playing audio.
- Two independent capture implementations (an `AVAudioEngine` input tap and an `AVAudioRecorder`)
  report the same thing.

The app declares both usage descriptions, confirmed in the bundle that installs:

```
NSMicrophoneUsageDescription         = Allow World of Warcraft in Wolkara to use the microphone ...
NSSpeechRecognitionUsageDescription  = Turn what you say into text in the game. Recognition runs on this iPad.
```

## 2. How we got here

The feature worked in a build that predates `c2d029c`, "one owner of the audio session". Everything
after it was reasoned about rather than measured at the moment that matters:

- The voice self-test opened the microphone, checked the session category, and cancelled before any
  buffer could arrive. It passed over a dead microphone, which is why "PASS 7/7" kept appearing next
  to a broken feature.
- When a check was added, it compared the peak against `> 0`. Silence meters at -120 dBFS, which is
  0.000001 linear, so silence passed that check as well.
- A recorder measurement reported `0.00000` when the `AVAudioFile` read-back had actually failed with
  error -50 - a measurement that failed looking exactly like the fault it was meant to detect.
- A "missing permission declaration" was concluded from `build/device/Build/Products/.../Tolkara.app`,
  which is a leftover from 14 October and is not the bundle that installs. It was wrong.

Each of those made a broken feature look verified. That is the mechanism by which this has taken as
long as it has.

## 3. Ruled out by measurement, not by argument

| Candidate | How it was ruled out |
|---|---|
| Session category | Measured with `PlayAndRecord` and with `Record`: -120 dBFS both times |
| Session options (`DefaultToSpeaker`, `AllowBluetooth`) | Same runs, options present and absent |
| Session mode | Measured with `Default` and with `VoiceChat`: both silent |
| Preferred input (built-in microphone by name) | Measured with it set and with it removed: both silent |
| Capture implementation | Two different APIs, same result |
| Microphone permission | `granted`, read from the running app |
| App in the background | `app active` at the moment of capture |
| Another app playing audio | `isOtherAudioPlaying 0` |
| A shim stealing the session mid-hold | Category read *during* capture is a recording category |
| The CoreAudio adapter forcing playback | Patch 0005 removes it; gate verifies; still silent |
| The AudioToolbox adapter forcing playback | Patch 0016 removes it; gate verifies; still silent |
| Stale build being installed | `build/platform/build/device/...` is rebuilt every install; new log lines appear immediately |
| The microphone usage description | Declared in the bundle that installs |

## 4. Every commit since 00:00 Sunday 18 October

Eighteen commits. "Audio path" means it can change what the microphone delivers or what the app does
with it.

| Commit | What it did | Audio path verdict |
|---|---|---|
| `a8bb6d8` Sun 22:14 | One-second recorder probe, logging | Probe only, later removed. Not a cause |
| `28c7706` Mon 07:58 | Session report document | Documentation. Not a cause |
| `df2fe75` Mon 09:00 | `pilot.sh` refuses a live game session | Tooling. Not a cause |
| `c2d029c` Mon 09:16 | **Introduces `AudioSessionCoordinator`**; patch 0005; gate | The last change before the feature is known broken. **Prime suspect historically** - but every property it controls has since been measured and eliminated |
| `7093add` Mon 09:28 | Diagnostics, persistence, tools that fail on their own mistakes | Logging/persistence. Not a cause |
| `f0cd5fd` Mon 10:50 | Coordinator: the adapter is the session's second owner; gate sees patches | Fixes a real defect. Did not restore audio |
| `e764dfb` Mon 11:39 | Project generated after overlay; export flag removed | Build ordering. Real fix, unrelated to silence |
| `dfbdcfe` Mon 12:11 | Push to talk leaves the launcher policy behind | Session restoration. Not a cause of silence |
| `eefb5f5` Mon 12:38 | `VoiceChat` for push to talk | **Disproven** - reverting to `Default` did not change the result |
| `1438c82` Mon 14:15 | Patch 0016 (AudioToolbox second owner), diagnostics, gate hole closed | Real defect, real fix, did not restore audio |
| `8ba738c` Mon 16:59 | Device scripts prove launcher recovery | Tooling |
| `4fba5db` Mon 17:04 | Installs recover without a container query | Tooling; changes how the app is launched |
| `cbe9fd2` Mon 17:11 | Plain launch owns enrollment recovery | Tooling; changes how the app is launched |
| `26b35b1` Mon 18:36 | Permission hop removed; `Default` mode; install EXIT trap; bound 8s→30s | Mode part disproven; the rest tooling |
| `dc57406` Mon 19:07 | Capture `Record`, no preferred input | **Disproven** - still -120 dBFS |
| `1160102` Mon 19:36 | Capture becomes `AVAudioRecorder` + file recognition | The control that eliminated the engine. Still silent |
| `28ae5f3` Mon 21:54 | Records `app active`; names a refused permission | Measurement only |
| `db621ac` Mon 22:03 | `PILOT_DEVICE_TIMEOUT` 30s→180s; withdrawals | Tooling fix for failing installs |

The commits `8ba738c`, `4fba5db`, `cbe9fd2` and the install trap in `26b35b1` all change *how the app
is started*. If a launch ever left the app not frontmost, iOS would withhold the microphone - but
`app active` is now logged at capture, and it is true. So that route is closed on the evidence.

## 5. What is still open

### Inside the process

1. **The platform's own audio shims.** `platform/translation/AudioToolbox/Output.m` creates a RemoteIO
   output unit, and `translation/CoreAudio/Hardware.m` maps the desktop HAL onto it. If either enables
   the input scope or holds the input hardware, the system could be routing the microphone there and
   giving our recorder silence. Not yet checked: whether those shims are instantiated at launch in
   this build, and whether `kAudioOutputUnitProperty_EnableIO` touches the input scope.
   *Discriminator:* log every audio component instance created in the process; grep the shims for
   input-scope property writes.

2. **The recording itself has never been examined off-device.** The meter says -120 dBFS, and the
   engine tap said all zeros, but the `.wav` has not been pulled off the iPad and analysed on the Mac.
   *Discriminator:* write the recording to `Documents/`, copy it with `pilot.sh`, measure the peak on
   the Mac. This is independent of every API the app used to measure itself.

3. **Something else in the app holding the input.** Grep finds only `Dictation.m` and the platform
   translation layer creating audio units. The shims are the only unexamined possibility.

### Installation and permissions

4. **A stale permission *record* that still reports `granted`.** iOS does get into this state after an
   app is installed over itself many times. A Settings toggle forces it to be re-established.
   *Not tested.*

5. **Re-signing between installs.** Each `xcodebuild` re-signs; if the provisioning profile or team
   ever differed between installs, TCC can be reset or orphaned. The installed build's signature has
   not been compared across installs.

6. **The 30-second `devicectl` bound.** It caused installs to fail closed and, before that, could
   leave the app stopped or on a development status screen. Fixed to 180 in `db621ac`. Whether earlier
   failed installs ever left the container in a state that matters is unknown.

7. **The 50.7 GB data revalidation** that starts after every replacement. It does not explain silence,
   but it has made each experiment cost ten minutes.

### The device and the operating system

8. **The microphone hardware.** Untested. `AVAudioSession` reports the input available and the route as
   the built-in microphone, which reflects routing, not whether the transducer works.

9. **Another *capture* on the device.** `isOtherAudioPlaying` reports playback, not recording. A call,
   a Continuity capture, or an app holding the input would silence us and still report `0` here.

10. **A stuck CoreAudio/media server.** Classic signature: every session property correct, every sample
    zero. Cleared only by a restart. Not tested.

11. **Voice Isolation / microphone mode.** Affects capture processing, but should not produce digital
    zero. Not tested.

## 6. The one measurement that decides it

Every remaining candidate inside the app depends on audio reaching the process at all. A recording made
**outside Wolkara on the same iPad** answers that in thirty seconds:

- **Voice Memos records sound** - the device delivers audio, the fault is inside the process, and the
  next suspects are item 1 and item 3 above.
- **Voice Memos records silence** - the device does not deliver audio to any app, and nothing in this
  repository can fix it.

This control was written down as the next step on 2026-10-18 (`0c568a9`) and has still not been taken.
It is the reason this has gone in circles.

## 7. State of the tree at the time of writing

- `controller` at `db621ac`, working tree clean.
- A hand-edited rollback toward the engine-based build was found in the working tree and preserved in
  `stash@{0}` rather than discarded. It is not the current build.
- `asdf` was rewritten as `26b35b1` with a message describing its eight files of unrelated work. The
  content of every commit is unchanged by the rewrite.
- Push to talk: `AVAudioSessionCategoryRecord`, `AVAudioSessionModeDefault`, no options.
- Capture: `AVAudioRecorder` to a file, recognised with `SFSpeechURLRecognitionRequest`.
- `PILOT_DEVICE_TIMEOUT` defaults to 180 seconds.
- `check_layers.sh` OK, voice suite 297 checks, pilot suite 43 checks.

## 8. Corrections to earlier claims in this repository

- "The microphone is delivering digital silence and that is the fault" - correct as a measurement, but
  it was reported before the permission and foreground checks were done.
- "Speech recognition has no usage description" - wrong. It is declared; the bundle inspected was stale.
- "The voice self-test proves the microphone works" - it never did. It cancelled before audio arrived.
- "The audio session is provably correct" - it was provably correct in the properties being logged, and
  the property that mattered had not been logged.
