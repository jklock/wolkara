# Experimental touch input

The AppKit adapter provides two translucent buttons at the bottom right of
an application's window. The keyboard button opens and closes the iOS
keyboard. It stays above the keyboard when open, respecting the safe area;
the guest's rendering size stays unchanged. A small accessory row provides
Escape, Tab, left/right arrows, Return and a close button.

The hand button toggles trackpad mode and appears cyan when enabled. The
initial default is on for iPhone, off for iPad; a user's choice is saved
locally. Switching it off restores direct touch input. Long-press the hand
button for a menu with left, right and middle clicks.

| Finger action in trackpad mode | Mouse input |
| --- | --- |
| Slide one finger | Relative cursor movement; lifting/repositioning does not move the cursor. |
| Tap once / twice | Left click / double click. |
| Tap with two fingers | Right click. |
| Tap with three fingers | Middle click. The hand button's menu provides an alternative. |
| Slide two fingers | Vertical or horizontal wheel scrolling, with accumulated partial steps. |
| Hold one finger still for about half a second, then slide | Left-button drag until release. |
| Hold two fingers still for about half a second, then slide | Right-button drag, including relative camera motion when the guest captures the mouse. |

Finger-count changes do not jump the cursor. Cancelled gestures, mode changes,
window changes and app interruptions release a held touch-generated button.
Touch input has a software cursor; physical mouse events retain their own
path. Opening the keyboard cancels a current trackpad gesture.

Select a text field in the application, then open the keyboard manually.
There is no automatic detection of guest text fields. The bridge forwards
committed text, composed Unicode characters and paired key events; it does
not read the guest's text or selection. Autocorrection and smart substitutions
are disabled, and neither entered text nor key codes are written to the adapter's
keyboard diagnostics. Rich composition,
selection and predictive editing through `UITextInput` are not implemented.

## System keyboard dictation

The keyboard now requests normal text entry instead of treating every guest
field as a password. This removes the secure-input restriction on iOS keyboard
dictation. Select the game's chat field, open our keyboard and use its system
microphone button. Dictated text follows the same input path as typed text;
press Return yourself to send it. Tolkara adds no speech engine or recording UI.

Enable **Settings > General > Keyboard > Enable Dictation** on the iPhone and
use Apple's keyboard with a supported language. iOS controls microphone
availability and recognition. Because Tolkara does not inspect guest fields,
it cannot automatically switch back to secure keyboard traits for passwords;
the guest still controls its own text display and masking. The bridge does not
retain entered text or record audio itself.

The `feature/keyboard-dictation` branch starts at `9483e1a`, before the native
mouse experiment; `feature/native-mouse` remains separate. On 2026-10-04,
the simulator phrase-delivery test passed with a synthetic multiword result,
Unicode, backspace and focus restoration. The system microphone button was
visible in the Spanish keyboard on the iPhone 17 Pro / iOS 26.5 simulator.
The signed arm64 device build and strict signature verification also passed.
Actual microphone availability, recognition and game audio during dictation
still require an iPhone test; injecting text in the simulator does not validate
speech recognition.

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
