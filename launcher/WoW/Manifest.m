#import "Manifest.h"
#import <CommonCrypto/CommonDigest.h>
#include <zlib.h>

// BLTE / install / encoding layouts adapted from TACTSharp (MIT).
// See NOTICE.md. All fixtures in this repository are synthetic.

NSError *TKWoWError(NSString *message) {
    return [NSError errorWithDomain:@"Tolkara.WoW" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static id Fail(NSError **error, NSString *message) {
    if (error) *error=TKWoWError(message);
    return nil;
}
NSArray<NSDictionary *> *TKWoWProducts(void) {
    return @[
        @{@"id":@"wow_classic_beta", @"name":@"Forever · Beta", @"folder":@"_classic_beta_"},
        @{@"id":@"wow_classic_era", @"name":@"Classic Era", @"folder":@"_classic_era_"},
        @{@"id":@"wow_classic", @"name":@"Classic", @"folder":@"_classic_"},
        @{@"id":@"wow", @"name":@"Retail", @"folder":@"_retail_"},
        @{@"id":@"wow_beta", @"name":@"Retail · Beta", @"folder":@"_beta_"}
    ];
}
BOOL TKWoWHashValid(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length!=32) return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static NSString *Hex(const uint8_t *bytes, NSUInteger length) {
    NSMutableString *s=[NSMutableString stringWithCapacity:length*2];
    for (NSUInteger i=0;i<length;i++) [s appendFormat:@"%02x",bytes[i]];
    return s;
}
NSString *TKWoWMD5(NSData *data) {
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // MD5 is required by the CDN format; transport still uses HTTPS.
    CC_MD5(data.bytes,(CC_LONG)data.length,digest);
#pragma clang diagnostic pop
    return Hex(digest,sizeof(digest));
}
static NSArray<NSString *> *Lines(NSData *data, NSError **error) {
    if (data.length>2*1024*1024) return Fail(error,@"Metadata exceeds its size limit.");
    NSString *s=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s || [s rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location!=NSNotFound)
        return Fail(error,@"Invalid metadata text.");
    NSMutableArray *lines=[NSMutableArray new];
    for (NSString *raw in [s componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length && ![line hasPrefix:@"#"]) [lines addObject:line];
    }
    return lines;
}
NSArray<NSDictionary<NSString *, NSString *> *> *TKWoWTable(NSData *data, NSError **error) {
    NSArray *lines=Lines(data,error);
    if (!lines) return nil;
    if (lines.count<2) return Fail(error,@"No version information is published for this channel.");
    NSMutableArray *keys=[NSMutableArray new], *rows=[NSMutableArray new];
    for (NSString *column in [lines[0] componentsSeparatedByString:@"|"]) {
        NSString *key=[column componentsSeparatedByString:@"!"][0];
        if (!key.length || [keys containsObject:key]) return Fail(error,@"Invalid metadata columns.");
        [keys addObject:key];
    }
    if (keys.count>64 || lines.count>4096) return Fail(error,@"Metadata has too many rows or columns.");
    for (NSUInteger i=1;i<lines.count;i++) {
        NSArray *values=[lines[i] componentsSeparatedByString:@"|"];
        if (values.count!=keys.count) return Fail(error,@"Incomplete metadata row.");
        [rows addObject:[NSDictionary dictionaryWithObjects:values forKeys:keys]];
    }
    return rows;
}
NSDictionary<NSString *, NSString *> *TKWoWConfig(NSData *data, NSError **error) {
    NSArray *lines=Lines(data,error);
    if (!lines) return nil;
    NSMutableDictionary *config=[NSMutableDictionary new];
    for (NSString *line in lines) {
        NSRange split=[line rangeOfString:@" = "];
        if (!split.length) return Fail(error,@"Invalid build configuration.");
        NSString *key=[line substringToIndex:split.location];
        if (!key.length || config[key]) return Fail(error,@"Duplicate build configuration field.");
        config[key]=[line substringFromIndex:NSMaxRange(split)];
    }
    return config;
}
static uint64_t BE(const uint8_t *p, NSUInteger n) {
    uint64_t value=0;
    for (NSUInteger i=0;i<n;i++) value=(value<<8)|p[i];
    return value;
}
static BOOL Chunk(const uint8_t *p, NSUInteger length, uint8_t *output, NSUInteger expected, NSError **error) {
    if (!length) { Fail(error,@"Empty BLTE chunk."); return NO; }
    if (p[0]=='N') {
        if (length-1!=expected) { Fail(error,@"Incorrect uncompressed chunk size."); return NO; }
        memcpy(output,p+1,expected); return YES;
    }
    if (p[0]!='Z') {
        Fail(error,p[0]=='E' ? @"This file requires an encryption key. Encrypted extraction is not supported." : @"Unsupported BLTE chunk type.");
        return NO;
    }
    // Decode directly into one preallocated result. Foundation subdata slices of
    // a mutable download can retain/copy its entire backing store per chunk.
    uint8_t emptyOutput;
    z_stream stream={0};
    stream.next_in=(Bytef *)(p+1); stream.avail_in=(uInt)(length-1);
    stream.next_out=expected?output:&emptyOutput; stream.avail_out=(uInt)(expected?:1);
    if (inflateInit(&stream)!=Z_OK) { Fail(error,@"Cannot initialize decompression."); return NO; }
    int result=inflate(&stream,Z_FINISH);
    BOOL valid=result==Z_STREAM_END && stream.total_out==expected && stream.avail_in==0;
    inflateEnd(&stream);
    if (!valid) Fail(error,@"Truncated, oversized or invalid compressed chunk.");
    return valid;
}
NSData *TKWoWDecode(NSData *data, NSString *encodingKey, NSString *contentKey,
    NSUInteger expectedSize, NSUInteger limit, NSError **error) {
    if (!TKWoWHashValid(encodingKey) || !TKWoWHashValid(contentKey) || !expectedSize ||
        limit>512*1024*1024 || expectedSize>limit || data.length>limit || data.length<9)
        return Fail(error,@"Invalid BLTE size or content hash.");
    const uint8_t *p=data.bytes;
    if (memcmp(p,"BLTE",4)) return Fail(error,@"Invalid BLTE signature.");
    NSUInteger header=(NSUInteger)BE(p+4,4);
    if (header>data.length || (header && header<12)) return Fail(error,@"Truncated BLTE header.");
    NSData *hashData=header ? [NSData dataWithBytes:p length:header] : data;
    if (![TKWoWMD5(hashData) isEqualToString:encodingKey]) return Fail(error,@"Encoded content hash mismatch.");
    NSMutableData *result=[NSMutableData dataWithLength:expectedSize];
    uint8_t *output=result.mutableBytes;
    if (!header) {
        if (!Chunk(p+8,data.length-8,output,expectedSize,error)) return nil;
    } else {
        NSUInteger count=(NSUInteger)BE(p+9,3), pos=header, outputPos=0;
        if (p[8]!=15 || !count || count>65536 || header!=12+24*count)
            return Fail(error,@"Unsupported or malformed BLTE chunk table.");
        for (NSUInteger i=0;i<count;i++) {
            const uint8_t *entry=p+12+i*24;
            NSUInteger compressed=(NSUInteger)BE(entry,4), decodedSize=(NSUInteger)BE(entry+4,4);
            if (!compressed || compressed>data.length-pos || decodedSize>expectedSize-outputPos)
                return Fail(error,@"BLTE chunk exceeds its bounds.");
            NSData *encoded=[NSData dataWithBytesNoCopy:(void *)(p+pos) length:compressed freeWhenDone:NO];
            if (![TKWoWMD5(encoded) isEqualToString:Hex(entry+8,16)]) return Fail(error,@"BLTE chunk checksum mismatch.");
            if (!Chunk(p+pos,compressed,output+outputPos,decodedSize,error)) return nil;
            pos+=compressed; outputPos+=decodedSize;
        }
        if (pos!=data.length || outputPos!=expectedSize) return Fail(error,@"BLTE length mismatch.");
    }
    if (![TKWoWMD5(result) isEqualToString:contentKey]) return Fail(error,@"Decoded content hash mismatch.");
    return result;
}
static NSString *ReadString(NSData *data, NSUInteger *pos) {
    const uint8_t *p=data.bytes;
    if (*pos>=data.length) return nil;
    const uint8_t *end=memchr(p+*pos,0,MIN(data.length-*pos,4097));
    if (!end) return nil;
    NSUInteger length=end-(p+*pos);
    NSString *s=[[NSString alloc] initWithBytes:p+*pos length:length encoding:NSUTF8StringEncoding];
    *pos+=length+1;
    return s;
}
static BOOL SafePath(NSString *path) {
    if (!path.length || [path hasPrefix:@"/"] || [path containsString:@":"] ||
        [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."]) return NO;
    return YES;
}
NSArray<NSDictionary *> *TKWoWInstall(NSData *data, NSError **error) {
    const uint8_t *p=data.bytes;
    if (data.length<10 || data.length>16*1024*1024 || memcmp(p,"IN",2) || p[2]!=1 || p[3]!=16)
        return Fail(error,@"Unsupported install manifest.");
    NSUInteger tagCount=(NSUInteger)BE(p+4,2), count=(NSUInteger)BE(p+6,4), pos=10;
    if (tagCount>256 || count>100000) return Fail(error,@"Install manifest exceeds its limits.");
    NSUInteger maskSize=(count+7)/8;
    NSMutableArray *tags=[NSMutableArray new], *entries=[NSMutableArray new];
    for (NSUInteger i=0;i<tagCount;i++) {
        NSString *name=ReadString(data,&pos);
        if (!name.length || data.length-pos<2+maskSize) return Fail(error,@"Truncated install tag.");
        NSNumber *type=@(BE(p+pos,2)); pos+=2;
        NSData *mask=[data subdataWithRange:NSMakeRange(pos,maskSize)]; pos+=maskSize;
        [tags addObject:@{@"name":name,@"type":type,@"mask":mask}];
    }
    for (NSUInteger i=0;i<count;i++) {
        NSString *path=[ReadString(data,&pos) stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if (!SafePath(path) || data.length-pos<20) return Fail(error,@"Unsafe path or truncated install entry.");
        NSString *key=Hex(p+pos,16); pos+=16;
        NSNumber *size=@(BE(p+pos,4)); pos+=4;
        NSMutableDictionary *entryTags=[NSMutableDictionary new];
        for (NSDictionary *tag in tags) {
            const uint8_t *mask=[tag[@"mask"] bytes];
            if (!(mask[i/8]&(0x80>>(i%8)))) continue;
            NSString *type=[tag[@"type"] stringValue];
            if (!entryTags[type]) entryTags[type]=[NSMutableArray new];
            [entryTags[type] addObject:tag[@"name"]];
        }
        // The manifest may contain the same path for different platforms/tags.
        [entries addObject:@{@"path":path,@"contentKey":key,@"size":size,@"tags":entryTags}];
    }
    if (pos!=data.length) return Fail(error,@"Unexpected install manifest suffix.");
    return entries;
}
NSArray<NSDictionary *> *TKWoWMacFiles(NSArray<NSDictionary *> *entries, NSString *locale, NSString *region) {
    NSMutableArray *selected=[NSMutableArray new];
    NSDictionary *selection=@{@"1":@"OSX",@"2":@"arm64",@"3":locale,@"4":region.uppercaseString};
    for (NSDictionary *entry in entries) {
        NSDictionary *tags=entry[@"tags"];
        BOOL matches=YES;
        for (NSString *type in selection) if ([tags[type] count] && ![tags[type] containsObject:selection[type]]) matches=NO;
        if (matches) [selected addObject:entry];
    }
    return selected;
}
BOOL TKWoWBuildCurrent(NSArray<NSDictionary *> *installedRows, NSString *product, NSDictionary *latest) {
    if (!TKWoWHashValid(latest[@"BuildConfig"]) || !TKWoWHashValid(latest[@"CDNConfig"])) return NO;
    NSDictionary *match=nil;
    for (NSDictionary *row in installedRows) {
        if (![row[@"Product"] isEqual:product] || ![row[@"Active"] isEqual:@"1"]) continue;
        if (match) return NO;
        match=row;
    }
    return match && [match[@"Build Key"] isEqual:latest[@"BuildConfig"]] &&
        [match[@"CDN Key"] isEqual:latest[@"CDNConfig"]] && [match[@"Version"] isEqual:latest[@"VersionsName"]];
}
NSString *TKWoWEncodingKey(NSData *data, NSString *contentKey, NSError **error) {
    const uint8_t *p=data.bytes;
    if (!TKWoWHashValid(contentKey) || data.length<22 || memcmp(p,"EN",2) || p[2]!=1 || p[3]!=16 || p[4]!=16 || p[17])
        return Fail(error,@"Unsupported encoding manifest.");
    NSUInteger pageSize=(NSUInteger)BE(p+5,2)*1024, pages=(NSUInteger)BE(p+9,4), strings=(NSUInteger)BE(p+18,4);
    if (!pageSize || strings>data.length-22 || pages>(data.length-22-strings)/32)
        return Fail(error,@"Truncated encoding page table.");
    NSUInteger start=22+strings+pages*32;
    if (pages>(data.length-start)/pageSize) return Fail(error,@"Truncated encoding pages.");
    uint8_t key[16];
    for (NSUInteger i=0;i<16;i++) key[i]=(uint8_t)strtoul([[contentKey substringWithRange:NSMakeRange(i*2,2)] UTF8String],NULL,16);
    // The manifest is content-verified before this lookup. Scan bounded pages;
    // stop at the first match, without building a dictionary of millions of files.
    for (NSUInteger page=0;page<pages;page++) {
        NSUInteger pos=start+page*pageSize, end=pos+pageSize;
        while (pos<end && p[pos]) {
            NSUInteger n=p[pos], length=22+16*n;
            if (length>end-pos) return Fail(error,@"Encoding entry crosses its page boundary.");
            if (!memcmp(p+pos+6,key,16)) return Hex(p+pos+22,16);
            pos+=length;
        }
    }
    return Fail(error,@"File is absent from the encoding manifest.");
}
