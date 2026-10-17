# Voice: the settings, the modes, and what we match from Handy

Status: design and first implementation. Supersedes the ad-hoc "tap Share"
wiring, and sits on `docs/INPUT_TRIGGERS.md`, which is what makes the button part
work on any controller.

## The shape

1. **A section in the launcher** called **Voice Manager**, with two rows:
   **Key / Button Configuration** and **Test Voice**. Both open as popups over the
   home page rather than pushing the user away from it, with a Done button.
2. The first row starts with a switch. **Voice is off until the user turns it on**, and
   nothing is armed, opened or changed before then; with it off, the rest of the page is
   dimmed and the router is given no trigger.
3. Switching it on lets the user **map the button or key**, and set the options below.
   Mapping can be cleared, which gives the system its gesture back.
4. **Test Voice** is where the button is tried out before the game is opened: a box that
   receives the transcript, exactly as the game would, and nothing is typed into the game
   from there.
5. In the game, **that button starts transcription**. Nothing of ours appears.
6. The transcript is typed into the game, and optionally sent.

Both pages are drawn from `wolkara/Shell/WolkaraTheme.{h,m}`, which is the one place the
launcher's ink and gold are written down - the Add-on Manager's values, because that is
the screen the rest is expected to match. Building them from `UIColor.system*` is what
made them the one part of the launcher that did not look like the launcher.

## What it will not do

- **It will not start by itself.** No default trigger, no fallback, and a system signal is
  not an input at all: iPadOS does not say whether a screenshot came from a controller or
  from a thumb on the screen, so it is recorded in the log and offered to nobody. A
  mapping that points at one is refused, and one written by an earlier build is dropped
  with a line in the log saying so.
- **It will not change a controller without being asked.** A reserved system gesture is
  released for the exact element the user mapped, and given back when the mapping is
  cleared, voice is switched off, or the pad disconnects.
- **It will not send audio anywhere.** Recognition is on-device or it does not run: a
  device that cannot do that is refused with a message rather than quietly falling back
  to a server.
- **It will not deliver twice, or deliver half.** The audio ends, the recogniser is asked
  for its final result, and the text goes to the game once, when that result arrives. If
  it never arrives - the recogniser is unavailable, or nothing was said - nothing is typed
  and the user is told, because what is in hand at that point is a partial result, and half
  a sentence in a chat box is worse than an empty one.
- **It will not stop the game seeing the button.** The press reaches the game as well as
  us, so the button should be one the user is willing to share. See `INPUT_TRIGGERS.md`.
- **It will not tell one identical pad from another.** GameController exposes no per-device
  identity, so a mapping is remembered per *model* and two identical controllers share it.
  The log says so when that is what is connected.

## The audio session, as a policy rather than a promise

Dictation takes the session as `Record`, and puts back the category, mode and options it
found, leaving the session **active**. `AVAudioSession` has no public way to ask whether it
was active beforehand, so the previous activation state cannot be observed and is not
claimed: this is a deliberate policy for a foreground game host, not a snapshot of
everything. An interruption - a call, Siri, anything else taking the audio - ends the
session rather than leaving the microphone open behind a session we no longer own.

## Handy is the baseline

Handy's own behaviour, and where we stand:

| Handy | What it is | Ours |
| --- | --- | --- |
| Hold to record, release to stop | push to talk | **same**, and it is the default |
| Tap to toggle on and off | press once on, once off | **same** |
| Hold-only / toggle-only | either forced | same two modes offered; the variants are the same code path |
| Auto-submit | send after inserting | **same**, off by default |
| Direct typing vs clipboard paste | how the text is inserted | typing, which is what the game already accepts. Clipboard paste needs the guest's pasteboard, which does not exist — see `CONTROLLER_INPUT.md` |
| Dictionary | custom words, biased at recognition | **same**, through the recogniser's `contextualStrings` |
| Post-processing | an optional pass over the transcript | not yet; it needs a model, and is a separate decision |
| History | browse past transcripts | not yet; trivially added, and the log already holds them |
| Paste delays | timing workarounds for the clipboard | not applicable when typing |
| Language, translate | recognition options | later, via the same request object |

The two that matter most, and are built here: **the modes** and **auto-submit**.
Dictionary is in as well, because it is the one that changes what the recogniser
hears rather than what we do with it afterwards.

## Settings, and where they live

Stored with the layer's other per-user choices, under `AKVoice*` keys, so they
survive reinstalls and are inspectable. They are also written to
`Documents/wolkara-config.json` in the app's container, which the installer
replaces in place — so the choices come back after an update without being
re-entered. The CurseForge key is deliberately not in that file; it belongs in
the keychain, and is already there. See `wolkara/Shell/WolkaraConfig.h`.

| Key | Meaning |
| --- | --- |
| `AKVoiceMode` | `hold` (push to talk) or `toggle` |
| `AKVoiceAutoSubmit` | send Return after inserting |
| `AKVoiceTrailingSpace` | a space after the text, for chat boxes that need it |
| `AKVoiceCustomWords` | the dictionary |
| `AKInputTrigger.<device>` | the button, per controller, from `INPUT_TRIGGERS.md` |

## Mapping the button

Arm, then press. The launcher opens a sheet that says so; the next event from any
source — gamepad element, keyboard key, mouse button, touchpad, or the system
signal a reserved button produces — becomes the trigger, remembered for that
device. This is why the mapping needs no list of supported controllers: it is the
hardware that tells us what it has.

## Trying it before the game

**Test Voice** presses nothing on its own: `Shell/main.m` already sends the mapped
trigger to the dictation engine, so the page arms itself as the listener and shows
what arrives. That is deliberate — a test screen with its own button would prove
the screen works, not the mapping. `AKDictation` hands the text over instead of
typing it only while a test screen has claimed it
(`transcriptHandler`/`listeningChanged`), and it is let go before the page goes
away, so a half-heard utterance cannot land in the game's chat box on the way out.

## Modes, in the engine

- **Hold**: the trigger fires on press and again on release. Dictation starts on
  the first and stops on the second.
- **Toggle**: each press alternates.

Both are the same trigger with a different pattern, which is why the router
carries a `hold` pattern alongside press, double, long and chord.

## What this cannot do, said plainly

**A mapping listens to a button; it does not take the button away from the
game.** The router observes input and the game observes it too, so a button the
game already uses does both things at once — and a pattern does not change that:
hold-to-talk is still a press the game receives, and a chord is still those keys.
Nothing here arbitrates, owns or swallows input, and no pattern should be read as
a way to make a button safe to share. The page says this where the mapping is
made, and so does the log line written when one is saved.

What follows from that, for anyone choosing a button: pick one the game does not
already use. Apple-reserved buttons cannot be fully ours either, which is why a
system signal cannot be mapped at all and why hold-to-talk needs a button whose
press *and* release both reach us.

**The launcher offers two patterns: hold to talk, and press to start and stop.**
The trigger model stores and validates press, double, long and chord, and
migrations keep old mappings readable, but the page offers no double-tap, long
press or chord choice — so do not read the model's four patterns as four options
the user has. Implementing arbitration or offering the other patterns is not
started; see `development/NOTES.md`.
