// Wolkara layer: the controller inspector, in full.
//
// Why this exists: two buttons on the pad do nothing in this app — Share, and
// the extra top button — and we cannot tell whether the pad never sends them,
// whether iPadOS takes them for itself, or whether the game ignores them. Every
// decision we plan on top of pad input depends on which, so this reports what
// the pad has and what it does, rather than guessing.
//
// It reads. It never consumes an input, never writes to a pad, and changes
// nothing about how input reaches the game — with one deliberate exception:
// while this is active it clears the system's reservation on Share, because a
// reserved button cannot be observed at all. That is logged when it happens.

#import "ControllerInspector.h"

#import "../App/WolkaraLog.h"

// Both channels: the platform's line, which is what a console run and a guest run
// show, and the layer's file, which is what is left afterwards. What the pad
// actually reports is the whole subject of this file, so it belongs in the file that
// is still readable a minute later.
#if __has_include("AKSupport.h")
#import "AKSupport.h"
#define AKCILog(...) do { AKLog(__VA_ARGS__); WKLog("input", __VA_ARGS__); } while (0)
#else
#define AKCILog(...) do { NSLog(@"[ak] %@", [NSString stringWithFormat:__VA_ARGS__]); WKLog("input", __VA_ARGS__); } while (0)
#endif

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#import "../Input/InputElement.h"

// How many events the on-screen panel keeps. The log itself is not limited.
static NSUInteger const AKCIHistoryLimit = 12;

// Stick axes stream continuously; without a threshold the log becomes unreadable
// and the game pays for it. Values are logged when they cross into a different
// half-unit, so a stick reads as -2, -1, 0, 1, 2 rather than a river of floats.
static double const AKCIAxisBucket = 2.0;

// The model, not the device: see the header. GameController has no serial number to key a
// per-device map on, so this is the finest identity available and the docs say so.
NSString *AKControllerIdentity(GCController *pad) {
    if (!pad) return @"unknown";
    return [NSString stringWithFormat:@"%@.%@",
            AKInputIdentifierSlug(pad.vendorName ?: @"controller"),
            AKInputIdentifierSlug(pad.productCategory ?: @"unknown")];
}

// The two methods the queue helpers below call. Declared here because the helpers are
// defined before the implementation, and a category on somebody else's class is the wrong
// tool for a private method.
@interface AKControllerInspector ()
- (void)markDevice:(NSString *)device name:(NSString *)name source:(NSString *)source;
- (void)noteElement:(NSString *)element value:(double)value pressed:(BOOL)pressed detail:(nullable NSString *)detail;
- (void)noteAxis:(NSString *)element value:(double)value;
@end

// Every report is delivered on the main queue, whatever thread the system called the
// handler on. This is what makes the router's state single-threaded by construction
// rather than by assumption: the audit's point was that input callbacks mutate mutable
// state while the long-press timers run on main, so one of the two had to move. Game
// Controller does not promise which thread its handlers arrive on, and the timers cannot
// be anywhere else, so the reports move.
static void AKCIReport(AKControllerInspector *inspector, NSString *device, NSString *name,
                       NSString *source, NSString *element, double value, BOOL pressed,
                       NSString *detail) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [inspector markDevice:device name:name source:source];
        [inspector noteElement:element value:value pressed:pressed detail:detail];
    });
}

static void AKCIReportAxis(AKControllerInspector *inspector, NSString *device, NSString *name,
                           NSString *source, NSString *element, double value) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [inspector markDevice:device name:name source:source];
        [inspector noteAxis:element value:value];
    });
}

@implementation AKControllerInspector {
    NSMutableArray<NSString *> *_history;
    NSMutableDictionary<NSString *, NSNumber *> *_axisBuckets;
    // Element ids whose system gesture this app has released, per device identity, so
    // the exact gesture can be handed back rather than guessed at.
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *_releasedGestures;
    UILabel *_panel;
    BOOL _began;
    NSString *_currentDevice;
    NSString *_currentDeviceName;
    NSString *_currentSourceName;
}

- (NSString *)currentDevice { return _currentDevice; }
- (NSString *)currentDeviceName { return _currentDeviceName; }
- (NSString *)currentSourceName { return _currentSourceName; }

