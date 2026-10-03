#import "Client.h"

// Each transfer has its own serial delegate queue and bounded buffer. No cookies,
// credentials, redirects, HTTP fallback, or application-installation writes.
@interface TKWoWTransfer : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) NSMutableData *data;
@property(nonatomic) NSError *error;
@property(nonatomic) NSUInteger limit;
@property(nonatomic) dispatch_semaphore_t done;
@end
@implementation TKWoWTransfer
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    (void)session; (void)task;
    NSInteger status=[(NSHTTPURLResponse *)response statusCode];
    if (status!=200 || response.expectedContentLength>(int64_t)self.limit) {
        self.error=TKWoWError(status!=200 ? [NSString stringWithFormat:@"Download failed (HTTP %ld).",(long)status] : @"Download exceeds its size limit.");
        completion(NSURLSessionResponseCancel);
    } else completion(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;
    if (data.length>self.limit-self.data.length) {
        self.error=TKWoWError(@"Download exceeds its size limit."); [task cancel];
    } else [self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest * _Nullable))completion {
    (void)session; (void)task; (void)response; (void)request;
    self.error=TKWoWError(@"Unexpected download redirect."); completion(nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session; (void)task;
    if (!self.error) self.error=error;
    dispatch_semaphore_signal(self.done);
}
@end

@implementation TKWoWClient {
    NSLock *_lock;
    BOOL _cancelled;
    NSURLSession *_session;
}
- (instancetype)init {
    if ((self=[super init])) _lock=[NSLock new];
    return self;
}
- (void)cancel {
    [_lock lock]; _cancelled=YES; [_session invalidateAndCancel]; [_lock unlock];
}
- (NSData *)fetch:(NSURL *)url limit:(NSUInteger)limit error:(NSError **)error {
    if (![url.scheme isEqualToString:@"https"] || !url.host.length || url.user || url.password) {
        if (error) *error=TKWoWError(@"A valid HTTPS download URL is required.");
        return nil;
    }
    TKWoWTransfer *transfer=[TKWoWTransfer new];
    transfer.data=[NSMutableData new]; transfer.limit=limit; transfer.done=dispatch_semaphore_create(0);
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage=nil; config.URLCredentialStorage=nil; config.URLCache=nil;
    config.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest=30; config.timeoutIntervalForResource=300;
    config.HTTPMaximumConnectionsPerHost=1;
    config.HTTPAdditionalHeaders=@{@"Accept-Encoding":@"identity"};
    NSOperationQueue *queue=[NSOperationQueue new]; queue.maxConcurrentOperationCount=1;
    NSURLSession *session=[NSURLSession sessionWithConfiguration:config delegate:transfer delegateQueue:queue];
    [_lock lock];
    BOOL cancelled=_cancelled;
    if (!cancelled) { _session=session; [[session dataTaskWithURL:url] resume]; }
    [_lock unlock];
    if (cancelled) {
        [session invalidateAndCancel];
        if (error) *error=TKWoWError(@"Download cancelled.");
        return nil;
    }
    // Delegate completion is guaranteed by the resource timeout/cancellation.
    dispatch_semaphore_wait(transfer.done,DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];
    [_lock lock]; _session=nil; cancelled=_cancelled; [_lock unlock];
    if (transfer.error || cancelled) {
        if (error) *error=transfer.error?:TKWoWError(@"Download cancelled.");
        return nil;
    }
    return transfer.data;
}
- (NSDictionary *)rowAt:(NSURL *)url field:(NSString *)field value:(NSString *)value error:(NSError **)error {
    NSData *data=[self fetch:url limit:2*1024*1024 error:error];
    if (!data) return nil;
    NSArray *rows=TKWoWTable(data,error);
    if (!rows) return nil;
    NSDictionary *match=nil;
    for (NSDictionary *row in rows) if ([row[field] isEqualToString:value]) {
        if (match) { if (error) *error=TKWoWError(@"Ambiguous region metadata."); return nil; }
        match=row;
    }
    if (!match && error) *error=TKWoWError(@"This channel is not available in the selected region.");
    return match;
}
- (BOOL)validProduct:(NSString *)product region:(NSString *)region error:(NSError **)error {
    BOOL known=NO;
    for (NSDictionary *entry in TKWoWProducts()) if ([entry[@"id"] isEqualToString:product]) known=YES;
    if (!known || ![@[@"eu",@"us",@"kr",@"tw"] containsObject:region]) {
        if (error) *error=TKWoWError(@"Unknown product or region.");
        return NO;
    }
    return YES;
}
- (NSURL *)endpoint:(NSString *)product region:(NSString *)region name:(NSString *)name {
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://%@.version.battle.net/v2/products/%@/%@",region,product,name]];
}
- (NSDictionary *)versionForProduct:(NSString *)product region:(NSString *)region error:(NSError **)error {
    if (![self validProduct:product region:region error:error]) return nil;
    NSDictionary *row=[self rowAt:[self endpoint:product region:region name:@"versions"] field:@"Region" value:region error:error];
    if (!row) return nil;
    if (!TKWoWHashValid(row[@"BuildConfig"]) || !TKWoWHashValid(row[@"CDNConfig"]) || ![row[@"VersionsName"] length]) {
        if (error) *error=TKWoWError(@"The channel has no usable build.");
        return nil;
    }
    return row;
}
- (NSString *)cdn:(NSString *)product region:(NSString *)region error:(NSError **)error {
    NSDictionary *row=[self rowAt:[self endpoint:product region:region name:@"cdns"] field:@"Name" value:region error:error];
    if (!row) return nil;
    if (![row[@"Path"] isEqualToString:@"tpr/wow"]) {
        if (error) *error=TKWoWError(@"Unsupported CDN path."); return nil;
    }
    for (NSString *server in [row[@"Servers"] componentsSeparatedByString:@" "]) {
        NSURL *url=[NSURL URLWithString:server];
        NSString *host=url.host.lowercaseString;
        if ([url.scheme isEqualToString:@"https"] && !url.user && !url.password && !url.port &&
            ([host hasSuffix:@".blizzard.com"] || [host hasSuffix:@".akamaihd.net"]))
            return [NSString stringWithFormat:@"https://%@/tpr/wow",host];
    }
    if (error) *error=TKWoWError(@"No supported HTTPS CDN is advertised.");
    return nil;
}
- (NSData *)object:(NSString *)key kind:(NSString *)kind cdn:(NSString *)cdn limit:(NSUInteger)limit error:(NSError **)error {
    if (!TKWoWHashValid(key)) { if (error) *error=TKWoWError(@"Invalid content hash."); return nil; }
    NSString *url=[NSString stringWithFormat:@"%@/%@/%@/%@/%@",cdn,kind,[key substringToIndex:2],[key substringWithRange:NSMakeRange(2,2)],key];
    return [self fetch:[NSURL URLWithString:url] limit:limit error:error];
}
static NSArray *Words(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @[];
    return [[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
}
static NSUInteger ManifestSize(NSString *text) {
    if (![text isKindOfClass:NSString.class] || !text.length || text.length>10 ||
        [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound) return 0;
    return (NSUInteger)text.longLongValue;
}
- (NSData *)manifest:(NSString *)name config:(NSDictionary *)config cdn:(NSString *)cdn error:(NSError **)error {
    NSArray *keys=Words(config[name]), *sizes=Words(config[[name stringByAppendingString:@"-size"]]);
    if (keys.count!=2 || sizes.count!=2 || !ManifestSize(sizes[0]) || !ManifestSize(sizes[1]) ||
        ManifestSize(sizes[0])>256*1024*1024 || ManifestSize(sizes[1])>256*1024*1024) {
        if (error) *error=TKWoWError(@"Unsupported manifest size or configuration."); return nil;
    }
    NSData *data=[self object:keys[1] kind:@"data" cdn:cdn limit:ManifestSize(sizes[1]) error:error];
    if (!data) return nil;
    if (data.length!=ManifestSize(sizes[1])) { if (error) *error=TKWoWError(@"Incomplete manifest download."); return nil; }
    return TKWoWDecode(data,keys[1],keys[0],ManifestSize(sizes[0]),256*1024*1024,error);
}
- (NSDictionary *)planForProduct:(NSString *)product region:(NSString *)region locale:(NSString *)locale error:(NSError **)error {
    if (![@[@"enUS",@"esES",@"deDE",@"frFR",@"itIT",@"esMX",@"ptBR",@"ruRU",@"koKR",@"zhTW"] containsObject:locale]) {
        if (error) *error=TKWoWError(@"Unsupported locale."); return nil;
    }
    NSDictionary *version=[self versionForProduct:product region:region error:error];
    if (!version) return nil;
    NSString *cdn=[self cdn:product region:region error:error];
    if (!cdn) return nil;
    NSData *data=[self object:version[@"BuildConfig"] kind:@"config" cdn:cdn limit:2*1024*1024 error:error];
    if (!data) return nil;
    if (![TKWoWMD5(data) isEqualToString:version[@"BuildConfig"]]) {
        if (error) *error=TKWoWError(@"Build configuration checksum mismatch."); return nil;
    }
    NSDictionary *config=TKWoWConfig(data,error);
    if (!config) return nil;
    if (![config[@"build-uid"] isEqualToString:product]) {
        if (error) *error=TKWoWError(@"The build belongs to a different product."); return nil;
    }
    NSData *install=[self manifest:@"install" config:config cdn:cdn error:error];
    if (!install) return nil;
    NSArray *entries=TKWoWInstall(install,error);
    if (!entries) return nil;
    NSArray *selected=TKWoWMacFiles(entries,locale,region);
    // Conflicting paths cannot be silently overwritten when eventually installing.
    NSMutableDictionary *seen=[NSMutableDictionary new];
    uint64_t total=0;
    for (NSDictionary *file in selected) {
        NSString *path=[file[@"path"] lowercaseString];
        if (seen[path]) { if (error) *error=TKWoWError(@"Ambiguous install tags: multiple files map to one path."); return nil; }
        seen[path]=file; total+=[file[@"size"] unsignedLongLongValue];
    }
    if (!selected.count) { if (error) *error=TKWoWError(@"No macOS ARM64 install files in this build."); return nil; }
    return @{@"product":product,@"region":region,@"locale":locale,@"version":version,@"cdn":cdn,
        @"config":config,@"files":selected,@"installFileBytes":@(total),@"complete":@NO};
}
- (NSString *)stageFile:(NSDictionary *)file plan:(NSDictionary *)plan directory:(NSString *)directory error:(NSError **)error {
    if (![plan[@"files"] containsObject:file] || !TKWoWHashValid(file[@"contentKey"]) ||
        ![file[@"size"] unsignedIntegerValue] || [file[@"size"] unsignedIntegerValue]>256*1024*1024) {
        if (error) *error=TKWoWError(@"File is absent from the plan or exceeds the extraction limit."); return nil;
    }
    // Re-query before a large operation; never continue an already superseded plan.
    NSDictionary *current=[self versionForProduct:plan[@"product"] region:plan[@"region"] error:error];
    if (!current) return nil;
    if (![current[@"BuildConfig"] isEqual:plan[@"version"][@"BuildConfig"]] ||
        ![current[@"CDNConfig"] isEqual:plan[@"version"][@"CDNConfig"]]) {
        if (error) *error=TKWoWError(@"A newer build is available. Check this channel again."); return nil;
    }
    NSArray *encodingKeys=Words(plan[@"config"][@"encoding"]), *encodingSizes=Words(plan[@"config"][@"encoding-size"]);
    if (encodingKeys.count!=2 || encodingSizes.count!=2 || !TKWoWHashValid(encodingKeys[0])) {
        if (error) *error=TKWoWError(@"Invalid encoding configuration."); return nil;
    }
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSString *cache=[directory stringByAppendingPathComponent:[encodingKeys[0] stringByAppendingString:@".encoding"]];
    NSData *encoding=nil;
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:cache error:nil];
    if ([attributes[NSFileSize] unsignedLongLongValue]==ManifestSize(encodingSizes[0]) &&
        ManifestSize(encodingSizes[0])<=256*1024*1024) {
        NSData *cached=[NSData dataWithContentsOfFile:cache options:NSDataReadingMappedIfSafe error:nil];
        if (cached && [TKWoWMD5(cached) isEqual:encodingKeys[0]]) encoding=cached;
    }
    if (!encoding) {
        encoding=[self manifest:@"encoding" config:plan[@"config"] cdn:plan[@"cdn"] error:error];
        if (encoding && ![encoding writeToFile:cache options:NSDataWritingAtomic error:error]) return nil;
    }
    if (!encoding) return nil;
    NSString *key=TKWoWEncodingKey(encoding,file[@"contentKey"],error);
    if (!key) return nil;
    NSData *raw=[self object:key kind:@"data" cdn:plan[@"cdn"] limit:256*1024*1024 error:error];
    if (!raw) {
        if (error && *error) *error=TKWoWError([NSString stringWithFormat:@"Original file download: %@ An archive-only file cannot be extracted by this prototype yet.",(*error).localizedDescription]);
        return nil;
    }
    NSData *decoded=TKWoWDecode(raw,key,file[@"contentKey"],[file[@"size"] unsignedIntegerValue],256*1024*1024,error);
    if (!decoded) return nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    // Content-addressed flat output, never a path supplied by the manifest.
    NSString *path=[directory stringByAppendingPathComponent:[file[@"contentKey"] stringByAppendingString:@".original"]];
    if (![decoded writeToFile:path options:NSDataWritingAtomic error:error]) return nil;
    return path;
}
@end
