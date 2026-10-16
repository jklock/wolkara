// Wolkara: what to watch for, on any controller, in full.

#import "Trigger.h"

NSString *const AKTriggerAnyElement = @"*";

// Where a chosen trigger is remembered, per controller.
static NSString *const AKTriggerDefaultsPrefix = @"AKInputTrigger.";

@implementation AKTrigger

- (instancetype)init {
    if ((self = [super init])) {
        _element = AKTriggerAnyElement;
        _pattern = AKTriggerPatternLong;
        _holdInterval = 0.6;
        _doubleInterval = 0.35;
    }
    return self;
}

+ (instancetype)systemButtonTrigger {
    AKTrigger *trigger = [AKTrigger new];
    // The name the system uses for the button an Xbox-family pad declares when
    // it declares one at all. Its system gesture is released elsewhere, so the
    // press lands with us rather than becoming a screenshot.
    trigger.element = @"Button Share";
    trigger.pattern = AKTriggerPatternPress;
    return trigger;
}

+ (instancetype)defaultTriggerForController:(nullable NSString *)vendor {
    (void)vendor;
    // No reserved button and nothing learned yet: a long press is the safest
    // thing to watch, because a game that binds single presses cannot be using
    // it. The element is left open until the user says which button they want.
    AKTrigger *trigger = [AKTrigger new];
    trigger.element = AKTriggerAnyElement;
    trigger.pattern = AKTriggerPatternLong;
    return trigger;
}

#pragma mark - What it watches

- (BOOL)watchesElement:(NSString *)element {
    if (!element.length) return NO;
    if ([self.element isEqualToString:AKTriggerAnyElement]) return YES;
    // A family match: "Button " covers Button A through Button Share, so a
    // controller we have never seen is still covered.
    if ([self.element hasSuffix:@" "]) return [element hasPrefix:self.element];
    return [self.element isEqualToString:element];
}

- (NSString *)summary {
    NSString *pattern = @[@"press", @"double", @"long", @"chord"][(NSUInteger)self.pattern];
    if (self.pattern == AKTriggerPatternChord && self.chordElement.length)
        return [NSString stringWithFormat:@"%@ + %@ (%@)", self.element, self.chordElement, pattern];
    return [NSString stringWithFormat:@"%@ (%@)", self.element, pattern];
}

#pragma mark - Remembering a choice, per controller

+ (NSString *)defaultsKeyForVendor:(nullable NSString *)vendor {
    NSString *name = vendor.length ? vendor : @"any";
    return [AKTriggerDefaultsPrefix stringByAppendingString:name];
}

+ (nullable instancetype)savedTriggerForVendor:(nullable NSString *)vendor defaults:(NSUserDefaults *)defaults {
    NSDictionary *stored = [defaults dictionaryForKey:[self defaultsKeyForVendor:vendor]];
    if (![stored isKindOfClass:NSDictionary.class]) return nil;
    AKTrigger *trigger = [AKTrigger new];
    trigger.element = stored[@"element"] ?: AKTriggerAnyElement;
    trigger.chordElement = stored[@"chord"];
    trigger.pattern = (AKTriggerPattern)[stored[@"pattern"] integerValue];
    trigger.holdInterval = stored[@"hold"] ? [stored[@"hold"] doubleValue] : 0.6;
    trigger.doubleInterval = stored[@"double"] ? [stored[@"double"] doubleValue] : 0.35;
    return trigger;
}

- (void)saveForVendor:(nullable NSString *)vendor defaults:(NSUserDefaults *)defaults {
    NSMutableDictionary *stored = [NSMutableDictionary dictionary];
    stored[@"element"] = self.element;
    stored[@"pattern"] = @(self.pattern);
    stored[@"hold"] = @(self.holdInterval);
    stored[@"double"] = @(self.doubleInterval);
    if (self.chordElement.length) stored[@"chord"] = self.chordElement;
    [defaults setObject:stored forKey:[AKTrigger defaultsKeyForVendor:vendor]];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    AKTrigger *copy = [[AKTrigger allocWithZone:zone] init];
    copy.element = self.element;
    copy.chordElement = self.chordElement;
    copy.pattern = self.pattern;
    copy.holdInterval = self.holdInterval;
    copy.doubleInterval = self.doubleInterval;
    return copy;
}

@end