- (BOOL)currentControllerDeclaresShare {
    for (GCController *pad in GCController.controllers)
        if (pad.physicalInputProfile.buttons[GCInputButtonShare]) return YES;
    return NO;
}

+ (instancetype)shared {
    static AKControllerInspector *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [AKControllerInspector new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _history = [NSMutableArray array];
        _axisBuckets = [NSMutableDictionary dictionary];
        _releasedGestures = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Start

- (void)begin {
    if (_began) { [self logInventories]; return; }
    _began = YES;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(padsChanged:) name:GCControllerDidConnectNotification object:nil];
    [center addObserver:self selector:@selector(padsChanged:) name:GCControllerDidDisconnectNotification object:nil];
    if (@available(iOS 14.0, *)) {
        [center addObserver:self selector:@selector(padsChanged:) name:GCKeyboardDidConnectNotification object:nil];
        [center addObserver:self selector:@selector(padsChanged:) name:GCKeyboardDidDisconnectNotification object:nil];
        [center addObserver:self selector:@selector(padsChanged:) name:GCMouseDidConnectNotification object:nil];
        [center addObserver:self selector:@selector(padsChanged:) name:GCMouseDidDisconnectNotification object:nil];
    }

    AKCILog(@"inspector: watching for controller input");

    // The pad's Share button is a Print Screen key, and iPadOS spends that key on
    // the screenshot gesture before any app is offered it. The screenshot itself
    // is announced to the app, though, so Share is reachable after all: this is
    // the only route to it that the system provides.
    [center addObserver:self selector:@selector(screenshotTaken:) name:UIApplicationUserDidTakeScreenshotNotification object:nil];
    // And the hold gesture, which the system spends on screen recording.
    [center addObserver:self selector:@selector(screenCaptureChanged:) name:UIScreenCapturedDidChangeNotification object:nil];
    [self attachEverything];
    [self logInventories];
}

- (void)screenshotTaken:(NSNotification *)notification {
    (void)notification;
    // The pad's Share button is a Print Screen key, and iPadOS spends that key on the
    // screenshot gesture before any app is offered it - so a screenshot is as close to
    // "the pad's Share was pressed" as the system gets.
    //
    // It is recorded and **not** reported as input. The first version offered it as
    // `system.screenshot` for the user to map, and the remediation review is right that
    // this is not enough: nothing in the notification says whether a pad or a thumb on
    // the screen produced it, so mapping it only moves the guess to the user. A button
    // that can start the microphone has to be one we know was pressed.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self markSystemDevice];
        [self recordLine:@"system.screenshot (recorded; not an input)"];
    });
}

- (void)screenCaptureChanged:(NSNotification *)notification {
    (void)notification;
    BOOL captured = UIScreen.mainScreen.isCaptured;
    [self markSystemDevice];
    AKCILog(@"inspector: screen capture changed, captured=%d", captured);
    // Recorded, never reported as input.
    //
    // This used to go through reportLine: as "Share held", on the reasoning that
    // iPadOS spends the pad's Share hold on screen recording, so seeing a capture
    // start meant Share was held. That is only true when the pad started it, and this
    // notification cannot tell us who did. Measured on 2026-10-16: with the iPad being
    // captured from a Mac, `isCaptured` was already 1, the change fired about a tenth
    // of a second after every launch, and the launcher started dictating by itself -
    // six times in one log, with nobody touching anything.
    [self recordLine:captured ? @"system.capture on" : @"system.capture off"];
}

// A system signal belongs to no controller, but it is still attributed to the pad
// when there is one, so a per-controller choice applies to it.
- (void)markSystemDevice {
    GCController *pad = GCController.controllers.firstObject;
    [self markDevice:pad ? AKControllerIdentity(pad) : @"system"
                name:pad.vendorName ?: @"System"
              source:@"system"];
}

- (void)padsChanged:(NSNotification *)notification {
    AKCILog(@"inspector: %@", notification.name);
    if ([notification.name isEqualToString:GCControllerDidDisconnectNotification]) {
        // A released gesture belongs to a connection, not to a pad forever. Forget it
        // so a reconnect starts from the system's own behaviour, and so the router
        // re-decides from the stored mapping rather than from stale state.
        GCController *pad = notification.object;
        NSString *identity = pad ? AKControllerIdentity(pad) : nil;
        if (identity) [_releasedGestures removeObjectForKey:identity];
        else [_releasedGestures removeAllObjects];
    }
    [self attachEverything];
    [self logInventories];
}

