# Touch controller feasibility

Assessment, 2026-10-06. This is a proposal; no virtual controller is enabled by
the home-screen change, and no game/account test has been performed.

## Recommended first prototype

Use Apple's public `GCVirtualController` with its standard touch overlay.
It provides a `GCController` after connecting, with button and stick events.
Show it only after the game window appears and when no physical gamepad is
connected. Ignore our own virtual controller when counting physical devices.
Provide Auto / Touch / Off so a disconnected or unsuitable controller does not
leave the user without input. A physical controller takes precedence in Auto.

Each finger controls a button or axis directly. Release inputs on touch
cancellation, focus loss, backgrounding and controller disconnection. Do not add
turbo, timed sequences, gameplay decisions, input broadcasting or macros. Test
these lifecycles with an original synthetic input fixture before using a game.
Coordinate touch ownership with the existing keyboard and trackpad; overlapping
overlays must not deliver the same gesture twice.

This is promising, not yet proven for WoW through this runtime. Validate that
WoW receives this controller through the framework path it already uses, that
both sticks and needed buttons are available, and that reconnecting works. The
experimental `translation/GameController` adapter is not a solution: it reports
no controllers and explicitly hides physical controllers too. Do not enable it
for this experiment. No game executable or integrity behavior needs changing.

## Alternative when the system layout is too limited

iOS 17 adds a hidden virtual-controller configuration, plus public setters for
button values and stick positions. It allows an original custom touch layout
to feed the same controller API. It costs more implementation and testing:
multitouch ownership, safe areas, button sizes, layout editing, simultaneous
sticks, and interaction with chat/trackpad all become our responsibility.
Start with the system overlay; only build custom controls after input delivery
and physical-device usability have been demonstrated.

## Account-policy limits

Direct touch-to-input mapping has no autonomous gameplay logic, but this design
does not establish Blizzard approval. Its EULA restricts bots and other
unauthorized software. There is no verified assurance here that a particular
API, one-to-one mapping, virtual controller or compatibility layer cannot lead
to a sanction. A working controller test cannot establish account safety.
Use the documented virtual identity; do not disguise it as physical hardware
or add anti-cheat/integrity workarounds. Distribution decisions need to consider
Blizzard's terms separately from Tolkara's open-source license.

## License and attribution

The checked-in Tolkara license is MIT: derivative products can be free or paid,
provided the copyright and permission notices accompany relevant copies. The
fork also retains TACTSharp/CascLib notices in `NOTICE.md`. This permission covers
that software, not Blizzard's game files, artwork, trademarks or account terms.
The home is original text/UI, not bundled game artwork; About carries the
independent-project attribution and licenses.

References checked for this assessment:

- [Apple: GCVirtualController](https://developer.apple.com/documentation/gamecontroller/gcvirtualcontroller)
- [Apple: virtual and physical game controllers](https://developer.apple.com/videos/play/wwdc2021/10081/)
- Xcode 27 iPhoneOS SDK, `GameController.framework/Headers/GCVirtualController.h`:
  standard overlay, connected controller, hidden configuration and input setters.
- [MIT license](https://opensource.org/license/mit)
- [Blizzard EULA](https://www.blizzard.com/en-gb/legal/08b946df-660a-40e4-a072-1fbde65173b1/blizzard-end-user-license-agreement)
