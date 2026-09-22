#import "AppLibrary.h"
#import "GuestImage.h"
#import "GuestModule.h"
#include <stdlib.h>
#include <sys/stat.h>

static NSString *const TKModulesDirectory=@"GuestModules";

static BOOL library_error(NSError **error, NSString *message) {
    if (error) *error=[NSError errorWithDomain:@"TKAppLibrary" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSString *real_path(NSString *path) {
    char buffer[PATH_MAX];
    return realpath(path.fileSystemRepresentation,buffer) ? @(buffer) : nil;
}
// Relative to Documents, without escapes. An empty string is Documents itself.
static BOOL valid_relative(id path, BOOL allowEmpty) {
    if (![path isKindOfClass:NSString.class] || [path length]>4096) return NO;
    if (![path length]) return allowEmpty;
    if ([path hasPrefix:@"/"] || [path hasSuffix:@"/"]) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return YES;
}
static BOOL valid_hash(id hash) {
    if (![hash isKindOfClass:NSString.class] || [hash length]!=64) return NO;
    return [hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static NSString *join(NSString *directory, NSString *relative) {
    return relative.length ? [directory stringByAppendingPathComponent:relative] : directory;
}
static NSString *clean_name(id name) {
    if (![name isKindOfClass:NSString.class]) return nil;
    NSString *trimmed=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    return trimmed.length>100 ? [trimmed substringToIndex:100] : trimmed;
}

@interface TKApp ()
@property(nonatomic, copy) NSDictionary *record;
@end
@implementation TKApp
+ (instancetype)appWithRecord:(NSDictionary *)record {
    NSString *source=record[@"source"];
    if (![record[@"id"] isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:record[@"id"]]) return nil;
    if (!clean_name(record[@"name"]) || !valid_relative(record[@"executable"],NO) || !valid_relative(record[@"workingDirectory"],YES)) return nil;
    if (![source isEqual:@"documents"] && !([source isEqual:@"copy"] && valid_hash(record[@"sha256"]))) return nil;
    if (record[@"sha256"] && !valid_hash(record[@"sha256"])) return nil;
    if (record[@"profile"] && ![record[@"profile"] isKindOfClass:NSString.class]) return nil;
    if (![record[@"added"] isKindOfClass:NSNumber.class]) return nil;
    if (record[@"lastLaunched"] && ![record[@"lastLaunched"] isKindOfClass:NSNumber.class]) return nil;
    TKApp *app=[TKApp new]; app.record=record; return app;
}
- (NSString *)identifier { return self.record[@"id"]; }
- (NSString *)name { return self.record[@"name"]; }
- (TKAppSource)source { return [self.record[@"source"] isEqual:@"copy"] ? TKAppSourceCopy : TKAppSourceDocuments; }
- (NSString *)executable { return self.record[@"executable"]; }
- (NSString *)workingDirectory { return self.record[@"workingDirectory"]; }
- (NSString *)sha256 { return self.record[@"sha256"]?:@""; }
- (NSString *)profile { return self.record[@"profile"]; }
- (NSDate *)added { return [NSDate dateWithTimeIntervalSince1970:[self.record[@"added"] doubleValue]]; }
- (NSDate *)lastLaunched {
    NSNumber *value=self.record[@"lastLaunched"];
    return value ? [NSDate dateWithTimeIntervalSince1970:value.doubleValue] : nil;
}
- (NSString *)description { return [NSString stringWithFormat:@"<TKApp %@ %@>",self.name,self.executable]; }
@end

@implementation TKAppLibrary {
    NSString *_documents, *_storage, *_loadWarning;
    NSArray<NSDictionary *> *_profiles;
    NSMutableArray<NSDictionary *> *_records;
    NSMutableSet<NSString *> *_dismissedProfiles;
    BOOL _legacyImported;
}

+ (NSArray<NSDictionary *> *)profilesInDirectory:(NSString *)directory {
    NSMutableArray *profiles=[NSMutableArray new];
    NSMutableSet *seen=[NSMutableSet new];
    NSArray *names=[[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        if (![name.pathExtension isEqual:@"json"]) continue;
        NSData *data=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
        id profile=data.length && data.length<=65536 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        // Same rules as tools/check_profile.py: data only, paths inside Documents.
        if (![profile isKindOfClass:NSDictionary.class] || !clean_name(profile[@"name"]) ||
            ![profile[@"id"] isKindOfClass:NSString.class] || ![profile[@"id"] length] || [seen containsObject:profile[@"id"]] ||
            !valid_relative(profile[@"workingDirectory"],NO) || !valid_relative(profile[@"executable"],NO)) continue;
        [seen addObject:profile[@"id"]];
        [profiles addObject:profile];
    }
    return profiles;
}

- (instancetype)initWithDocuments:(NSString *)documents storage:(NSString *)storage profiles:(NSArray<NSDictionary *> *)profiles {
    if (!(self=[super init])) return nil;
    _documents=documents.copy; _storage=storage.copy; _profiles=profiles.copy;
    _records=[NSMutableArray new]; _dismissedProfiles=[NSMutableSet new];
    NSString *path=[self libraryPath];
    NSData *data=[NSData dataWithContentsOfFile:path];
    if (!data) return self;
    id value=data.length<=4*1024*1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"format"] isEqual:@1] || ![value[@"apps"] isKindOfClass:NSArray.class]) {
        // Keep the damaged file for inspection rather than overwrite it.
        NSString *aside=[path stringByAppendingFormat:@".damaged-%@",NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager moveItemAtPath:path toPath:aside error:NULL];
        _loadWarning=[NSString stringWithFormat:@"The app library could not be read and was reset. The old file was kept as %@.",aside.lastPathComponent];
        return self;
    }
    NSMutableSet *identifiers=[NSMutableSet new];
    for (id record in value[@"apps"]) {
        if (![record isKindOfClass:NSDictionary.class]) continue;
        TKApp *app=[TKApp appWithRecord:record];
        if (!app || [identifiers containsObject:app.identifier]) continue;
        [identifiers addObject:app.identifier];
        [_records addObject:record];
    }
    for (id profile in value[@"dismissedProfiles"]) if ([profile isKindOfClass:NSString.class]) [_dismissedProfiles addObject:profile];
    _legacyImported=[value[@"legacyImported"] isEqual:@YES];
    return self;
}

- (NSString *)libraryPath { return [_storage stringByAppendingPathComponent:@"apps.json"]; }
- (NSString *)modulesRoot { return [_documents stringByAppendingPathComponent:TKModulesDirectory]; }
- (NSString *)loadWarning { @synchronized (self) { return _loadWarning; } }

// Caller holds the lock.
- (BOOL)saveRecords:(NSArray *)records dismissed:(NSSet *)dismissed legacy:(BOOL)legacy error:(NSError **)error {
    if (![NSFileManager.defaultManager createDirectoryAtPath:_storage withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSDictionary *value=@{@"format":@1,@"apps":records,
        @"dismissedProfiles":[dismissed.allObjects sortedArrayUsingSelector:@selector(compare:)],@"legacyImported":@(legacy)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];
    if (!data || ![data writeToFile:[self libraryPath] options:NSDataWritingAtomic error:error]) return NO;
    _records=[records mutableCopy]; _dismissedProfiles=[dismissed mutableCopy]; _legacyImported=legacy;
    return YES;
}

- (NSArray<TKApp *> *)apps {
    NSMutableArray *apps=[NSMutableArray new];
    @synchronized (self) { for (NSDictionary *record in _records) [apps addObject:[TKApp appWithRecord:record]]; }
    [apps sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(TKApp *a, TKApp *b) {
        if (a.lastLaunched || b.lastLaunched) {
            if (!b.lastLaunched) return NSOrderedAscending;
            if (!a.lastLaunched) return NSOrderedDescending;
            return [b.lastLaunched compare:a.lastLaunched];
        }
        return [a.added compare:b.added];
    }];
    return apps;
}
- (TKApp *)appWithIdentifier:(NSString *)identifier {
    for (TKApp *app in self.apps) if ([app.identifier isEqual:identifier]) return app;
    return nil;
}
- (TKApp *)defaultApp {
    NSArray<TKApp *> *apps=self.apps;
    if (apps.firstObject.lastLaunched) return apps.firstObject;
    // An app with its resources beats a bare executable copy.
    for (TKApp *app in apps) if (app.source==TKAppSourceDocuments) return app;
    return apps.firstObject;
}

// Documents-relative path of an existing path inside Documents, or nil.
- (NSString *)relativeInDocuments:(NSString *)path {
    NSString *root=real_path(_documents), *real=real_path(path);
    if (!root || !real || ![real hasPrefix:[root stringByAppendingString:@"/"]]) return nil;
    return [real substringFromIndex:root.length+1];
}
// Name and working directory for .../Name.app/Contents/MacOS/executable, so the
// application finds its bundle resources next to the executable.
- (NSDictionary *)describeExecutable:(NSString *)relative {
    for (NSDictionary *profile in _profiles)
        if ([join(profile[@"workingDirectory"],profile[@"executable"]).stringByStandardizingPath isEqual:relative])
            return @{@"name":clean_name(profile[@"name"]),@"workingDirectory":profile[@"workingDirectory"],@"profile":profile[@"id"]};
    NSArray<NSString *> *parts=relative.pathComponents;
    NSUInteger n=parts.count;
    if (n>=4 && [parts[n-2] isEqual:@"MacOS"] && [parts[n-3] isEqual:@"Contents"] && [parts[n-4].pathExtension isEqual:@"app"]) {
        NSString *bundle=[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0,n-3)]];
        NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[join(_documents,bundle) stringByAppendingPathComponent:@"Contents/Info.plist"]];
        NSString *name=clean_name(info[@"CFBundleDisplayName"])?:clean_name(info[@"CFBundleName"])?:clean_name(parts[n-4].stringByDeletingPathExtension);
        NSString *directory=n>4 ? [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0,n-4)]] : @"";
        return @{@"name":name?:parts[n-1],@"workingDirectory":directory};
    }
    return @{@"name":parts[n-1],@"workingDirectory":n>1 ? relative.stringByDeletingLastPathComponent : @""};
}
- (NSString *)nameForCopiedSource:(NSString *)source {
    NSArray<NSString *> *parts=source.pathComponents;
    NSUInteger n=parts.count;
    if (n>=4 && [parts[n-2] isEqual:@"MacOS"] && [parts[n-3] isEqual:@"Contents"] && [parts[n-4].pathExtension isEqual:@"app"])
        return clean_name(parts[n-4].stringByDeletingPathExtension)?:parts[n-1];
    return clean_name(source.lastPathComponent)?:@"Imported app";
}

