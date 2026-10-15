// Wolkara layer: the window that watches for the Share button.

#import "ControllerWindow.h"

#if __has_include("AKSupport.h")
#import "AKSupport.h"
#define AKCWLog(...) AKLog(__VA_ARGS__)
#else
#define AKCWLog(...) NSLog(@"[ak] %@", [NSString stringWithFormat:__VA_ARGS__])
#endif

@implementation AKControllerWindow {
    UIKeyCommand *_printScreen;
}

// The key command is what lets an app take a key the system would otherwise
// handle itself. wantsPriorityOverSystemBehavior exists for exactly that, and
// is documented as "execute if it conflicts with focus or text-editing system
// commands". Whether it wins against the screenshot gesture is what we measure.
- (NSArray<UIKeyCommand *> *)keyCommands {
    if (!_printScreen) {
        // The key has no public input constant, so it is described by the
        // character UIKit reports for it: 0x46 in the HID usage table. UIKit
        // represents special keys by their own string, which is why this is
        // built from the code point rather than a name.
        NSString *input = [NSString stringWithFormat:@"%C", (unichar)0x46];
        _printScreen = [UIKeyCommand keyCommandWithInput:input
                                           modifierFlags:0
                                                  action:@selector(printScreenPressed:)];
        _printScreen.wantsPriorityOverSystemBehavior = YES;
        AKCWLog(@"window: offered a key command for Print Screen (input=0x46)");
    }
    return @[_printScreen];
}

- (void)printScreenPressed:(UIKeyCommand *)command {
    AKCWLog(@"window: PRINT SCREEN CLAIMED by key command (modifiers=%lu)",
            (unsigned long)command.modifierFlags);
    [NSNotificationCenter.defaultCenter postNotificationName:@"AKControllerPrintScreenNotification" object:nil];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (!key) { AKCWLog(@"window: press with no key (type=%ld)", (long)press.type); continue; }
        AKCWLog(@"window: press usage=%lu chars=%@ ignoringModifiers=%@ mods=%lu",
                (unsigned long)key.keyCode,
                key.characters.length ? key.characters : @"(none)",
                key.charactersIgnoringModifiers.length ? key.charactersIgnoringModifiers : @"(none)",
                (unsigned long)key.modifierFlags);
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (key) AKCWLog(@"window: release usage=%lu", (unsigned long)key.keyCode);
    }
    [super pressesEnded:presses withEvent:event];
}

@end
