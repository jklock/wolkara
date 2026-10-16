// Wolkara: the config file, in full.
//
// The file is an import boundary. It lives in Documents, which the user can reach
// through Files, and it is read at launch into NSUserDefaults, which is what the rest
// of the app trusts. The 2026-10-16 audit was right that the old version read whatever
// it found: a malformed trigger dictionary could create a pattern that indexes off the
// end of a table, and the version number was written but never checked.
//
// So every value is checked against a schema before any of it is applied, a file that
// fails is kept as `.rejected` rather than silently ignored, the write goes through a
// temporary file with the previous good copy kept beside it, and writes are coalesced
// so a burst of defaults changes is one file, not thirty.

#import "WolkaraConfig.h"
#import "../Input/Trigger.h"
#import "../App/WolkaraLog.h"

#import <UIKit/UIKit.h>

// The choices the launcher and the voice layer own. Anything else in the defaults
// database is either the system's business or a request that has already been served
// (an install or repair asked for, and since carried out).
static NSArray<NSString *> *TKWolkaraConfigKeys(void) {
    return @[@"WoWProduct", @"WoWRegion", @"WoWLocale",
             @"AKVoiceEnabled", @"AKVoiceMode", @"AKVoiceAutoSubmit",
             @"AKVoiceTrailingSpace", @"AKVoiceCustomWords"];
}

// One mapping per controller, so the key carries an identity we cannot know in advance.
static NSString *const TKWolkaraConfigTriggerPrefix = @"AKInputTrigger.";

// Bumped when the shape of the file changes. A file from the future is refused rather
// than half-read.
static NSInteger const TKWolkaraConfigVersion = 1;

// Bounds. Anything outside these is a corrupt file, not a preference.
static NSUInteger const TKWolkaraConfigWordLimit = 512;
static NSUInteger const TKWolkaraConfigWordLength = 64;
static NSUInteger const TKWolkaraConfigStringLimit = 64;

@implementation TKWolkaraConfig {
    BOOL _loaded;
    BOOL _writing;
    BOOL _writeScheduled;
    // One attempt at the previous good copy per launch. See -rejectFileBecause:.
    BOOL _recoveredFromBackup;
    dispatch_queue_t _queue;
    NSString *_lastImportProblem;
}

+ (instancetype)shared {
    static TKWolkaraConfig *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [TKWolkaraConfig new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("local.wolkara.config", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSString *)path {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"wolkara-config.json"];
}

- (NSString *)backupPath { return [self.path stringByAppendingPathExtension:@"bak"]; }
- (NSString *)rejectedPath { return [self.path stringByAppendingPathExtension:@"rejected"]; }
- (nullable NSString *)lastImportProblem { return _lastImportProblem; }

#pragma mark - The schema

// One entry per key we own: what type it is, and what counts as a value.
static NSDictionary<NSString *, NSDictionary *> *TKWolkaraConfigSchema(void) {
    static NSDictionary *schema;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        schema = @{
            @"WoWProduct": @{@"kind": @"slug"},
            @"WoWRegion": @{@"kind": @"enum", @"values": @[@"eu", @"us", @"kr", @"tw"]},
            @"WoWLocale": @{@"kind": @"enum", @"values": @[@"enUS", @"esES"]},
            @"AKVoiceEnabled": @{@"kind": @"bool"},
            @"AKVoiceMode": @{@"kind": @"int", @"min": @0, @"max": @1},
            @"AKVoiceAutoSubmit": @{@"kind": @"bool"},
            @"AKVoiceTrailingSpace": @{@"kind": @"bool"},
            @"AKVoiceCustomWords": @{@"kind": @"words"},
        };
    });
    return schema;
}

// A JSON boolean arrives as an NSNumber whose type is BOOL or char; 0 and 1 arrive as
// plain integers. A bool key accepts either spelling, because an older file may hold
// one and a hand-edited file may hold the other.
+ (BOOL)isBoolean:(id)value {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if ([self isBooleanTyped:value]) return YES;
    double number = [(NSNumber *)value doubleValue];
    return number == 0 || number == 1;
}

// Whether the number is a boolean *and not a number*: this is what an int key has to
// reject, and 0 and 1 are not it. Caught by the suite: a mode of 1 was being refused
// as "not a number", which would have silently dropped a valid setting.
+ (BOOL)isBooleanTyped:(id)value {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    const char *type = ((NSNumber *)value).objCType;
    return type && (strcmp(type, @encode(BOOL)) == 0 || strcmp(type, "c") == 0 || strcmp(type, "B") == 0);
}

