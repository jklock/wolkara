// Our own files and duck-typed library. No application binaries or accounts.
#import "../launcher/WoW/Installation.h"
#import "../launcher/WoW/Manifest.h"
#include <assert.h>

@interface TKFixtureApp : NSObject
@property(nonatomic) TKAppSource source;
@property(nonatomic, copy) NSString *workingDirectory;
@end
@implementation TKFixtureApp
@end

@interface TKFixtureLibrary : NSObject
@property(nonatomic, copy) NSString *root;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, copy) NSString *executable;
@property(nonatomic, copy) NSArray *apps;
@property(nonatomic, strong) NSData *bytes;
- (NSArray *)discover;
- (NSString *)workingDirectoryForApp:(id)app error:(NSError **)error;
- (NSString *)executablePathForApp:(id)app error:(NSError **)error;
- (NSDictionary *)planForProduct:(NSString *)product revision:(NSUInteger)revision;
- (void)writeMetadata:(NSUInteger)revision duplicate:(BOOL)duplicate;
@end
@implementation TKFixtureLibrary
- (instancetype)init {
    if (!(self=[super init])) return nil;
    _root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    _directory=[_root stringByAppendingPathComponent:@"_classic_beta_"];
    _executable=[_directory stringByAppendingPathComponent:@"Synthetic.app/Contents/MacOS/Synthetic"];
    assert([NSFileManager.defaultManager createDirectoryAtPath:_executable.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL]);
    _bytes=[@"our own synthetic executable fixture" dataUsingEncoding:NSUTF8StringEncoding];
    assert([_bytes writeToFile:_executable atomically:YES]);
    TKFixtureApp *app=[TKFixtureApp new]; app.source=TKAppSourceDocuments; app.workingDirectory=@"_classic_beta_";
    _apps=@[app]; [self writeMetadata:0 duplicate:NO]; return self;
}
- (NSArray *)discover { return @[]; }
- (NSString *)workingDirectoryForApp:(id)app error:(NSError **)error { (void)app; (void)error; return _directory; }
- (NSString *)executablePathForApp:(id)app error:(NSError **)error { (void)app; (void)error; return _executable; }
- (NSDictionary *)planForProduct:(NSString *)product revision:(NSUInteger)revision {
    NSString *version=[NSString stringWithFormat:@"1.60.1.%lu (demo)",(unsigned long)revision];
    return @{@"product":product,@"version":@{@"VersionsName":version,
        @"BuildConfig":TKWoWMD5([version dataUsingEncoding:NSUTF8StringEncoding]),
        @"CDNConfig":TKWoWMD5([@"synthetic CDN" dataUsingEncoding:NSUTF8StringEncoding])},
        @"files":@[@{@"path":@"Synthetic.app/Contents/MacOS/Synthetic",@"size":@(_bytes.length),@"contentKey":TKWoWMD5(_bytes)}]};
}
- (void)writeMetadata:(NSUInteger)revision duplicate:(BOOL)duplicate {
    NSDictionary *v=[self planForProduct:@"wow_classic_beta" revision:revision][@"version"];
    NSString *row=[NSString stringWithFormat:@"wow_classic_beta|1|%@|%@|%@\n",v[@"BuildConfig"],v[@"CDNConfig"],v[@"VersionsName"]];
    NSString *text=[@"Product|Active|Build Key|CDN Key|Version\n" stringByAppendingString:duplicate?[row stringByAppendingString:row]:row];
    assert([text writeToFile:[_root stringByAppendingPathComponent:@".build.info"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
}
- (void)dealloc { [NSFileManager.defaultManager removeItemAtPath:_root error:NULL]; }
@end
