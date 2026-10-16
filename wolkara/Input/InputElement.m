#import "InputElement.h"

static NSString *const AKInputElementControllerPrefix = @"controller.button.";
static NSString *const AKInputElementControllerAxisPrefix = @"controller.axis.";
static NSString *const AKInputElementKeyboardPrefix = @"keyboard.key.";
static NSString *const AKInputElementMousePrefix = @"mouse.button.";
static NSString *const AKInputElementTouchpadPrefix = @"touchpad.";
static NSString *const AKInputElementDirectionPadPrefix = @"dpad.";
static NSString *const AKInputElementSystemPrefix = @"system.";

// Names the system uses that read badly when lowercased and de-spaced on their own.
static NSDictionary<NSString *, NSString *> *AKInputElementButtonNames(void) {
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{ @"share": @"Share", @"a": @"A", @"b": @"B", @"x": @"X", @"y": @"Y",
                   @"menu": @"Menu", @"options": @"Options", @"home": @"Home",
                   @"left.shoulder": @"Left shoulder", @"right.shoulder": @"Right shoulder",
                   @"left.trigger": @"Left trigger", @"right.trigger": @"Right trigger",
                   @"left.thumbstick": @"Left stick", @"right.thumbstick": @"Right stick",
                   @"left.thumbstick.button": @"Left stick click",
                   @"right.thumbstick.button": @"Right stick click",
                   @"up": @"Up", @"down": @"Down", @"left": @"Left", @"right": @"Right",
                   @"paddle1": @"Paddle 1", @"paddle2": @"Paddle 2",
                   @"paddle3": @"Paddle 3", @"paddle4": @"Paddle 4" };
    });
    return names;
}

// One spelling for one thing, whatever the system calls it.
NSString *AKInputIdentifierSlug(NSString *text) {
    NSString *lower = text.lowercaseString;
    NSMutableString *slug = [NSMutableString string];
    BOOL lastWasDot = YES;   // collapses leading and repeated separators
    for (NSUInteger index = 0; index < lower.length; index++) {
        unichar character = [lower characterAtIndex:index];
        if ((character >= 'a' && character <= 'z') || (character >= '0' && character <= '9')) {
            [slug appendFormat:@"%C", character];
            lastWasDot = NO;
        } else if (!lastWasDot) {
            [slug appendString:@"."];
            lastWasDot = YES;
        }
    }
    while ([slug hasSuffix:@"."]) [slug deleteCharactersInRange:NSMakeRange(slug.length - 1, 1)];
    return slug;
}

NSString *AKInputElementForControllerButton(NSString *buttonName) {
    NSString *name = buttonName;
    // GameController names every button "Button <Something>"; the prefix carries no
    // information and only makes the key longer.
    if ([name hasPrefix:@"Button "]) name = [name substringFromIndex:@"Button ".length];
    return [AKInputElementControllerPrefix stringByAppendingString:AKInputIdentifierSlug(name)];
}

NSString *AKInputElementForControllerAxis(NSString *axisName) {
    return [AKInputElementControllerAxisPrefix stringByAppendingString:AKInputIdentifierSlug(axisName)];
}

NSString *AKInputElementForKeyboardKey(NSInteger keyCode) {
    return [AKInputElementKeyboardPrefix stringByAppendingFormat:@"%ld", (long)keyCode];
}

NSString *AKInputElementForMouseButton(NSString *button) {
    return [AKInputElementMousePrefix stringByAppendingString:AKInputIdentifierSlug(button)];
}

NSString *AKInputElementForTouchpad(NSString *pad, NSString *phase) {
    return [NSString stringWithFormat:@"%@%@.%@", AKInputElementTouchpadPrefix, AKInputIdentifierSlug(pad), AKInputIdentifierSlug(phase)];
}

// The axes, not the numbers: a diagonal is "up.left" rather than "0.71,-0.71", which
// is a different string every time a thumb moves.
NSString *AKInputElementForDirectionPad(NSString *pad, double x, double y) {
    static double const deadzone = 0.35;
    NSString *vertical = y > deadzone ? @"down" : (y < -deadzone ? @"up" : @"centre");
    NSString *horizontal = x > deadzone ? @"right" : (x < -deadzone ? @"left" : @"centre");
    if ([vertical isEqualToString:@"centre"] && [horizontal isEqualToString:@"centre"]) vertical = @"centre";
    return [NSString stringWithFormat:@"%@%@.%@.%@", AKInputElementDirectionPadPrefix,
            AKInputIdentifierSlug(pad), vertical, horizontal];
}

NSString *AKInputElementSystemScreenshot(void) { return @"system.screenshot"; }
NSString *AKInputElementSystemCapture(void) { return @"system.capture"; }

BOOL AKInputElementIsSystem(NSString *element) {
    return [element hasPrefix:AKInputElementSystemPrefix];
}

