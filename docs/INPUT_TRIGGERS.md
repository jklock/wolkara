# Input triggers: any button, on any controller

Status: design. The Share work proved the mechanism on one pad; this is the layer
that makes it work for whatever the user plugs in.

## Why

Controllers differ wildly. The GameSir G7 Pro declares 34 elements and no Share
element at all, so its Share had to be caught as a system signal. An Xbox Elite
declares paddles. A DualSense declares a touchpad and a Share button. A Siri
Remote declares only a d-pad. A keyboard declares 134 keys. A Magic Keyboard's
trackpad declares clicks.

A feature that names one button on one pad is a feature for one person. The
trigger has to come from **whatever the hardware offers**, chosen by the user,
with no per-device code.

## What the codebase already provides

- **Generic enumeration.** `wolkara/Controller/ControllerInspector.m` attaches to
  every element of every connected controller through `physicalInputProfile` —
  `buttons`, `axes`, `dpads`, `touchpads`. That is profile-agnostic: it needs no
  knowledge of `GCXboxGamepad`, `GCDualSenseGamepad` or `GCMicroGamepad`. It also
  attaches to `GCKeyboard` and `GCMouse`.
- **Hot plug.** Connect and disconnect are already observed, with
  `wolkara/Touch/TouchGamepad.m` as the in-repo precedent for watching
  `GCController.controllers` and re-attaching.
- **Per-user settings.** `AKGamepadLayout initWithDefaults:` and keys such as
  `TKTouchGamepadEnabled` are the established way the layer remembers a choice.
- **Test fixtures.** `wolkara/Touch/tests/test_touch_gamepad_app.m` already fakes a
  controller with `extendedGamepad` and `physicalInputProfile`, so every profile
  can be tested without hardware.
- **The system-consumed path.** A button iPadOS keeps for itself (Share, Guide)
  is still reachable through the notifications its gesture posts — measured, see
  `CONTROLLER_INPUT.md`.

## What is missing

1. **Identity in the stream.** A press arrives as `element, value, pressed`. Which
   device it came from is not carried, so nothing can be remembered per device.
2. **Patterns.** Only single presses are distinguished, so a controller whose
   every button the game already uses has nothing left to offer.
3. **A way to choose.** No arm-and-press, so any choice needs code.
4. **One stream.** Gamepad, keyboard, mouse, touchpad and system signals are
   separate today.
5. **Always on.** Everything sits behind `--inspect-controller`, which is a
   diagnostic flag, not a feature.

## Design

### 1. One event type

```
AKInputEvent {
    source     controller | keyboard | mouse | touchpad | system
    vendor     e.g. "Xbox Bluetooth Gamepad"
    product    e.g. "Xbox One"
    element    e.g. "Button Share", "keycode 70", "leftButton", "Share"
    value      analog value, 0..1
    pressed    edge
    time       monotonic
}
```

### 2. One router

`AKInputRouter` subscribes to the inspector's stream and to the system signals,
normalises them into that type, and hands every event to the trigger matcher. It
is the only place that knows about sources, so adding a source later touches
nothing else.

### 3. One matcher

`AKTrigger` describes what to watch and how:

| Field | Meaning |
| --- | --- |
| element | an exact name, or a family (`Button Share`), or `any` |
| pattern | `press`, `double`, `long`, `chord`, `hold` |
| hold ms | threshold for `long` |
| chord | the partner element for `chord` |

Patterns are what make "any button" true. A game can own every *tap* of a
controller and still leave every *long press*, *double tap* and *chord* free,
because the client binds single presses only.

### 4. Resolution order, per device

1. A real element, preferring one iOS reserves but does not deliver to games
   (`Button Share`), with its system gesture released.
2. Otherwise the system signal for that button — the screenshot notification,
   which is a discrete gesture the user made.
   The *capture* notification is deliberately not in this list, and it used to be.
   `UIScreen.isCaptured` says only that something is recording or mirroring the
   iPad, not that the pad's Share was held: measured on 2026-10-16, with the iPad
   being captured from a Mac, it fired a tenth of a second into every launch and
   the launcher started dictating by itself. It is recorded in the inspector's
   history and the log, and reported to nobody.
3. Otherwise a learned element, chosen by the user.
4. Otherwise a pattern on an element the game uses — long press, double tap or
   chord. This is the universal fallback that needs no cooperation from anything.

### 5. Learning, without a UI

Arm, then press. The next event becomes the trigger, and it is stored per
vendor and product, so the same pad behaves the same way next time. Entered once
from the launcher screen; never during play, and nothing appears inside the game.

### 6. Tests

Fixture controllers per profile — extended, Xbox with and without a Share
element, DualSense with a touchpad, micro with only a d-pad — asserting the
matcher fires for each. No hardware needed, and it is the only way to know this
works for pads we do not own.

## Plan

1. Carry identity in the inspector's stream, and normalise keyboard, mouse and
   system signals through the router.
2. Implement `AKTrigger` and its matcher, with tests per profile.
3. Add learning and per-device persistence.
4. Move the feature out from behind the diagnostic flag; keep the logging behind
   it.
5. Point dictation at the resolved trigger instead of at "Share".
