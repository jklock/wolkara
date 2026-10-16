// Wolkara: the voice settings, where every part of the feature is decided.
//
// Modelled on Handy's, because it has already worked out what these options should
// be: hold to talk or tap to toggle, whether to send after inserting, a dictionary of
// words to recognise, and - our own addition - a mapping that can come from any
// button on any controller.
//
// Two rules come straight out of the 2026-10-16 audit and are the reason this class
// looks the way it does:
//
//   1. **Off until asked for.** `enabled` is NO until the user turns it on, and there
//      is no default trigger and no fallback. Nothing listens, nothing is mapped, and
//      no system gesture is held, until a person has said so.
//   2. **The mode owns the pattern.** A mapping stores which *element* the user chose;
//      whether that means hold-to-talk or press-to-toggle is the mode, read at the
//      time. Storing the pattern as well let the two disagree after a mode change.

#import <Foundation/Foundation.h>
#import "Trigger.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AKVoiceMode) {
    // Hold the button to talk, release to finish. Handy's default.
    AKVoiceModeHold = 0,
    // Press once to start, once more to stop.
    AKVoiceModeToggle,
};

@interface AKVoiceSettings : NSObject

+ (instancetype)shared;

// The whole feature, on or off. Off means: no trigger fires, nothing is mapped, and
// the system keeps its own gestures. Default NO.
@property (nonatomic) BOOL enabled;

@property (nonatomic) AKVoiceMode mode;
// Send Return once the transcript has been typed in.
@property (nonatomic) BOOL autoSubmit;
// A space after the text, for a field that needs one.
@property (nonatomic) BOOL trailingSpace;
// Words the recogniser should expect: names, places, game terms. Handy calls this the
// dictionary; the SDK calls it contextualStrings.
@property (nonatomic, copy) NSArray<NSString *> *customWords;

// The mapping for a device, or nil when there is none - which is the normal state
// until the user makes one. Never invents a trigger.
- (nullable AKTrigger *)triggerForDevice:(nullable NSString *)device;
// Remember a learned trigger for the device it came from.
- (void)setTrigger:(AKTrigger *)trigger forDevice:(nullable NSString *)device;
// Adopt the element that was just pressed, using the pattern this mode needs.
- (void)setLearnedElement:(NSString *)element forDevice:(nullable NSString *)device;
// Remove a mapping, so the device fires nothing at all.
- (void)clearMappingForDevice:(nullable NSString *)device;

// Moves a mapping made by an older build - keyed by the vendor name alone - onto the
// controller's own identity, once, the first time that controller is seen. Returns
// YES if it moved one.
- (BOOL)adoptLegacyMappingForDevice:(NSString *)device vendor:(nullable NSString *)vendor;

// How the mapping reads in the launcher: "Share (screenshot) (hold to talk)",
// "Key 70 (press)", "Not set".
- (NSString *)mappingSummaryForDevice:(nullable NSString *)device;

// Fired when anything above changes, so the launcher can redraw and the input router
// can re-decide which system gestures are ours to hold.
extern NSNotificationName const AKVoiceSettingsDidChangeNotification;

@end

NS_ASSUME_NONNULL_END