- (TKApp *)addRecord:(NSDictionary *)record error:(NSError **)error {
    @synchronized (self) {
        // An entry for the same file (or copy) already exists: refresh its hash.
        for (NSUInteger i=0;i<_records.count;i++) {
            NSDictionary *existing=_records[i];
            BOOL same=[existing[@"source"] isEqual:record[@"source"]] &&
                ([record[@"source"] isEqual:@"copy"] ? [existing[@"sha256"] isEqual:record[@"sha256"]] : [existing[@"executable"] isEqual:record[@"executable"]]);
            if (!same) continue;
            NSMutableArray *records=[_records mutableCopy];
            NSMutableDictionary *updated=[existing mutableCopy];
            if (record[@"sha256"]) updated[@"sha256"]=record[@"sha256"];
            records[i]=updated;
            NSMutableSet *dismissed=[_dismissedProfiles mutableCopy];
            if (updated[@"profile"]) [dismissed removeObject:updated[@"profile"]];
            return [self saveRecords:records dismissed:dismissed legacy:_legacyImported error:error] ? [TKApp appWithRecord:updated] : nil;
        }
        NSMutableDictionary *added=[record mutableCopy];
        added[@"id"]=NSUUID.UUID.UUIDString;
        added[@"added"]=@(NSDate.date.timeIntervalSince1970);
        TKApp *app=[TKApp appWithRecord:added];
        if (!app) { library_error(error,@"The app entry is invalid."); return nil; }
        NSMutableSet *dismissed=[_dismissedProfiles mutableCopy];
        if (added[@"profile"]) [dismissed removeObject:added[@"profile"]];
        return [self saveRecords:[_records arrayByAddingObject:added] dismissed:dismissed legacy:_legacyImported error:error] ? app : nil;
    }
}

