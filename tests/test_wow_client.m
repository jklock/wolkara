// Protocol pipeline tests: replace the transport, never contact a real server.
#import <Foundation/Foundation.h>
#include <assert.h>
#import "../launcher/WoW/Client.h"

@interface TKWoWClient (TestTransport)
- (NSData *)fetch:(NSURL *)url limit:(NSUInteger)limit error:(NSError **)error;
@end
@interface TKFixtureClient : TKWoWClient
@property(nonatomic) NSMutableDictionary<NSString *,NSData *> *responses;
@property(nonatomic) NSUInteger calls;
@end
@implementation TKFixtureClient
- (NSData *)fetch:(NSURL *)url limit:(NSUInteger)limit error:(NSError **)error {
    self.calls++;
    assert([url.scheme isEqual:@"https"]);
    NSData *data=self.responses[url.lastPathComponent];
    if (!data || data.length>limit) { if (error) *error=TKWoWError(@"Synthetic transport failure."); return nil; }
    return data;
}
@end
static NSData *Text(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
static void BE(NSMutableData *d, uint64_t n, NSUInteger size) {
    for (NSUInteger i=size;i>0;i--) { uint8_t byte=(uint8_t)(n>>((i-1)*8)); [d appendBytes:&byte length:1]; }
}
static NSData *Hash(NSData *data) {
    NSString *hex=TKWoWMD5(data); NSMutableData *bytes=[NSMutableData new];
    for (NSUInteger i=0;i<16;i++) BE(bytes,strtoul([[hex substringWithRange:NSMakeRange(i*2,2)] UTF8String],NULL,16),1);
    return bytes;
}
static NSData *Wrap(NSData *data) {
    NSMutableData *raw=[Text(@"BLTE") mutableCopy]; BE(raw,0,4); BE(raw,'N',1); [raw appendData:data]; return raw;
}
static NSString *Reference(NSString *name, NSData *data, TKFixtureClient *client) {
    NSData *raw=Wrap(data); client.responses[TKWoWMD5(raw)]=raw;
    return [NSString stringWithFormat:@"%@ = %@ %@\n%@-size = %lu %lu\n",name,TKWoWMD5(data),TKWoWMD5(raw),name,(unsigned long)data.length,(unsigned long)raw.length];
}
int main(void) {
    @autoreleasepool {
        TKFixtureClient *client=[TKFixtureClient new]; client.responses=[NSMutableDictionary new];
        NSData *original=Text(@"test"), *raw=Wrap(original); client.responses[TKWoWMD5(raw)]=raw;
        NSMutableData *install=[Text(@"IN") mutableCopy]; BE(install,1,1); BE(install,16,1); BE(install,0,2); BE(install,1,4);
        [install appendData:Text(@"Test.app/Contents/MacOS/Test")]; BE(install,0,1); [install appendData:Hash(original)]; BE(install,original.length,4);
        NSMutableData *encoding=[Text(@"EN") mutableCopy]; BE(encoding,1,1); BE(encoding,16,1); BE(encoding,16,1);
        BE(encoding,1,2); BE(encoding,1,2); BE(encoding,1,4); BE(encoding,0,4); BE(encoding,0,1); BE(encoding,0,4);
        [encoding appendData:[NSMutableData dataWithLength:32]];
        BE(encoding,1,1); BE(encoding,original.length,5); [encoding appendData:Hash(original)]; [encoding appendData:Hash(raw)]; encoding.length=22+32+1024;
        NSString *config=[NSString stringWithFormat:@"build-uid = wow_classic_beta\n%@%@",Reference(@"install",install,client),Reference(@"encoding",encoding,client)];
        NSString *build=TKWoWMD5(Text(config)), *cdn=TKWoWMD5(Text(@"cdn")); client.responses[build]=Text(config);
        NSString *versions=[NSString stringWithFormat:@"Region|BuildConfig|CDNConfig|VersionsName\neu|%@|%@|synthetic-1\n",build,cdn];
        client.responses[@"versions"]=Text(versions);
        client.responses[@"cdns"]=Text(@"Name|Path|Servers\neu|tpr/wow|https://level3.ssl.blizzard.com/?fallback=1\n");
        NSError *error=nil;
        NSDictionary *plan=[client planForProduct:@"wow_classic_beta" region:@"eu" locale:@"enUS" error:&error];
        assert(plan && !error && [plan[@"files"] count]==1 && ![plan[@"complete"] boolValue]);
        NSDictionary *file=plan[@"files"][0];
        NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *path=[client stageFile:file plan:plan directory:directory error:&error];
        assert(path && !error && [[NSData dataWithContentsOfFile:path] isEqual:original]);
        // Reuse only a checksum-verified encoding cache. A damaged one is refetched.
        NSString *cache=[directory stringByAppendingPathComponent:[TKWoWMD5(encoding) stringByAppendingString:@".encoding"]];
        [Text(@"bad") writeToFile:cache atomically:YES];
        assert([client stageFile:file plan:plan directory:directory error:&error]);
        assert([[NSData dataWithContentsOfFile:cache] isEqual:encoding]);
        // A published patch invalidates the staged plan before any payload request.
        client.responses[@"versions"]=Text([versions stringByReplacingOccurrencesOfString:build withString:TKWoWMD5(Text(@"new build"))]);
        NSUInteger calls=client.calls;
        assert(![client stageFile:file plan:plan directory:directory error:&error]);
        assert(client.calls==calls+1 && [error.localizedDescription containsString:@"newer build"]);
        assert([[NSData dataWithContentsOfFile:path] isEqual:original]);
        // Corrupt configuration, duplicate region and transport failures stop the plan.
        client.responses[@"versions"]=Text(versions); client.responses[build]=Text(@"corrupt");
        assert(![client planForProduct:@"wow_classic_beta" region:@"eu" locale:@"enUS" error:&error]);
        assert([error.localizedDescription containsString:@"checksum"]);
        client.responses[build]=Text(config);
        client.responses[@"versions"]=Text([versions stringByAppendingString:[[versions componentsSeparatedByString:@"\n"][1] stringByAppendingString:@"\n"]]);
        assert(![client versionForProduct:@"wow_classic_beta" region:@"eu" error:&error]);
        assert([error.localizedDescription containsString:@"Ambiguous"]);
        [client.responses removeObjectForKey:@"versions"];
        assert(![client planForProduct:@"wow_classic_beta" region:@"eu" locale:@"enUS" error:&error]);
        assert([error.localizedDescription containsString:@"transport"]);
        client.responses[@"versions"]=Text(versions);
        client.responses[@"cdns"]=Text(@"Name|Path|Servers\neu|tpr/wow|http://level3.blizzard.com/\n");
        assert(![client planForProduct:@"wow_classic_beta" region:@"eu" locale:@"enUS" error:&error]);
        assert([error.localizedDescription containsString:@"HTTPS"]);
        assert([NSFileManager.defaultManager removeItemAtPath:directory error:&error]);
    }
    puts("WoW client tests PASS: verified staging, cache repair, patch invalidation, malformed metadata and failed transport.");
    return 0;
}
