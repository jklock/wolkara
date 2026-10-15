// Native CDN probe, sharing the iOS launcher's implementation. No installed-game writes.
#import <Foundation/Foundation.h>
#import "../launcher/WoW/Client.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc!=4 && argc!=6) {
            fprintf(stderr,"Usage: wow_cdn PRODUCT REGION OUTPUT_DIRECTORY [--stage INSTALL_PATH]\n");
            return 2;
        }
        NSString *product=@(argv[1]), *region=@(argv[2]), *directory=@(argv[3]);
        if (argc==6 && strcmp(argv[4],"--stage")) return 2;
        TKWoWClient *client=[TKWoWClient new]; NSError *error=nil;
        NSDictionary *plan=[client planForProduct:product region:region locale:@"enUS" error:&error];
        if (!plan) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1; }
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1;
        }
        NSData *json=[NSJSONSerialization dataWithJSONObject:plan options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
        if (!json || ![json writeToFile:[directory stringByAppendingPathComponent:@"plan.json"] options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1;
        }
        printf("Verified %s %s: %lu macOS install files, %llu bytes (excludes CASC game data).\n",
            product.UTF8String,[plan[@"version"][@"VersionsName"] UTF8String],(unsigned long)[plan[@"files"] count],
            [plan[@"installFileBytes"] unsignedLongLongValue]); fflush(stdout);
        if (argc==6) {
            NSDictionary *selected=nil;
            for (NSDictionary *file in plan[@"files"]) if ([file[@"path"] isEqualToString:@(argv[5])]) selected=file;
            if (!selected) { fprintf(stderr,"Requested file is absent from the macOS plan.\n"); return 1; }
            printf("Downloading encoding metadata and original file; no installation is modified.\n"); fflush(stdout);
            NSString *path=[client stageFile:selected plan:plan directory:directory error:&error];
            if (!path) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 1; }
            printf("Verified original saved to %s\n",path.UTF8String);
        }
        printf("This is a verified download plan, not a complete or playable installation.\n");
    }
    return 0;
}
