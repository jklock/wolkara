# Input triggers: any button, on any controller

Status: design. The Share work proved the mechanism on one pad; this is the layer
that makes it work for whatever the user plugs in.

**Nothing here fires on its own.** A trigger exists only once the user has switched voice
on and pressed the button they want; until then the router is given no trigger at all and
the inspector changes nothing about the pad. The 2026-10-16 audit's first release blocker
was a path where an unrelated screenshot could start the microphone, and the answer is
this rule rather than a better guess about who pressed what.

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
- **The system-consumed path.** A button iPadOS keeps for itself (Share, Guide) posts
the notifications its gesture produces, so it is reachable — measured, see
`CONTROLLER_INPUT.md`. A screenshot is offered to the user as `system.screenshot` and
does nothing unless they map it; a screen-capture change is never offered at all.

## What is built

1. **Identity in the stream.** `AKInputEvent` carries the device, as the controller's
   identity (`AKControllerIdentity`) rather than its vendor name, so two pads from one
   vendor are two pads.
2. **Patterns.** Press, double, long, chord and push-to-talk are all matched. Only press
   and push-to-talk are offered by the launcher; the rest are reachable by a stored
   mapping and are covered by the suite.
3. **A way to choose.** Arm, then press. `AKInputRouter beginLearning` takes the first
   event as the mapping and disarms itself after twenty seconds.
4. **One stream.** Gamepad, keyboard, mouse, touchpad and system signals arrive as one
   kind of event.
5. **Off by default.** Nothing fires until the user switches voice on and maps a button.

## What is not, and must not be claimed

Input arbitration. The router *observes* input; it does not stop the game receiving the
same press. A button the game also uses will still do whatever the game does with it,
and a long press or a chord can fire the game's own binding as well as ours. The launcher
says so where the button is chosen, and the honest description of this feature is
"a button you are willing to share with the game", not "a button the game cannot see".
Making it collision-free means owning the input, which is a different piece of work.

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

There is no fallback. For a device the user has mapped:

1. The element they chose, as a canonical id (`controller.button.share`,
   `keyboard.key.36`, `system.screenshot`).
2. If that element is a controller button iOS reserves, its system gesture is released
   for that button on that controller - and only then, and given back when the mapping is
   removed, when voice is switched off, or when the pad goes away.
3. Nothing else. An unmapped device fires nothing, and no element of a pad is touched
   before the user asks.

Element names are ids from `wolkara/Input/InputElement.h`, never display text. Display
text was a bad key in three ways: the system's screenshot signal was called `Share`
while the pad's button is `Button Share`, so a mapping made by pressing one could never
match the other; a d-pad or touchpad event carried its coordinates in the name, so it
was a different string every time and nothing learned from one press could match the
next; and a name written into a user's defaults cannot be renamed later without losing
their mapping. A name an older build wrote is migrated on read, once, by
`AKTrigger migrateStoredTriggersInDefaults:`.

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