#pragma mark - The system's gestures, released only on request

- (nullable GCControllerButtonInput *)buttonForElement:(NSString *)element device:(nullable NSString *)device inPad:(GCController *)pad {
    if (device.length && ![AKControllerIdentity(pad) isEqualToString:device]) return nil;
    for (NSString *name in pad.physicalInputProfile.buttons)
        if ([AKInputElementForControllerButton(name) isEqualToString:element])
            return pad.physicalInputProfile.buttons[name];
    return nil;
}

- (BOOL)releaseSystemGestureForElement:(NSString *)element device:(nullable NSString *)device {
    BOOL released = NO;
    for (GCController *pad in GCController.controllers) {
        GCControllerButtonInput *button = [self buttonForElement:element device:device inPad:pad];
        if (!button) continue;
        if (button.preferredSystemGestureState != GCSystemGestureStateDisabled) {
            button.preferredSystemGestureState = GCSystemGestureStateDisabled;
            AKCILog(@"inspector: released the system gesture on %@ for %@, because the user mapped it", element, AKControllerIdentity(pad));
        }
        NSString *identity = AKControllerIdentity(pad);
        if (!_releasedGestures[identity]) _releasedGestures[identity] = [NSMutableSet set];
        [_releasedGestures[identity] addObject:element];
        released = YES;
    }
    return released;
}

- (void)restoreSystemGestureForElement:(NSString *)element device:(nullable NSString *)device {
    for (GCController *pad in GCController.controllers) {
        NSString *identity = AKControllerIdentity(pad);
        if (device.length && ![identity isEqualToString:device]) continue;
        if (![_releasedGestures[identity] containsObject:element]) continue;
        GCControllerButtonInput *button = [self buttonForElement:element device:identity inPad:pad];
        // Back to what the system had, which is "the gesture is mine".
        if (button.preferredSystemGestureState == GCSystemGestureStateDisabled)
            button.preferredSystemGestureState = GCSystemGestureStateEnabled;
        [_releasedGestures[identity] removeObject:element];
        AKCILog(@"inspector: gave the system its gesture back on %@ for %@", element, identity);
    }
}

- (void)restoreAllSystemGestures {
    for (GCController *pad in GCController.controllers) {
        NSString *identity = AKControllerIdentity(pad);
        for (NSString *element in [_releasedGestures[identity] allObjects]) {
            GCControllerButtonInput *button = [self buttonForElement:element device:identity inPad:pad];
            if (button.preferredSystemGestureState == GCSystemGestureStateDisabled)
                button.preferredSystemGestureState = GCSystemGestureStateEnabled;
        }
    }
    NSUInteger count = _releasedGestures.count;
    [_releasedGestures removeAllObjects];
    if (count) AKCILog(@"inspector: every released system gesture has been given back");
}

#pragma mark - Inventories: what does this pad actually have?

- (void)logInventories {
    NSArray<GCController *> *pads = GCController.controllers;
    AKCILog(@"inspector: %lu controller(s) connected", (unsigned long)pads.count);
    for (GCController *pad in pads) [self describe:pad];

    if (@available(iOS 14.0, *)) {
        // The SDK coalesces every connected keyboard into one object, and
        // reports the current pointing device the same way.
        GCKeyboard *keyboard = GCKeyboard.coalescedKeyboard;
        GCMouse *mouse = GCMouse.current;
        AKCILog(@"inspector: keyboard=%@ mouse=%@",
                keyboard ? (keyboard.vendorName ?: @"present") : @"none",
                mouse ? (mouse.vendorName ?: @"present") : @"none");
        // Which keys does the system say this keyboard has? A GameSir pad sends
        // its Share button as a Print Screen key, so this is where we find out
        // whether that key exists to us at all, before anyone presses it.
        if (keyboard) {
            GCKeyboardInput *input = keyboard.keyboardInput;
            NSArray<NSString *> *names = [input.buttons.allKeys sortedArrayUsingSelector:@selector(compare:)];
            NSArray<NSString *> *printScreen = [names filteredArrayUsingPredicate:
                [NSPredicate predicateWithFormat:@"SELF CONTAINS[c] 'print'"]];
            AKCILog(@"inspector: keyboard keys=%lu printScreen=%@",
                    (unsigned long)names.count,
                    printScreen.count ? [printScreen componentsJoinedByString:@","] : @"absent");
            AKCILog(@"inspector: keyboard key names=%@", [names componentsJoinedByString:@" | "]);
            // Attach to the object we just enumerated, not to whichever one
            // existed when we started: the coalesced keyboard is replaced when a
            // keyboard comes or goes, and a handler left on the old object would
            // make every press look like silence.
            [self attachKeyboard:keyboard];
        }
    }
    AKCILog(@"inspector: watching controller, keyboard, screenshot and capture");
}