BOOL AKInputElementIsCanonical(NSString *element) {
    if (!element.length) return NO;
    if ([element isEqualToString:@"*"]) return YES;
    for (NSString *prefix in @[AKInputElementControllerPrefix, AKInputElementControllerAxisPrefix,
                               AKInputElementKeyboardPrefix,
                               AKInputElementMousePrefix, AKInputElementTouchpadPrefix,
                               AKInputElementDirectionPadPrefix, AKInputElementSystemPrefix])
        if ([element hasPrefix:prefix]) return YES;
    return NO;
}

#pragma mark - Coming from an older build

NSString *AKInputElementCanonicalized(NSString *element) {
    if (!element.length) return element;
    if (AKInputElementIsCanonical(element)) return element;

    // "Button Share", "Button Left Shoulder" - the pad's own elements, as the
    // inspector used to report them.
    if ([element hasPrefix:@"Button "]) return AKInputElementForControllerButton(element);

    // "Share" was what the *system* signal was called, and it is what the unasked-for
    // default mapping pointed at. It is the screenshot notification, and the audit is
    // right that it must not be resurrected as an automatic trigger - but a user who
    // pressed a button to map it did choose it, so their choice is kept, under its
    // real name.
    if ([element isEqualToString:@"Share"]) return AKInputElementSystemScreenshot();

    if ([element hasPrefix:@"keycode "])
        return AKInputElementForKeyboardKey([[element substringFromIndex:@"keycode ".length] integerValue]);

    NSDictionary<NSString *, NSString *> *mouse = @{ @"mouse left": @"left", @"mouse right": @"right", @"mouse middle": @"middle" };
    if (mouse[element]) return AKInputElementForMouseButton(mouse[element]);

    // "dpad x=0.42 y=-1.00" and "touchpad down x=0.51 y=0.33" carried their values in
    // the name. Only the phase survives; the numbers were never part of the identity.
    if ([element hasPrefix:@"dpad "]) return [AKInputElementDirectionPadPrefix stringByAppendingString:@"dpad.centre.centre"];
    if ([element hasPrefix:@"touchpad "]) {
        NSString *rest = [element substringFromIndex:@"touchpad ".length];
        NSString *phase = [rest componentsSeparatedByString:@" "].firstObject;
        return AKInputElementForTouchpad(@"touchpad", phase);
    }
    return element;
}

#pragma mark - Reading it out

static NSString *AKInputElementPrettify(NSString *slug) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *part in [slug componentsSeparatedByString:@"."])
        if (part.length) [words addObject:[[part substringToIndex:1].uppercaseString
                                          stringByAppendingString:[part substringFromIndex:1]]];
    return [words componentsJoinedByString:@" "];
}

NSString *AKInputElementDisplay(NSString *element) {
    if (!element.length) return @"Nothing";
    if ([element isEqualToString:@"*"]) return @"Any button";
    if ([element isEqualToString:AKInputElementSystemScreenshot()]) return @"Share (screenshot)";
    if ([element isEqualToString:AKInputElementSystemCapture()]) return @"Share (screen recording)";

    if ([element hasPrefix:AKInputElementControllerPrefix]) {
        NSString *slug = [element substringFromIndex:AKInputElementControllerPrefix.length];
        return AKInputElementButtonNames()[slug] ?: AKInputElementPrettify(slug);
    }
    if ([element hasPrefix:AKInputElementControllerAxisPrefix]) {
        NSString *slug = [element substringFromIndex:AKInputElementControllerAxisPrefix.length];
        return AKInputElementButtonNames()[slug] ?: AKInputElementPrettify(slug);
    }
    if ([element hasPrefix:AKInputElementKeyboardPrefix])
        return [@"Key " stringByAppendingString:[element substringFromIndex:AKInputElementKeyboardPrefix.length]];
    if ([element hasPrefix:AKInputElementMousePrefix])
        return [AKInputElementPrettify([element substringFromIndex:AKInputElementMousePrefix.length]) stringByAppendingString:@" mouse button"];
    if ([element hasPrefix:AKInputElementTouchpadPrefix])
        return [@"Touchpad " stringByAppendingString:AKInputElementPrettify([element substringFromIndex:AKInputElementTouchpadPrefix.length])];
    if ([element hasPrefix:AKInputElementDirectionPadPrefix]) {
        NSString *rest = [element substringFromIndex:AKInputElementDirectionPadPrefix.length];
        NSArray<NSString *> *parts = [rest componentsSeparatedByString:@"."];
        if (parts.count >= 3) {
            NSString *vertical = parts[parts.count - 2], *horizontal = parts[parts.count - 1];
            NSString *where = nil;
            if ([vertical isEqualToString:@"centre"] && [horizontal isEqualToString:@"centre"]) where = @"centre";
            else if ([vertical isEqualToString:@"centre"]) where = horizontal;
            else if ([horizontal isEqualToString:@"centre"]) where = vertical;
            else where = [vertical stringByAppendingFormat:@"-%@", horizontal];
            return [@"D-pad " stringByAppendingString:where];
        }
        return @"D-pad";
    }
    // Something we have never seen: show it as it is rather than invent a name.
    return element;
}
