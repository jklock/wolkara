// Wolkara: the one input stream, and the patterns a trigger can match on.

#import "InputRouter.h"

#if __has_include("AKSupport.h")
#import "AKSupport.h"
#define AKIRLog(...) AKLog(__VA_ARGS__)
#else
#define AKIRLog(...) NSLog(@"[ak] %@", [NSString stringWithFormat:__VA_ARGS__])
#endif

#import "../Controller/ControllerInspector.h"
#import "../Voice/VoiceSettings.h"

static AKInputSource AKInputSourceFromName(NSString *name) {
    if ([name isEqualToString:@"keyboard"]) return AKInputSourceKeyboard;
    if ([name isEqualToString:@"mouse"]) return AKInputSourceMouse;
    if ([name isEqualToString:@"touchpad"]) return AKInputSourceTouchpad;
    if ([name isEqualToString:@"system"]) return AKInputSourceSystem;
    return AKInputSourceController;
}

@implementation AKInputEvent
- (NSString *)description {
    return [NSString stringWithFormat:@"%@/%@ %@=%.2f", self.device, self.element,
            self.pressed ? @"pressed" : @"released", self.value];
}
@end

// Per element state, so patterns can be measured rather than guessed.
@interface AKInputElementState : NSObject
@property (nonatomic) NSTimeInterval lastPress;
@property (nonatomic) NSTimeInterval pressedSince;
@property (nonatomic) BOOL down;
// Set when this element's press is the first half of a chord that already fired,
// so it cannot fire again until it is released.
@property (nonatomic) BOOL consumed;
@end
@implementation AKInputElementState
@end

@implementation AKInputRouter {
    NSMutableDictionary<NSString *, AKInputElementState *> *_states;  // "device|element"
    NSMutableSet<NSString *> *_down;                                  // "device|element", for chords
    BOOL _began;
    BOOL _learning;
    NSString *_learningDevice;
}

+ (instancetype)shared {
    static AKInputRouter *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [AKInputRouter new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _states = [NSMutableDictionary dictionary];
        _down = [NSMutableSet set];
    }
    return self;
}

- (BOOL)learning { return _learning; }

#pragma mark - Start

- (void)begin {
    if (_began) return;
    _began = YES;

    __weak AKInputRouter *weakSelf = self;
    // The inspector already watches every element of every connected controller,
    // the keyboard and the mouse, and reports the system's Share signals. It is
    // the source this router does not have to duplicate.
    AKControllerInspector.shared.onInput = ^(NSString *element, double value, BOOL pressed) {
        AKControllerInspector *inspector = AKControllerInspector.shared;
        [weakSelf reportElement:element value:value pressed:pressed
                         device:inspector.currentDevice
                         source:AKInputSourceFromName(inspector.currentSourceName)];
    };
    [AKControllerInspector.shared begin];
    AKIRLog(@"input: router watching every source");
}

#pragma mark - Learning

- (void)beginLearning {
    _learning = YES;
    _learningDevice = nil;
    AKIRLog(@"input: learning — press the button you want to use");
}

#pragma mark - The one entry point for every source

- (void)reportElement:(NSString *)element
                value:(double)value
              pressed:(BOOL)pressed
               device:(nullable NSString *)device
               source:(AKInputSource)source {
    if (!element.length) return;

    AKInputEvent *event = [AKInputEvent new];
    event.source = source;
    event.device = device.length ? device : @"?";
    event.element = element;
    event.value = value;
    event.pressed = pressed;
    event.time = NSProcessInfo.processInfo.systemUptime;

    if (_learning && pressed) {
        // Whatever arrives first is what the user wants. This is how any button
        // on any controller becomes usable without a line of per-device code.
        AKTrigger *learned = [AKTrigger new];
        learned.element = element;
        learned.pattern = AKTriggerPatternPress;
        _learning = NO;
        _learningDevice = event.device;
        [learned saveForVendor:event.device defaults:NSUserDefaults.standardUserDefaults];
        AKIRLog(@"input: learned %@ on %@", element, event.device);
        if (self.onLearned) self.onLearned(learned, event.device);
        return;
    }

    NSString *key = [NSString stringWithFormat:@"%@|%@", event.device, element];
    AKInputElementState *state = _states[key];
    if (!state) { state = [AKInputElementState new]; _states[key] = state; }

    if (pressed) { [self handlePress:event element:element key:key state:state]; }
    else { [self handleRelease:event element:element key:key state:state]; }
}

#pragma mark - Patterns

- (void)handlePress:(AKInputEvent *)event element:(NSString *)element key:(NSString *)key state:(AKInputElementState *)state {
    state.down = YES;
    state.pressedSince = event.time;
    [_down addObject:key];

    AKTrigger *trigger = [self triggerForDevice:event.device];
    if (![trigger watchesElement:element]) return;

    switch (trigger.pattern) {
        case AKTriggerPatternPress:
            [self fire:trigger event:event];
            break;

        case AKTriggerPatternDouble:
            if (state.lastPress && event.time - state.lastPress <= trigger.doubleInterval) {
                state.lastPress = 0;
                [self fire:trigger event:event];
            } else {
                state.lastPress = event.time;
            }
            break;

        case AKTriggerPatternLong: {
            // Fires only if it is still held when the interval is up, so a tap
            // the game owns is untouched.
            if (state.consumed) return;
            NSTimeInterval deadline = trigger.holdInterval;
            NSString *device = event.device;
            __weak AKInputRouter *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AKInputRouter *strongSelf = weakSelf;
                if (!strongSelf) return;
                AKInputElementState *now = strongSelf->_states[key];
                if (now.down && now.pressedSince == state.pressedSince) {
                    now.consumed = YES;
                    [strongSelf fire:trigger event:event];
                }
            });
            (void)device;
            break;
        }

        case AKTriggerPatternPushToTalk:
            // Press starts it; the release below finishes it. Marked as consumed
            // so the pair cannot overlap.
            if (state.consumed) return;
            state.consumed = YES;
            AKIRLog(@"input: trigger %@ began from %@", [trigger summary], event);
            if (self.onTriggerBegan) self.onTriggerBegan(trigger, event);
            break;

        case AKTriggerPatternChord: {
            if (!trigger.chordElement.length) return;
            NSString *partner = [NSString stringWithFormat:@"%@|%@", event.device, trigger.chordElement];
            if ([_down containsObject:partner]) {
                AKTrigger *copy = [trigger copy];
                [self fire:copy event:event];
            }
            break;
        }
    }
}

- (void)handleRelease:(AKInputEvent *)event element:(NSString *)element key:(NSString *)key state:(AKInputElementState *)state {
    AKTrigger *trigger = [self triggerForDevice:event.device];
    if (state.consumed && trigger.pattern == AKTriggerPatternPushToTalk &&
        [trigger watchesElement:element]) {
        AKIRLog(@"input: trigger %@ ended from %@", [trigger summary], event);
        if (self.onTriggerEnded) self.onTriggerEnded(trigger, event);
    }
    state.down = NO;
    state.consumed = NO;
    state.pressedSince = 0;
    [_down removeObject:key];
}

- (void)fire:(AKTrigger *)trigger event:(AKInputEvent *)event {
    AKIRLog(@"input: trigger %@ from %@", [trigger summary], event);
    if (self.onTrigger) self.onTrigger(trigger, event);
}

#pragma mark - Which trigger applies

- (AKTrigger *)triggerForDevice:(nullable NSString *)device {
    // The choice, and what happens before one is made, both belong to the voice
    // settings: they are what the user edits in the launcher.
    return [AKVoiceSettings.shared triggerForDevice:device];
}

@end