- (void)describe:(GCController *)pad {
    GCPhysicalInputProfile *profile = pad.physicalInputProfile;
    AKCILog(@"inspector: pad name=%@ vendor=%@ category=%@ profile=%@",
            pad.vendorName ?: @"?", pad.vendorName ?: @"?", pad.productCategory ?: @"?", NSStringFromClass(profile.class));

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *name in profile.buttons) {
        GCControllerButtonInput *button = profile.buttons[name];
        [lines addObject:[NSString stringWithFormat:@"button %@%@", name, button.isAnalog ? @" [analog]" : @""]];
    }
    for (NSString *name in profile.axes) {
        [lines addObject:[NSString stringWithFormat:@"axis %@", name]];
    }
    for (NSString *name in profile.dpads) {
        [lines addObject:[NSString stringWithFormat:@"dpad %@", name]];
    }
    for (NSString *name in profile.touchpads) {
        [lines addObject:[NSString stringWithFormat:@"touchpad %@", name]];
    }
    AKCILog(@"inspector: elements (%lu): %@", (unsigned long)lines.count, [lines componentsJoinedByString:@", "]);

    // Aliases matter: a pad that reports the same control under two names is
    // telling us something about how it presents itself. The sets hold element
    // objects, so the difference in count is what is reportable.
    AKCILog(@"inspector: buttons=%lu (all=%lu) axes=%lu (all=%lu) dpads=%lu (all=%lu)",
            (unsigned long)profile.buttons.count, (unsigned long)profile.allButtons.count,
            (unsigned long)profile.axes.count, (unsigned long)profile.allAxes.count,
            (unsigned long)profile.dpads.count, (unsigned long)profile.allDpads.count);

    // The two buttons in question, by name and by profile property.
    GCControllerButtonInput *share = profile.buttons[GCInputButtonShare];
    AKCILog(@"inspector: share=%@ gesture=%@", share ? @"present" : @"absent",
            share ? (share.preferredSystemGestureState == GCSystemGestureStateDisabled ? @"disabled" : @"system") : @"n/a");

    if ([profile isKindOfClass:GCXboxGamepad.class]) {
        GCXboxGamepad *xbox = (GCXboxGamepad *)profile;
        NSMutableArray<NSString *> *paddles = [NSMutableArray array];
        if (xbox.paddleButton1) [paddles addObject:@"P1"];
        if (xbox.paddleButton2) [paddles addObject:@"P2"];
        if (xbox.paddleButton3) [paddles addObject:@"P3"];
        if (xbox.paddleButton4) [paddles addObject:@"P4"];
        AKCILog(@"inspector: xbox paddles=%@ share=%@", paddles.count ? [paddles componentsJoinedByString:@","] : @"none",
                xbox.buttonShare ? @"present" : @"absent");
    }
    if ([profile isKindOfClass:GCExtendedGamepad.class]) {
        GCExtendedGamepad *extended = (GCExtendedGamepad *)profile;
        AKCILog(@"inspector: menu=%@ options=%@ l3=%@ r3=%@",
                extended.buttonMenu ? @"y" : @"n",
                extended.buttonOptions ? @"y" : @"n",
                extended.leftThumbstickButton ? @"y" : @"n",
                extended.rightThumbstickButton ? @"y" : @"n");
    }
}

#pragma mark - Attaching: every element, live

- (void)attachEverything {
    for (GCController *pad in GCController.controllers) [self attachPad:pad];
    if (@available(iOS 14.0, *)) {
        GCKeyboard *keyboard = GCKeyboard.coalescedKeyboard;
        if (keyboard) [self attachKeyboard:keyboard];
        GCMouse *mouse = GCMouse.current;
        if (mouse) [self attachMouse:mouse];
    }
}

