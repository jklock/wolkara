// Wolkara: the one input stream, and the patterns a trigger can match on.

#import "InputRouter.h"

#import "../App/WolkaraLog.h"

// Both channels; see ControllerInspector.m for why.
#if __has_include("AKSupport.h")
#import "AKSupport.h"
#define AKIRLog(...) do { AKLog(__VA_ARGS__); WKLog("input", __VA_ARGS__); } while (0)
#else
#define AKIRLog(...) do { NSLog(@"[ak] %@", [NSString stringWithFormat:__VA_ARGS__]); WKLog("input", __VA_ARGS__); } while (0)
#endif

#import "../Controller/ControllerInspector.h"
#import "../Voice/VoiceSettings.h"
#import "InputElement.h"

NSNotificationName const AKInputRouterLearningDidExpireNotification = @"AKInputRouterLearningDidExpire";

// One queue for every piece of input state. Game Controller does not promise which
// thread its handlers arrive on, the long-press timers run on the main queue, and both
// touch the same dictionaries - so the inspector marshals every report onto the main
// queue and this asserts it rather than hoping. The audit's point: callbacks mutating
// state while timers run on main is a race waiting for the right load.
static void AKAssertInputQueue(void) {
    dispatch_assert_queue(dispatch_get_main_queue());
}

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
@property (nonatomic) BOOL down;
// Set after push-to-talk begins so its release ends it exactly once.
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
    // Every arming gets a number, so a deadline set for one arming cannot cancel a
    // later one that replaced it.
    NSUInteger _learningGeneration;
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
        _learningTimeout = 20.0;
    }
    return self;
}

- (BOOL)learning { return _learning; }

#pragma mark - Ownership

#pragma mark - Start

- (void)begin {
    AKAssertInputQueue();
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

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    // A mapping is armed by a screen and lives here. Everything that can make the
    // armed state wrong clears it: the app going away, a pad going away, and the
    // deadline below.
    [center addObserver:self selector:@selector(cancelLearning)
                   name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(padConnected:)
                   name:GCControllerDidConnectNotification object:nil];
    [center addObserver:self selector:@selector(padDisconnected:)
                   name:GCControllerDidDisconnectNotification object:nil];
    // Any change to what the user has chosen re-decides which system gestures are
    // ours to hold. This is the only place that decides it.
    [center addObserver:self selector:@selector(applyMappings)
                   name:AKVoiceSettingsDidChangeNotification object:nil];
    [self applyMappings];
    AKIRLog(@"input: router watching every source");
}

// A pad arriving means the stored mapping for it may now need its gesture released.
// It does NOT disarm the mapper: the user may be sitting there waiting to press a
// button on the pad that just connected, and cancelling then would make mapping
// impossible. Measured in the fixture on 2026-10-16, where a controller connects a
// moment after launch and the second mapping attempt was silently cancelled.
- (void)padConnected:(NSNotification *)notification {
    AKIRLog(@"input: %@", notification.name);
    [self applyMappings];
}

// A pad leaving does disarm it: the element that was being learned no longer exists.
- (void)padDisconnected:(NSNotification *)notification {
    AKIRLog(@"input: %@", notification.name);
    [self cancelLearning];
    [self applyMappings];
}

#pragma mark - Which system gestures are ours to hold

- (void)applyMappings {
    AKAssertInputQueue();
    AKControllerInspector *inspector = AKControllerInspector.shared;
    // Start from the system's own behaviour every time, then hand over only what the
    // user actually asked for. Any other order leaves a gesture released for a mapping
    // that no longer exists, or for a feature that is switched off.
    [inspector restoreAllSystemGestures];
    if (!AKVoiceSettings.shared.enabled) return;

    for (GCController *pad in GCController.controllers) {
        NSString *device = AKControllerIdentity(pad);
        [AKVoiceSettings.shared adoptLegacyMappingForDevice:device vendor:pad.vendorName];
        AKTrigger *trigger = [AKVoiceSettings.shared triggerForDevice:device];
        if (!trigger) continue;
        // Only a controller button can have a system gesture to give up. A keyboard
        // key or a mouse button needs nothing from us.
        if (![trigger.element hasPrefix:@"controller.button."]) continue;
        [inspector releaseSystemGestureForElement:trigger.element device:device];
    }

    // Two pads of the same model cannot be told apart by GameController, so one mapping
    // applies to both. That is a property of the platform, not a bug to fix quietly: say it
    // where someone will see it, because the alternative is a user wondering why the spare
    // pad starts dictation too.
    NSMutableDictionary<NSString *, NSNumber *> *models = [NSMutableDictionary dictionary];
    for (GCController *pad in GCController.controllers) {
        NSString *device = AKControllerIdentity(pad);
        models[device] = @([models[device] integerValue] + 1);
    }
    for (NSString *device in models) {
        if (models[device].integerValue < 2) continue;
        WKLog("input", @"%@ controllers of the same model are connected, so the mapping for %@",
              models[device], device);
        WKLog("input", @"applies to all of them: GameController does not identify individual pads");
        break;
    }
}

