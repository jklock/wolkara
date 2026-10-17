#import "CurseForgeClient.h"
#include <stdio.h>

// A fake transport feeds the real client's parser. No key or network is used.
@interface TestTask : NSObject
@property(copy) void (^action)(void);
- (void)resume;
@end
@implementation TestTask
- (void)resume { self.action(); }
@end
@interface TestSession : NSObject
@property NSInteger status;
@property(copy) NSString *body;
@property(strong) NSError *failure;
@property(strong) NSURLRequest *request;
@end
@implementation TestSession
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    self.request = request;
    TestTask *task = [TestTask new];
    task.action = ^{ completion([self.body dataUsingEncoding:NSUTF8StringEncoding], [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:self.status HTTPVersion:@"HTTP/1.1" headerFields:@{}], self.failure); };
    return task;
}
@end
#define CHECK(x, label) do { checks++; if (!(x)) { fprintf(stderr,"FAIL: %s\n",label); return 1; } } while (0)
int main(void) {
    @autoreleasepool {
        NSUInteger checks = 0;
        TKCurseForgeClient *client = [[TKCurseForgeClient alloc] initWithAPIKey:@"fixture-key"];
        TestSession *session = [TestSession new];
        [client setValue:session forKey:@"session"];
        __block id result;
        __block NSError *error;
        __block NSUInteger calls;
        TKCurseForgeCompletion completion = ^(id value, NSError *problem) { result=value; error=problem; calls++; };
        for (NSString *body in @[@"[]", @"null", @"broken", @"{}", @"{\"data\":null}"]) {
            session.status = 200; session.body = body; calls=0;
            [client categoriesForGameID:1 completion:completion];
            CHECK(error && !result && calls==1, "malformed response fails once without exception");
        }
        for (NSNumber *status in @[@401, @403, @429, @500]) {
            session.status=status.integerValue; session.body=@"{}";
            [client categoriesForGameID:1 completion:completion];
            CHECK(error && !result, "HTTP failure reported");
        }
        session.status=200; session.body=@"{\"data\":[]}";
        [client categoriesForGameID:1 completion:completion];
        CHECK([result isKindOfClass:NSArray.class] && !error, "valid categories");
        CHECK([[session.request valueForHTTPHeaderField:@"x-api-key"] isEqual:@"fixture-key"], "API credential header");
        [client browseModsWithQuery:@"a&b café" sortField:2 sortOrder:@"desc" categoryID:@42 index:50 completion:completion];
        CHECK([result isKindOfClass:NSDictionary.class] && !error, "browse preserves pagination envelope");
        NSURLComponents *parts=[NSURLComponents componentsWithURL:session.request.URL resolvingAgainstBaseURL:NO];
        NSMutableDictionary *query=[NSMutableDictionary new];
        for (NSURLQueryItem *item in parts.queryItems) query[item.name]=item.value;
        CHECK([query[@"searchFilter"] isEqual:@"a&b café"] && [query[@"index"] isEqual:@"50"], "query encoding and pagination");
        session.body=@"{\"data\":[null,42,{}, {\"gameVersions\":[\"1.60.1\"],\"isAvailable\":true,\"fileDate\":\"2026-01-01\",\"id\":1}, {\"gameVersions\":[\"1.60.1\"],\"isAvailable\":true,\"fileDate\":\"2026-02-01\",\"id\":2}]}";
        [client latestFileForModID:@1 gameVersion:@"1.60.1" completion:completion];
        CHECK([result[@"id"] isEqual:@2] && !error, "invalid entries ignored; newest compatible file chosen");
        for (NSString *url in @[@"http://edge.forgecdn.net/a", @"https://forgecdn.net.evil.test/a", @"https://example.org/a"]) {
            NSError *failure=nil;
            CHECK(![client assetRequestForURL:url error:&failure] && failure, "untrusted asset URL refused");
        }
        NSError *failure=nil;
        CHECK([[client assetRequestForURL:@"https://edge.forgecdn.net/a" error:&failure] valueForHTTPHeaderField:@"x-api-key"] != nil, "approved CDN request");
        session.failure=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
        [client categoriesForGameID:1 completion:completion];
        CHECK(error==session.failure && !result, "transport error preserved");
        printf("CURSEFORGE PASS: %lu checks, no network or credentials\n", (unsigned long)checks);
    }
    return 0;
}