+ (nullable id)validatedValue:(id)value forKey:(NSString *)key problem:(NSString **)problem {
    if ([key hasPrefix:TKWolkaraConfigTriggerPrefix]) {
        NSDictionary *validated = [AKTrigger validatedStoredForm:value];
        if (!validated) { *problem = @"a controller mapping is not readable"; return nil; }
        return validated;
    }
    NSDictionary *rule = TKWolkaraConfigSchema()[key];
    if (!rule) { *problem = @"the key is not one we own"; return nil; }
    NSString *kind = rule[@"kind"];

    if ([kind isEqualToString:@"slug"]) {
        if (![value isKindOfClass:NSString.class]) { *problem = @"not a string"; return nil; }
        NSString *text = value;
        if (!text.length || text.length > TKWolkaraConfigStringLimit) { *problem = @"the wrong length"; return nil; }
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789_"];
        if ([text rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) { *problem = @"not a name"; return nil; }
        return text;
    }
    if ([kind isEqualToString:@"enum"]) {
        if (![value isKindOfClass:NSString.class] || ![rule[@"values"] containsObject:value]) {
            *problem = @"not one of the values we know"; return nil;
        }
        return value;
    }
    if ([kind isEqualToString:@"bool"]) {
        if (![TKWolkaraConfig isBoolean:value]) { *problem = @"not a boolean"; return nil; }
        return @([value boolValue]);
    }
    if ([kind isEqualToString:@"int"]) {
        if (![value isKindOfClass:NSNumber.class] || [TKWolkaraConfig isBooleanTyped:value]) { *problem = @"not a number"; return nil; }
        double number = [value doubleValue];
        if (number < [rule[@"min"] doubleValue] || number > [rule[@"max"] doubleValue]) { *problem = @"out of range"; return nil; }
        return @((NSInteger)number);
    }
    if ([kind isEqualToString:@"words"]) {
        if (![value isKindOfClass:NSArray.class]) { *problem = @"not a list"; return nil; }
        NSMutableArray<NSString *> *words = [NSMutableArray array];
        for (id entry in (NSArray *)value) {
            if (![entry isKindOfClass:NSString.class]) { *problem = @"a word is not a word"; return nil; }
            NSString *word = [entry stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!word.length || word.length > TKWolkaraConfigWordLength) { *problem = @"a word is the wrong length"; return nil; }
            if (words.count >= TKWolkaraConfigWordLimit) { *problem = @"too many words"; return nil; }
            if (![words containsObject:word]) [words addObject:word];
        }
        return words;
    }
    *problem = @"the rule for this key is not one we know";
    return nil;
}

+ (BOOL)ownsKey:(NSString *)key {
    return [TKWolkaraConfigSchema() objectForKey:key] != nil ||
           [key hasPrefix:TKWolkaraConfigTriggerPrefix];
}

// The whole file, checked before any of it is applied. Nothing is half-read: a value
// that fails its rule is left out and described, and the rest of the file still stands.
+ (NSDictionary<NSString *, id> *)validatedSettingsFromFile:(nullable NSDictionary *)file
                                                    problem:(NSString *_Nullable *_Nullable)problem {
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    NSMutableDictionary<NSString *, id> *accepted = [NSMutableDictionary dictionary];
    if (problem) *problem = nil;
    if (![file isKindOfClass:NSDictionary.class]) {
        if (problem) *problem = @"it is not a JSON object";
        return accepted;
    }
    NSNumber *version = [file[@"version"] isKindOfClass:NSNumber.class] ? file[@"version"] : nil;
    if (!version) {
        if (problem) *problem = @"it has no version";
        return accepted;
    }
    if (version.integerValue > TKWolkaraConfigVersion) {
        if (problem) *problem = [NSString stringWithFormat:@"it was written by a newer version (%@)", version];
        return accepted;
    }
    NSDictionary *settings = [file[@"settings"] isKindOfClass:NSDictionary.class] ? file[@"settings"] : nil;
    if (!settings) {
        if (problem) *problem = @"it has no settings";
        return accepted;
    }
    for (NSString *key in settings) {
        if (![TKWolkaraConfig ownsKey:key]) {
            [problems addObject:[NSString stringWithFormat:@"%@ (not a key we own)", key]];
            continue;
        }
        NSString *why = nil;
        id value = [TKWolkaraConfig validatedValue:settings[key] forKey:key problem:&why];
        if (!value) {
            [problems addObject:[NSString stringWithFormat:@"%@ (%@)", key, why ?: @"refused"]];
            continue;
        }
        accepted[key] = value;
    }
    if (problems.count && problem)
        *problem = [NSString stringWithFormat:@"%lu setting(s) were refused: %@",
                    (unsigned long)problems.count, [problems componentsJoinedByString:@", "]];
    return accepted;
}

#pragma mark - Reading it back

- (void)load {
    if (_loaded) return;
    _loaded = YES;
    [self importFromFile];
    // From here on the file follows the running app, including changes made by code
    // that knows nothing about this class.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(defaultsChanged:)
        name:NSUserDefaultsDidChangeNotification object:nil];
    // A write started by a defaults change is delayed; going away must not lose it.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(save)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    // Write it out now, so a first run already has the file to fall back on.
    [self save];
}

