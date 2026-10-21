# Voice: the settings, the modes, and what we match from Handy

Status: implemented and verified on the iPad - on the home screen and inside the
running game. Supersedes the ad-hoc "tap Share"
wiring, and sits on `docs/INPUT_TRIGGERS.md`, which is what makes the button part
work on any controller.

The launcher also carries a Permissions row that opens this app's own page in Settings, where the
Microphone and Speech Recognition switches live. Nothing inside the app can change those: iOS gives
an app no way to grant or reset its own privacy permission, so the row exists to take you to the
right page instead of describing where it is.

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

## Typing into the game

The touch controls are the layer's `UIKeyInput`: their `insertText:` goes to their delegate,
which turns the words into the guest's key events. They announce themselves to the shell
(`AKTouchGameTextInputDidAppearNotification`), the shell hands that view to `AKDictation`, and
a transcript is typed there and nowhere else - into whatever field the game has focused. The
draft editor is **not** the game's input: it is a `UITextView` that holds words for the
keyboard's Replace button and cannot reach the game at all.

The two channels stay separate on purpose. The system keyboard's own microphone writes into
the draft and the user decides when Replace puts it into the field (`TOUCH_INPUT.md`). A
mapped voice trigger writes straight into the field and presses Return only when auto-submit
is on; nothing of ours appears for it.

### The crash that made this explicit

That announcement once named the draft editor, so the first sentence spoken inside the game -
at the login screen, into the password field - aborted the app:

```
NSInvalidArgumentException: -[AKKeyboardTextView touchInsertText:]: unrecognized selector
-[AKDictation typeIntoGame:] -> -[AKDictation deliver] ... _exit(1)
```

**Test Voice and the home screen never showed it**, because both set a transcript handler and
the game's path was never taken; only a dictation inside a running game exercised it. Two
things make the same mistake impossible now: the controls answer `touchInsertText:` and
`touchSpecialKey:characters:` themselves, and `AKDictation` asks `respondsToSelector:` before
either send - a wrong target loses the words instead of killing a running game.

## Verified, on the device

| Where | What was done | What the logs say |
| --- | --- | --- |
| Home screen, **Test Voice** | Options on an Xbox pad mapped, a sentence spoken, held and released | `dictation: heard 40 characters, for the test screen`; the session went back to idle and nothing was typed into a game |
| In the game, login screen | the same trigger twice, into a focused field, auto-submit on | `heard 21 characters` and `sent Return` both times; the guest dequeued 43 key events on the first (21 down/up pairs plus Return) and the session went back to `game` |

Measured on Dadpad (iPad Pro 12.9-inch, 5th generation), 2026-10-21, Developer service. No
crash report was written and the app was still running afterwards. The self-test
`--selftest=dictation-target` asks the registered target the same two questions and is what
the device matrix can run without a person speaking; it reported `PASS 2/2 checks
(AKTouchControls answers both selectors)` in the same run.

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

These are the two supported patterns. The mode owns the mapping behavior.
Repeated down samples are ignored until release.

## What this cannot do, said plainly

**By default a mapping listens to a button; it does not take the button away from the
game.** The router observes input and the game observes it too, so a button the game already
uses does both things at once — and a pattern does not change that: hold-to-talk is still a
press the game receives.

**Keep the game from seeing it**, the switch on the same page, is the one thing that does take
a button away — and only for what can be taken:

- **A keyboard key works.** The user maps the key and turns the switch on; the key then
  reaches dictation and nothing else. The adapter does not post it to the guest at all, press
  or release, so the game is never left holding a key down. The trigger still fires, because
  the router learns what was pressed from the adapter's own observation rather than from the
  guest's event queue: the same physical key, seen once, forwarded nowhere.
- **A controller button does not, and the page says so.** iPadOS reports a pad's buttons to us
  as gamepad elements, and the guest receives them as key events with no way to tell which pad
  button produced one — there is no API that maps a pad button to the usage the game sees. A
  pad mapping therefore cannot be matched at the point where a key would be swallowed, and
  choosing a button the game does not use remains the answer for a pad.
- **A system signal never can be.** There is no key event to swallow; the layer releases the
  system gesture for the element it holds instead, which is why `system.screenshot` cannot be
  mapped at all.

So: with the switch off, pick a button the game does not use. With it on and a keyboard key,
the game genuinely does not see the key. Apple-reserved buttons cannot be fully ours either,
which is why hold-to-talk needs a button whose press *and* release both reach us.

**The launcher offers two patterns: hold to talk, and press to start and stop.**
This is the accepted product scope as of 2026-10-17. Double, long and chord
execution has been removed. Stored mappings using those retired patterns are
rejected and removed on startup; the user must explicitly map a supported input
again. Existing Hold and Toggle mappings retain their stored numeric values.
