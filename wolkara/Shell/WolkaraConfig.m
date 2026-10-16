// Wolkara: the config file, in full.

#import "WolkaraConfig.h"

#if __has_include("AKSupport.h")
#import "AKSupport.h"
#define TKConfigLog(...) AKLog(__VA_ARGS__)
#else
#define TKConfigLog(...) NSLog(@"[ak] %@", [NSString stringWithFormat:__VA_ARGS__])
#endif

// The choices the launcher and the voice layer own. Anything else in the defaults
// database is either the system's business or a request that has already been
// served (an install or repair asked for, and since carried out).
static NSArray<NSString *> *TKWolkaraConfigKeys(void) {
    return @[@"WoWProduct", @"WoWRegion", @"WoWLocale",
             @"AKVoiceMode", @"AKVoiceAutoSubmit", @"AKVoiceTrailingSpace",
             @"AKVoiceCustomWords"];
}

// One mapping per controller, so the key carries a name we cannot know in advance.
static NSString *const TKWolkaraConfigTriggerPrefix = @"AKInputTrigger.";

// Bumped when the shape of the file changes, so an older file can be recognised
// rather than misread.
static NSInteger const TKWolkaraConfigVersion = 1;

@implementation TKWolkaraConfig {
    BOOL _loaded;
    BOOL _saving;
}

+ (instancetype)shared {
    static TKWolkaraConfig *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [TKWolkaraConfig new]; });
    return shared;
}

- (NSString *)path {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"wolkara-config.json"];
}

#pragma mark - Reading it back

- (void)load {
    if (_loaded) return;
    _loaded = YES;
    [self importFromFile];
    // From here on the file follows the running app, including changes made by
    // code that knows nothing about this class.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(defaultsChanged:)
        name:NSUserDefaultsDidChangeNotification object:nil];
    // Write it out now, so a first run already has the file to fall back on.
    [self save];
}

- (void)importFromFile {
    NSData *data = [NSData dataWithContentsOfFile:self.path];
    if (!data.length) {
        TKConfigLog(@"config: no file yet at %@", self.path);
        return;
    }
    NSError *error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        TKConfigLog(@"config: %@ is not readable (%@); leaving the stored choices alone",
            self.path.lastPathComponent, error.localizedDescription);
        return;
    }
    NSDictionary *settings = ((NSDictionary *)parsed)[@"settings"];
    if (![settings isKindOfClass:NSDictionary.class]) {
        TKConfigLog(@"config: %@ has no settings; leaving the stored choices alone",
            self.path.lastPathComponent);
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSUInteger restored = 0;
    for (NSString *key in settings) {
        if (![self ownsKey:key]) continue;
        id value = settings[key];
        // A value already in the database was either written by this same import
        // or set on this run; the file is the durable copy, so it wins.
        if (![value isEqual:[defaults objectForKey:key]]) {
            [defaults setObject:value forKey:key];
            restored++;
        }
    }
    TKConfigLog(@"config: restored %lu choice(s) from %@", (unsigned long)restored, self.path.lastPathComponent);
}

- (BOOL)ownsKey:(NSString *)key {
    return [TKWolkaraConfigKeys() containsObject:key] || [key hasPrefix:TKWolkaraConfigTriggerPrefix];
}

#pragma mark - Writing it out

- (void)defaultsChanged:(NSNotification *)note {
    (void)note;
    [self save];
}

- (void)save {
    if (_saving) return;   // the write below is not itself a choice
    _saving = YES;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    for (NSString *key in TKWolkaraConfigKeys()) {
        id value = [defaults objectForKey:key];
        if (value) settings[key] = value;
    }
    for (NSString *key in defaults.dictionaryRepresentation) {
        if (![key hasPrefix:TKWolkaraConfigTriggerPrefix]) continue;
        id value = [defaults objectForKey:key];
        if (value) settings[key] = value;
    }
    NSDictionary *file = @{@"version": @(TKWolkaraConfigVersion), @"settings": settings};
    if (![NSJSONSerialization isValidJSONObject:file]) {
        TKConfigLog(@"config: a choice is not writable as JSON; the file is unchanged");
        _saving = NO;
        return;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:file
        options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys) error:&error];
    if (!data || ![data writeToFile:self.path atomically:YES]) {
        TKConfigLog(@"config: could not write %@ (%@)", self.path.lastPathComponent,
            error.localizedDescription ?: @"write failed");
        _saving = NO;
        return;
    }
    _saving = NO;
}

@end
