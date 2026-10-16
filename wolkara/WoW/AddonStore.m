#import "AddonStore.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#import <objc/message.h>
#import "UpdateLock.h"

static NSString *const ManifestName=@".wolkara-addons.json";
static BOOL Fail(NSError **error, NSString *message) { if(error)*error=[NSError errorWithDomain:@"Wolkara.AddOns" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];return NO; }
static NSString *TOC(NSString *folder) {
    NSArray *names=[[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:NULL] sortedArrayUsingSelector:@selector(compare:)];
    for(NSString *name in names) if([name.pathExtension.lowercaseString isEqual:@"toc"]) {
        NSData *data=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:name] options:0 error:NULL];
        if(data.length && data.length<=256*1024) return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]?:[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    return nil;
}
static NSString *Value(NSString *toc,NSString *key) {
    for(NSString *line in [toc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) if([line hasPrefix:[@"## " stringByAppendingString:key]]) {
        NSString *value=[[line substringFromIndex:key.length+3] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(value.length&&value.length<512)return value;
    }
    return nil;
}
static NSString *Digest(NSData *data) { unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);NSMutableString *s=[NSMutableString new];for(NSUInteger i=0;i<sizeof(hash);i++)[s appendFormat:@"%02x",hash[i]];return s; }
static BOOL Managed(NSDictionary *item) { return [item[@"folders"] isKindOfClass:NSArray.class] && [item[@"identifier"] isKindOfClass:NSString.class]; }

@implementation TKAddonRecord
@end

@implementation TKAddonStore { NSString *_directory,*_product,*_version,*_support; NSArray<TKAddonRecord *> *_records; }
- (instancetype)initWithAddOnsDirectory:(NSString *)directory product:(NSString *)product gameVersion:(NSString *)version {
    if(!(self=[super init]))return nil;_directory=directory.copy;_product=product.copy;_version=version.copy?:@"unknown";
    NSString *base=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
    _support=[[[base stringByAppendingPathComponent:@"Wolkara/AddOns"] stringByAppendingPathComponent:_product] stringByAppendingPathComponent:Digest([directory dataUsingEncoding:NSUTF8StringEncoding])];[self reload];return self;
}
- (NSArray<TKAddonRecord *> *)records { return _records?:@[]; }
- (NSDictionary *)manifest {
    NSData *data=[NSData dataWithContentsOfFile:[_directory stringByAppendingPathComponent:ManifestName]];
    id value=data.length&&data.length<2*1024*1024?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    return [value isKindOfClass:NSDictionary.class]&&[value[@"format"] isEqual:@1]?[value copy]:@{ @"format":@1,@"packages":@[] };
}
- (BOOL)saveManifest:(NSArray *)packages error:(NSError **)error {
    NSDictionary *value=@{ @"format":@1,@"product":_product,@"gameVersion":_version,@"packages":packages };
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:error];
    return data&&[data writeToFile:[_directory stringByAppendingPathComponent:ManifestName] options:NSDataWritingAtomic error:error];
}
- (void)reload {
    NSDictionary *manifest=[self manifest];NSMutableDictionary *owned=[NSMutableDictionary new];
    for(id item in manifest[@"packages"])if([item isKindOfClass:NSDictionary.class]&&[item[@"identifier"] isKindOfClass:NSString.class])owned[item[@"identifier"]]=item;
    NSMutableArray *found=[NSMutableArray new];NSArray *names=[[NSFileManager.defaultManager contentsOfDirectoryAtPath:_directory error:NULL] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for(NSString *folder in names) { if([folder hasPrefix:@"."])continue;NSString *path=[_directory stringByAppendingPathComponent:folder];BOOL isDirectory=NO;if(![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory]||!isDirectory)continue;NSString *toc=TOC(path);if(!toc)continue;
        NSDictionary *item=owned[folder];TKAddonRecord *record=[TKAddonRecord new];record.identifier=folder;record.name=Value(toc,@"Title:")?:folder;record.version=Value(toc,@"Version:")?:@"Unknown version";record.source=item?@"Wolkara import":@"Existing";record.folders=item[@"folders"]?:@[folder];record.managed=item!=nil;record.disabled=NO;record.pinned=[item[@"pinned"] boolValue];[found addObject:record]; }
    for (NSDictionary *item in manifest[@"packages"]) { if (!Managed(item) || ![item[@"disabled"] boolValue]) continue;
        TKAddonRecord *record=[TKAddonRecord new]; record.identifier=item[@"identifier"]; record.name=item[@"name"]?:record.identifier; record.version=item[@"version"]?:@"Unknown version"; record.source=@"Wolkara import"; record.folders=item[@"folders"]; record.managed=YES; record.disabled=YES; record.pinned=[item[@"pinned"] boolValue]; [found addObject:record];
    }
    _records=found;
}
- (int)lock:(NSError **)error {
    NSString *root=[[_directory stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    return TKWoWAcquireUpdateLock(root,error);
}
- (BOOL)compatibleFolders:(NSArray<NSString *> *)folders from:(NSString *)extract error:(NSError **)error {
    for (NSString *name in folders) {
        NSString *toc=TOC([extract stringByAppendingPathComponent:name]);
        NSString *interface=Value(toc,@"Interface:");
        if (![_product isEqual:@"wow_classic_beta"]) return Fail(error,@"This edition is browse-only until its compatibility mapping is added.");
        if (!interface.length) return Fail(error,[NSString stringWithFormat:@"%@ has no Interface version in its TOC.",name]);
        BOOL supported=NO;
        for (NSString *value in [interface componentsSeparatedByString:@","]) {
            if ([[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqual:@"16001"]) { supported=YES; break; }
        }
        if (!supported) return Fail(error,[NSString stringWithFormat:@"%@ is not verified for Forever 1.60.1 (interface 16001).",name]);
    }
    return YES;
}
- (NSMutableArray *)mutablePackages { return [[self manifest][@"packages"] mutableCopy]?:[NSMutableArray new]; }
- (BOOL)writePackages:(NSArray *)packages error:(NSError **)error { return [self saveManifest:packages error:error]; }
- (NSDictionary *)packageForRecord:(TKAddonRecord *)record packages:(NSArray *)packages index:(NSUInteger *)index {
    for (NSUInteger i=0;i<packages.count;i++) if ([packages[i][@"identifier"] isEqual:record.identifier]) { if(index)*index=i; return packages[i]; } return nil;
}
- (BOOL)importZIPAtURL:(NSURL *)url error:(NSError **)error {
    NSData *archive=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];if(!archive||archive.length>128*1024*1024)return Fail(error,@"The selected ZIP is missing or exceeds the 128 MiB limit.");
    NSString *job=[_support stringByAppendingPathComponent:NSUUID.UUID.UUIDString],*extract=[job stringByAppendingPathComponent:@"extract"];
    if(![NSFileManager.defaultManager createDirectoryAtPath:job withIntermediateDirectories:YES attributes:nil error:error])return NO;
    Class archiveClass=NSClassFromString(@"TKAddonArchive");SEL selector=NSSelectorFromString(@"extractArchiveAtURL:toDirectoryURL:error:");
    if(!archiveClass||![archiveClass respondsToSelector:selector])return Fail(error,@"ZIP support is unavailable in this build.");
    BOOL (*extractor)(id,SEL,NSURL *,NSURL *,NSError **)= (void *)objc_msgSend;
    if(!extractor(archiveClass,selector,url,[NSURL fileURLWithPath:extract],error))return NO;
    NSArray *top=[[NSFileManager.defaultManager contentsOfDirectoryAtPath:extract error:error] sortedArrayUsingSelector:@selector(compare:)];NSMutableArray *folders=[NSMutableArray new];
    for(NSString *name in top){NSString *path=[extract stringByAppendingPathComponent:name];if(TOC(path))[folders addObject:name];}
    if(!folders.count&&top.count==1){NSString *wrapper=[extract stringByAppendingPathComponent:top[0]];NSArray *inside=[NSFileManager.defaultManager contentsOfDirectoryAtPath:wrapper error:NULL];for(NSString *name in inside)if(TOC([wrapper stringByAppendingPathComponent:name]))[folders addObject:name];if(folders.count)extract=wrapper;}
    if(!folders.count)return Fail(error,@"The ZIP contains no add-on folder with a .toc manifest.");
    if(![self compatibleFolders:folders from:extract error:error])return NO;
    int lock=[self lock:error];if(lock<0)return NO;BOOL success=NO;
    // The folders this call actually created, so a failure cleans up after itself and
    // nothing else. The cleanup used to remove every folder in the import on any failure,
    // and the duplicate check returns through that path - so trying to install an add-on
    // that was already there deleted the one that was already there. Found by the fixture
    // in wolkara/WoW/tests/test_wow_launcher_app.m, which is the coverage the audit asked
    // for; the manifest kept saying the package was owned while its folder was gone.
    NSMutableArray<NSString *> *created=[NSMutableArray new];
    @try { for(NSString *name in folders)if([NSFileManager.defaultManager fileExistsAtPath:[_directory stringByAppendingPathComponent:name]])return Fail(error,[NSString stringWithFormat:@"%@ already exists; remove or disable the managed package first.",name]);
        NSMutableArray *packages=[self mutablePackages];NSString *identifier=folders.firstObject;NSString *toc=TOC([extract stringByAppendingPathComponent:identifier]);[packages addObject:@{ @"identifier":identifier,@"name":Value(toc,@"Title:")?:identifier,@"version":Value(toc,@"Version:")?:@"Unknown version",@"source":@"zip",@"archiveSHA256":Digest(archive),@"folders":folders,@"pinned":@NO,@"disabled":@NO }];
        for(NSString *name in folders) { if(![NSFileManager.defaultManager copyItemAtPath:[extract stringByAppendingPathComponent:name] toPath:[_directory stringByAppendingPathComponent:name] error:error])return NO; [created addObject:name]; }
        if(![self saveManifest:packages error:error])return NO;success=YES;[self reload];return YES;
    } @finally {TKWoWReleaseUpdateLock(lock);if(!success)for(NSString *name in created)[NSFileManager.defaultManager removeItemAtPath:[_directory stringByAppendingPathComponent:name] error:NULL];[NSFileManager.defaultManager removeItemAtPath:job error:NULL];}
}
- (BOOL)setDisabled:(BOOL)disabled record:(TKAddonRecord *)record error:(NSError **)error {
    if (!record.managed) return Fail(error,@"Wolkara only changes folders it installed.");
    int lock=[self lock:error]; if(lock<0)return NO; BOOL success=NO;
    @try { NSMutableArray *packages=[self mutablePackages]; NSUInteger index=NSNotFound; NSMutableDictionary *item=[[self packageForRecord:record packages:packages index:&index] mutableCopy]; if(!item)return Fail(error,@"The package ownership record is missing.");
        NSString *disabledRoot=[[_support stringByAppendingPathComponent:@"disabled"] stringByAppendingPathComponent:record.identifier]; NSFileManager *fm=NSFileManager.defaultManager;
        if(disabled) { if([fm fileExistsAtPath:disabledRoot])return Fail(error,@"A disabled copy already exists."); if(![fm createDirectoryAtPath:disabledRoot withIntermediateDirectories:YES attributes:nil error:error])return NO; for(NSString *folder in record.folders) { NSString *source=[_directory stringByAppendingPathComponent:folder]; if(![fm fileExistsAtPath:source]||![fm moveItemAtPath:source toPath:[disabledRoot stringByAppendingPathComponent:folder] error:error])return NO; } }
        else { for(NSString *folder in record.folders) { NSString *source=[disabledRoot stringByAppendingPathComponent:folder],*destination=[_directory stringByAppendingPathComponent:folder]; if([fm fileExistsAtPath:destination])return Fail(error,@"An existing folder blocks restore."); if(![fm moveItemAtPath:source toPath:destination error:error])return NO; } [fm removeItemAtPath:disabledRoot error:NULL]; }
        item[@"disabled"]=@(disabled); packages[index]=item; if(![self writePackages:packages error:error])return NO; success=YES; [self reload]; return YES;
    } @finally { TKWoWReleaseUpdateLock(lock); if(!success)[self reload]; }
}
- (BOOL)removeRecord:(TKAddonRecord *)record error:(NSError **)error {
    if(!record.managed)return Fail(error,@"Wolkara only removes folders it installed."); int lock=[self lock:error];if(lock<0)return NO; BOOL success=NO;
    @try { NSMutableArray *packages=[self mutablePackages];NSUInteger index=NSNotFound;NSDictionary *item=[self packageForRecord:record packages:packages index:&index];if(!item)return Fail(error,@"The package ownership record is missing.");NSFileManager *fm=NSFileManager.defaultManager;NSString *base=[item[@"disabled"] boolValue]?[[_support stringByAppendingPathComponent:@"disabled"] stringByAppendingPathComponent:record.identifier]:_directory;NSString *previous=[[_support stringByAppendingPathComponent:@"previous"] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@",record.identifier,NSUUID.UUID.UUIDString]];if(![fm createDirectoryAtPath:previous withIntermediateDirectories:YES attributes:nil error:error])return NO;for(NSString *folder in record.folders){NSString *source=[base stringByAppendingPathComponent:folder];if([fm fileExistsAtPath:source]&&![fm moveItemAtPath:source toPath:[previous stringByAppendingPathComponent:folder] error:error])return NO;}[packages removeObjectAtIndex:index];if(![self writePackages:packages error:error])return NO;success=YES;[self reload];return YES; } @finally { TKWoWReleaseUpdateLock(lock); if(!success)[self reload]; }
}
- (BOOL)setPinned:(BOOL)pinned record:(TKAddonRecord *)record error:(NSError **)error { if(!record.managed)return Fail(error,@"Only managed packages can be pinned.");int lock=[self lock:error];if(lock<0)return NO;@try {NSMutableArray *packages=[self mutablePackages];NSUInteger index=NSNotFound;NSMutableDictionary *item=[[self packageForRecord:record packages:packages index:&index] mutableCopy];if(!item)return Fail(error,@"The package ownership record is missing.");item[@"pinned"]=@(pinned);packages[index]=item;if(![self writePackages:packages error:error])return NO;[self reload];return YES;} @finally {TKWoWReleaseUpdateLock(lock);} }
@end
