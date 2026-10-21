#import "ForeverUI.h"

NSErrorDomain const TKForeverUIErrorDomain = @"WolkaraForever.ForeverUI";
NSString *const TKForeverUIEdition = @"wow_classic_beta";

// A Config.wtf is a few kilobytes. Anything near this is not a config file, and
// reading it whole would be the wrong answer to a damaged one anyway.
static const NSUInteger TKForeverConfigLimit = 1024 * 1024;

static NSError *TKError(NSString *message) {
    return [NSError errorWithDomain:TKForeverUIErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSArray<NSString *> *TKTokens(NSString *line) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray new];
    for (NSString *token in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
        if (token.length) [tokens addObject:token];
    return tokens;
}

// The CVar name of a `SET name value` line, or nil for anything else. The name
// keeps its case; comparisons are case-insensitive, as the client's are.
static NSString *TKCVarName(NSString *line) {
    NSArray<NSString *> *tokens = TKTokens(line);
    if (tokens.count < 2 || ![tokens[0].uppercaseString isEqualToString:@"SET"]) return nil;
    return tokens[1];
}

// The value of a `SET name value` line with quotes removed, or nil.
static NSString *TKCVarValue(NSString *line) {
    NSArray<NSString *> *tokens = TKTokens(line);
    if (tokens.count < 3) return nil;
    NSString *value = tokens[2];
    if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""])
        value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
    return value;
}

static BOOL TKNameIs(NSString *name, NSString *expected) {
    return name && [name caseInsensitiveCompare:expected] == NSOrderedSame;
}

// The Forever graphics/display CVars a reset removes.
//
// This is an explicit list, not a prefix rule: the client owns far more
// settings than these, and a reset must never guess. Everything else - account,
// portal, locale, audio, UI, input, controller (GamePad*), cache, bindings,
// SavedVariables and any setting not named here - survives untouched. A CVar
// this list misses is preserved rather than guessed at, which is the safe way to
// be incomplete.
static NSSet<NSString *> *TKGraphicsCVars(void) {
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            // Display and renderer
            @"gxAdapter", @"gxApi", @"gxColorBits", @"gxDepthBits", @"gxCursor",
            @"gxFixLag", @"gxForegroundFPS", @"gxBackgroundFPS", @"gxFullscreenResolution",
            @"gxMaximize", @"gxMaxFrameLatency", @"gxMonitor", @"gxMSAA", @"gxMultisample",
            @"gxMultisampleQuality", @"gxRefresh", @"gxResolution", @"gxScreenshotFormat",
            @"gxTextureCacheSize", @"gxTripleBuffer", @"gxVSync", @"gxWindow",
            @"gxWindowedResolution",
            // Graphics quality
            @"graphicsQuality", @"graphicsTextureResolution", @"graphicsSpellDensity",
            @"graphicsViewDistance", @"graphicsGroundClutter", @"graphicsLiquidDetail",
            @"graphicsSunshafts", @"graphicsParticleDensity", @"graphicsShadowQuality",
            @"graphicsSSAO", @"graphicsDepthEffects", @"graphicsOutlineMode",
            @"graphicsComputeEffects", @"graphicsReflectionQuality", @"graphicsTextureFiltering",
            @"graphicsProjectedTextures", @"graphicsEnvironmentDetail", @"graphicsTripleBuffering",
            @"graphicsMSAA", @"graphicsResampleQuality", @"graphicsGammaAdjustment",
            @"graphicsContrast", @"graphicsBrightness", @"graphicsRaidFramerate",
        ]];
    });
    return set;
}

static BOOL TKInside(NSString *root, NSString *candidate) {
    NSString *canonicalRoot = [root stringByResolvingSymlinksInPath].stringByStandardizingPath;
    NSString *canonicalPath = [candidate stringByResolvingSymlinksInPath].stringByStandardizingPath;
    return [canonicalPath isEqualToString:canonicalRoot] ||
           [canonicalPath hasPrefix:[canonicalRoot stringByAppendingString:@"/"]];
}