- (void)reloadFromFile {
    // The observers are left alone: this is a re-read, not a second launch.
    [self importFromFile];
}

- (void)importFromFile {
    NSData *data = [NSData dataWithContentsOfFile:self.path];
    if (!data.length) {
        WKLog("config", @"no file yet at %@", self.path);
        return;
    }
    NSError *error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![parsed isKindOfClass:NSDictionary.class]) {
        [self rejectFileBecause:[NSString stringWithFormat:@"it is not readable: %@", error.localizedDescription ?: @"not JSON"]];
        return;
    }
    NSString *problem = nil;
    NSDictionary<NSString *, id> *settings = [TKWolkaraConfig validatedSettingsFromFile:parsed problem:&problem];
    if (!settings.count && problem) {
        // Nothing at all could be used: the shape of the file is wrong, not one value
        // in it. Kept, and the last good copy is tried.
        [self rejectFileBecause:problem];
        return;
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // The file is the durable copy, so a valid value in it wins over what is in the
    // database. It is read once, at launch, before anything can change it.
    NSUInteger restored = [TKWolkaraConfig applySettings:settings toDefaults:defaults];
    _lastImportProblem = problem;
    if (problem) WKLog("config", @"%@", problem);
    WKLog("config", @"restored %lu choice(s) from %@", (unsigned long)restored, self.path.lastPathComponent);
}

+ (NSUInteger)applySettings:(NSDictionary<NSString *, id> *)settings toDefaults:(NSUserDefaults *)defaults {
    NSUInteger applied = 0;
    for (NSString *key in settings) {
        if ([settings[key] isEqual:[defaults objectForKey:key]]) continue;
        [defaults setObject:settings[key] forKey:key];
        applied++;
    }
    return applied;
}

// A file we could not read is kept, not overwritten: it is the user's, it may hold
// something they want, and the next save would otherwise destroy the evidence.
//
// The previous good copy is tried once, and it is *validated before it is used*. The
// first version copied it over the primary and re-read the file, which meant a malformed
// primary beside an unusable-but-readable backup went round that loop until the stack ran
// out - both files are reachable from the user-editable Documents boundary. Now the
// backup has to pass the same schema as any other file, and the values are applied
// directly, so there is no second read to recurse through.
- (void)rejectFileBecause:(NSString *)reason {
    _lastImportProblem = [NSString stringWithFormat:@"%@ was not used: %@", self.path.lastPathComponent, reason];
    WKLog("config", @"%@", _lastImportProblem);
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtPath:self.rejectedPath error:NULL];
    if (![files copyItemAtPath:self.path toPath:self.rejectedPath error:NULL])
        WKLog("config", @"could not keep a copy of the refused file");

    if (_recoveredFromBackup) {
        WKLog("config", @"the previous copy has already been tried once this launch");
        return;
    }
    _recoveredFromBackup = YES;

    NSData *backup = [NSData dataWithContentsOfFile:self.backupPath];
    if (!backup.length) {
        WKLog("config", @"there is no previous copy to fall back on");
        return;
    }
    id parsed = [NSJSONSerialization JSONObjectWithData:backup options:0 error:NULL];
    NSString *why = nil;
    NSDictionary<NSString *, id> *settings = [TKWolkaraConfig validatedSettingsFromFile:parsed problem:&why];
    if (!settings.count) {
        WKLog("config", @"the previous copy is not usable either (%@); nothing was applied", why ?: @"empty");
        return;
    }
    // Put the good copy back where the app reads it, and apply it here rather than by
    // re-reading: one path, no recursion.
    if (![backup writeToFile:self.path atomically:YES]) {
        WKLog("config", @"could not put the previous copy back");
        return;
    }
    NSUInteger restored = [TKWolkaraConfig applySettings:settings toDefaults:NSUserDefaults.standardUserDefaults];
    WKLog("config", @"recovered %lu choice(s) from the previous copy", (unsigned long)restored);
}