- (void)attachPad:(GCController *)pad {
    GCPhysicalInputProfile *profile = pad.physicalInputProfile;
    // Carried with every report from this pad. The identity is what a mapping is
    // remembered against; the name is only ever shown to a person.
    NSString *device = AKControllerIdentity(pad);
    NSString *deviceName = pad.vendorName ?: @"Controller";
    __weak AKControllerInspector *weakSelf = self;

    for (NSString *name in profile.buttons) {
        GCControllerButtonInput *button = profile.buttons[name];
        NSString *element = AKInputElementForControllerButton(name);
        button.pressedChangedHandler = ^(GCControllerButtonInput *input, float value, BOOL pressed) {
            (void)input;
            AKCIReport(weakSelf, device, deviceName, @"controller", element, value, pressed, nil);
        };
    }
    for (NSString *name in profile.axes) {
        GCControllerAxisInput *axis = profile.axes[name];
        NSString *element = AKInputElementForControllerAxis(name);
        axis.valueChangedHandler = ^(GCControllerAxisInput *input, float value) {
            (void)input;
            AKCIReportAxis(weakSelf, device, deviceName, @"controller", element, value);
        };
    }
    for (NSString *name in profile.dpads) {
        GCControllerDirectionPad *dpad = profile.dpads[name];
        dpad.valueChangedHandler = ^(GCControllerDirectionPad *input, float x, float y) {
            (void)input;
            // The direction is the name; where the thumb actually is goes in the
            // detail. As a name it changed with every movement, so nothing learned
            // from one press could ever match the next one.
            NSString *element = AKInputElementForDirectionPad(name, x, y);
            AKCIReport(weakSelf, device, deviceName, @"controller", element, 1, (x != 0 || y != 0),
                       [NSString stringWithFormat:@"x=%.2f y=%.2f", x, y]);
        };
    }
    for (NSString *name in profile.touchpads) {
        GCControllerTouchpad *touchpad = profile.touchpads[name];
        NSString *down = AKInputElementForTouchpad(name, @"down");
        NSString *up = AKInputElementForTouchpad(name, @"up");
        NSString *moved = AKInputElementForTouchpad(name, @"moved");
        touchpad.touchDown = ^(GCControllerTouchpad *input, float x, float y, float buttonValue, BOOL buttonPressed) {
            (void)input; (void)buttonValue;
            AKCIReport(weakSelf, device, deviceName, @"touchpad", down, 1, YES,
                       [NSString stringWithFormat:@"x=%.2f y=%.2f button=%d", x, y, buttonPressed]);
        };
        touchpad.touchUp = ^(GCControllerTouchpad *input, float x, float y, float buttonValue, BOOL buttonPressed) {
            (void)input; (void)buttonValue;
            AKCIReport(weakSelf, device, deviceName, @"touchpad", up, 0, NO,
                       [NSString stringWithFormat:@"x=%.2f y=%.2f button=%d", x, y, buttonPressed]);
        };
        touchpad.touchMoved = ^(GCControllerTouchpad *input, float x, float y, float buttonValue, BOOL buttonPressed) {
            (void)input; (void)buttonValue; (void)buttonPressed;
            AKCIReport(weakSelf, device, deviceName, @"touchpad", moved, 0, NO,
                       [NSString stringWithFormat:@"x=%.2f y=%.2f", x, y]);
        };
    }

    // The inventory is read-only. This used to disable Share's system gesture here,
    // for every pad that declared one, at startup - which changed how the controller
    // behaved before the user had asked for anything, and is the second of the
    // audit's release blockers. The gesture is now released only by
    // -releaseSystemGestureForElement:device:, which the router calls because the
    // user mapped that element, and it is given back afterwards.
    GCControllerButtonInput *share = profile.buttons[GCInputButtonShare];
    if (share) {
        AKCILog(@"inspector: %@ declares Share; its system gesture is %@ until mapped",
                deviceName,
                share.preferredSystemGestureState == GCSystemGestureStateDisabled ? @"already released" : @"still the system's");
    }
}

