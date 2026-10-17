// Wolkara: the voice settings, in full.

#import "VoiceSettings.h"
#import "../App/WolkaraLog.h"
#import "../Input/InputElement.h"

NSNotificationName const AKVoiceSettingsDidChangeNotification = @"AKVoiceSettingsDidChange";

static NSString *const AKVoiceEnabledKey = @"AKVoiceEnabled";
static NSString *const AKVoiceModeKey = @"AKVoiceMode";
static NSString *const AKVoiceAutoSubmitKey = @"AKVoiceAutoSubmit";
static NSString *const AKVoiceTrailingSpaceKey = @"AKVoiceTrailingSpace";
static NSString *const AKVoiceCustomWordsKey = @"AKVoiceCustomWords";
static NSString *const AKVoiceTakeButtonKey = @"AKVoiceTakeButtonFromGame";

// The dictionary is biased into the recogniser, so it is bounded: a huge list is not a
// dictionary, it is a corrupt file, and it would be handed to the SDK either way.
static NSUInteger const AKVoiceWordLimit = 512;
static NSUInteger const AKVoiceWordLengthLimit = 64;

@implementation AKVoiceSettings

+ (instancetype)shared {
    static AKVoiceSettings *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [AKVoiceSettings new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        // Off, and staying off, until the user turns it on. See the header.
        _enabled = [defaults boolForKey:AKVoiceEnabledKey];
        // Hold to talk unless the user says otherwise: it is what Handy defaults to,
        // and it fails safe - a stuck toggle leaves the microphone open.
        if ([defaults objectForKey:AKVoiceModeKey])
            _mode = (AKVoiceMode)[defaults integerForKey:AKVoiceModeKey];
        else
            _mode = AKVoiceModeHold;
        _autoSubmit = [defaults boolForKey:AKVoiceAutoSubmitKey];
        _trailingSpace = [defaults boolForKey:AKVoiceTrailingSpaceKey];
        _customWords = [self sanitizedWords:[defaults arrayForKey:AKVoiceCustomWordsKey] ?: @[]];
        // Off: a mapping listens to a button, and making the game stop seeing it is a
        // change to how the game behaves that the user has to ask for.
        _takeButtonFromGame = [defaults boolForKey:AKVoiceTakeButtonKey];
        // One pass at startup: an older build wrote element names that are not ids.
        NSUInteger migrated = [AKTrigger migrateStoredTriggersInDefaults:defaults];
        if (migrated) WKLog("voice", @"migrated %lu stored mapping(s) to canonical element ids", (unsigned long)migrated);
    }
    return self;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [self persist:AKVoiceEnabledKey value:@(enabled)];
}
- (void)setMode:(AKVoiceMode)mode {
    _mode = mode;
    // The mode owns the pattern; see the header. Rewriting the stored patterns here
    // is what stops a mapping made in one mode behaving like the other one.
    [self applyModeToStoredMappings];
    [self persist:AKVoiceModeKey value:@(mode)];
}
- (void)setAutoSubmit:(BOOL)autoSubmit { _autoSubmit = autoSubmit; [self persist:AKVoiceAutoSubmitKey value:@(autoSubmit)]; }
- (void)setTakeButtonFromGame:(BOOL)takeButtonFromGame {
    _takeButtonFromGame = takeButtonFromGame;
    [self persist:AKVoiceTakeButtonKey value:@(takeButtonFromGame)];
}

// The one place that decides whether the guest is kept from seeing an input. Deliberately
// asked by *element* and not by device: the adapter sees a key press, not a controller, and
// the mapping is per device, so "any device has taken this" is the only question the
// adapter's position can answer.
- (BOOL)ownsElement:(NSString *)element {
    if (!_enabled || !_takeButtonFromGame) return NO;
    if (!element.length || AKInputElementIsSystem(element)) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if (![key hasPrefix:@"AKInputTrigger."]) continue;
        AKTrigger *stored = [AKTrigger triggerFromStored:[defaults dictionaryForKey:key]];
        // A hand-written mapping could name a system element; nothing about a screenshot
        // can be swallowed, so it is refused here too rather than only on migration.
        if (!stored || AKInputElementIsSystem(stored.element)) continue;
        if ([stored.element isEqualToString:element]) return YES;
    }
    return NO;
}

// The same decision in the form the adapter can use: it is about to post a key and knows the
// usage, not the element. One scan, for the shell to publish to the adapter as a set.
- (NSSet<NSNumber *> *)ownedKeyUsages {
    if (!_enabled || !_takeButtonFromGame) return [NSSet set];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableSet<NSNumber *> *usages = [NSMutableSet set];
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if (![key hasPrefix:@"AKInputTrigger."]) continue;
        AKTrigger *stored = [AKTrigger triggerFromStored:[defaults dictionaryForKey:key]];
        if (!stored) continue;
        NSString *element = stored.element;
        if (![element hasPrefix:AKInputElementKeyboardPrefix]) continue;
        // Digits only after the prefix: `keyboard.key.a` is not a usage, and something that
        // is not a usage must not be turned into one.
        NSString *tail = [element substringFromIndex:AKInputElementKeyboardPrefix.length];
        if (!tail.length) continue;
        if ([tail rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) continue;
        [usages addObject:@(tail.integerValue)];
    }
    return usages;
}
- (void)setTrailingSpace:(BOOL)trailingSpace { _trailingSpace = trailingSpace; [self persist:AKVoiceTrailingSpaceKey value:@(trailingSpace)]; }
- (void)setCustomWords:(NSArray<NSString *> *)customWords {
    _customWords = [self sanitizedWords:customWords];
    [self persist:AKVoiceCustomWordsKey value:_customWords];
}

