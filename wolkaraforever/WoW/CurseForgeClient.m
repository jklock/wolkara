#import "CurseForgeClient.h"
// The app target has WolkaraForeverLog; a standalone host test compiles this
// file on its own. Log when it is there, stay silent when it is not.
#if __has_include("../App/WolkaraForeverLog.h")
#import "../App/WolkaraForeverLog.h"
#define TKAddonLog(...) WKLog("addons", __VA_ARGS__)
#else
#define TKAddonLog(...) do {} while (0)
#endif

static NSString *const BaseURL=@"https://api.curseforge.com/v1";
static NSError *CFError(NSString *message) { return [NSError errorWithDomain:@"WolkaraForever.CurseForge" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }

@implementation TKCurseForgeClient { NSString *_key; NSURLSession *_session; }
- (instancetype)initWithAPIKey:(NSString *)key { if((self=[super init])){_key=key.copy;_session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];}return self; }
- (void)get:(NSString *)path completion:(TKCurseForgeCompletion)completion {
    NSURL *url=[NSURL URLWithString:[BaseURL stringByAppendingString:path]]; if(!url){completion(nil,CFError(@"Invalid CurseForge API URL."));return;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];[request setValue:_key forHTTPHeaderField:@"x-api-key"];
    NSURLSessionDataTask *task=[_session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *failure){NSHTTPURLResponse *http=(id)response;if(failure){completion(nil,failure);return;}if(http.statusCode==403){TKAddonLog(@"GET %@ rejected: HTTP 403",path);completion(nil,CFError(@"CurseForge rejected this Core API key. Create an approved Core API key in the developer console."));return;}if(http.statusCode<200||http.statusCode>=300){TKAddonLog(@"GET %@ failed: HTTP %ld",path,(long)http.statusCode);completion(nil,CFError([NSString stringWithFormat:@"CurseForge API returned HTTP %ld.",(long)http.statusCode]));return;}id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:&failure];if(![value isKindOfClass:NSDictionary.class]||failure){completion(nil,CFError(@"CurseForge returned invalid JSON."));return;}id payload=value[@"data"];if(!payload || payload == NSNull.null){completion(nil,CFError(@"CurseForge returned no data."));return;}completion(payload,nil);}];
    [task resume];
}
- (void)categoriesForGameID:(NSInteger)gameID completion:(TKCurseForgeCompletion)completion { [self get:[NSString stringWithFormat:@"/categories?gameId=%ld",(long)gameID] completion:completion]; }
- (void)browseModsWithQuery:(NSString *)query sortField:(NSInteger)sortField sortOrder:(NSString *)sortOrder categoryID:(NSNumber *)categoryID index:(NSUInteger)index completion:(TKCurseForgeCompletion)completion {
    [self browseModsWithQuery:query sortField:sortField sortOrder:sortOrder categoryID:categoryID
                  gameVersion:nil classID:nil index:index completion:completion];
}
- (void)browseModsWithQuery:(NSString *)query sortField:(NSInteger)sortField sortOrder:(NSString *)sortOrder categoryID:(NSNumber *)categoryID gameVersion:(NSString *)gameVersion classID:(NSNumber *)classID index:(NSUInteger)index completion:(TKCurseForgeCompletion)completion {
    NSURLComponents *c=[NSURLComponents componentsWithString:@"https://placeholder"]; NSMutableArray *items=[@[[NSURLQueryItem queryItemWithName:@"gameId" value:@"1"],[NSURLQueryItem queryItemWithName:@"pageSize" value:@"50"],[NSURLQueryItem queryItemWithName:@"index" value:[NSString stringWithFormat:@"%lu",(unsigned long)index]],[NSURLQueryItem queryItemWithName:@"sortField" value:[NSString stringWithFormat:@"%ld",(long)sortField]],[NSURLQueryItem queryItemWithName:@"sortOrder" value:sortOrder?:@"desc"]] mutableCopy];
    if(query.length)[items addObject:[NSURLQueryItem queryItemWithName:@"searchFilter" value:query]];
    if(categoryID)[items addObject:[NSURLQueryItem queryItemWithName:@"categoryId" value:categoryID.stringValue]];
    if(gameVersion.length)[items addObject:[NSURLQueryItem queryItemWithName:@"gameVersion" value:gameVersion]];
    if(classID)[items addObject:[NSURLQueryItem queryItemWithName:@"classId" value:classID.stringValue]];
    c.queryItems=items;
    NSURL *url=[NSURL URLWithString:[BaseURL stringByAppendingFormat:@"/mods/search?%@",c.percentEncodedQuery]]; NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];[request setValue:_key forHTTPHeaderField:@"x-api-key"];
    [[_session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *failure){NSHTTPURLResponse *http=(id)response;if(failure){TKAddonLog(@"mods/search failed: %@",failure.localizedDescription);completion(nil,failure);return;}if(http.statusCode==403){TKAddonLog(@"mods/search rejected: HTTP 403");completion(nil,CFError(@"CurseForge rejected this Core API key."));return;}id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;if(http.statusCode<200||http.statusCode>=300||![value isKindOfClass:NSDictionary.class]){completion(nil,CFError(http.statusCode?[NSString stringWithFormat:@"CurseForge API returned HTTP %ld.",(long)http.statusCode]:@"CurseForge returned invalid JSON."));return;}if(![value[@"data"] isKindOfClass:NSArray.class]){completion(nil,CFError(@"CurseForge returned no mod list."));return;}completion(value,nil);} ] resume];
}
- (void)latestFileForModID:(NSNumber *)modID gameVersion:(NSString *)gameVersion completion:(TKCurseForgeCompletion)completion { [self get:[NSString stringWithFormat:@"/mods/%@/files?pageSize=50",modID] completion:^(id value,NSError *error){if(error){completion(nil,error);return;}if (![value isKindOfClass:NSArray.class]) { completion(nil,CFError(@"CurseForge returned an invalid file list.")); return; } NSArray *files=value;NSArray *matches=[files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id item,NSDictionary *bindings){(void)bindings;return [item isKindOfClass:NSDictionary.class] && [item[@"gameVersions"] isKindOfClass:NSArray.class] && [item[@"isAvailable"] isKindOfClass:NSNumber.class] && [item[@"fileDate"] isKindOfClass:NSString.class] && [item[@"gameVersions"] containsObject:gameVersion] && [item[@"isAvailable"] boolValue];}]];NSDictionary *latest=[matches sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"fileDate"] compare:a[@"fileDate"]];}].firstObject;completion(latest,latest?nil:CFError([NSString stringWithFormat:@"This project has no file tagged %@.",gameVersion]));}]; }
- (void)downloadURLForModID:(NSNumber *)modID fileID:(NSNumber *)fileID completion:(TKCurseForgeCompletion)completion { [self get:[NSString stringWithFormat:@"/mods/%@/files/%@/download-url",modID,fileID] completion:^(id value,NSError *error){if(error){completion(nil,error);return;}completion([value isKindOfClass:NSString.class]?value:nil,[value isKindOfClass:NSString.class]?nil:CFError(@"CurseForge returned an invalid download URL."));}]; }
- (NSURLRequest *)assetRequestForURL:(NSString *)string error:(NSError **)error {
    NSURL *url=[NSURL URLWithString:string]; NSString *host=url.host.lowercaseString;
    if(![url.scheme.lowercaseString isEqual:@"https"] || !([host isEqual:@"forgecdn.net"] || [host hasSuffix:@".forgecdn.net"])) { if(error)*error=CFError(@"CurseForge returned an untrusted asset host."); return nil; }
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];
    // CurseForge now attributes CDN downloads through the same API credential, so the key goes
    // with the request. Reviewed 2026-10-17 and left as it is: the allowlist above is
    // CurseForge's own domain, and the only caller in the app passes a URL this client has just
    // been given by the API. Anything that changes who calls this method inherits the question,
    // which is why it is written down here rather than left to the header.
    [request setValue:_key forHTTPHeaderField:@"x-api-key"];
    return request;
}
@end
