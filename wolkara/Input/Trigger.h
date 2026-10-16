// Wolkara: what to watch for, on any controller.
//
// A trigger names an *element* and a *pattern*. The element is a canonical id from
// InputElement.h, never display text: "controller.button.share", "keyboard.key.36",
// "system.screenshot". The pattern exists because a game that binds single presses
// cannot be using a long press, a double press or a chord - but see the note below
// about what is actually offered.
//
// There is deliberately no default trigger and no fallback. The 2026-10-16 audit was
// right that a feature which starts listening because an unrelated screenshot was
// taken is a privacy failure, so a trigger exists only once the user has made one,
// and voice does nothing at all until they have.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AKTriggerPattern) {
    // One press and release.
    AKTriggerPatternPress = 0,
    // Two presses inside the double window.
    AKTriggerPatternDouble,
    // Held past the hold threshold.
    AKTriggerPatternLong,
    // Two elements held together.
    AKTriggerPatternChord,
    // Push to talk: fires on press and again on release, so dictation can start on
    // the first and finish on the second. It needs a button whose press and release
    // we both receive, so it cannot be used on one iOS keeps for itself.
    AKTriggerPatternPushToTalk,
};

// Matches any element name at all. Useful while learning; never stored.
extern NSString *const AKTriggerAnyElement;

@interface AKTrigger : NSObject <NSCopying>

@property (nonatomic, copy) NSString *element;
// The partner element for a chord, and ignored otherwise.
@property (nonatomic, copy, nullable) NSString *chordElement;
@property (nonatomic) AKTriggerPattern pattern;
// How long "long" means, and how close together a double must be. Both in seconds.
@property (nonatomic) NSTimeInterval holdInterval;
@property (nonatomic) NSTimeInterval doubleInterval;

// Readable text for the log and the settings screen, built from the element's
// display name rather than from the id.
- (NSString *)summary;
// "press", "hold to talk", "double press", "long press", "chord". Only press and
// push-to-talk are offered by the launcher; the rest are reachable by a stored
// mapping and are covered by tests, but nothing in the UI pretends they are safe.
- (NSString *)patternName;
- (BOOL)patternIsOfferedInTheLauncher;
// Whether this trigger watches the given element id. Exact, "any", or a family:
// a trigger on "controller.button." covers every button.
- (BOOL)watchesElement:(NSString *)element;

#pragma mark - Storage

// A stored dictionary is validated before any of it is used: one bad value must not
// half-apply. Returns nil for anything that is not a usable trigger.
+ (nullable NSDictionary *)validatedStoredForm:(nullable NSDictionary *)stored;
- (NSDictionary *)storedForm;
+ (nullable instancetype)triggerFromStored:(nullable NSDictionary *)stored;

#pragma mark - Remembering a choice, per controller

// The key is the controller's *model* identity - vendor and category - because that is the
// finest thing GameController offers. Two identical pads share one mapping; that is stated
// here rather than papered over with a per-device claim the platform cannot support.
+ (NSString *)defaultsKeyForDevice:(nullable NSString *)device;
// The mapping for a controller, or nil when there is none. A mapping an older build
// wrote under the vendor name alone is moved onto the identity first, by
// -[AKVoiceSettings adoptLegacyMappingForDevice:vendor:], not guessed at here.
+ (nullable instancetype)savedTriggerForDevice:(nullable NSString *)device defaults:(NSUserDefaults *)defaults;
- (void)saveForDevice:(nullable NSString *)device defaults:(NSUserDefaults *)defaults;
+ (void)forgetTriggerForDevice:(nullable NSString *)device defaults:(NSUserDefaults *)defaults;

// The key older builds used, for the one-time move onto a controller's identity.
+ (NSString *)legacyDefaultsKeyForVendor:(nullable NSString *)vendor;

// Rewrites every stored mapping to canonical element ids, once, and returns how many
// it changed. Called at startup so an existing user's button keeps working.
+ (NSUInteger)migrateStoredTriggersInDefaults:(NSUserDefaults *)defaults;

@end

NS_ASSUME_NONNULL_END
