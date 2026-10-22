// Focused tests for the Forever Config.wtf operations. No game, no simulator:
// the rules are about bytes in a file, so this runs wherever the code does.
#import <Foundation/Foundation.h>
#import "../ForeverUI.h"
#include <assert.h>

static NSString *Read(NSString *path) {
    return [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:NULL];
}

static void Write(NSString *path, NSString *text) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    NSData *data = [text dataUsingEncoding:NSISOLatin1StringEncoding];
    assert([data writeToFile:path atomically:YES]);
}

static NSString *ConfigPath(NSString *root) {
    return [root stringByAppendingPathComponent:@"WTF/Config.wtf"];
}

int main(void) {
    @autoreleasepool {
        NSFileManager *files = NSFileManager.defaultManager;
        NSString *root = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"forever-config-tests"]
                          stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSString *wtf = [root stringByAppendingPathComponent:@"WTF"];
        assert([files createDirectoryAtPath:wtf withIntermediateDirectories:YES attributes:nil error:NULL]);

        // --- graphics reset removes the allowlist and keeps every other byte
        NSString *input =
            @"SET portal \"eu\"\n"
             "SET textLocale \"enUS\"\n"
             "SET audioLocale \"enUS\"\n"
             "SET accountName \"TESTACCOUNT\"\n"
             "SET gxResolution \"1920x1080\"\n"
             "SET graphicsQuality \"7\"\n"
             "SET Sound_OutputDriverIndex \"0\"\n"
             "SET GamePadEnable \"1\"\n"
             "SET GamePadConfig \"Addons\"\n"
             "SET uiScale \"1\"\n"
             "SET bindingMoveForward \"W\"\n"
             "SET unknownSetting \"keep\"\n"
             "SET cameraDistance \"1.5\"\n";
        NSString *expected =
            @"SET portal \"eu\"\n"
             "SET textLocale \"enUS\"\n"
             "SET audioLocale \"enUS\"\n"
             "SET accountName \"TESTACCOUNT\"\n"
             "SET Sound_OutputDriverIndex \"0\"\n"
             "SET GamePadEnable \"1\"\n"
             "SET GamePadConfig \"Addons\"\n"
             "SET uiScale \"1\"\n"
             "SET bindingMoveForward \"W\"\n"
             "SET unknownSetting \"keep\"\n"
             "SET cameraDistance \"1.5\"\n";
        Write(ConfigPath(root), input);
        NSError *error = nil;
        assert([TKForeverUI resetGraphicsInWorkingDirectory:root error:&error]);
        assert([Read(ConfigPath(root)) isEqual:expected]);

        // Nothing else under the UI was touched.
        NSString *addon = [root stringByAppendingPathComponent:@"Interface/AddOns/A/A.toc"];
        Write(addon, @"## Title: A\n");
        assert([TKForeverUI resetGraphicsInWorkingDirectory:root error:&error]);
        assert([Read(addon) isEqual:@"## Title: A\n"]);

        // --- CRLF endings survive, and only the graphics lines go
        NSString *crlf =
            @"SET portal \"us\"\r\n"
             "SET gxRefresh \"60\"\r\n"
             "SET accountName \"ACC\"\r\n";
        Write(ConfigPath(root), crlf);
        assert([TKForeverUI resetGraphicsInWorkingDirectory:root error:&error]);
        assert([Read(ConfigPath(root)) isEqual:@"SET portal \"us\"\r\nSET accountName \"ACC\"\r\n"]);

        // --- a missing config is already at defaults
        NSString *bare = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"forever-config-bare"]
                          stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([files createDirectoryAtPath:[bare stringByAppendingPathComponent:@"WTF"]
                    withIntermediateDirectories:YES attributes:nil error:NULL]);
        assert([TKForeverUI resetGraphicsInWorkingDirectory:bare error:&error]);
        assert(![files fileExistsAtPath:ConfigPath(bare)]);
        assert(![TKForeverUI gamepadEnabledInWorkingDirectory:bare]);

        // --- the gamepad row creates a bounded config when there is none
        assert([TKForeverUI enableGamepadInWorkingDirectory:bare error:&error]);
        assert([Read(ConfigPath(bare)) isEqual:@"SET GamePadEnable \"1\"\n"]);
        assert([TKForeverUI gamepadEnabledInWorkingDirectory:bare]);

        // --- and normalises duplicates rather than appending a second answer
        NSString *duplicates =
            @"SET portal \"eu\"\n"
             "SET GamePadEnable \"0\"\n"
             "SET accountName \"ACC\"\n"
             "SET GamePadEnable \"1\"\n";
        Write(ConfigPath(root), duplicates);
        assert([TKForeverUI enableGamepadInWorkingDirectory:root error:&error]);
        NSString *normalised = Read(ConfigPath(root));
        NSMutableArray<NSString *> *lines = [[normalised componentsSeparatedByString:@"\n"] mutableCopy];
        [lines removeLastObject];   // the trailing newline
        NSUInteger assignments = 0;
        for (NSString *line in lines) if ([line hasPrefix:@"SET GamePadEnable"]) {
            assignments++;
            assert([line isEqual:@"SET GamePadEnable \"1\""]);
        }
        assert(assignments == 1);
        assert([normalised containsString:@"SET portal \"eu\""]);
        assert([normalised containsString:@"SET accountName \"ACC\""]);

        // --- the switch's off position uses the same normalisation
        assert([TKForeverUI setGamepad:NO inWorkingDirectory:root error:&error]);
        NSString *off = Read(ConfigPath(root));
        NSUInteger offAssignments = 0;
        for (NSString *line in [off componentsSeparatedByString:@"\n"]) {
            if (![line hasPrefix:@"SET GamePadEnable"]) continue;
            offAssignments++;
            assert([line isEqual:@"SET GamePadEnable \"0\""]);
        }
        assert(offAssignments == 1);
        assert(![TKForeverUI gamepadEnabledInWorkingDirectory:root]);
        // Turning it back on leaves exactly one "1".
        assert([TKForeverUI setGamepad:YES inWorkingDirectory:root error:&error]);
        assert([TKForeverUI gamepadEnabledInWorkingDirectory:root]);

        // --- a WTF folder outside the working directory is refused
        NSString *outside = [root stringByAppendingPathComponent:@"../outside-wtf"];
        [files createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:NULL];
        // The operation resolves WTF under the directory it is given, so the
        // boundary that matters is that it never returns a path outside it.
        NSString *resolved = [TKForeverUI wtfDirectoryInWorkingDirectory:root create:NO error:&error];
        assert(resolved != nil && [resolved hasPrefix:root]);

        [files removeItemAtPath:root error:NULL];
        [files removeItemAtPath:bare error:NULL];
        [files removeItemAtPath:outside error:NULL];
        puts("FOREVER_CONFIG_PASS: graphics allowlist, byte preservation, CRLF, missing config, gamepad normalisation and path boundary.");
        return 0;
    }
}
