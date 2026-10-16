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

// How many events the on-screen panel keeps. The log itself is not limited.
static NSUInteger const AKCIHistoryLimit = 12;

// Stick axes stream continuously; without a threshold the log becomes unreadable
// and the game pays for it. Values are logged when they cross into a different
// half-unit, so a stick reads as -2, -1, 0, 1, 2 rather than a river of floats.
static double const AKCIAxisBucket = 2.0;

@implementation AKControllerInspector {
    NSMutableArray<NSString *> *_history;
    NSMutableDictionary<NSString *, NSNumber *> *_axisBuckets;
    UILabel *_panel;
    BOOL _began;
    NSString *_currentDevice;
    NSString *_currentSourceName;
}

- (NSString *)currentDevice { return _currentDevice; }
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
    // A press of the pad's Share button, as far as this app can tell. Attributed
    // to the connected pad when there is one, so a per-controller choice
    // applies to it.
    _currentDevice = GCController.controllers.firstObject.vendorName ?: @"System";
    _currentSourceName = @"system";
    [self reportLine:@"Share (system screenshot)" element:@"Share" value:1 pressed:YES];
}

- (void)screenCaptureChanged:(NSNotification *)notification {
    (void)notification;
    _currentDevice = GCController.controllers.firstObject.vendorName ?: @"System";
    _currentSourceName = @"system";
    BOOL captured = UIScreen.mainScreen.isCaptured;
    AKCILog(@"inspector: screen capture changed, captured=%d", captured);
    // Recorded, never reported as input.
    //
    // This used to go through reportLine: as "Share held", on the reasoning that
    // iPadOS spends the pad's Share hold on screen recording, so seeing a capture
    // start meant Share was held. That is only true when the pad started it, and
    // this notification cannot tell us who did. Measured on 2026-10-16: with the
    // iPad being captured from a Mac, `isCaptured` was already 1, the change fired
    // about a tenth of a second after every launch, and the launcher started
    // dictating by itself - six times in one log, with nobody touching anything.
    // The device's own log is what showed it, which is why the line is kept.
    [self recordLine:[NSString stringWithFormat:@"Share held (screen capture %@)", captured ? @"on" : @"off"]];
}

- (void)padsChanged:(NSNotification *)notification {
    AKCILog(@"inspector: %@", notification.name);
    [self attachEverything];
    [self logInventories];
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
    // Carried with every report from this pad, so a trigger can be remembered
    // against it rather than against "the controller".
    NSString *device = pad.vendorName ?: @"Controller";
    __weak AKControllerInspector *weakSelf = self;

    for (NSString *name in profile.buttons) {
        GCControllerButtonInput *button = profile.buttons[name];
        button.pressedChangedHandler = ^(GCControllerButtonInput *input, float value, BOOL pressed) {
            (void)input;
            [weakSelf markDevice:device source:@"controller"];
            [weakSelf noteElement:name value:value pressed:pressed];        };
    }
    for (NSString *name in profile.axes) {
        GCControllerAxisInput *axis = profile.axes[name];
        axis.valueChangedHandler = ^(GCControllerAxisInput *input, float value) {
            (void)input;
            [weakSelf markDevice:device source:@"controller"];
            [weakSelf noteAxis:name value:value];
        };
    }
    for (NSString *name in profile.dpads) {
        GCControllerDirectionPad *dpad = profile.dpads[name];
        dpad.valueChangedHandler = ^(GCControllerDirectionPad *input, float x, float y) {
            (void)input;
            [weakSelf markDevice:device source:@"controller"];
            [weakSelf noteElement:[NSString stringWithFormat:@"%@ x=%.2f y=%.2f", name, x, y]
                            value:(x != 0 ? x : y) pressed:(x != 0 || y != 0)];
        };
    }
    for (NSString *name in profile.touchpads) {
        GCControllerTouchpad *touchpad = profile.touchpads[name];
        touchpad.touchDown = ^(GCControllerTouchpad *input, float x, float y, float buttonValue, BOOL buttonPressed) {
            (void)input; (void)buttonValue;
            [weakSelf markDevice:device source:@"touchpad"];
            [weakSelf noteElement:[NSString stringWithFormat:@"%@ down x=%.2f y=%.2f button=%d", name, x, y, buttonPressed] value:1 pressed:YES];
        };
        touchpad.touchUp = ^(GCControllerTouchpad *input, float x, float y, float buttonValue, BOOL buttonPressed) {
            (void)input; (void)buttonValue;
            [weakSelf markDevice:device source:@"touchpad"];
            [weakSelf noteElement:[NSString stringWithFormat:@"%@ up x=%.2f y=%.2f button=%d", name, x, y, buttonPressed] value:0 pressed:NO];
        };
        touchpad.touchMoved = ^(GCControllerTouchpad *input, float x, float y, float buttonValue, BOOL buttonPressed) {
            (void)input; (void)buttonValue; (void)buttonPressed;
            [weakSelf noteElement:[NSString stringWithFormat:@"%@ moved x=%.2f y=%.2f", name, x, y] value:0 pressed:NO];
        };
    }

    // A reserved Share button is invisible until the reservation is cleared.
    // That is a change to how the system behaves, so it is said out loud.
    GCControllerButtonInput *share = profile.buttons[GCInputButtonShare];
    if (share && share.preferredSystemGestureState != GCSystemGestureStateDisabled) {
        share.preferredSystemGestureState = GCSystemGestureStateDisabled;
        AKCILog(@"inspector: Share released from the system gesture so it can be seen");
    }
}

