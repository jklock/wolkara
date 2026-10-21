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
        // A removal that cannot write its record must not move anything. The state that loses
        // a package is folders moved aside while the record still claims them, so the record
        // is written first; making the add-on directory unwritable is what proves the order,
        // and the package has to be there and still be listed afterwards.
        CHECK([store importZIPAtURL:zip error:&error], "re-import for the removal checks");
        NSDictionary *permissions = [fm attributesOfItemAtPath:directory error:&error];
        CHECK([fm setAttributes:@{ NSFilePosixPermissions: @(0500) } ofItemAtPath:directory error:&error], "make the add-on directory unwritable");
        CHECK(![store removeRecord:store.records.firstObject error:&error], "removal refused when its record cannot be written");
        CHECK([fm fileExistsAtPath:toc], "and the package's folders are still there");
        CHECK([fm setAttributes:@{ NSFilePosixPermissions: permissions[NSFilePosixPermissions] } ofItemAtPath:directory error:&error], "put the directory back");
        CHECK(store.records.count == 1 && store.records.firstObject.managed, "and it is still listed as managed");
        CHECK([store removeRecord:store.records.firstObject error:&error], "removal works once it can write again");
        CHECK(store.records.count == 0 && ![fm fileExistsAtPath:toc], "and then removes it");
        // One previous copy per package, not one per removal: nothing reads that directory,
        // so a copy per removal was storage that grew for ever and could never be used.
        CHECK([store importZIPAtURL:zip error:&error], "re-import for the pruning check");
        CHECK([store removeRecord:store.records.firstObject error:&error], "remove a second time");
        NSString *previousRoot = [[store valueForKey:@"support"] stringByAppendingPathComponent:@"previous"];
        NSUInteger copies = 0;
        for (NSString *name in [fm contentsOfDirectoryAtPath:previousRoot error:&error]) if ([name hasPrefix:@"Fixture-"]) copies += 1;
        CHECK(copies == 1, "one previous copy is kept, not one per removal");
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
