// WolkaraForever: the canonical names for the things that can be pressed.
//
// An element name is a key. It is compared on every input event, it is written into
// NSUserDefaults as the user's mapping, and it is what the launcher shows them. Using
// display text for that was wrong in three separate ways, all of them found by the
// 2026-10-16 audit:
//
//   * "Share" (what the system's screenshot signal was called) and "Button Share"
//     (what the pad's own button is called) are different strings for what the user
//     thinks is one button, so a mapping made by pressing Share could not match the
//     physical element and only ever worked through the screenshot workaround.
//   * "dpad x=0.42 y=-1.00" and "touchpad down x=0.51 y=0.33" are new strings every
//     time they are reported. Nothing learned from one press could ever match the
//     next one: the mapping was saved and then never fired.
//   * A name written down by a user's device cannot be renamed later without
//     silently discarding their mapping, so the vocabulary is fixed and versioned.
//
// The shape is `kind.what.the.thing.is` - `controller.button.share`,
// `keyboard.key.36`, `touchpad.touchpad.down`, `system.screenshot` - and the readable
// text is *derived* from it for the log and the settings screen. Values that move
// (a stick's position, a touchpad's coordinates) are event metadata, never part of
// the name.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A pad's button, named as GameController names it ("Button Share", "Button A").
NSString *AKInputElementForControllerButton(NSString *buttonName);
/// A pad's analog axis. An axis is not a button; it is here so the log and a
/// stick-as-button mapping have a stable name for one.
NSString *AKInputElementForControllerAxis(NSString *axisName);
/// A keyboard key, by HID usage code.
NSString *AKInputElementForKeyboardKey(NSInteger keyCode);
// The prefix every keyboard element id is built from, so a caller that has an id can take it
// apart - and so two modules cannot come to disagree about what the ids look like.
extern NSString *const AKInputElementKeyboardPrefix;
/// A mouse button: "left", "right" or "middle".
NSString *AKInputElementForMouseButton(NSString *button);
/// A touchpad event: phase is "down", "up" or "moved".
NSString *AKInputElementForTouchpad(NSString *pad, NSString *phase);
/// A d-pad position, built from its axes so a diagonal is a name rather than numbers.
NSString *AKInputElementForDirectionPad(NSString *pad, double x, double y);

/// The system's own signals. Both are real, both are only ever acted on if the user
/// mapped them.
NSString *AKInputElementSystemScreenshot(void);
NSString *AKInputElementSystemCapture(void);
BOOL AKInputElementIsSystem(NSString *element);

/// The same id for a name an older build wrote down, so an existing mapping survives
/// the change instead of quietly ceasing to match.
NSString *AKInputElementCanonicalized(NSString *element);
/// True when the name is already one of ours.
BOOL AKInputElementIsCanonical(NSString *element);

/// Readable text for a canonical id: "Share", "A", "key 36", "d-pad up-left".
NSString *AKInputElementDisplay(NSString *element);

/// The one spelling used for every identifier here: lowercase, dot-separated, with
/// runs of anything else collapsed to a single dot. Public because a device's
/// identity is built the same way as an element's.
NSString *AKInputIdentifierSlug(NSString *text);

NS_ASSUME_NONNULL_END
