// The startup status lines: step, count, durations and the last file written.
#import "StartupActivityText.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        // No step yet: nothing; a step without parts stays as it is.
        assert(!TKStartupStepText(NULL, 0, 0));
        assert([TKStartupStepText("linking the app with system libraries", 0, 0) isEqualToString:@"linking the app with system libraries"]);
        // Counted parts use the reader's number grouping.
        NSString *counted = TKStartupStepText("running the app's startup code", 6012, 13287);
        NSString *expected = [NSString localizedStringWithFormat:@"running the app's startup code (%llu of %llu)", 6012ULL, 13287ULL];
        assert([counted isEqualToString:expected]);

        // Seconds, then minutes and seconds.
        assert([TKStartupActivityText(@"loading", 4.7, nil, 0, 0) isEqualToString:@"Now: loading · 4 s"]);
        assert([TKStartupActivityText(@"loading", 150, nil, 0, 0) isEqualToString:@"Now: loading · 2 min 30 s"]);
        assert([TKStartupActivityText(@"loading", -1, nil, 0, 0) isEqualToString:@"Now: loading · 0 s"]);
        assert([TKStartupActivityText(nil, 3, nil, 0, 0) isEqualToString:@""]);

        // The last file written: path, size and age on a second line.
        NSString *two = TKStartupActivityText(@"the app is running its own startup", 131,
            @"Errors/2026-09-27_18.55.04_Error_40749.txt", 344414, 1);
        NSArray<NSString *> *lines = [two componentsSeparatedByString:@"\n"];
        assert(lines.count == 2);
        assert([lines[0] isEqualToString:@"Now: the app is running its own startup · 2 min 11 s"]);
        NSString *size = [NSByteCountFormatter stringFromByteCount:344414 countStyle:NSByteCountFormatterCountStyleFile];
        NSString *written = [NSString stringWithFormat:@"Last file written: Errors/2026-09-27_18.55.04_Error_40749.txt · %@ · 1 s ago", size];
        assert([lines[1] isEqualToString:written]);
        // A file just created shows a number, not "Zero".
        NSString *empty = [[TKStartupActivityText(nil, 0, @"Logs/TestSuite.log", 0, 1) componentsSeparatedByString:@" · "] objectAtIndex:1];
        assert([empty hasPrefix:@"0"]);
        // Only a file, before any step.
        assert([TKStartupActivityText(nil, 0, @"Logs/gx.log", 10, 2) hasPrefix:@"Last file written: Logs/gx.log · "]);

        // A long path keeps its start and its file name, within 72 characters.
        NSString *deep = [[@"" stringByPaddingToLength:90 withString:@"folder/" startingAtIndex:0] stringByAppendingString:@"final-name.txt"];
        NSString *line = TKStartupActivityText(nil, 0, deep, 1, 0);
        NSString *shown = [[line substringFromIndex:@"Last file written: ".length] componentsSeparatedByString:@" · "][0];
        assert(shown.length == 72 && [shown hasPrefix:@"folder/folder/"] && [shown hasSuffix:@"final-name.txt"] && [shown containsString:@"…"]);
        NSString *exact = [@"" stringByPaddingToLength:72 withString:@"a" startingAtIndex:0];
        assert([TKStartupActivityText(nil, 0, exact, 1, 0) containsString:exact]);
    }
    puts("startup activity text: steps, counts, durations and last-written file pass");
    return 0;
}
