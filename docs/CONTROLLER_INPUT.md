# Controller input: seeing everything the pad sends, and everything the game gets

Status: plan and diagnostic build. Branch `controller`, cut from `main` after the
layer work was collapsed into it.

## Why this exists

Two buttons on the pad do nothing in this app: **Share** and the **extra top
button**. We cannot currently tell which of three things is true:

1. The pad never reports them over Bluetooth.
2. iPadOS reports them to us but takes them for itself.
3. They arrive, and the game simply ignores them.

Every decision planned on top of pad input — a dictation trigger, opening chat,
sending, corrections — depends on knowing which. So this work builds
**visibility first**, and no features on top of it until the answer is measured.

## The two ends of the pipe

Input reaches the game through us, and there are two places worth watching:

| End | Who owns it | What it can show |
| --- | --- | --- |
| Pad | our layer (`launcher/`) | what the pad reports: its elements, and every change to them |
| Game | the platform (`translation/AppKit`) | what the guest's event queue hands the game: type, key code, characters |

Correlating the two answers the question that matters: **does a pad press become
a keystroke, and which one does the game receive?**

## What we know today, measured

- Our layer already enumerates the real controllers (`wolkara/Touch/TouchGamepad.m`,
  `connectedControllers` returns `GCController.controllers`), so the pad is
  reachable from our code.
- Nothing anywhere logs controller input. The platform's `authorization/Diagnostics/`
  is a local-service probe only, and the AppKit adapter logs windows.
- The platform logs only the **first 16** key deliveries per session
  (`platform/translation/AppKit/AppKit.m`, `loggedDelivery<16`), so the existing
  line cannot be used to test a press.
- The guest's GameController shim defines **no** `GCInputButtonShare` constant, so
  the game has no name to bind Share to. That is a strong hint Share cannot
  collide with the game, if we can reach it at all.
- Apple documents Share as **system-reserved**: "the system reserves the Share
  button for screenshot and video recording gestures, which can be disabled by
  setting the button's `preferredSystemGestureState` to disabled."
- The user's own binding table (`WTF/Account/<id>/bindings-cache.wtf`) holds pad
  buttons beside keyboard keys — `PADLTRIGGER`, `PADRTRIGGER`, `PADLSHOULDER`,
  including `CTRL-`/`SHIFT-` prefixed forms. So the client does treat pad inputs
  as bindable keys internally, matching the `GamePadEmulate{Ctrl,Shift,Alt}`
  CVars, whose documented purpose is "emulates modifier keys using a game pad".
- The client's side of that mapping is private: those keystrokes, if synthesised,
  are resolved inside the guest process and never appear as OS-level events.
  That is why our own Control+Option+D hook never fired once.

## Design

### 1. Controller inspector — our layer, `wolkara/Controller/`

Files land in the prepared tree under `launcher/Controller/` and compile with no
project change: the platform's `AppBase` template declares `- path: launcher`, so
everything beneath it is built.

It must:

- On start, and on every connect/disconnect, log each pad's identity:
  `vendorName`, `productCategory`, the profile class, and the **full element
  list** from `physicalInputProfile` — buttons, axes, d-pads, touchpads — naming
  each element and whether it is analog.
- Report specifically whether **Share** and any **paddles** exist, since those are
  the two open questions.
- Attach `pressedChangedHandler` to every button and `valueChangedHandler` to
  every axis, d-pad and stick, logging every press and release with element name,
  value and timestamp. Stick axes are logged on direction changes rather than
  continuously, so the log stays readable and the game is not slowed.
- Include `GCKeyboard` and `GCMouse`, so the Magic Keyboard's keys and its
  trackpad appear in the same stream.
- Log through the platform's own channel (`AKLog` → `Documents/native-guest.log`)
  so the result is readable from the Mac with `devicectl copy from` and **no
  root**. `idevicesyslog` returns nothing useful here and `log collect` needs
  root, so this is the only window we have.
- Optionally show a small on-screen panel of the last events, so the user can
  *see* it too. Off unless asked for (`--inspect-controller` or a notification).

It reads. It never consumes an input, never writes to a pad, and changes nothing
about how input reaches the game — with one deliberate exception: when it is
enabled it clears the system gesture reservation on Share, because otherwise that
button cannot be observed at all. That is logged loudly when it happens.

### 2. Guest-side visibility — platform patch `0012`

The guest's queue is where we find out what the game actually receives:

- Log every event handed to the guest, not just the first 16: type, key code,
  characters, characters-ignoring-modifiers, modifier flags, delivery age and the
  number still pending.
- Keep it behind a switch, so ordinary play pays nothing.

This is a Tolkara change, so it goes in as a patch applied by `wolkara/tools/apply.sh`
— never a hand edit of the prepared tree.

### 3. What we learn, and what each answer means

| What we observe | What it means | What follows |
| --- | --- | --- |
| Share/extras appear at the pad end | iPadOS reports them to apps | usable as our trigger, once the system reservation is cleared |
| Present at the pad end, absent from the guest's queue | the game never sees them | ideal trigger: physically separate from anything the game uses |
| Absent at the pad end | the pad's firmware never sends them over Bluetooth | dead on iPad; no software can invent them |
| Pad presses appear in the guest's queue as keys | the client synthesises keystrokes | we learn the exact codes the game acts on |

### 4. Only then: dictation

With the answer known, the trigger is one input with a measured collision
profile. Then, and in this order:

1. The trigger starts Apple's on-device recogniser (`SpeechAnalyzer` /
   `SpeechTranscriber`, iPadOS 26+ — no keyboard, no text field).
2. The transcript is inserted into the game through the **existing** insert path
   (`touchInsertText:`), which the layer already ships and which the user has
   confirmed works in the game.
3. Send is Return, as Handy's own **Auto Submit** setting does — the user may
   press it themselves instead.

Nothing in that flow shows the user a panel, a keyboard or a Wolkara overlay.
The game's own chat box is the only thing on screen that is part of it.

## Verification

On the device, with the interposer off the game's own input path:

1. Install with the guard (`wolkara/tools/install.sh` — it refuses while a game
   is live).
2. Launch, and press each control once in a documented order: face buttons,
   shoulders, triggers, d-pad, stick clicks, sticks to their limits, Menu,
   Options, Share, each extra button, plus a trackpad click and a key on the
   Magic Keyboard.
3. Read `Documents/native-guest.log` from the Mac and compare the two streams.
4. Record what each control produced, in this file, and keep the result.

One clean run proves nothing on its own; the output is a table of controls
against observed events, and gaps in that table are findings too.

## Constraints this respects

- The original executable is never modified, and no application memory is
  inspected. Everything here is the guest's own public framework surface plus our
  own log.
- Tolkara stays byte-identical: the guest-side change is patch `0012`.
- The inspector is a diagnostic. Nothing is enabled for the user by default, and
  nothing appears on screen during normal play.
