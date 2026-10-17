// Wolkara: what to watch for, on any controller, in full.

#import "Trigger.h"
#import "InputElement.h"
#import "../App/WolkaraLog.h"

NSString *const AKTriggerAnyElement = @"*";

// Where a chosen trigger is remembered, per controller. The prefix is part of the
// contract with WolkaraConfig, which mirrors every "AKInputTrigger." key into the
// user's config file.
static NSString *const AKTriggerDefaultsPrefix = @"AKInputTrigger.";

// Bounds for the two intervals. A stored value outside these is not a slow press, it
// is a corrupt file.
static NSTimeInterval const AKTriggerHoldMinimum = 0.1;
static NSTimeInterval const AKTriggerHoldMaximum = 10.0;
static NSTimeInterval const AKTriggerDoubleMinimum = 0.05;
static NSTimeInterval const AKTriggerDoubleMaximum = 2.0;

@implementation AKTrigger

- (instancetype)init {
    if ((self = [super init])) {
        _element = AKTriggerAnyElement;
        _pattern = AKTriggerPatternPress;
    }
    return self;
}

#pragma mark - What it watches

- (BOOL)watchesElement:(NSString *)element {
    if (!element.length) return NO;
    if ([self.element isEqualToString:AKTriggerAnyElement]) return YES;
    if ([self.element isEqualToString:element]) return YES;
    // A family: "controller.button." covers every controller button, "system." covers
    // both of the system's signals.
    if ([self.element hasSuffix:@"."]) return [element hasPrefix:self.element];
    return NO;
}

- (NSString *)patternName {
    switch (self.pattern) {
    case AKTriggerPatternPress: return @"press";
    case AKTriggerPatternPushToTalk: return @"hold to talk";
    }
    return @"press";
}

- (NSString *)summary {
    NSString *element = AKInputElementDisplay(self.element);
    return [NSString stringWithFormat:@"%@ (%@)", element, [self patternName]];
}

#pragma mark - Storage

+ (nullable NSDictionary *)validatedStoredForm:(nullable NSDictionary *)stored {
    if (![stored isKindOfClass:NSDictionary.class]) return nil;

    id element = stored[@"element"];
    if (![element isKindOfClass:NSString.class] || !((NSString *)element).length) return nil;
    NSString *canonical = AKInputElementCanonicalized(element);
    // A name we cannot read is not a mapping, and guessing at it would be worse than
    // saying so.
    if (!AKInputElementIsCanonical(canonical)) return nil;
    if (canonical.length > 128) return nil;
    // A system signal is not a button. iPadOS does not say whether a screenshot came from
    // a controller or from the user's own fingers, so attributing it to whichever pad is
    // connected and letting that start the microphone is not something a mapping can make
    // safe - the audit's second remediation blocker. It is recorded in the log and
    // reported to nobody, and no stored mapping may point at it.
    if (AKInputElementIsSystem(canonical)) return nil;

    id patternValue = stored[@"pattern"] ?: @(AKTriggerPatternPress);
    if (![patternValue isKindOfClass:NSNumber.class]) return nil;
    NSInteger pattern = [patternValue integerValue];
    if ([patternValue doubleValue] != pattern ||
        (pattern != AKTriggerPatternPress && pattern != AKTriggerPatternPushToTalk)) return nil;

    id chord = stored[@"chord"];
    if (chord && ![chord isKindOfClass:NSString.class]) return nil;
    if ([chord isKindOfClass:NSString.class] && ((NSString *)chord).length &&
        !AKInputElementIsCanonical(chord)) return nil;

    NSMutableDictionary *validated = [NSMutableDictionary dictionary];
    validated[@"element"] = canonical;
    validated[@"pattern"] = @(pattern);
    if ([chord isKindOfClass:NSString.class] && ((NSString *)chord).length) validated[@"chord"] = chord;

    id hold = stored[@"hold"];
    if (hold) {
        if (![hold isKindOfClass:NSNumber.class]) return nil;
        double seconds = [hold doubleValue];
        if (!(seconds >= AKTriggerHoldMinimum && seconds <= AKTriggerHoldMaximum)) return nil;
        validated[@"hold"] = @(seconds);
    }
    id doubleTap = stored[@"double"];
    if (doubleTap) {
        if (![doubleTap isKindOfClass:NSNumber.class]) return nil;
        double seconds = [doubleTap doubleValue];
        if (!(seconds >= AKTriggerDoubleMinimum && seconds <= AKTriggerDoubleMaximum)) return nil;
        validated[@"double"] = @(seconds);
    }
    return validated;
}

+ (nullable instancetype)triggerFromStored:(nullable NSDictionary *)stored {
    NSDictionary *validated = [self validatedStoredForm:stored];
    if (!validated) return nil;
    AKTrigger *trigger = [AKTrigger new];
    trigger.element = validated[@"element"];
    trigger.pattern = (AKTriggerPattern)[validated[@"pattern"] integerValue];
    return trigger;
}

- (NSDictionary *)storedForm {
    NSMutableDictionary *stored = [NSMutableDictionary dictionary];
    stored[@"element"] = AKInputElementCanonicalized(self.element);
    stored[@"pattern"] = @(self.pattern);
    return stored;
}

#pragma mark - Remembering a choice, per controller

+ (NSString *)defaultsKeyForDevice:(nullable NSString *)device {
    return [AKTriggerDefaultsPrefix stringByAppendingString:device.length ? device : @"any"];
}

// The key older builds wrote: vendor alone.
+ (NSString *)legacyDefaultsKeyForVendor:(nullable NSString *)vendor {
    return [AKTriggerDefaultsPrefix stringByAppendingString:vendor.length ? vendor : @"any"];
}

+ (nullable instancetype)savedTriggerForDevice:(nullable NSString *)device defaults:(NSUserDefaults *)defaults {
    NSDictionary *stored = [defaults dictionaryForKey:[self defaultsKeyForDevice:device]];
    if (![stored isKindOfClass:NSDictionary.class]) return nil;
    return [self triggerFromStored:stored];
}

- (void)saveForDevice:(nullable NSString *)device defaults:(NSUserDefaults *)defaults {
    [defaults setObject:[self storedForm] forKey:[AKTrigger defaultsKeyForDevice:device]];
}

+ (void)forgetTriggerForDevice:(nullable NSString *)device defaults:(NSUserDefaults *)defaults {
    [defaults removeObjectForKey:[self defaultsKeyForDevice:device]];
}

+ (NSUInteger)migrateStoredTriggersInDefaults:(NSUserDefaults *)defaults {
    NSUInteger changed = 0;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if (![key hasPrefix:AKTriggerDefaultsPrefix]) continue;
        NSDictionary *stored = [defaults dictionaryForKey:key];
        if (![stored isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *validated = [self validatedStoredForm:stored];
        if (!validated) {
            // Unreadable before and unreadable now: removed rather than left to be
            // re-examined on every launch. A mapping that pointed at a system signal is
            // in here too, so say which key went and why, or a user would just find that
            // their button stopped working.
            WKLog("voice", @"dropping the stored mapping at %@: it is not a trigger this build can use", key);
            [defaults removeObjectForKey:key];
            changed++;
            continue;
        }
        if ([validated isEqualToDictionary:stored]) continue;
        [defaults setObject:validated forKey:key];
        changed++;
    }
    return changed;
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    AKTrigger *copy = [[AKTrigger allocWithZone:zone] init];
    copy.element = self.element;
    copy.pattern = self.pattern;
    return copy;
}

@end
