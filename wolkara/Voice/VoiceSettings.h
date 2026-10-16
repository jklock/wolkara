// Wolkara: the voice settings, where every part of the feature is decided.
//
// Modelled on Handy's, because it has already worked out what these options
// should be: hold to talk or tap to toggle, whether to send after inserting, a
// dictionary of words to recognise, and — our own addition — a mapping that can
// come from any button on any controller.

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

@property (nonatomic) AKVoiceMode mode;
// Send Return once the transcript has been typed in.
@property (nonatomic) BOOL autoSubmit;
// A space after the text, for a field that needs one.
@property (nonatomic) BOOL trailingSpace;
// Words the recogniser should expect: names, places, game terms. Handy calls
// this the dictionary; the SDK calls it contextualStrings.
@property (nonatomic, copy) NSArray<NSString *> *customWords;

// The trigger for a device, choosing one if none was ever chosen.
- (AKTrigger *)triggerForDevice:(nullable NSString *)device;
// Remember a learned trigger for the device it came from.
- (void)setTrigger:(AKTrigger *)trigger forDevice:(nullable NSString *)device;
// Adopt the element that was just pressed, using the pattern this mode needs.
- (void)setLearnedElement:(NSString *)element forDevice:(nullable NSString *)device;
// How the mapping reads in the launcher: "Button Share", "keycode 70", "not set".
- (NSString *)mappingSummaryForDevice:(nullable NSString *)device;

// Fired when anything above changes, so the launcher can redraw.
extern NSNotificationName const AKVoiceSettingsDidChangeNotification;

@end

NS_ASSUME_NONNULL_END
