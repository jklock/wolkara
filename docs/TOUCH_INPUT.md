# Experimental touch input

The AppKit adapter provides four translucent toolbar buttons: pointer, keyboard,
automatic touch controller and control settings (gear). The toolbar always stays
at the top center inside the safe area, including with a physical controller,
with the keyboard open or with touch controls hidden. The keyboard button opens
and closes the iOS keyboard and a visible draft editor immediately above it;
the guest's rendering size stays unchanged. The accessory row provides Escape,
Tab, left/right arrows, game backspace, Return and a close button.
The control-transparency slider also fades all four toolbar buttons, updates
them live and restores the saved value at launch. It does not fade the native
keyboard or the settings panel. The pointer icon is optically centered with a
small rightward offset, without moving its touch target.

The gamepad button enables automatic touch controls when no physical controller
is connected, or turns them off. The custom layout provides two sticks, D-pad,
ABXY, LB/LT/RB/RT and `+`; it hides and releases held input while the keyboard is
open. See [touch controller details and validation](TOUCH_CONTROLLER_PROPOSAL.md).

The pointer button toggles trackpad mode and appears cyan when enabled. The
initial default is on for iPhone, off for iPad; a user's choice is saved
locally. Switching it off restores direct touch input. Long-press the pointer
button for a menu with left, right and middle clicks.

| Finger action in trackpad mode | Mouse input |
| --- | --- |
| Slide one finger | Relative cursor movement; lifting/repositioning does not move the cursor. |
| Tap once / twice | Left click / double click. |
| Tap with two fingers | Right click. |
| Tap with three fingers | Middle click. The pointer button's menu provides an alternative. |
| Slide two fingers | Vertical or horizontal wheel scrolling, with accumulated partial steps. |
| Hold one finger still for about half a second, then slide | Left-button drag until release. |
| Hold two fingers still for about half a second, then slide | Right-button drag, including relative camera motion when the guest captures the mouse. |

Finger-count changes do not jump the cursor. Cancelled gestures, mode changes,
window changes and app interruptions release a held touch-generated button.
Temporary loss of focus keeps the keyboard open for system dictation panels;
entering the background or removing the host view dismisses it.
Touch input has a software cursor; physical mouse events retain their own
path. Opening the keyboard cancels a current trackpad gesture.