// An application bundle stands for the executable its Info.plist names.
static NSString *bundle_executable(NSString *path, NSError **error) {
    BOOL directory=NO;
    if (![path.pathExtension isEqual:@"app"] || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || !directory) return path;
    NSString *name=[NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]][@"CFBundleExecutable"];
    if (![name isKindOfClass:NSString.class] || !name.length || [name containsString:@"/"] || [name isEqual:@".."]) {
        library_error(error,@"This application bundle does not name a macOS executable."); return nil;
    }
    return [path stringByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:name]];
}

- (TKApp *)importExecutable:(NSString *)path copy:(BOOL)copy error:(NSError **)error {
    path=bundle_executable(path,error);
    if (!path) return nil;
    NSString *relative=copy ? nil : [self relativeInDocuments:path];
    NSString *modules=[TKModulesDirectory stringByAppendingString:@"/"];
    if (relative && ![relative hasPrefix:modules]) {
        uint64_t size=0;
        NSString *hash=guest_module_hash(join(_documents,relative),&size,error);
        if (!hash) return nil;
        GuestImage image={0}; char reason[2048];
        if (!gi_load(join(_documents,relative).fileSystemRepresentation,&image,reason,sizeof reason)) {
            library_error(error,[NSString stringWithFormat:@"Unsupported executable: %s",reason]); return nil;
        }
        gi_destroy(&image);
        NSDictionary *described=[self describeExecutable:relative];
        NSMutableDictionary *record=[@{@"source":@"documents",@"executable":relative,@"sha256":hash} mutableCopy];
        [record addEntriesFromDictionary:described];
        return [self addRecord:record error:error];
    }
    // Outside Documents only the picked file is accessible: keep a verified copy.
    NSString *hash=guest_module_import_hash(path,[self modulesRoot],error);
    if (!hash) return nil;
    NSString *directory=[TKModulesDirectory stringByAppendingPathComponent:hash];
    return [self addRecord:@{@"source":@"copy",@"name":[self nameForCopiedSource:path],@"sha256":hash,
        @"executable":[directory stringByAppendingPathComponent:@"OriginalExecutable.bin"],@"workingDirectory":directory} error:error];
}

