# Voice: the settings, the modes, and what we match from Handy

Status: design and first implementation. Supersedes the ad-hoc "tap Share"
wiring, and sits on `docs/INPUT_TRIGGERS.md`, which is what makes the button part
work on any controller.

## The shape

1. **A row in the launcher**, beside Add-ons / Manage, called **Voice**.
2. Opening it lets the user **map the button or key**, and set the options below.
3. In the game, **that button starts transcription**. Nothing of ours appears.
4. The transcript is typed into the game, and optionally sent.

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
survive reinstalls and are inspectable:

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

## Modes, in the engine

- **Hold**: the trigger fires on press and again on release. Dictation starts on
  the first and stops on the second.
- **Toggle**: each press alternates.

Both are the same trigger with a different pattern, which is why the router
carries a `hold` pattern alongside press, double, long and chord.