Select a text field in the application, then open the keyboard manually.
Write, select, correct, paste or dictate into the native **Draft** panel; tap
**Replace** (or the system keyboard's **Done**) to replace **all** text in the
selected game field. This does not press Return. Press **↵** separately to submit
in the game. An empty draft clears the field: open the keyboard and tap Replace
without entering text. A just-submitted draft is cleared locally and Replace is
then disabled until another edit or keyboard session, preventing a second tap
or queued Done callback from accidentally clearing the replacement.

While a draft is present or recognition/composition is still pending, game
accessory keys are disabled, so they cannot move to another field or submit an
unfinished draft. **Clear draft** clears only this local document; the accessory
**⌫** acts on existing game text when the draft is empty.

The editor keeps a normal UIKit text document during editing. It no longer
clears the document/selection/undo history after every letter, and there is no
per-keystroke asynchronous forwarding. The explicit Replace action queues
**Command+A**, **Backspace**, then the draft's normal Unicode key events, in
order. All keys have matching releases; Command is scoped to the A events.
It does not query a field, use the clipboard, infer password length, send a
fixed series of deletes, press Return or retry automatically. Newlines, tabs
and control characters in pasted text become spaces rather than implicit game
commands. Ordinary direct text input retains its insertion behavior.
Closing the keyboard or entering the background discards the draft without
sending it; temporary focus loss for the dictation UI keeps it available.

There is no automatic detection or reading of game text fields. This panel is a
local draft, **not a mirror of the game field**: it starts empty rather than
retrieving already-entered text. AppKit offers text-context queries through
[`NSTextInputClient`](https://developer.apple.com/documentation/appkit/nstextinputclient),
but the current adapter has no verified whole-field text/selection query for
WoW. The user chose whole-field replacement as the fallback. No application
memory inspection or game-specific hooks are used. The editor is visible plain
text, including when the user selects a password field in the game.
Autocorrection and smart substitutions are disabled. Drafts are not saved or logged.

The replacement path depends on the focused game field recognizing the macOS
Select All shortcut. Original fixtures verify replacement with existing text,
a cursor in the middle, partial selection, empty clearing, duplicate suppression,
composition/dictation and exact key order/modifiers. The updated iOS build still
needs a physical WoW login/chat-field check; the synthetic result does not
prove every game field honors that shortcut. On 2026-10-07 the input fixture,
translation suite, required ASan/UBSan suite, signed arm64 device build and strict
signature verification passed. Manual simulator key taps replaced `a` with `b`
without appending, then an empty Replace cleared the field. No game was run or
credentials read during these checks.

## System keyboard dictation

The keyboard requests normal text entry instead of treating every guest
field as a password. A native UIKit text view is the first responder, providing
the `UITextInput` contract used by system dictation instead of only `UIKeyInput`.
Select the game's chat field, open our keyboard and use its system
microphone button. Dictated text appears in the editable draft;
tap Replace, then press Return yourself to send it. Tolkara adds no speech engine or recording UI.

Enable **Settings > General > Keyboard > Enable Dictation** on the iPhone and
use Apple's keyboard with a supported language. iOS controls microphone
availability and recognition. Because Tolkara does not inspect guest fields,
it cannot automatically switch back to secure keyboard traits for passwords;
the guest still controls its own text display and masking. The bridge does not
record audio itself or retain text after insertion. The local draft is
discarded when the keyboard closes or the app enters the background.

The `feature/keyboard-dictation` branch starts at `9483e1a`, before the native
mouse experiment; `feature/native-mouse` remains separate. On 2026-10-04,
the first change (`72d7468`) made the microphone visible, but the user reported
that tapping it did not start dictation on the iPhone, while other apps worked.
Button visibility and injected phrases were insufficient validation.

The follow-up replaces the simple key-input responder with the native text
view and stops dismissing it on temporary window/app deactivation. The system
dictation panel itself can trigger those notifications; dismissing the first
responder cancels it. An A/B simulator check showed no panel with the original
`UIKeyInput` responder even with the focus fix, and no panel with the native
responder alone. With both changes, tapping the microphone opened iOS's
"Enable Dictation" prompt, also seen with an unmodified UIKit reference field.
The prompt was cancelled without granting permission or recording audio.

Simulator checks exercise actual `UITextInput` marked-text updates,
commit/replacement, dictation placeholders, Unicode, backspace, cancelled
composition, late results after closing, and focus restoration. They verify
no duplicate text or automatic Return, preserve the keyboard through temporary
focus loss, and close it on background entry. The test runner also requires its
success marker, because `simctl launch` can return zero after an assertion.
These are synthetic input tests. On 2026-10-06 the user confirmed that the
microphone works on the iPhone, but reported long stalls after a few ordinary
keystrokes even without using dictation. The bridge previously reset UIKit's
document, selection and undo history synchronously inside text-edit callbacks.
The earlier follow-up deferred that reset and text delivery until the callback returned,
and preserves ordering for immediate Return, backspace and keyboard close.
The user subsequently confirmed that the stall still occurs on the iPhone.
The visible draft revision above replaces that per-key bridge; see the latest
validation below. The minutes-long device stall has not been reproduced in the simulator.
No microphone audio was captured as part of automated validation.

The expanded fixture can run inside the same timer-entered, nonblocking desktop
event loop as the runtime (`--guest-poll-loop`). It covers 64 repeated groups of
typing and deletion, delayed text delivery, immediate Return/close, cancelled
callbacks after reopen and the existing composition/dictation cases. A separate
watchdog makes a blocked main thread fail instead of waiting indefinitely.

Validation for this follow-up on Xcode 27.0 / iOS 27.0:
- `tools/test_touch_controls_ui.sh --self-test --guest-poll-loop`: passed.
- `tools/test_emulation.sh`: passed, including the signing test that failed
  under the previous Xcode installation; no signing code was changed here.
- Signed arm64 `iphoneos` Debug build and strict code-signature verification:
  passed.
- Manual taps on the simulator's software keyboard produced the complete
  phrase without a stall. This does not establish that the reported iPhone
  freeze is fixed or validate live speech recognition after this change.
- Installed in place on the iPhone 16 Pro Max with the game closed. Game-data,
  settings and addon inventories were preserved, as were the configuration,
  build metadata and original game executable hashes. Device typing/dictation
  validation is pending.

For manual comparison, `tools/test_touch_controls_ui.sh
--native-keyboard-reference` opens an ordinary UIKit text view in the synthetic
fixture, without the keyboard adapter.

## Native UI stalls while the guest continues (2026-10-06)

The user reported that both software keys and settings sliders can stick while
WoW keeps animating and responding to the controller. Beginning the deferred
Control Center gesture releases the native UI. This broadens the issue beyond
the text bridge; the earlier text-edit change did not establish a device fix.

The adapter returned queued desktop events without ever servicing UIKit while
that queue stayed nonempty. An original simulator fixture reproduced starvation:
a native animation failed to complete within two seconds with continuous queued
events, although the guest polling loop kept running. Empty-queue and
source-driven polls passed before the correction. This demonstrates a defect in
the adapter, not proof that it is the only cause of the reported device stall.

`nextEventMatchingMask:` now gives UIKit a short turn even with queued events,
limited to once per 1/120 second on that path, before inspecting the queue.
Masks, peeking, priority insertion and delivery order are preserved. The shared
pump also flushes pending implicit Core Animation transactions after native
callbacks return; it does not commit a caller's explicit transaction. The same
pump is used by `NSApplication.run`. No system gesture is synthesized and no
keyboard text or application memory is inspected.

The input fixture no longer forces a display flush after each translated key
or mouse event, which could conceal presentation problems. Checks on iOS 27 /
Xcode 27 passed:

- `tools/test_touch_controls_ui.sh --self-test --ui-progress-test`: native
  animation completion, main-queue work and timer-driven slider updates under
  empty polling, source traffic, continuous queued events, non-dequeuing peeks
  and `NSApplication.run`. The failing queued-event case now passes.
- `tools/test_touch_controls_ui.sh --self-test --guest-poll-loop --queued-traffic`:
  existing repeated typing, deletion, composition, dictation-placeholder,
  immediate Return/close, cancellation and focus checks.
- `tools/test_translation_sim.sh`: mask/peek/priority behavior, including native
  callbacks changing the queue while it is being serviced, plus existing adapters.
- `tools/test_emulation.sh`: required ASan/UBSan regression suite passed.
- Manual simulator software-key taps produced `hola prueba`; actual drags changed
  transparency and both size sliders while the synthetic queue stayed occupied,
  without invoking Control Center. This did not run a game or record dictation.
- Signed arm64 iOS Debug build and strict/deep signature verification passed.

On 2026-10-07 the user confirmed that the physical-device stall persists:
several typed keys queue up and all arrive after beginning Control Center or
Notification Center. The earlier busy-queue fix therefore did **not** resolve
the full reported issue.

### Visible draft and tracking-mode follow-up (2026-10-07)

In addition to replacing per-key document resets with explicit draft insertion,
the main-thread pump gives UIKit's tracking mode a nonblocking turn, at most
120 times per second, **only while the native keyboard/editor or control settings
are open**. It still services the default mode every turn and keeps the existing
event mask/order/peek behavior. Normal gameplay with these panels closed retains
the preceding pump path. No system gesture is synthesized and no private UIKit
API is used.

A focused synthetic test schedules tracking-mode and default-mode work inside
the timer-entered desktop loop. Before this change only default-mode work ran;
after it both complete with the keyboard or settings open. This demonstrates the
missing mode service, **not that it explains every real-device stall**. Apple
documents [UITrackingRunLoopMode](https://developer.apple.com/documentation/uikit/uitrackingrunloopmode)
as the mode used for tracking controls and describes mode-specific execution in
[CFRunLoopRunInMode](https://developer.apple.com/documentation/corefoundation/cfrunloopruninmode(_:_:_:)).

Current checks use only original fixtures, with no game or accounts:
- `tools/test_touch_controls_ui.sh --self-test --guest-poll-loop --queued-traffic`:
  draft editing/selection/deletion, 64 repeated edits, explicit insertion without
  duplicate text, Unicode, marked composition, synthetic dictation, cancellation,
  control-character filtering, separate Return, focus and fixed toolbar geometry.
- `tools/test_touch_controls_ui.sh --self-test --tracking-progress-test`:
  default and tracking-mode progress with both native surfaces.
- `tools/test_touch_controls_ui.sh --self-test --ui-progress-test`: ordinary
  animation/timer/main-queue progress across empty/occupied queues and peeking.

- Required `tools/test_emulation.sh` (ASan/UBSan) and
  `tools/test_translation_sim.sh`: passed.
- Signed arm64 iOS Debug build and strict/deep signature verification: passed.
- Manual simulator keyboard taps, deletion and Insert produced exactly `hola`
  in the original input fixture. Drags changed all three sliders without a
  system-edge gesture. The draft/toolbar and non-overlapping settings layout
  were inspected visually. No speech was recorded or game run.

Physical typing, dictation, sliders and game frame-rate must be checked again
before marking the user's stall resolved. The build is prepared for Xcode;
this work does not install it or interrupt the user's game.

## Validation

On 2026-10-02, the following checks passed:

- The synthetic trackpad and text tests on the Mac with `-Wall -Wextra
  -Werror`, ASan and UBSan: motion, click buttons, slow/negative scrolling,
  finger transitions, long holds, interruption, malformed traces, ANSI key
  mapping, composed Unicode and newline normalization.
- `SIMULATOR='iPhone 17 Pro' bash tools/test_translation_sim.sh` on iOS 26.5:
  UIKit/AppKit event delivery, cursor bounds, captured deltas without a mouse,
  wheel values, three buttons, double click and software keyboard events.
- `bash tools/test_touch_controls_ui.sh --self-test`: our original fixture
  opened the system keyboard, checked visible keyboard/controls geometry,
  delivered text and backspace, closed it and restored hardware-key focus.
  The keyboard-open and keyboard-closed layouts were also inspected visually.
- The signed arm64 device build succeeded with Xcode 26.6 / iOS 26.5 SDK.

The device build used the existing locally signed project:

```bash
xcodebuild -project Tolkara.xcodeproj -scheme Tolkara \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/iphone-touch-signed ARCHS=arm64 \
  TOLKARA_SYSTEM_ROOTS=YES build
```

`tools/test_emulation.sh` was rerun and still fails at
`tests.test_sign_guest_local.AdhocTests.test_matches_codesign_byte_for_byte`
with `differs from codesign -s - for sgl-fixture.dylib`. This failure was
previously reproduced on unchanged upstream `199da9e`; the full suite is not
green. The commands after that failure were run separately and passed.

To inspect or interact with the original fixture, run
`bash tools/test_touch_controls_ui.sh` (set `SIMULATOR` to choose a device).
It builds and launches only the test screen, never an imported application.
`--show-keyboard` opens its keyboard for visual inspection; `--self-test`
exits after the assertions. Synthetic tests are also registered in the
standard emulation and translation test scripts.

On 2026-10-02 the user confirmed that the new keyboard and trackpad controls
work correctly in WoW Forever on the iPhone 16 Pro Max / iOS 27.0 setup. This
is a manual usability report in addition to the synthetic and simulator
checks above. Other devices, physical iPad input, other applications and rich
text composition remain unverified. The earlier two-hour gameplay and 60 FPS
report used the Bluetooth-keyboard/AssistiveTouch setup; it is not a new
performance measurement of these controls.
