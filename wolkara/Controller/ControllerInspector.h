// Wolkara layer: what a controller reports to us, and every change to it.
//
// Diagnostic only. This reads: it attaches observers to the pads, keyboards and
// pointing devices the system reports, names everything it finds, and logs every
// change as it happens. It never consumes an input and never writes to a pad, so
// the game receives exactly what it would have received anyway.
//
// Output goes to the platform's own log channel, so it lands in
// Documents/native-guest.log and can be read from a Mac without root.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AKControllerInspector : NSObject

+ (instancetype)shared;

// Start watching: the pads connected now, and any that connect later. Also the
// keyboards and mice the system reports. Safe to call more than once.
- (void)begin;

// The identical stream the log carries, for a caller that wants to act on it —
// a dictation trigger, later. `element` is the name the system uses (for example
// "Button Share", "Left Thumbstick", "dpad.up"); `pressed` distinguishes an edge
// from a value change.
@property (nonatomic, copy, nullable) void (^onInput)(NSString *element, double value, BOOL pressed);

// Log the identity and full element list of everything connected right now.
// This is the call that answers "what does this pad actually have?".
- (void)logInventories;

// Show the same events in a small panel over the game. Off unless asked for.
- (void)showPanel:(BOOL)visible;

// Which device and kind of source reported the event currently being delivered.
// Read from inside the `onInput` block: it is set for the duration of the call,
// so a trigger can be remembered per controller.
@property (nonatomic, copy, readonly, nullable) NSString *currentDevice;
@property (nonatomic, copy, readonly, nullable) NSString *currentSourceName;

// Whether a connected controller declares the Share element that iPadOS
// reserves. If one does, its gesture is released and the press lands with us.
@property (nonatomic, readonly) BOOL currentControllerDeclaresShare;

@end

NS_ASSUME_NONNULL_END