static NSString *TKReadConfig(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;
    if (data.length > TKForeverConfigLimit) {
        if (error) *error = TKError(@"The game's configuration file is unexpectedly large.");
        return nil;
    }
    // Latin-1 maps every byte to one character, so splitting into lines and
    // joining them again reproduces the file byte for byte - including line
    // endings, comments and settings this code does not understand.
    NSString *text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!text) {
        if (error) *error = TKError(@"The game's configuration file is not readable text.");
        return nil;
    }
    return text;
}

static BOOL TKWriteConfig(NSString *path, NSString *text, NSError **error) {
    NSData *data = [text dataUsingEncoding:NSISOLatin1StringEncoding];
    if (!data) {
        if (error) *error = TKError(@"The game's configuration could not be written.");
        return NO;
    }
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

@implementation TKForeverUI

+ (nullable NSString *)wtfDirectoryInWorkingDirectory:(NSString *)directory
                                               create:(BOOL)create
                                                error:(NSError **)error {
    if (!directory.length) {
        if (error) *error = TKError(@"The game's working folder is not known.");
        return nil;
    }
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
        if (error) *error = TKError(@"The game's working folder is missing.");
        return nil;
    }
    NSString *wtf = [directory stringByAppendingPathComponent:@"WTF"];
    if (!TKInside(directory, wtf)) {
        if (error) *error = TKError(@"The game's settings folder is outside its working folder.");
        return nil;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:wtf]) {
        if (!create) {
            if (error) *error = TKError(@"The game's settings folder is missing. Start the game once.");
            return nil;
        }
        NSError *failure = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:wtf withIntermediateDirectories:NO
                                                      attributes:nil error:&failure]) {
            if (error) *error = failure ?: TKError(@"The game's settings folder could not be created.");
            return nil;
        }
    }
    return wtf;
}

+ (BOOL)enableGamepadInWorkingDirectory:(NSString *)directory error:(NSError **)error {
    NSString *wtf = [self wtfDirectoryInWorkingDirectory:directory create:YES error:error];
    if (!wtf) return NO;
    NSString *path = [wtf stringByAppendingPathComponent:@"Config.wtf"];
    if (!TKInside(directory, path)) {
        if (error) *error = TKError(@"The game's configuration is outside its working folder.");
        return NO;
    }

    NSString *text = nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
        text = TKReadConfig(path, error);
        if (!text) return NO;
    } else {
        // Absent config: create the one bounded document this action needs.
        text = @"";
    }

    NSMutableArray<NSString *> *kept = [NSMutableArray new];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (TKNameIs(TKCVarName(line), @"GamePadEnable")) continue;
        [kept addObject:line];
    }
    NSString *normalised = [kept componentsJoinedByString:@"\n"];
    if (normalised.length && ![normalised hasSuffix:@"\n"]) normalised = [normalised stringByAppendingString:@"\n"];
    normalised = [normalised stringByAppendingString:@"SET GamePadEnable \"1\"\n"];

    if (!TKWriteConfig(path, normalised, error)) return NO;

    // Re-read rather than trust the write: exactly one assignment, value 1.
    NSError *rereadError = nil;
    NSString *written = TKReadConfig(path, &rereadError);
    if (!written) {
        if (error) *error = rereadError;
        return NO;
    }
    NSUInteger assignments = 0;
    BOOL enabled = NO;
    for (NSString *line in [written componentsSeparatedByString:@"\n"]) {
        if (!TKNameIs(TKCVarName(line), @"GamePadEnable")) continue;
        assignments++;
        enabled = [TKCVarValue(line) isEqualToString:@"1"];
    }
    if (assignments != 1 || !enabled) {
        if (error) *error = TKError(@"The gamepad setting could not be stored.");
        return NO;
    }
    return YES;
}

+ (BOOL)gamepadEnabledInWorkingDirectory:(NSString *)directory {
    NSError *error = nil;
    NSString *wtf = [self wtfDirectoryInWorkingDirectory:directory create:NO error:&error];
    if (!wtf) return NO;
    NSString *path = [wtf stringByAppendingPathComponent:@"Config.wtf"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return NO;
    NSString *text = TKReadConfig(path, NULL);
    if (!text) return NO;
    NSUInteger assignments = 0;
    BOOL enabled = NO;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!TKNameIs(TKCVarName(line), @"GamePadEnable")) continue;
        assignments++;
        enabled = [TKCVarValue(line) isEqualToString:@"1"];
    }
    return assignments == 1 && enabled;
}

