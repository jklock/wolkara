// Wolkara: every input, in one stream, so a trigger never has to know where a
// press came from.
//
// Gamepad elements, keyboard keys, mouse clicks, touchpad touches and the system's
// own signals all arrive here as the same kind of event, each carrying a canonical
// element id from InputElement.h rather than display text.

#import <Foundation/Foundation.h>
#import "Trigger.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AKInputSource) {
    AKInputSourceController = 0,
    AKInputSourceKeyboard,
    AKInputSourceMouse,
    AKInputSourceTouchpad,
    // A press iPadOS kept for itself and told us about afterwards, such as the
    // screenshot a Share button produces.
    AKInputSourceSystem,
};

@interface AKInputEvent : NSObject
@property (nonatomic) AKInputSource source;
@property (nonatomic, copy) NSString *device;
@property (nonatomic, copy) NSString *element;
@property (nonatomic) double value;
@property (nonatomic) BOOL pressed;
// Seconds, monotonic.
@property (nonatomic) NSTimeInterval time;
@end

@interface AKInputRouter : NSObject

+ (instancetype)shared;

// Start watching. Safe to call more than once.
- (void)begin;

// Fired when a trigger is matched, once per activation. Toggle-style triggers
// use this one.
@property (nonatomic, copy, nullable) void (^onTrigger)(AKTrigger *trigger, AKInputEvent *event);
// Push-to-talk triggers use these two instead: the first on press, the second
// on release.
@property (nonatomic, copy, nullable) void (^onTriggerBegan)(AKTrigger *trigger, AKInputEvent *event);
@property (nonatomic, copy, nullable) void (^onTriggerEnded)(AKTrigger *trigger, AKInputEvent *event);

// Whether the guest must be kept from seeing this keyboard key. The adapter asks at the
// one place it posts key events to the guest, so a key the user has taken for dictation
// reaches the microphone and not the game. `usage` is what the adapter has: a
// UIKeyboardHIDUsage, which is the same number the inspector reports a keyboard key with.
// Answered here, not in the adapter, because the decision is the user's settings.
- (BOOL)shouldTakeKeyWithUsage:(unsigned short)usage;

// The device whose input should be remembered when learning finishes.
- (void)beginLearning;
// Disarm, without adopting anything. Learning takes the first event that arrives, so
// a mapper left armed quietly rewrites the user's mapping when they press anything
// at all later on - which is what a timed-out mapping used to do. Called on timeout,
// when the app goes to the background, and when a controller goes away.
- (void)cancelLearning;
@property (nonatomic, readonly) BOOL learning;
// Called after a learn press with the trigger that was adopted.
@property (nonatomic, copy, nullable) void (^onLearned)(AKTrigger *trigger, NSString *device);
// Posted when learning runs out of time without adopting anything, so the screen that
// armed it can say so. The arming itself expires here rather than in the screen: a
// screen that is gone cannot be relied on to clean up.
FOUNDATION_EXPORT NSNotificationName const AKInputRouterLearningDidExpireNotification;

// Re-reads what the user has mapped and makes the system agree with it: the reserved
// system gesture of a mapped element is released so its press reaches us, and every
// other gesture is given back. Called when a mapping or the voice setting changes and
// when a controller connects. With voice off, nothing is mapped and nothing may
// remain changed.
- (void)applyMappings;

// How long an armed mapping waits for a press before disarming itself. Twenty seconds
// is the product's answer; a test sets it to something it can wait for.
@property (nonatomic) NSTimeInterval learningTimeout;

// Report an event from a source this class does not own. The inspector calls
// this; so would any future source.
- (void)reportElement:(NSString *)element
                value:(double)value
              pressed:(BOOL)pressed
               device:(nullable NSString *)device
               source:(AKInputSource)source;

// The trigger in force for a device, choosing one if none was ever chosen.
- (AKTrigger *)triggerForDevice:(nullable NSString *)device;

@end

NS_ASSUME_NONNULL_END
