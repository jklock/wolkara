# Input triggers

Voice is off by default. Enabling it and explicitly mapping an input are both
required before that input can start dictation. Screenshots and capture changes
are diagnostic signals only: they cannot be mapped and never start the microphone.

## Supported modes

The product decision on 2026-10-17 is **Hold to talk** or **Press to start and stop**.
The mode determines every mapping's pattern. Double, long and chord execution has
been removed; stored values 1–3 are rejected and removed during startup migration.
Users with one of those manually authored mappings must map their button again.
Values 0 (press) and 4 (push-to-talk) retain their existing storage meaning. Legacy
interval/chord fields are validated for compatibility but have no runtime effect.
Repeated down samples do not trigger another toggle or another hold session.

## Identity and learning

`AKControllerInspector` enumerates the controller's public physical input profile,
keyboard and mouse. It sends canonical element IDs such as `controller.button.share`
and `keyboard.key.36`, with source, device identity, value and pressed state.
Events and router state are confined to the main queue.

Mappings use vendor and product category, the identity public GameController APIs
provide. Identical controller models share a mapping. Legacy vendor-only mappings
are adopted once. Unknown element names and system signals are rejected.

Mapping waits for the first supported press and then disarms. Timeout, dismissal,
backgrounding, mode changes and controller disconnection cancel learning. A late
input cannot silently replace the saved mapping.

## Ownership

The default is observation: a mapped input may also reach the game. The page warns
users to choose a controller button the game does not use. The user accepted this
controller limitation on 2026-10-17; no unmeasured HID translation table is used.

“Keep the game from seeing it” owns mapped **keyboard keys**. The shell publishes
owned usages through `AKTouchOwnedKeyUsagesDidChange`; the separately built AppKit
dylib suppresses both press and release while still reporting the input to the
router. Disabling ownership restores forwarding. Controller buttons cannot be
matched to guest key usages by the current implementation.

The inspector changes a controller's system gesture only for an enabled, explicit
mapping of that element. It restores gestures on unmapping, disabling and disconnect.
A controller button hidden entirely by iPadOS cannot be mapped through a screenshot.

## Verification

`wolkara/tools/test_voice.sh` tests mapping, persistence, invalid/retired patterns,
repeat suppression, both modes, cancellation, system-signal isolation and voice state.
`wolkara/tools/test_touch_controls_ui.sh --self-test` tests the adapter's keyboard
swallowing and forwarding. These synthetic fixtures do not prove physical controller
button delivery; that requires a real press on the final installed build.

A real press was measured on Dadpad on 2026-10-21: Options on an Xbox Bluetooth pad was
mapped, and two hold-to-talk utterances in the running game were delivered - `heard 21
characters` and `sent Return` each time, with the guest dequeuing 43 key events (21
down/up pairs plus Return) and no crash. The same run also covered the home screen's **Test
Voice** page. `--selftest=dictation-target` checks the wiring without a person speaking, by
asking the registered text target whether it takes words and keys. See
[`VOICE.md`](VOICE.md#verified-on-the-device).
