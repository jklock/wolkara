# Automatic touch controller

Implemented on `feature/touch-controller` from `feature/wow-home` (`2b87fd8`),
2026-10-06. This replaces the earlier feasibility-only proposal. The native mouse
experiment remains separate, and the inherited keyboard correction is retained.

## Layout and behavior

When the guest window is active and no physical gamepad is connected, a translucent
controller appears automatically. Connecting a physical gamepad removes it;
disconnecting the physical pad restores it. The toolbar's gamepad icon toggles
Automatic / Off and saves that preference. The toolbar moves to the top center
while the touch controller is visible, leaving the game controls free.

- LB and LT at the upper left; RT and RB at the upper right.
- Two analog sticks at the bottom, with radial dead zones and clamped output.
- Four independent direction buttons form an annular D-pad around the left stick.
- Y/B/A/X form the matching ring around the right stick. Only the visible sectors
  are touch targets; the gaps and empty center do not trigger another button.
- `+` is centered below, aligned with A and the D-pad's down label.
- `−` is omitted at the user's request: Apple's virtual profile does not expose
  an Options/Select button. No keyboard action is substituted for it.

Buttons and axes follow fingers directly, including simultaneous held modifiers
and D-pad diagonals. There are no timed sequences, turbo, macros, automatic game
commands, input broadcasting or gameplay decisions. Touches outside the controls
continue to the existing trackpad. Opening the keyboard, losing focus, entering
the background, hiding the controls or connecting hardware releases held inputs.
A cancelled asynchronous connection cannot restore an unwanted overlay.

## Controller API

The adapter uses Apple's public `GCVirtualController` with `hidden = YES` and an
original UIKit layout. The guest receives the system's virtual `GCController`;
physical controllers and their handlers are not modified. The experimental
`translation/GameController` stub is not enabled. No game executable is changed,
no game memory is inspected and no physical-device identity is impersonated.

The configuration retains Apple's legacy layout restrictions even when hidden:
declaring both the D-pad and left stick throws, as do explicit Menu/Options
elements. The connected extended profile nevertheless provides D-pad and Menu.
The public setters for those inputs, alongside both configured sticks and all
face/shoulder/trigger buttons, are verified against the real framework in our
synthetic fixture. Options is absent, so there is deliberately no `−` control.

Apple's standard visible overlay was explored first; its fixed placement was
replaced with the requested custom layout. No copied assets are needed.

## Validation

The fixture contains only original UI and synthetic input, with no game, account
or network connection. It separately exercises delayed/failed connections with
fake transports and real GameController input delivery in the iOS simulator.

```sh
SIMULATOR='<available simulator>' bash tools/test_touch_gamepad_ui.sh --self-test
SIMULATOR='<available simulator>' bash tools/test_touch_gamepad_ui.sh --self-test-input
SIMULATOR='<available simulator>' bash tools/test_touch_controls_ui.sh --self-test --guest-poll-loop
SIMULATOR='<available simulator>' bash tools/test_wow_launcher_ui.sh
SIMULATOR='<available simulator>' bash tools/test_translation_sim.sh
bash tools/test_emulation.sh
```

The input fixture checks all nine buttons, both simultaneous sticks, radial
bounds and malformed coordinates, D-pad diagonals/opposing directions/cancel,
held modifiers, neutral release, annular hit regions, `+` alignment and trackpad
passthrough. The lifecycle fixture checks physical priority, own-controller and
snapshot filtering, keyboard/focus suspension, late replies, error/retry and
teardown. The launcher fixture checks that status text fits at normal and large
accessibility font sizes.

All six commands above passed with Xcode 27.0 and the iOS 27.0 iPhone 16 Pro Max
simulator. The integration test still asserted the old toolbar's secure-entry
trait; it now checks the separate dictation text view and its disabled spelling
and autocorrection traits. No keyboard implementation change was needed.

The signed device build also passed:

```sh
xcodebuild -project Tolkara.xcodeproj -scheme Tolkara -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/iphone-touch-gamepad-signed ARCHS=arm64 \
  TOLKARA_SYSTEM_ROOTS=YES build
codesign --verify --deep --strict \
  build/iphone-touch-gamepad-signed/Build/Products/Debug-iphoneos/Tolkara.app
```

Strict signature verification passed with normal access to the macOS keychain.
The only build warnings concerned skipped App Intents metadata extraction.
The embedded AppKit adapter contains the new touch-controller implementation.
This build was not installed on the user's iPhone during this work.

For manual inspection, run the gamepad fixture without a self-test flag. If the
simulator forwards a controller from the Mac, `--ignore-other-controllers` lets
this fixture alone display the touch UI without disconnecting the user's
hardware. Production never uses that override. This option must not be confused
with a successful automatic no-hardware test.

Physical-iPhone usability, Bluetooth handover during gameplay and WoW's response
to this virtual profile still require manual validation. Simulator input success
does not prove game compatibility or Blizzard approval/account safety.

References:
- [Apple: adding virtual controls](https://developer.apple.com/documentation/gamecontroller/adding-virtual-controls-to-games-that-support-game-controllers-in-ios)
- [Apple: GCVirtualController](https://developer.apple.com/documentation/gamecontroller/gcvirtualcontroller)
- Xcode 27 iPhoneOS SDK, `GameController.framework/Headers/GCVirtualController.h`.
