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

## Measured on the device, 2026-10-15

Pad: GameSir G7 Pro, paired over Bluetooth. iPadOS reports it as **"Xbox
Bluetooth Gamepad"**, category `Xbox One`, profile `GCXboxGamepad`.

Everything the pad declares, in full — **34 elements**:

- **25 buttons**: `Button A`, `Button B`, `Button X`, `Button Y`;
  `Left Shoulder`, `Right Shoulder`; `Left Trigger`, `Right Trigger` (both
  `[analog]`); `Left Thumbstick Button`, `Right Thumbstick Button`; `Button
  Menu`, `Button Options`, `Button Home`; `Direction Pad Up/Down/Left/Right`;
  and eight stick-direction buttons — `Left/Right Thumbstick Up/Down/Left/Right`,
  all `[analog]`.
- **6 axes**: `Left/Right Thumbstick X/Y Axis`, `Direction Pad X/Y Axis`.
- **3 d-pads**: `Left Thumbstick`, `Right Thumbstick`, `Direction Pad`.

What is *not* there, which is the answer to the two dead buttons:

- **`Button Share` is absent**, and so are paddles (`xbox paddles=none`,
  `share=absent`). The pad's firmware never declares Share or any back button to
  iPadOS, so no app can see them — and neither can the game. That is why Share
  and the extra top button do nothing. They can only be useful if GameSir's own
  software remaps them onto a standard input.
- No touchpad and no motion element are declared either.

Presses, live, as they happened: `Button Options`, `Button Menu`, `Button Y`,
`Button B`, `Button A` — each reported twice, press then release, with
timestamps. Reading the pad in real time works.

What the game received from those same presses: **nothing**. Zero key deliveries.

That settles the mapping question. A pad press does **not** reach the game as a
keystroke: the game reads the controller itself, and any button-to-action mapping
happens inside its own code, where nothing outside it can see or hook it. Our
layer sees the pad directly, and that is what a trigger needs.

Consequence for the trigger, given Share and the paddles are unavailable:

1. **Remap an extra button** in GameSir's own software onto a standard input
   (L3/R3, for instance). Then it is a real element again and we can watch it.
2. **A two-button chord** the game cannot have bound, because the Gamepad UI
   binds single presses only.
3. **`Button Home`** is in the list, and iPadOS usually keeps it for itself —
   worth exactly one test before ruling it out.

### Why Share works on macOS and not here, and the undocumented mode

A reverse-engineering write-up of this exact pad
(`arcataroger/gamesir-g7-pro-bluetooth-for-macos`) documents what the G7 Pro's
Bluetooth mode actually sends, and it explains every dead button:

- The pad's Bluetooth mode **is its Android mode**, and it presents a **composite
  HID device**: a Consumer Control collection first, then gamepad, keyboard and
  mouse collections.
- **Share is sent as a keyboard PrintScreen keystroke**, not as a gamepad button —
  *"which no game sees as a gamepad button"*. That is why it works on macOS, where
  it arrives as an ordinary key, and why no `Button Share` element exists here.
- **The Xbox button is sent as a Consumer Control "AC Home" key**, which the OS
  keeps for itself as the system button. That is why pressing it produced nothing
  at all in our capture.
- **The back buttons L4/R4/L5/R5 mirror other buttons** in this mode, and *"only
  GameSir's own software can reassign them, and that software runs on Windows
  only for now"* — consistent with the pad's own mapping sequence being the route
  for those.

And the finding worth acting on: **the pad has an undocumented real Xbox
Bluetooth mode.** The write-up credits a Reddit post for it, and the steps are:

1. Set the mode switch to Bluetooth.
2. Hold the pairing button until the Xbox light blinks and swirls.
3. **Hold B and the Xbox button together for about five seconds** — the light goes
   out for a second and comes back on.
4. Finish pairing. macOS then lists it as an Xbox controller, rumble included.

If that mode also changes what iPadOS reports, `Button Share` could become a real
element here — which would be the ideal trigger, since the game cannot bind it and
our inspector already releases it from the system gesture.

The write-up also notes Apple's daemon `gamecontrollerd` adopts a third-party HID
pad only when its database lists the pad's vendor ID, product ID and firmware
version — and Apple lists the GameSir X3, not the G7 Pro. On macOS that meant the
pad was ignored until patched. Here it appeared as `GCXboxGamepad` on its own, so
iPadOS 27 accepts it as it is.

### Why macOS can see Share and iPadOS cannot

On macOS the pad is *also* a raw HID device, and any app may open it:

- Apple's own Game Controller documentation assumes exactly that mix. It publishes
  `class func supportsHIDDevice(_ device: IOHIDDevice) -> Bool`, whose discussion
  says *"if the Game Controller framework supports the input device, you can use
  the Game Controller APIs to interact with the device instead of the IOKit
  APIs"* — the framework is designed to sit beside IOKit HID, not instead of it.
- It also publishes `kIOHIDGCSyntheticDeviceKey` for use with **IOHIDManager** and
  **IOServiceGetMatchingServices**, telling apps how to filter the framework's own
  synthetic devices out of a HID search. You only need that if you are running
  such a search.
