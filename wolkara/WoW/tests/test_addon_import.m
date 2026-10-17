#import "AddonStore.h"
#include <stdio.h>

#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL: %s (%s)\n", message, error.localizedDescription.UTF8String ?: "no error"); return 1; } } while (0)
int TestRealAddonImport(const char *fixtures, const char *temporary) {
    @autoreleasepool {
        NSString *root = [NSString stringWithUTF8String:temporary];
        NSString *directory = [root stringByAppendingPathComponent:@"Game/Interface/AddOns"];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;
        CHECK([fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error], "create sandbox");
        TKAddonStore *store = [[TKAddonStore alloc] initWithAddOnsDirectory:directory product:@"wow_classic_beta" gameVersion:@"1.60.1"];
        NSURL *zip = [NSURL fileURLWithPath:[[NSString stringWithUTF8String:fixtures] stringByAppendingPathComponent:@"valid.zip"]];
        CHECK([store importZIPAtURL:zip error:&error], "real Swift ZIP imports through Objective-C bridge");
        CHECK(store.records.count == 1 && store.records.firstObject.managed, "managed manifest survives reload");
        NSString *toc = [directory stringByAppendingPathComponent:@"Fixture/Fixture.toc"];
        NSData *before = [NSData dataWithContentsOfFile:toc];
        CHECK(![store importZIPAtURL:zip error:&error], "duplicate import refused");
        CHECK([before isEqual:[NSData dataWithContentsOfFile:toc]], "duplicate preserves original bytes");
        CHECK([store setDisabled:YES record:store.records.firstObject error:&error], "disable imported addon");
        CHECK(store.records.firstObject.disabled && ![fm fileExistsAtPath:toc], "disabled state");
        CHECK([store setDisabled:NO record:store.records.firstObject error:&error], "restore imported addon");
        CHECK([before isEqual:[NSData dataWithContentsOfFile:toc]], "restore preserves bytes");
        CHECK([store removeRecord:store.records.firstObject error:&error], "remove owned addon");
        CHECK(store.records.count == 0 && ![fm fileExistsAtPath:toc], "removed state");
        NSURL *bad = [NSURL fileURLWithPath:[[NSString stringWithUTF8String:fixtures] stringByAppendingPathComponent:@"corrupt.zip"]];
        NSString *support = [store valueForKey:@"support"];
        NSArray *jobsBefore = [fm contentsOfDirectoryAtPath:support error:&error];
        CHECK(![store importZIPAtURL:bad error:&error], "corrupt ZIP rejected by real store");
        NSArray *jobsAfter = [fm contentsOfDirectoryAtPath:support error:&error];
        CHECK([[NSSet setWithArray:jobsBefore] isEqual:[NSSet setWithArray:jobsAfter]], "failed extraction leaves no staging job");
        // Clean only this fixture's private support directory, never another import.
        CHECK([fm removeItemAtPath:support error:&error], "remove fixture staging and backups");
        puts("ADDON IMPORT PASS: real ZIP -> Objective-C bridge -> store -> duplicate/disable/restore/remove");
        return 0;
    }
}