#pragma mark - Writing it out

- (void)defaultsChanged:(NSNotification *)note {
    (void)note;
    // Coalesced. NSUserDefaultsDidChangeNotification fires for every unrelated change
    // as well, and the old code rewrote the whole file, on the calling thread, each
    // time. A burst now becomes one write, on the config's own queue.
    @synchronized (self) {
        if (_writeScheduled) return;
        _writeScheduled = YES;
    }
    __weak TKWolkaraConfig *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), _queue, ^{
        TKWolkaraConfig *strongSelf = weakSelf;
        if (!strongSelf) return;
        @synchronized (strongSelf) { strongSelf->_writeScheduled = NO; }
        [strongSelf writeFile];
    });
}

- (void)save {
    @synchronized (self) { _writeScheduled = NO; }
    [self writeFile];
}

- (void)writeFile {
    @synchronized (self) {
        if (_writing) return;
        _writing = YES;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    for (NSString *key in TKWolkaraConfigKeys()) {
        id value = [defaults objectForKey:key];
        if (!value) continue;
        NSString *problem = nil;
        // What we write is validated by the same rules as what we read, so the file can
        // never contain something the next launch would refuse.
        id validated = [TKWolkaraConfig validatedValue:value forKey:key problem:&problem];
        if (!validated) {
            WKLog("config", @"%@ is not written out: %@", key, problem ?: @"refused");
            continue;
        }
        settings[key] = validated;
    }
    for (NSString *key in defaults.dictionaryRepresentation) {
        if (![key hasPrefix:TKWolkaraConfigTriggerPrefix]) continue;
        id value = [defaults objectForKey:key];
        if (!value) continue;
        NSString *problem = nil;
        id validated = [TKWolkaraConfig validatedValue:value forKey:key problem:&problem];
        if (!validated) {
            WKLog("config", @"%@ is not written out: %@", key, problem ?: @"refused");
            continue;
        }
        settings[key] = validated;
    }

    NSDictionary *file = @{@"version": @(TKWolkaraConfigVersion), @"settings": settings};
    if (![NSJSONSerialization isValidJSONObject:file]) {
        WKLog("config", @"a choice is not writable as JSON; the file is unchanged");
        @synchronized (self) { _writing = NO; }
        return;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:file
        options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys) error:&error];
    if (!data) {
        WKLog("config", @"could not serialise the config (%@)", error.localizedDescription);
        @synchronized (self) { _writing = NO; }
        return;
    }

    // Temporary file, then an atomic replacement. The first version removed the primary
    // and then moved the temporary over the gap, so a termination or a failed move
    // between those two steps left no config file at all - and the previous copy that
    // this class falls back to only exists after a second save. The old file now stays
    // where it is until the new one is committed.
    NSString *temporary = [self.path stringByAppendingPathExtension:@"writing"];
    NSFileManager *files = NSFileManager.defaultManager;
    if (![data writeToFile:temporary options:NSDataWritingAtomic error:&error]) {
        WKLog("config", @"could not write %@ (%@)", temporary.lastPathComponent, error.localizedDescription);
        @synchronized (self) { _writing = NO; }
        return;
    }
    NSURL *destination = [NSURL fileURLWithPath:self.path];
    if ([files fileExistsAtPath:self.path]) {
        // The previous file is kept as .bak before it is replaced: that is what the
        // recovery path above reads.
        [files removeItemAtPath:self.backupPath error:NULL];
        [files copyItemAtPath:self.path toPath:self.backupPath error:NULL];
        NSError *replaceError = nil;
        if (![files replaceItemAtURL:destination
                       withItemAtURL:[NSURL fileURLWithPath:temporary]
                      backupItemName:nil options:0 resultingItemURL:NULL error:&replaceError]) {
            WKLog("config", @"could not replace %@ (%@); the previous file is untouched",
                  self.path.lastPathComponent, replaceError.localizedDescription);
            [files removeItemAtPath:temporary error:NULL];
        }
    } else if (![files moveItemAtPath:temporary toPath:self.path error:&error]) {
        WKLog("config", @"could not put %@ in place (%@)", self.path.lastPathComponent, error.localizedDescription);
        [files removeItemAtPath:temporary error:NULL];
    }
    @synchronized (self) { _writing = NO; }
}

@end