#pragma mark - Learning

// Long enough to find a button, short enough that a forgotten mapper is not left
// listening. The screen that armed it is told, so it can say so.
static NSTimeInterval const AKLearningTimeoutDefault = 20.0;

- (void)beginLearning {
    AKAssertInputQueue();
    _learning = YES;
    _learningDevice = nil;
    _learningGeneration++;
    NSUInteger generation = _learningGeneration;
    NSTimeInterval timeout = _learningTimeout > 0 ? _learningTimeout : AKLearningTimeoutDefault;
    AKIRLog(@"input: learning — press the button you want to use");
    __weak AKInputRouter *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AKInputRouter *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_learningGeneration != generation) return;
        if (!strongSelf->_learning) return;
        [strongSelf cancelLearning];
        [NSNotificationCenter.defaultCenter postNotificationName:AKInputRouterLearningDidExpireNotification
                                                         object:strongSelf];
    });
}

- (void)cancelLearning {
    AKAssertInputQueue();
    if (!_learning) return;
    _learning = NO;
    _learningDevice = nil;
    // Bumped so the outstanding deadline cannot fire against a later arming.
    _learningGeneration++;
    AKIRLog(@"input: learning cancelled; nothing was saved");
}

#pragma mark - The one entry point for every source

- (void)reportElement:(NSString *)element
                value:(double)value
              pressed:(BOOL)pressed
               device:(nullable NSString *)device
               source:(AKInputSource)source {
    AKAssertInputQueue();
    if (!element.length) return;

    AKInputEvent *event = [AKInputEvent new];
    event.source = source;
    event.device = device.length ? device : @"?";
    event.element = element;
    event.value = value;
    event.pressed = pressed;
    event.time = NSProcessInfo.processInfo.systemUptime;

    if (_learning && pressed) {
        // Whatever arrives first is what the user wants. This is how any button on any
        // controller becomes usable without a line of per-device code.
        AKTrigger *learned = [AKTrigger new];
        learned.element = element;
        // Only a placeholder: the pattern belongs to the mode, and the settings decide
        // it when they store this. The router does not write anything itself, so there
        // is one owner of what is remembered.
        learned.pattern = AKTriggerPatternPress;
        _learning = NO;
        _learningDevice = event.device;
        // The deadline that was armed for this mapping has nothing left to do.
        _learningGeneration++;
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
    if (state.down) return; // Repeated samples are not another physical press.
    state.down = YES;
    [_down addObject:key];

    AKTrigger *trigger = [self triggerForDevice:event.device];
    // Nothing mapped, or the feature is off: the event is still tracked, so a release
    // still clears it, but nothing fires.
    if (!trigger) return;
    if (![trigger watchesElement:element]) return;

    switch (trigger.pattern) {
        case AKTriggerPatternPress:
            [self fire:trigger event:event];
            break;

        case AKTriggerPatternPushToTalk:
            // Press starts it; the release below finishes it. Marked as consumed
            // so the pair cannot overlap.
            if (state.consumed) return;
            state.consumed = YES;
            AKIRLog(@"input: trigger %@ began from %@", [trigger summary], event);
            if (self.onTriggerBegan) self.onTriggerBegan(trigger, event);
            break;


    }
}

- (void)handleRelease:(AKInputEvent *)event element:(NSString *)element key:(NSString *)key state:(AKInputElementState *)state {
    AKTrigger *trigger = [self triggerForDevice:event.device];
    if (state.consumed && trigger && trigger.pattern == AKTriggerPatternPushToTalk &&
        [trigger watchesElement:element]) {
        AKIRLog(@"input: trigger %@ ended from %@", [trigger summary], event);
        if (self.onTriggerEnded) self.onTriggerEnded(trigger, event);
    }
    state.down = NO;
    state.consumed = NO;
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
