// Wolkara: every input, in one stream, so a trigger never has to know where a
// press came from.
//
// Gamepad elements, keyboard keys, mouse clicks, touchpad touches and the
// system's own signals (the screenshot and screen-capture notifications that
// buttons iOS reserves produce) all arrive here as the same kind of event.

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

// The device whose input should be remembered when learning finishes.
- (void)beginLearning;
@property (nonatomic, readonly) BOOL learning;
// Called after a learn press with the trigger that was adopted.
@property (nonatomic, copy, nullable) void (^onLearned)(AKTrigger *trigger, NSString *device);

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
