// Wolkara layer: what a controller reports to us, and every change to it.
//
// Reading only. It attaches observers to the pads, keyboards and pointing devices the
// system reports, names everything it finds, and logs every change as it happens. It
// never consumes an input, and it never changes a pad's behaviour on its own: a
// reserved system gesture is released only when the user has mapped that exact
// element, through -releaseSystemGestureForElement:device:, which the input router
// calls. Before 2026-10-16 it disabled Share's gesture at startup for every pad that
// declared one, which changed how the controller behaved before the user had chosen
// anything - see development/STABILITY_AUDIT_2026-10-16.md.
//
// Output goes to the platform's own log channel and to Documents/wolkara.log.

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

NS_ASSUME_NONNULL_BEGIN

/// A controller's identity for remembering a mapping against: vendor *and* category,
/// because two pads from one vendor are two pads. Never the player index, which moves
/// when pads come and go, and never the display name, which a mapping key should not
/// have to be.
FOUNDATION_EXPORT NSString *AKControllerIdentity(GCController *pad);

@interface AKControllerInspector : NSObject

+ (instancetype)shared;

// Start watching: the pads connected now, and any that connect later. Also the
// keyboards and mice the system reports. Safe to call more than once.
- (void)begin;

// The identical stream the log carries, for a caller that wants to act on it.
// `element` is a canonical id from InputElement.h ("controller.button.share",
// "system.screenshot"); `pressed` distinguishes an edge from a value change.
@property (nonatomic, copy, nullable) void (^onInput)(NSString *element, double value, BOOL pressed);

// Log the identity and full element list of everything connected right now.
// This is the call that answers "what does this pad actually have?".
- (void)logInventories;

// Show the same events in a small panel over the game. Off unless asked for.
- (void)showPanel:(BOOL)visible;

// Which device reported the event currently being delivered, and what kind of source
// it was. Read from inside the `onInput` block: it is set for the duration of the
// call, so a trigger can be remembered per controller. `currentDevice` is the
// identity; `currentDeviceName` is what to show a person.
@property (nonatomic, copy, readonly, nullable) NSString *currentDevice;
@property (nonatomic, copy, readonly, nullable) NSString *currentDeviceName;
@property (nonatomic, copy, readonly, nullable) NSString *currentSourceName;

// Whether a connected controller declares the Share element that iPadOS reserves.
@property (nonatomic, readonly) BOOL currentControllerDeclaresShare;

// Release the system's claim on one element of one controller, so its press reaches
// the app. Only ever called because the user mapped that element; the identity is
// remembered so the exact gesture can be given back.
- (BOOL)releaseSystemGestureForElement:(NSString *)element device:(nullable NSString *)device;
// Give it back, and forget that it was released.
- (void)restoreSystemGestureForElement:(NSString *)element device:(nullable NSString *)device;
// Give everything back: voice switched off, a mapping removed, or a pad gone.
- (void)restoreAllSystemGestures;

@end

NS_ASSUME_NONNULL_END
