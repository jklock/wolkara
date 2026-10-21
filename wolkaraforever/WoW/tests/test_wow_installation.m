#import "wow_installation_fixture.h"
int main(void) {
    @autoreleasepool {
        TKFixtureLibrary *fixture=[TKFixtureLibrary new];
        TKAppLibrary *library=(id)fixture;
        NSDictionary *product=TKWoWProducts()[0], *plan=[fixture planForProduct:product[@"id"] revision:0];
        NSArray *apps=fixture.apps; fixture.apps=@[];
        assert(TKWoWInspectInstallation(library,product,plan).state==TKWoWInstallationMissing);
        fixture.apps=apps;
        NSString *settings=[fixture.directory stringByAppendingPathComponent:@"Config.wtf"];
        assert([@"synthetic settings" writeToFile:settings atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        TKWoWInstallation *result=TKWoWInspectInstallation(library,product,plan);
        assert(result.state==TKWoWInstallationReady && result.app==(id)apps[0]);
        assert(TKWoWInspectInstallation(library,product,[fixture planForProduct:product[@"id"] revision:1]).state==TKWoWInstallationOutdated);
        [fixture writeMetadata:0 duplicate:YES];
        assert(TKWoWInspectInstallation(library,product,plan).state==TKWoWInstallationNeedsRepair);
        [fixture writeMetadata:0 duplicate:NO];
        assert([[@"changed" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:fixture.executable atomically:YES]);
        assert(TKWoWInspectInstallation(library,product,plan).state==TKWoWInstallationNeedsRepair);
        assert([fixture.bytes writeToFile:fixture.executable atomically:YES]);
        NSMutableData *changed=[fixture.bytes mutableCopy]; ((uint8_t *)changed.mutableBytes)[0]^=1;
        assert([changed writeToFile:fixture.executable atomically:YES]);
        assert(TKWoWInspectInstallation(library,product,plan).state==TKWoWInstallationNeedsRepair);
        assert([fixture.bytes writeToFile:fixture.executable atomically:YES]);
        NSString *saved=fixture.executable; fixture.executable=[fixture.root stringByAppendingPathComponent:@"outside"];
        assert(TKWoWInspectInstallation(library,product,plan).state==TKWoWInstallationNeedsRepair);
        fixture.executable=saved;
        assert([NSFileManager.defaultManager removeItemAtPath:[fixture.root stringByAppendingPathComponent:@".build.info"] error:NULL]);
        assert(TKWoWInspectInstallation(library,product,plan).state==TKWoWInstallationNeedsRepair);
        assert([[NSString stringWithContentsOfFile:settings encoding:NSUTF8StringEncoding error:NULL] isEqual:@"synthetic settings"]);
        assert([[NSData dataWithContentsOfFile:fixture.executable] isEqual:fixture.bytes]);
        puts("WoW installation PASS: missing, current, outdated, ambiguous/missing metadata, changed bytes, path bounds; no writes.");
    }
    return 0;
}