+ (BOOL)resetGraphicsInWorkingDirectory:(NSString *)directory error:(NSError **)error {
    NSString *wtf = [self wtfDirectoryInWorkingDirectory:directory create:NO error:error];
    if (!wtf) return NO;
    NSString *path = [wtf stringByAppendingPathComponent:@"Config.wtf"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return YES;   // nothing to reset
    NSString *text = TKReadConfig(path, error);
    if (!text) return NO;
    NSSet<NSString *> *graphics = TKGraphicsCVars();
    NSMutableArray<NSString *> *kept = [NSMutableArray new];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *name = TKCVarName(line);
        BOOL remove = NO;
        if (name) for (NSString *cvar in graphics) if (TKNameIs(name, cvar)) { remove = YES; break; }
        if (!remove) [kept addObject:line];
    }
    NSString *reset = [kept componentsJoinedByString:@"\n"];
    if ([reset isEqualToString:text]) return YES;
    return TKWriteConfig(path, reset, error);
}

#pragma mark - Archive bridge

static Class TKArchiveClass(NSError **error) {
    Class archive = NSClassFromString(@"TKForeverUIArchive");
    if (!archive) {
        if (error) *error = TKError(@"The backup component is not available in this build.");
        return Nil;
    }
    return archive;
}

+ (nullable NSString *)createUIBackupInWorkingDirectory:(NSString *)directory
                                               edition:(NSString *)edition
                                                 error:(NSError **)error {
    SEL selector = @selector(createBackupInWorkingDirectory:edition:error:);
    Class archive = TKArchiveClass(error);
    if (!archive || ![archive respondsToSelector:selector]) {
        if (archive && error) *error = TKError(@"The backup component cannot be used in this build.");
        return nil;
    }
    IMP implementation = [archive methodForSelector:selector];
    return ((NSString *(*)(id, SEL, NSString *, NSString *, NSError **))implementation)(archive, selector, directory, edition, error);
}

+ (nullable NSString *)newestUIBackupInWorkingDirectory:(NSString *)directory
                                                  error:(NSError **)error {
    SEL selector = @selector(newestBackupInWorkingDirectory:error:);
    Class archive = TKArchiveClass(error);
    if (!archive || ![archive respondsToSelector:selector]) {
        if (archive && error) *error = TKError(@"The backup component cannot be used in this build.");
        return nil;
    }
    IMP implementation = [archive methodForSelector:selector];
    return ((NSString *(*)(id, SEL, NSString *, NSError **))implementation)(archive, selector, directory, error);
}

+ (BOOL)restoreUIBackupNamed:(NSString *)name
          inWorkingDirectory:(NSString *)directory
                     edition:(NSString *)edition
                       error:(NSError **)error {
    SEL selector = @selector(restoreBackupNamed:inWorkingDirectory:edition:error:);
    Class archive = TKArchiveClass(error);
    if (!archive || ![archive respondsToSelector:selector]) {
        if (archive && error) *error = TKError(@"The backup component cannot be used in this build.");
        return NO;
    }
    IMP implementation = [archive methodForSelector:selector];
    return ((BOOL (*)(id, SEL, NSString *, NSString *, NSString *, NSError **))implementation)(
        archive, selector, name, directory, edition, error);
}

+ (BOOL)recoverInterruptedRestoreInWorkingDirectory:(NSString *)directory
                                             error:(NSError **)error {
    SEL selector = @selector(recoverInterruptedRestoreInWorkingDirectory:error:);
    Class archive = TKArchiveClass(error);
    if (!archive || ![archive respondsToSelector:selector]) {
        if (archive && error) *error = TKError(@"The backup component cannot be used in this build.");
        return NO;
    }
    IMP implementation = [archive methodForSelector:selector];
    return ((BOOL (*)(id, SEL, NSString *, NSError **))implementation)(archive, selector, directory, error);
}

@end