- (NSArray<TKApp *> *)discover {
    NSMutableArray *found=[NSMutableArray new];
    NSMutableSet *known=[NSMutableSet new], *dismissed;
    BOOL legacyImported;
    @synchronized (self) {
        for (NSDictionary *record in _records) {
            [known addObject:record[@"executable"]];
            if (record[@"sha256"]) [known addObject:record[@"sha256"]];
        }
        dismissed=[_dismissedProfiles copy]; legacyImported=_legacyImported;
    }
    for (NSDictionary *profile in _profiles) {
        NSString *relative=join(profile[@"workingDirectory"],profile[@"executable"]);
        if ([dismissed containsObject:profile[@"id"]] || [known containsObject:relative]) continue;
        // Recorded by its real location, as an import from the picker would be.
        NSString *real=[self relativeInDocuments:join(_documents,relative)];
        if (!real || [known containsObject:real]) continue;
        struct stat st;
        if (lstat(join(_documents,real).fileSystemRepresentation,&st) || !S_ISREG(st.st_mode)) continue;
        NSString *hash=guest_module_hash(join(_documents,real),NULL,NULL);
        if (!hash) continue;
        NSMutableDictionary *record=[@{@"source":@"documents",@"executable":real,@"sha256":hash} mutableCopy];
        [record addEntriesFromDictionary:[self describeExecutable:real]];
        TKApp *app=[self addRecord:record error:NULL];
        if (app) { [found addObject:app]; [known addObject:real]; [known addObject:hash]; }
    }
    if (!legacyImported) {
        // An older launcher kept a single imported module selected in current.json.
        NSString *path=guest_module_selected([self modulesRoot],NULL);
        NSString *hash=path.stringByDeletingLastPathComponent.lastPathComponent;
        if (path && valid_hash(hash) && ![known containsObject:hash]) {
            NSData *data=[NSData dataWithContentsOfFile:[path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"manifest.json"]];
            NSDictionary *manifest=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            NSString *name=[manifest isKindOfClass:NSDictionary.class] ? clean_name(manifest[@"source_name"]) : nil;
            NSString *directory=[TKModulesDirectory stringByAppendingPathComponent:hash];
            TKApp *app=[self addRecord:@{@"source":@"copy",@"name":name?:@"Imported app",@"sha256":hash,
                @"executable":[directory stringByAppendingPathComponent:@"OriginalExecutable.bin"],@"workingDirectory":directory} error:NULL];
            if (app) [found addObject:app];
        }
        @synchronized (self) { [self saveRecords:_records dismissed:_dismissedProfiles legacy:YES error:NULL]; }
    }
    return found;
}