- (void)attachKeyboard:(GCKeyboard *)keyboard API_AVAILABLE(ios(14.0)) {
    __weak AKControllerInspector *weakSelf = self;
    keyboard.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *input, GCDeviceButtonInput *key, GCKeyCode keyCode, BOOL pressed) {
        (void)input; (void)key;
        [weakSelf markDevice:@"Keyboard" source:@"keyboard"];
        [weakSelf noteElement:[NSString stringWithFormat:@"keycode %ld", (long)keyCode] value:(pressed ? 1 : 0) pressed:pressed];
    };
}

- (void)attachMouse:(GCMouse *)mouse API_AVAILABLE(ios(14.0)) {
    __weak AKControllerInspector *weakSelf = self;
    GCMouseInput *input = mouse.mouseInput;
    input.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        [weakSelf markDevice:@"Mouse" source:@"mouse"];
        [weakSelf noteElement:@"mouse left" value:value pressed:pressed];
    };
    input.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        [weakSelf noteElement:@"mouse right" value:value pressed:pressed];
    };
    input.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button;
        [weakSelf noteElement:@"mouse middle" value:value pressed:pressed];
    };
    input.mouseMovedHandler = ^(GCMouseInput *mouseInput, float deltaX, float deltaY) {
        (void)mouseInput;
        // Movement streams; the panel would never settle. Log the click only.
        (void)deltaX; (void)deltaY;
    };
}

#pragma mark - Reporting

// Called from the input handlers so that every report carries the device it
// came from. A message to a weak reference is safe where reading an ivar
// through one is not.
- (void)markDevice:(NSString *)device source:(NSString *)source {
    _currentDevice = device;
    _currentSourceName = source;
}

- (void)noteElement:(NSString *)element value:(double)value pressed:(BOOL)pressed {    NSString *line = [NSString stringWithFormat:@"%@ %@=%.2f", element, pressed ? @"pressed" : @"value", value];
    [self reportLine:line element:element value:value pressed:pressed];
}

- (void)noteAxis:(NSString *)name value:(double)value {
    NSInteger bucket = (NSInteger)lround(value * AKCIAxisBucket);
    NSNumber *last = _axisBuckets[name];
    if (last && last.integerValue == bucket) return;
    _axisBuckets[name] = @(bucket);
    [self reportLine:[NSString stringWithFormat:@"%@=%.2f", name, value] element:name value:value pressed:(bucket != 0)];
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
