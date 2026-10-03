#import <Foundation/Foundation.h>
#import "../launcher/WoW/Client.h"
#include <assert.h>
#include <zlib.h>

static NSData *Text(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
static void BE(NSMutableData *d, uint64_t n, NSUInteger size) {
    for (NSUInteger i=size;i>0;i--) { uint8_t byte=(uint8_t)(n>>((i-1)*8)); [d appendBytes:&byte length:1]; }
}
static void CString(NSMutableData *d, NSString *s) {
    [d appendData:Text(s)]; BE(d,0,1);
}
static NSData *HashBytes(NSData *d) {
    NSString *hex=TKWoWMD5(d); NSMutableData *bytes=[NSMutableData new];
    for (NSUInteger i=0;i<16;i++) BE(bytes,strtoul([[hex substringWithRange:NSMakeRange(i*2,2)] UTF8String],NULL,16),1);
    return bytes;
}
static NSData *BLTE(NSData *decoded, BOOL table, BOOL compressed) {
    NSMutableData *chunk=[NSMutableData new]; BE(chunk,compressed?'Z':'N',1);
    if (compressed) {
        uLongf n=compressBound(decoded.length); NSMutableData *z=[NSMutableData dataWithLength:n];
        assert(compress(z.mutableBytes,&n,decoded.bytes,decoded.length)==Z_OK); z.length=n; [chunk appendData:z];
    } else [chunk appendData:decoded];
    NSMutableData *d=[Text(@"BLTE") mutableCopy]; BE(d,table?36:0,4);
    if (table) { BE(d,15,1); BE(d,1,3); BE(d,chunk.length,4); BE(d,decoded.length,4); [d appendData:HashBytes(chunk)]; }
    [d appendData:chunk]; return d;
}
static NSString *EKey(NSData *d, BOOL table) { return TKWoWMD5(table?[d subdataWithRange:NSMakeRange(0,36)]:d); }
static NSData *Install(NSString *path, uint8_t bit) {
    NSMutableData *d=[Text(@"IN") mutableCopy]; BE(d,1,1); BE(d,16,1); BE(d,1,2); BE(d,1,4);
    CString(d,@"OSX"); BE(d,1,2); BE(d,bit,1);
    CString(d,path); [d appendData:HashBytes(Text(@"synthetic"))]; BE(d,9,4); return d;
}
static void TestBLTE(void) {
    NSData *plain=Text(@"Synthetic test content, no third-party files.");
    for (int table=0;table<2;table++) for (int compressed=0;compressed<2;compressed++) {
        NSData *d=BLTE(plain,table,compressed); NSError *e=nil;
        assert([TKWoWDecode(d,EKey(d,table),TKWoWMD5(plain),plain.length,1024,&e) isEqual:plain]); assert(!e);
        // Every truncation must fail, never over-read.
        for (NSUInteger n=0;n<d.length;n++) {
            assert(!TKWoWDecode([d subdataWithRange:NSMakeRange(0,n)],EKey(d,table),TKWoWMD5(plain),plain.length,1024,&e)); assert(e);
        }
        assert(!TKWoWDecode(d,EKey(d,table),TKWoWMD5(plain),plain.length,plain.length-1,&e));
        NSMutableData *bad=[d mutableCopy]; ((uint8_t *)bad.mutableBytes)[bad.length-1]^=1;
        assert(!TKWoWDecode(bad,EKey(d,table),TKWoWMD5(plain),plain.length,1024,&e));
        assert(!TKWoWDecode(d,EKey(d,table),TKWoWMD5(Text(@"wrong")),plain.length,1024,&e));
        assert(!TKWoWDecode(d,EKey(d,table),TKWoWMD5(plain),plain.length-1,1024,&e));
        assert(!TKWoWDecode(d,EKey(d,table),TKWoWMD5(plain),plain.length+1,1024,&e));
    }
    NSMutableData *encrypted=[Text(@"BLTE") mutableCopy]; BE(encrypted,0,4); [encrypted appendData:Text(@"Eopaque")];
    NSError *e=nil; assert(!TKWoWDecode(encrypted,EKey(encrypted,NO),TKWoWMD5(plain),plain.length,1024,&e));
    assert([e.localizedDescription containsString:@"encryption"]);
    // A valid zlib stream plus junk must not be accepted.
    NSMutableData *suffix=[BLTE(plain,NO,YES) mutableCopy]; BE(suffix,0,1);
    assert(!TKWoWDecode(suffix,EKey(suffix,NO),TKWoWMD5(plain),plain.length,1024,&e));
    // A highly compressible payload must still respect the declared output length.
    NSData *bomb=[NSMutableData dataWithLength:1024*1024]; NSData *compressed=BLTE(bomb,NO,YES);
    assert(!TKWoWDecode(compressed,EKey(compressed,NO),TKWoWMD5(bomb),16,4096,&e));
}
static void TestInstall(void) {
    NSError *e=nil; NSData *d=Install(@"Test.app\\Contents/MacOS/Test",128);
    NSArray *entries=TKWoWInstall(d,&e); assert(entries.count==1); assert(!e);
    assert([entries[0][@"path"] isEqual:@"Test.app/Contents/MacOS/Test"]);
    assert([entries[0][@"tags"][@"1"] containsObject:@"OSX"]);
    assert(TKWoWMacFiles(entries,@"enUS",@"eu").count==1);
    for (NSUInteger n=0;n<d.length;n++) assert(!TKWoWInstall([d subdataWithRange:NSMakeRange(0,n)],&e));
    for (NSString *path in @[@"../Test",@"/Test",@"C:\\Test",@"a//b",@"a/./b",@"a/../../b",@"a\nb",@""]) {
        assert(!TKWoWInstall(Install(path,128),&e)); assert(e);
    }
    NSMutableData *bad=[d mutableCopy]; ((uint8_t *)bad.mutableBytes)[9]=255;
    assert(!TKWoWInstall(bad,&e));
    bad=[d mutableCopy]; BE(bad,0,1); assert(!TKWoWInstall(bad,&e));
    NSArray *files=@[
        @{@"tags":@{@"1":@[@"Windows"]}},
        @{@"tags":@{@"1":@[@"OSX"],@"2":@[@"x86_64"]}},
        @{@"tags":@{@"1":@[@"OSX"],@"3":@[@"esES"]}},
        @{@"tags":@{@"1":@[@"OSX"],@"4":@[@"US"]}},
        @{@"tags":@{@"1":@[@"OSX"],@"2":@[@"arm64"],@"3":@[@"enUS"],@"4":@[@"EU"]}}
    ];
    assert(TKWoWMacFiles(files,@"enUS",@"eu").count==1);
}
static void TestManyChunks(void) {
    // A mutable download with hundreds of chunks caught a whole-buffer copy per
    // slice in Foundation. Keep decompression bounded to one final output buffer.
    const NSUInteger count=256, size=64*1024;
    NSData *plain=[NSMutableData dataWithLength:count*size];
    NSMutableData *chunk=[NSMutableData dataWithLength:size+1]; ((uint8_t *)chunk.mutableBytes)[0]='N';
    NSMutableData *raw=[Text(@"BLTE") mutableCopy]; BE(raw,12+24*count,4); BE(raw,15,1); BE(raw,count,3);
    NSData *hash=HashBytes(chunk);
    for (NSUInteger i=0;i<count;i++) { BE(raw,chunk.length,4); BE(raw,size,4); [raw appendData:hash]; }
    NSString *key=TKWoWMD5(raw);
    for (NSUInteger i=0;i<count;i++) [raw appendData:chunk];
    NSError *error=nil;
    NSData *decoded=TKWoWDecode(raw,key,TKWoWMD5(plain),plain.length,32*1024*1024,&error);
    assert([decoded isEqual:plain]); assert(!error);
    // Total decoded length and table size must agree, even with valid checksums.
    assert(!TKWoWDecode(raw,key,TKWoWMD5(plain),plain.length-1,32*1024*1024,&error));
}
static void TestEncoding(void) {
    NSData *plain=Text(@"own fixture"), *encoded=Text(@"own encoding");
    NSMutableData *d=[Text(@"EN") mutableCopy]; BE(d,1,1); BE(d,16,1); BE(d,16,1);
    BE(d,1,2); BE(d,1,2); BE(d,1,4); BE(d,0,4); BE(d,0,1); BE(d,0,4);
    [d appendData:[NSMutableData dataWithLength:32]];
    BE(d,1,1); BE(d,plain.length,5); [d appendData:HashBytes(plain)]; [d appendData:HashBytes(encoded)];
    d.length=22+32+1024;
    NSError *e=nil; assert([TKWoWEncodingKey(d,TKWoWMD5(plain),&e) isEqual:TKWoWMD5(encoded)]);
    for (NSUInteger n=0;n<d.length;n++) assert(!TKWoWEncodingKey([d subdataWithRange:NSMakeRange(0,n)],TKWoWMD5(plain),&e));
    assert(!TKWoWEncodingKey(d,TKWoWMD5(Text(@"missing")),&e));
    ((uint8_t *)d.mutableBytes)[54]=255; assert(!TKWoWEncodingKey(d,TKWoWMD5(plain),&e));
}
static void TestTextAndCancellation(void) {
    NSError *e=nil;
    NSArray *rows=TKWoWTable(Text(@"# comment\r\nRegion!STRING:0|Build!HEX:16\r\neu|abcd\r\n"),&e);
    assert(rows.count==1 && [rows[0][@"Region"] isEqual:@"eu"]);
    for (NSString *s in @[@"",@"A|A\nx|y",@"A|B\nx",@"A|B\nx|y|z"]) assert(!TKWoWTable(Text(s),&e));
    assert(!TKWoWTable([NSData dataWithBytes:"\xff" length:1],&e));
    assert([TKWoWConfig(Text(@"# comment\na = x\nb = y\n"),&e)[@"a"] isEqual:@"x"]);
    assert(!TKWoWConfig(Text(@"a = x\na = y"),&e)); assert(!TKWoWConfig(Text(@"a x"),&e));
    assert(TKWoWHashValid(@"0123456789abcdef0123456789abcdef")); assert(!TKWoWHashValid(@"../../secret"));
    TKWoWClient *client=[TKWoWClient new]; [client cancel];
    assert(![client versionForProduct:@"wow_classic_beta" region:@"eu" error:&e]);
    assert([e.localizedDescription containsString:@"cancelled"]);
    assert(![client versionForProduct:@"../x" region:@"eu" error:&e]);
    NSDictionary *latest=@{@"BuildConfig":TKWoWMD5(Text(@"build")),@"CDNConfig":TKWoWMD5(Text(@"cdn")),@"VersionsName":@"1.2.3"};
    NSDictionary *installed=@{@"Product":@"wow_classic_beta",@"Active":@"1",@"Build Key":latest[@"BuildConfig"],@"CDN Key":latest[@"CDNConfig"],@"Version":@"1.2.3"};
    assert(TKWoWBuildCurrent(@[installed],@"wow_classic_beta",latest));
    assert(!TKWoWBuildCurrent(@[],@"wow_classic_beta",latest));
    assert(!TKWoWBuildCurrent(@[installed,installed],@"wow_classic_beta",latest));
    assert(!TKWoWBuildCurrent(@[installed],@"wow",latest));
    assert(!TKWoWBuildCurrent(@[installed],@"wow_classic_beta",@{}));
    for (NSString *key in @[@"Active",@"Build Key",@"CDN Key",@"Version"]) {
        NSMutableDictionary *wrong=[installed mutableCopy]; wrong[key]=@"old";
        assert(!TKWoWBuildCurrent(@[wrong],@"wow_classic_beta",latest));
    }
}
int main(void) {
    @autoreleasepool { TestBLTE(); TestInstall(); TestManyChunks(); TestEncoding(); TestTextAndCancellation(); }
    puts("WoW manifest tests PASS (synthetic fixtures)."); return 0;
}