- (BOOL)updateApp:(TKApp *)app error:(NSError **)error change:(void (^)(NSMutableDictionary *record))change {
    @synchronized (self) {
        for (NSUInteger i=0;i<_records.count;i++) {
            if (![_records[i][@"id"] isEqual:app.identifier]) continue;
            NSMutableArray *records=[_records mutableCopy];
            NSMutableDictionary *record=[_records[i] mutableCopy];
            change(record);
            records[i]=record;
            return [self saveRecords:records dismissed:_dismissedProfiles legacy:_legacyImported error:error];
        }
    }
    return library_error(error,@"The app is no longer in the library.");
}
- (BOOL)renameApp:(TKApp *)app to:(NSString *)name error:(NSError **)error {
    NSString *clean=clean_name(name);
    if (!clean) return library_error(error,@"Enter a name.");
    return [self updateApp:app error:error change:^(NSMutableDictionary *record) { record[@"name"]=clean; }];
}
- (BOOL)recordLaunchOfApp:(TKApp *)app error:(NSError **)error {
    return [self updateApp:app error:error change:^(NSMutableDictionary *record) {
        record[@"lastLaunched"]=@(NSDate.date.timeIntervalSince1970);
    }];
}
- (BOOL)removeApp:(TKApp *)app error:(NSError **)error {
    NSString *unusedCopy=nil;
    @synchronized (self) {
        NSMutableArray *records=[NSMutableArray new];
        NSDictionary *removed=nil;
        for (NSDictionary *record in _records) {
            if ([record[@"id"] isEqual:app.identifier]) removed=record; else [records addObject:record];
        }
        if (!removed) return library_error(error,@"The app is no longer in the library.");
        NSMutableSet *dismissed=[_dismissedProfiles mutableCopy];
        // Do not let discovery add a removed profile app back.
        if (removed[@"profile"]) [dismissed addObject:removed[@"profile"]];
        if (!removed[@"profile"])
            for (NSDictionary *profile in _profiles)
                if ([join(profile[@"workingDirectory"],profile[@"executable"]).stringByStandardizingPath isEqual:removed[@"executable"]])
                    [dismissed addObject:profile[@"id"]];
        if (![self saveRecords:records dismissed:dismissed legacy:_legacyImported error:error]) return NO;
        if ([removed[@"source"] isEqual:@"copy"]) {
            unusedCopy=removed[@"sha256"];
            for (NSDictionary *record in records) if ([record[@"sha256"] isEqual:unusedCopy] && [record[@"source"] isEqual:@"copy"]) unusedCopy=nil;
        }
    }
    if (valid_hash(unusedCopy)) {
        NSString *root=[self modulesRoot], *current=[root stringByAppendingPathComponent:@"current.json"];
        NSData *data=[NSData dataWithContentsOfFile:current];
        NSDictionary *selected=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if ([selected isKindOfClass:NSDictionary.class] && [selected[@"sha256"] isEqual:unusedCopy])
            [NSFileManager.defaultManager removeItemAtPath:current error:NULL];
        [NSFileManager.defaultManager removeItemAtPath:[root stringByAppendingPathComponent:unusedCopy] error:NULL];
    }
    return YES;
}

- (NSString *)executablePathForApp:(TKApp *)app error:(NSError **)error {
    if (app.source==TKAppSourceCopy) return guest_module_path([self modulesRoot],app.sha256,error);
    NSString *path=join(_documents,app.executable);
    struct stat st;
    if (lstat(path.fileSystemRepresentation,&st)) {
        library_error(error,[NSString stringWithFormat:@"%@ is missing from Documents/%@. Copy it back or import it again.",app.name,app.executable]);
        return nil;
    }
    // Recorded by real path, so a symbolic link here was added afterwards.
    if (!S_ISREG(st.st_mode) || ![[self relativeInDocuments:path] isEqual:app.executable]) {
        library_error(error,@"The executable must be a regular file inside Documents."); return nil;
    }
    return path;
}
- (NSString *)currentSHA256OfApp:(TKApp *)app error:(NSError **)error {
    NSString *path=[self executablePathForApp:app error:error];
    NSString *hash=path ? guest_module_hash(path,NULL,error) : nil;
    if (hash && ![hash isEqual:app.sha256] && app.source==TKAppSourceDocuments)
        [self updateApp:app error:NULL change:^(NSMutableDictionary *record) { record[@"sha256"]=hash; }];
    return hash;
}
- (NSString *)workingDirectoryForApp:(TKApp *)app error:(NSError **)error {
    NSString *path=join(_documents,app.workingDirectory);
    NSString *relative=app.workingDirectory.length ? [self relativeInDocuments:path] : @"";
    BOOL directory=NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || !directory || ![relative isEqual:app.workingDirectory]) {
        library_error(error,[NSString stringWithFormat:@"The folder Documents/%@ is missing.",app.workingDirectory]); return nil;
    }
    return path;
}
@end