- (void)attachKeyboard:(GCKeyboard *)keyboard API_AVAILABLE(ios(14.0)) {
    __weak AKControllerInspector *weakSelf = self;
    // Read before the block: capturing the keyboard itself in its own handler is a
    // retain cycle, and the handler only needs its name.
    NSString *name = keyboard.vendorName ?: @"Keyboard";
    keyboard.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *input, GCDeviceButtonInput *key, GCKeyCode keyCode, BOOL pressed) {
        (void)input; (void)key;
        AKCIReport(weakSelf, @"keyboard", name, @"keyboard",
                   AKInputElementForKeyboardKey(keyCode), (pressed ? 1 : 0), pressed, nil);
    };
}

- (void)attachMouse:(GCMouse *)mouse API_AVAILABLE(ios(14.0)) {
    __weak AKControllerInspector *weakSelf = self;
    GCMouseInput *input = mouse.mouseInput;
    // Every handler marks the device first. The right and middle buttons used not to,
    // so they were attributed to whatever had been pressed before them.
    NSString *name = mouse.vendorName ?: @"Mouse";
    input.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        AKCIReport(weakSelf, @"mouse", name, @"mouse",
                   AKInputElementForMouseButton(@"left"), value, pressed, nil);
    };
    input.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        AKCIReport(weakSelf, @"mouse", name, @"mouse",
                   AKInputElementForMouseButton(@"right"), value, pressed, nil);
    };
    input.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        AKCIReport(weakSelf, @"mouse", name, @"mouse",
                   AKInputElementForMouseButton(@"middle"), value, pressed, nil);
    };
    input.mouseMovedHandler = ^(GCMouseInput *mouseInput, float deltaX, float deltaY) {
        (void)mouseInput;
        // Movement streams; the panel would never settle. Log the click only.
        (void)deltaX; (void)deltaY;
    };
}

#pragma mark - Reporting

// Called from the input handlers so that every report carries the device it came
// from. A message to a weak reference is safe where reading an ivar through one is
// not. The identity is what a mapping is stored against; the name is for people.
- (void)markDevice:(NSString *)device name:(NSString *)name source:(NSString *)source {
    _currentDevice = device;
    _currentDeviceName = name;
    _currentSourceName = source;
}

- (void)noteElement:(NSString *)element value:(double)value pressed:(BOOL)pressed detail:(nullable NSString *)detail {
    NSString *line = [NSString stringWithFormat:@"%@ %@=%.2f", element, pressed ? @"pressed" : @"value", value];
    if (detail.length) line = [line stringByAppendingFormat:@" %@", detail];
    [self reportLine:line element:element value:value pressed:pressed];
}

- (void)noteAxis:(NSString *)element value:(double)value {
    NSInteger bucket = (NSInteger)lround(value * AKCIAxisBucket);
    NSNumber *last = _axisBuckets[element];
    if (last && last.integerValue == bucket) return;
    _axisBuckets[element] = @(bucket);
    [self reportLine:[NSString stringWithFormat:@"%@=%.2f", element, value]
              element:element value:value pressed:(bucket != 0)];
}

- (void)reportLine:(NSString *)line element:(NSString *)element value:(double)value pressed:(BOOL)pressed {
    [self recordLine:line];
    if (self.onInput) self.onInput(element, value, pressed);
}

// The panel's own history and the log, without pretending to be an input. Some of
// what the inspector sees is a fact about the system rather than a button, and a
// fact must not start dictation.
- (void)recordLine:(NSString *)line {
    AKCILog(@"input: %@", line);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_history addObject:line];
        while (self->_history.count > AKCIHistoryLimit) [self->_history removeObjectAtIndex:0];
        self->_panel.text = [self->_history componentsJoinedByString:@"\n"];
        [self->_panel sizeToFit];
    });
}

#pragma mark - On-screen panel

- (void)showPanel:(BOOL)visible {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!visible) { [self->_panel removeFromSuperview]; self->_panel = nil; return; }
        if (self->_panel) return;
        UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        UILabel *label = [UILabel new];
        label.numberOfLines = AKCIHistoryLimit;
        label.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
        label.userInteractionEnabled = NO;
        label.text = @"controller inspector: waiting for input";
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [window addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:8],
            [label.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-8],
        ]];
        self->_panel = label;
    });
}

@end
