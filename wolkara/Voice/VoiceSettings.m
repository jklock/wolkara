// Wolkara: the voice settings, in full.

#import "VoiceSettings.h"

#if __has_include("AKSupport.h")
#import "AKSupport.h"
#define AKVSLog(...) AKLog(__VA_ARGS__)
#else
#define AKVSLog(...) NSLog(@"[ak] %@", [NSString stringWithFormat:__VA_ARGS__])
#endif

NSNotificationName const AKVoiceSettingsDidChangeNotification = @"AKVoiceSettingsDidChange";

static NSString *const AKVoiceModeKey = @"AKVoiceMode";
static NSString *const AKVoiceAutoSubmitKey = @"AKVoiceAutoSubmit";
static NSString *const AKVoiceTrailingSpaceKey = @"AKVoiceTrailingSpace";
static NSString *const AKVoiceCustomWordsKey = @"AKVoiceCustomWords";

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
        // Hold to talk unless the user says otherwise: it is what Handy defaults
        // to, and it fails safe — a stuck toggle leaves the microphone open.
        if ([defaults objectForKey:AKVoiceModeKey])
            _mode = (AKVoiceMode)[defaults integerForKey:AKVoiceModeKey];
        else
            _mode = AKVoiceModeHold;
        _autoSubmit = [defaults boolForKey:AKVoiceAutoSubmitKey];
        _trailingSpace = [defaults boolForKey:AKVoiceTrailingSpaceKey];
        _customWords = [defaults arrayForKey:AKVoiceCustomWordsKey] ?: @[];
    }
    return self;
}

- (void)setMode:(AKVoiceMode)mode { _mode = mode; [self persist:AKVoiceModeKey value:@(mode)]; }
- (void)setAutoSubmit:(BOOL)autoSubmit { _autoSubmit = autoSubmit; [self persist:AKVoiceAutoSubmitKey value:@(autoSubmit)]; }
- (void)setTrailingSpace:(BOOL)trailingSpace { _trailingSpace = trailingSpace; [self persist:AKVoiceTrailingSpaceKey value:@(trailingSpace)]; }
- (void)setCustomWords:(NSArray<NSString *> *)customWords {
    _customWords = [customWords copy] ?: @[];
    [self persist:AKVoiceCustomWordsKey value:_customWords];
}

- (void)persist:(NSString *)key value:(id)value {
    [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
    AKVSLog(@"voice: %@ set", key);
    [NSNotificationCenter.defaultCenter postNotificationName:AKVoiceSettingsDidChangeNotification
                                                      object:self];
}

#pragma mark - The button

- (AKTrigger *)triggerForDevice:(nullable NSString *)device {
    AKTrigger *chosen = [AKTrigger savedTriggerForVendor:device defaults:NSUserDefaults.standardUserDefaults];
    if (chosen) return chosen;
    // Nothing chosen yet. The default is the button iPadOS reserves, because
    // that is the one a game cannot bind — and it arrives as the system's own
    // screenshot signal. Tap to toggle only: a held reserved button is spent on
    // iOS's recording gesture, so there is no release for us to see.
    AKTrigger *fallback = [AKTrigger new];
    fallback.element = @"Share";
    fallback.pattern = AKTriggerPatternPress;
    return fallback;
}

- (void)setLearnedElement:(NSString *)element forDevice:(nullable NSString *)device {
    AKTrigger *trigger = [AKTrigger new];
    trigger.element = element;
    trigger.pattern = self.mode == AKVoiceModeHold ? AKTriggerPatternPushToTalk : AKTriggerPatternPress;
    [self setTrigger:trigger forDevice:device];
}

- (void)setTrigger:(AKTrigger *)trigger forDevice:(nullable NSString *)device {
    [trigger saveForVendor:device defaults:NSUserDefaults.standardUserDefaults];
    AKVSLog(@"voice: mapped %@ on %@", [trigger summary], device ?: @"any");
    [NSNotificationCenter.defaultCenter postNotificationName:AKVoiceSettingsDidChangeNotification
                                                      object:self];
}

- (NSString *)mappingSummaryForDevice:(nullable NSString *)device {
    AKTrigger *saved = [AKTrigger savedTriggerForVendor:device defaults:NSUserDefaults.standardUserDefaults];
    if (!saved) return @"Not set";
    return [saved summary];
}

@end