- `GCControllerLiveInput.capture()` returns a snapshot of the physical device's
  inputs, device-level rather than profile-level.

That is the door macOS userspace tools walk through, and it is the whole
difference: `IOHIDManager` discovers, **grabs (seizes)** and reads any HID device,
so a remapper can be handed the pad's PrintScreen usage and re-emit it as whatever
it likes.

- On macOS and Windows the tools that do this are ordinary applications: Steam
  Input's "Enable Steam Input for Generic Gamepads" — which **GameSir's own FAQ
  recommends for this exact pad in HID mode** — plus reWASD, ControllerMate, the
  macOS installer written for this pad, and general remappers such as `keymapper`,
  whose macOS daemon *"uses IOKit's IOHIDManager to discover, grab (seize), and
  read events from physical input devices"*.
- This is why Share works there: something with raw access sees the keyboard usage
  the pad sends and turns it into an action. It was never a gamepad button.

On iPadOS that door does not exist. Apps receive **only** the Game Controller
framework; there is no public IOKit HID, no device seizure, no re-emission. The
developer community's own answer to "is there an IOHIDManager equivalent on iOS?"
is the MFi program, which is a hardware programme, not an API. The only remapping
iPadOS offers is its own controller-customisation settings, which permute buttons
the framework has already recognised — it cannot discover a usage the framework
never surfaced, which is precisely Share's and Home's situation.

**So on iPad the answer to "how is this solved elsewhere" is: it isn't.** Nothing
in the platform can expose those two buttons. The only lever left is the one on
the pad itself — its own firmware mapping — which changes what the pad *sends*
instead of trying to read more than iPadOS gives out. That is why mapping a back
button onto `L3`/`R3` is the route, and not a workaround.


- **Share.** Pressed repeatedly in the Android Bluetooth descriptor: **0 keys
  reached the host boundary and 0 reached the game**, and the element list never
  gained a Share entry. The hidden Xbox Bluetooth mode (B + Xbox ~5 s during
  pairing, then pair) was tried on the iPad and **changed nothing**: the pad pairs
  with the same Android descriptor and `share=absent` again. macOS can read the
  pad's raw HID device directly, which is the whole difference; iPadOS offers no
  such door, and Share exists only as a keyboard PrintScreen usage inside a
  compound descriptor that iPadOS does not route anywhere.
- **Home / Xbox.** A Consumer Control "AC Home" key, held by the system. It is
  declared (`Button Home` appears in the element list) but never delivered.
- **The four extra buttons.** Null inputs until mapped, and mapping can only
  duplicate a standard button.
- **Chords.** Not free: the game's own guide documents modifier combinations
  (LB + RB + L3 among them), so a chord is not automatically collision-free —
  and Share + Menu is the pad's own input-mode toggle, which a trigger must not
  collide with either.
- **What is left, measured working:** every standard input, including
  `Left Thumbstick Button` and `Right Thumbstick Button` (L3/R3), which arrive
  cleanly as presses. A back button mapped onto one of them is a dedicated
  physical trigger.


### The pad maps its own extra buttons — no software needed

GameSir's manual for the G7 Pro documents on-pad mapping, so GameSir Nexus (which
has no macOS or iPadOS build) is not required:

> Press and hold the **M button + L4/R4/L5/R5**, and the XBOX indicator starts
> flashing slowly. Press the button you want to map to the extra button, and the
> indicator returns to solid.

The manual adds that the extra buttons are **"null inputs", with no assigned
function until mapped**, and that mapping is also available through Nexus — as an
alternative, not a requirement. That is exactly what the measurement showed: four
extra buttons, none of them declared to iPadOS, because they carry no value yet.

Two consequences, and one trap:

- **A mapped extra button can only duplicate a standard button.** The pad cannot
  invent an input iPadOS does not already report, so mapping L4 to L3 yields a
  comfortable physical button that reads as L3 to *both* the game and us. Whether
  that is free is a question about the game's bindings, not about the pad.
- **The extras are per-profile** (`M + Y/B/A/X` selects configurations 1–4), so
  any mapping made on the pad follows the profile in use.
- **Do not choose Share + Menu as a chord.** The manual documents Share + Menu
  held for about four seconds as the pad's own input-mode (HID/PID) toggle; a
  trigger bound to that would switch the controller's protocol. Menu + Options
  alone is not documented as a pad combination.


## Operational notes

- `AKLog` writes to **stderr**, and `Documents/native-guest.log` *is* that
  stderr, attached in `runNativeGame:` after the game starts. Anything logged
  before that attachment goes nowhere, which is why the inspector reports its
  inventory twice.
- Our module's lines carry an `NSLog`-style prefix rather than the platform's
  `[ak]` because `AKSupport.h` is not on that module's include path. Cosmetic;
  the lines land in the same file.
- The inspector's on-screen panel appears with `--inspect-controller`, and the
  guest-side key trace needs the same flag.