// Anything the recogniser is handed is bounded and stripped: empty entries dropped,
// nothing longer than the limit kept, and the whole list capped.
- (NSArray<NSString *> *)sanitizedWords:(NSArray *)words {
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (id entry in words) {
        if (![entry isKindOfClass:NSString.class]) continue;
        NSString *word = [(NSString *)entry stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!word.length || word.length > AKVoiceWordLengthLimit) continue;
        if ([clean containsObject:word]) continue;
        [clean addObject:word];
        if (clean.count >= AKVoiceWordLimit) break;
    }
    return clean;
}

- (void)persist:(NSString *)key value:(id)value {
    [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
    WKLog("voice", @"%@ set", key);
    [NSNotificationCenter.defaultCenter postNotificationName:AKVoiceSettingsDidChangeNotification
                                                      object:self];
}

#pragma mark - The button

- (nullable AKTrigger *)triggerForDevice:(nullable NSString *)device {
    // Off means nothing fires, whatever is stored. One gate, here, rather than a check
    // at every call site - and no fallback when nothing is stored, on purpose: the
    // audit's first release blocker was a feature that started listening because an
    // unrelated screenshot was taken.
    if (!_enabled) return nil;
    return [self storedTriggerForDevice:device];
}

// What is mapped, whether or not the feature is switched on: the settings screen has
// to be able to show the user what they chose while it is off.
- (nullable AKTrigger *)storedTriggerForDevice:(nullable NSString *)device {
    AKTrigger *trigger = [AKTrigger savedTriggerForDevice:device defaults:NSUserDefaults.standardUserDefaults];
    if (trigger) trigger.pattern = self.mode == AKVoiceModeHold ? AKTriggerPatternPushToTalk : AKTriggerPatternPress;
    return trigger;
}

- (void)setLearnedElement:(NSString *)element forDevice:(nullable NSString *)device {
    AKTrigger *trigger = [AKTrigger new];
    trigger.element = element;
    trigger.pattern = self.mode == AKVoiceModeHold ? AKTriggerPatternPushToTalk : AKTriggerPatternPress;
    [self setTrigger:trigger forDevice:device];
}

- (void)setTrigger:(AKTrigger *)trigger forDevice:(nullable NSString *)device {
    [trigger saveForDevice:device defaults:NSUserDefaults.standardUserDefaults];
    WKLog("voice", @"mapped %@ on %@", [trigger summary], device ?: @"any");
    [NSNotificationCenter.defaultCenter postNotificationName:AKVoiceSettingsDidChangeNotification
                                                      object:self];
}

- (void)clearMappingForDevice:(nullable NSString *)device {
    [AKTrigger forgetTriggerForDevice:device defaults:NSUserDefaults.standardUserDefaults];
    WKLog("voice", @"mapping cleared for %@", device ?: @"any");
    [NSNotificationCenter.defaultCenter postNotificationName:AKVoiceSettingsDidChangeNotification
                                                      object:self];
}

- (BOOL)adoptLegacyMappingForDevice:(NSString *)device vendor:(nullable NSString *)vendor {
    if (!device.length || !vendor.length) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults dictionaryForKey:[AKTrigger defaultsKeyForDevice:device]] ) return NO;
    NSDictionary *legacy = [defaults dictionaryForKey:[NSString stringWithFormat:@"AKInputTrigger.%@", vendor]];
    if (![legacy isKindOfClass:NSDictionary.class]) return NO;
    AKTrigger *trigger = [AKTrigger triggerFromStored:legacy];
    if (!trigger) {
        [defaults removeObjectForKey:[NSString stringWithFormat:@"AKInputTrigger.%@", vendor]];
        return NO;
    }
    [trigger saveForDevice:device defaults:defaults];
    [defaults removeObjectForKey:[NSString stringWithFormat:@"AKInputTrigger.%@", vendor]];
    WKLog("voice", @"adopted the mapping made before this change (%@) for %@", [trigger summary], device);
    [NSNotificationCenter.defaultCenter postNotificationName:AKVoiceSettingsDidChangeNotification
                                                      object:self];
    return YES;
}

// A mapping made in one mode must not keep the other mode's pattern.
- (void)applyModeToStoredMappings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    AKTriggerPattern wanted = self.mode == AKVoiceModeHold ? AKTriggerPatternPushToTalk : AKTriggerPatternPress;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if (![key hasPrefix:@"AKInputTrigger."]) continue;
        NSDictionary *stored = [defaults dictionaryForKey:key];
        AKTrigger *trigger = [AKTrigger triggerFromStored:stored];
        if (!trigger) continue;
        // Every supported mapping follows the selected mode.
        if (trigger.pattern == wanted) continue;
        trigger.pattern = wanted;
        [trigger saveForDevice:[key substringFromIndex:@"AKInputTrigger.".length] defaults:defaults];
    }
}

- (NSString *)mappingSummaryForDevice:(nullable NSString *)device {
    AKTrigger *saved = [self storedTriggerForDevice:device];
    if (!saved) return @"Not set";
    return [saved summary];
}

@end
