#import "Installation.h"
#import "Manifest.h"

@implementation TKWoWInstallation
@end

TKWoWInstallation *TKWoWInspectInstallation(TKAppLibrary *library, NSDictionary *product, NSDictionary *plan) {
    TKWoWInstallation *result=[TKWoWInstallation new];
    result.state=TKWoWInstallationMissing;
    for (TKApp *app in library.apps) {
        if (app.source!=TKAppSourceDocuments || ![app.workingDirectory.lastPathComponent isEqual:product[@"folder"]]) continue;
        result.state=TKWoWInstallationNeedsRepair; result.app=app;
        NSError *error=nil;
        NSString *directory=[library workingDirectoryForApp:app error:&error];
        NSString *path=[library executablePathForApp:app error:&error];
        if (!directory || !path) { result.error=error; return result; }
        NSString *info=[directory.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".build.info"];
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:info error:&error];
        if (!attributes || [attributes[NSFileSize] unsignedLongLongValue]>2*1024*1024) {
            result.error=error?:TKWoWError(@"Missing or oversized installation metadata."); return result;
        }
        NSData *data=[NSData dataWithContentsOfFile:info options:0 error:&error];
        NSArray *rows=data?TKWoWTable(data,&error):nil;
        if (!rows) { result.error=error; return result; }
        NSDictionary *match=nil;
        for (NSDictionary *row in rows) if ([row[@"Product"] isEqual:product[@"id"]] && [row[@"Active"] isEqual:@"1"]) {
            if (match) { result.error=TKWoWError(@"Ambiguous installed build."); return result; }
            match=row;
        }
        if (!match || !TKWoWHashValid(match[@"Build Key"]) || !TKWoWHashValid(match[@"CDN Key"]) || ![match[@"Version"] length]) {
            result.error=TKWoWError(@"No valid installed build metadata."); return result;
        }
        result.installedVersion=match[@"Version"];
        if (!TKWoWBuildCurrent(rows,product[@"id"],plan[@"version"])) {
            result.state=TKWoWInstallationOutdated; return result;
        }
        NSString *prefix=[directory stringByAppendingString:@"/"];
        if (![path hasPrefix:prefix]) { result.error=TKWoWError(@"Executable is outside the edition folder."); return result; }
        NSString *relative=[path substringFromIndex:prefix.length];
        for (NSDictionary *file in plan[@"files"]) if ([file[@"path"] isEqual:relative]) {
            attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:&error];
            uint64_t size=[attributes[NSFileSize] unsignedLongLongValue];
            if (!attributes || size>256*1024*1024 || size!=[file[@"size"] unsignedLongLongValue]) break;
            NSData *original=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&error];
            if (original && [TKWoWMD5(original) isEqual:file[@"contentKey"]]) {
                result.state=TKWoWInstallationReady; result.app=app; return result;
            }
            break;
        }
        result.error=error?:TKWoWError(@"The original executable does not match the published build.");
        return result;
    }
    return result;
}
