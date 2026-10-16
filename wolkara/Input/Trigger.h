// Wolkara: what to watch for, on any controller.
//
// A trigger is deliberately not "the Share button". Controllers differ: some
// declare Share, some declare paddles, some declare nothing but a d-pad, and one
// we measured declares 34 elements and no Share at all. So a trigger names an
// element — or a family of elements — and a *pattern*, because a game can own
// every single press of a button and still leave every long press, double press
// and chord free.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AKTriggerPattern) {
    // One press and release.
    AKTriggerPatternPress = 0,
    // Two presses inside the double window.
    AKTriggerPatternDouble,
    // Held past the hold threshold: free on a controller whose every tap the
    // game already uses.
    AKTriggerPatternLong,
    // Two elements held together, which a game that binds single presses cannot
    // have claimed.
    AKTriggerPatternChord,
    // Push to talk: fires on press and again on release, so dictation can start
    // on the first and finish on the second. It needs a button whose press and
    // release we both receive, so it cannot be used on one iOS keeps for itself.
    AKTriggerPatternPushToTalk,
};

@interface AKTrigger : NSObject <NSCopying>

// The element to watch: an exact name the system uses ("Button Share"), or a
// family prefix ("Button "), or AKTriggerAnyElement for anything at all.
@property (nonatomic, copy) NSString *element;
// The partner element for a chord, and ignored otherwise.
@property (nonatomic, copy, nullable) NSString *chordElement;
@property (nonatomic) AKTriggerPattern pattern;
// How long "long" means, and how close together a double must be. Both in
// seconds.
@property (nonatomic) NSTimeInterval holdInterval;
@property (nonatomic) NSTimeInterval doubleInterval;

// Matches any element name at all. A starting point for learning: the user
// presses what they want, and the name that arrives becomes the trigger.
extern NSString *const AKTriggerAnyElement;

// The default for hardware that offers nothing reserved: an element the user
// picks, or this if they never pick. A long press leaves the game's own single
// press untouched.
+ (instancetype)defaultTriggerForController:(nullable NSString *)vendor;
// The trigger to use when a controller declares a system-reserved button.
+ (instancetype)systemButtonTrigger;
// A description for the log, never shown inside the game.
- (NSString *)summary;
// Whether this trigger watches the given element name at all.
- (BOOL)watchesElement:(NSString *)element;

// A choice is remembered per controller, so the same pad behaves the same way
// next time and a different pad is unaffected.
+ (nullable instancetype)savedTriggerForVendor:(nullable NSString *)vendor defaults:(NSUserDefaults *)defaults;
- (void)saveForVendor:(nullable NSString *)vendor defaults:(NSUserDefaults *)defaults;

@end

NS_ASSUME_NONNULL_END
