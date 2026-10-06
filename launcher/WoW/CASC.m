#import "CASC.h"
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
// Public TACT/CASC format; reference readers: TACTSharp and CascLib (MIT).
// Jenkins mixing adapted from Bob Jenkins' lookup3 (May 2006, public domain).
static uint64_t BE(const uint8_t *p, NSUInteger n) { uint64_t v=0; while(n--) v=(v<<8)|*p++; return v; }
static uint64_t LE(const uint8_t *p, NSUInteger n) { uint64_t v=0; while(n) v=(v<<8)|p[--n]; return v; }
static void PutLE(uint8_t *p, uint64_t v, NSUInteger n) { while(n--) { *p++=(uint8_t)v; v>>=8; } }
static void PutBE(uint8_t *p, uint64_t v, NSUInteger n) { while(n) { p[--n]=(uint8_t)v; v>>=8; } }
static id Fail(NSError **error, NSString *s) { if(error) *error=TKWoWError(s); return nil; }
NSString *TKWoWHex(const uint8_t *p, NSUInteger n) { NSMutableString *s=[NSMutableString new]; for(NSUInteger i=0;i<n;i++) [s appendFormat:@"%02x",p[i]]; return s; }
BOOL TKWoWUnhex(NSString *s, uint8_t key[16]) {
    if(!TKWoWHashValid(s)) return NO;
    const char *p=s.UTF8String;
    for(int i=0;i<16;i++) { char pair[3]={p[2*i],p[2*i+1],0}; key[i]=(uint8_t)strtoul(pair,NULL,16); } return YES;
}
#define ROT(x,k) (((x)<<(k))|((x)>>(32-(k))))
uint32_t TKWoWJenkins(const void *bytes, size_t length, uint32_t *low, uint32_t seed) {
    const uint8_t *p=bytes; uint32_t a,b,c; a=b=c=0xdeadbeef+(uint32_t)length+seed; c+=low?*low:0;
    while(length>12) {
        a+=(uint32_t)LE(p,4); b+=(uint32_t)LE(p+4,4); c+=(uint32_t)LE(p+8,4);
        a-=c; a^=ROT(c,4); c+=b; b-=a; b^=ROT(a,6); a+=c; c-=b; c^=ROT(b,8); b+=a;
        a-=c; a^=ROT(c,16); c+=b; b-=a; b^=ROT(a,19); a+=c; c-=b; c^=ROT(b,4); b+=a;
        p+=12; length-=12;
    }
    if(length) {
        for(size_t i=0;i<length;i++) { uint32_t v=(uint32_t)p[i]<<((i%4)*8); if(i<4)a+=v; else if(i<8)b+=v; else c+=v; }
        c^=b; c-=ROT(b,14); a^=c; a-=ROT(c,11); b^=a; b-=ROT(a,25); c^=b; c-=ROT(b,16);
        a^=c; a-=ROT(c,4); b^=a; b-=ROT(a,14); c^=b; c-=ROT(b,24);
    }
    if(low) *low=b; return c;
}
#undef ROT
BOOL TKWoWEncodedValid(NSData *data, NSString *key, NSError **error) {
    const uint8_t *p=data.bytes;
    if(data.length<9 || data.length>256*1024*1024 || !TKWoWHashValid(key) || memcmp(p,"BLTE",4)) { Fail(error,@"Invalid encoded object."); return NO; }
    NSUInteger header=(NSUInteger)BE(p+4,4);
    if(header>data.length || (header && header<12)) { Fail(error,@"Invalid encoded header length."); return NO; }
    NSData *hash=header?[NSData dataWithBytesNoCopy:(void *)p length:header freeWhenDone:NO]:data;
    if(![TKWoWMD5(hash) isEqual:key]) { Fail(error,@"Encoded object checksum mismatch."); return NO; }
    if(!header) return YES;
    NSUInteger count=(NSUInteger)BE(p+9,3), pos=header;
    if(p[8]!=15 || !count || count>65536 || header!=12+24*count) { Fail(error,@"Invalid encoded chunk table."); return NO; }
    for(NSUInteger i=0;i<count;i++) {
        const uint8_t *e=p+12+24*i; NSUInteger size=(NSUInteger)BE(e,4);
        if(!size || size>data.length-pos) { Fail(error,@"Encoded chunk is truncated."); return NO; }
        NSData *chunk=[NSData dataWithBytesNoCopy:(void *)(p+pos) length:size freeWhenDone:NO];
        if(![TKWoWMD5(chunk) isEqual:TKWoWHex(e+8,16)]) { Fail(error,@"Encoded chunk checksum mismatch."); return NO; }
        pos+=size;
    }
    if(pos!=data.length) { Fail(error,@"Encoded length mismatch."); return NO; }
    // Encrypted assets are preserved as opaque original bytes, never decrypted.
    return YES;
}
NSData *TKWoWDownloads(NSData *data, NSString *locale, NSString *region, NSError **error) {
    const uint8_t *p=data.bytes;
    if(data.length<11 || data.length>256*1024*1024 || memcmp(p,"DL",2) || p[2]<1 || p[2]>3 || p[3]!=16 || p[4]>1)
        return Fail(error,@"Unsupported download manifest.");
    NSUInteger header=p[2]==1?11:p[2]==2?12:16;
    if(data.length<header) return Fail(error,@"Truncated download header.");
    NSUInteger count=(NSUInteger)BE(p+5,4), tags=(NSUInteger)BE(p+9,2), flags=p[2]>=2?p[11]:0;
    NSUInteger entrySize=22+(p[4]?4:0)+flags;
    if(flags>4 || count>5000000 || tags>256 || count>(data.length-header)/entrySize) return Fail(error,@"Download manifest bounds exceeded.");
    NSUInteger pos=header+count*entrySize, maskSize=(count+7)/8;
    NSMutableData *selected=[NSMutableData dataWithLength:maskSize]; memset(selected.mutableBytes,255,maskSize);
    NSDictionary *wanted=@{@1:@"OSX",@2:@"arm64",@3:locale,@4:region.uppercaseString};
    NSMutableDictionary *unions=[NSMutableDictionary new], *matches=[NSMutableDictionary new];
    NSMutableData *optional=[NSMutableData dataWithLength:maskSize];
    for(NSUInteger i=0;i<tags;i++) {
        if(pos>=data.length) return Fail(error,@"Missing download tag.");
        const uint8_t *end=memchr(p+pos,0,MIN(data.length-pos,4097));
        if(!end) return Fail(error,@"Invalid download tag name.");
        NSString *name=[[NSString alloc] initWithBytes:p+pos length:end-p-pos encoding:NSUTF8StringEncoding]; pos=(NSUInteger)(end-p)+1;
        if(!name.length || data.length-pos<2+maskSize) return Fail(error,@"Truncated download tag.");
        NSNumber *type=@(BE(p+pos,2)); pos+=2;
        // Alternate / HighRes / optional feature packs are not part of the
        // standard installation. Keep their opaque data out of mandatory updates.
        if(type.unsignedIntegerValue==0x4000) {
            uint8_t *bits=optional.mutableBytes;for(NSUInteger j=0;j<maskSize;j++)bits[j]|=p[pos+j];
        }
        if(wanted[type]) {
            if(!unions[type]) { unions[type]=[NSMutableData dataWithLength:maskSize]; matches[type]=[NSMutableData dataWithLength:maskSize]; }
            uint8_t *all=[unions[type] mutableBytes], *yes=[matches[type] mutableBytes];
            for(NSUInteger j=0;j<maskSize;j++) { all[j]|=p[pos+j]; if([name isEqual:wanted[type]]) yes[j]|=p[pos+j]; }
        }
        pos+=maskSize;
    }
    if(pos!=data.length) return Fail(error,@"Unexpected download suffix.");
    uint8_t *mask=selected.mutableBytes;
    const uint8_t *extra=optional.bytes;for(NSUInteger i=0;i<maskSize;i++)mask[i]&=(uint8_t)~extra[i];
    for(NSNumber *type in unions) {
        const uint8_t *all=[unions[type] bytes], *yes=[matches[type] bytes];
        for(NSUInteger i=0;i<maskSize;i++) mask[i]&=(uint8_t)(~all[i]|yes[i]);
    }
    NSMutableData *result=[NSMutableData new];
    for(NSUInteger i=0;i<count;i++) if(mask[i/8]&(0x80>>(i%8))) {
        const uint8_t *entry=p+header+i*entrySize; TKWoWDownloadEntry output={0};
        memcpy(output.key,entry,16); output.size=BE(entry+16,5);
        if(!output.size || output.size>256*1024*1024) return Fail(error,@"Download object exceeds the supported 256 MiB limit.");
        [result appendBytes:&output length:sizeof(output)];
    }
    if(!result.length)return Fail(error,@"No standard macOS content matches this edition and language.");
    return result;
}
NSData *TKWoWArchiveEntries(NSData *data, uint32_t archive, NSError **error) {
    if(data.length<36 || data.length>64*1024*1024) return Fail(error,@"Invalid archive index size.");
    const uint8_t *p=data.bytes, *f=p+data.length-20;
    NSUInteger page=(NSUInteger)f[3]*1024, count=(NSUInteger)LE(f+8,4);
    if(f[0]!=1 || f[1] || f[2] || !page || f[4]!=4 || f[5]!=4 || f[6]!=16 || f[7]!=8 || count>3000000)
        return Fail(error,@"Unsupported archive index.");
    uint8_t footer[20]={0}; memcpy(footer,f,12); uint8_t digest[16]; TKWoWUnhex(TKWoWMD5([NSData dataWithBytes:footer length:20]),digest);
    if(memcmp(digest,f+12,8)) return Fail(error,@"Archive footer checksum mismatch.");
    NSUInteger perPage=page/24, pages=(count+perPage-1)/perPage;
    if(pages>(data.length-36)/page) return Fail(error,@"Truncated archive pages.");
    NSMutableData *result=[NSMutableData dataWithLength:count*sizeof(TKWoWArchiveEntry)]; TKWoWArchiveEntry *entries=result.mutableBytes;
    for(NSUInteger i=0;i<count;i++) {
        const uint8_t *e=p+(i/perPage)*page+(i%perPage)*24;
        memcpy(entries[i].key,e,16); entries[i].size=(uint32_t)BE(e+16,4); entries[i].offset=(uint32_t)BE(e+20,4); entries[i].archive=archive;
        if(!entries[i].size || entries[i].size>256*1024*1024 || (uint64_t)entries[i].offset+entries[i].size>UINT32_MAX)
            return Fail(error,@"Invalid archive entry range.");
    }
    return result;
}

static int CompareLocal(const void *a,const void *b) { return memcmp(a,b,14); }
static unsigned Bucket(const uint8_t *p) { unsigned v=0; for(int i=0;i<9;i++)v^=p[i]; return (v^(v>>4))&15; }
static BOOL WriteAll(int fd,const void *bytes,size_t size) {
    const uint8_t *p=bytes; while(size) { ssize_t n=write(fd,p,size); if(n<0 && errno==EINTR)continue; if(n<=0)return NO; p+=n;size-=(size_t)n; } return YES;
}

// Optional local receipts, not a substitute for CDN checksums. Each compact
// record is a full EKey (16), packed location (5), and envelope size (4).
// Inode + nanosecond ctime catch replacements and writes even if mtime is reset.
static NSString *const VerificationFile=@".wolkara-verified";
static const NSUInteger ReceiptSize=25, ReceiptLimit=5000000, CacheLimit=160*1024*1024;
static NSString *SegmentPath(NSString *directory,uint64_t segment) {
    return [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"data.%03llu",segment]];
}
static NSArray *Stamp(const struct stat *s) {
    if(!S_ISREG(s->st_mode) || s->st_size<0)return nil;
    return @[[NSString stringWithFormat:@"%llu:%llu:%lld:%lld:%ld:%lld:%ld",
        (uint64_t)s->st_dev,(uint64_t)s->st_ino,(int64_t)s->st_size,
        (int64_t)s->st_mtimespec.tv_sec,s->st_mtimespec.tv_nsec,
        (int64_t)s->st_ctimespec.tv_sec,s->st_ctimespec.tv_nsec],
        [NSString stringWithFormat:@"%lld:%lld:%ld",(int64_t)s->st_size,
            (int64_t)s->st_mtimespec.tv_sec,s->st_mtimespec.tv_nsec]];
}
static NSArray *SegmentStamp(NSString *directory,uint64_t segment) {
    struct stat s;return lstat(SegmentPath(directory,segment).fileSystemRepresentation,&s)?nil:Stamp(&s);
}
static int CompareReceipt(const void *a,const void *b) { return memcmp(a,b,ReceiptSize); }
static NSArray *EmptyReceipts(void) {
    NSMutableArray *buckets=[NSMutableArray new];for(unsigned i=0;i<16;i++)[buckets addObject:[NSMutableData new]];return buckets;
}
static BOOL WriteVerification(NSDictionary *receipt,NSString *directory,NSError **error) { @autoreleasepool {
    NSData *body=[NSPropertyListSerialization dataWithPropertyList:receipt format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if(!body || body.length>CacheLimit-24) { Fail(error,@"Verification record exceeds its storage limit.");return NO; }
    NSMutableData *data=[[NSData dataWithBytes:"WKVERIFY" length:8] mutableCopy];
    uint8_t digest[16];TKWoWUnhex(TKWoWMD5(body),digest);[data appendBytes:digest length:16];[data appendData:body];
    return [data writeToFile:[directory stringByAppendingPathComponent:VerificationFile] options:NSDataWritingAtomic error:error];
}}
NSDictionary *TKWoWCASCVerificationSnapshot(NSString *directory) { @autoreleasepool {
    NSString *path=[directory stringByAppendingPathComponent:VerificationFile];
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK);if(fd<0)return nil;
    struct stat before,after;
    if(fstat(fd,&before) || !S_ISREG(before.st_mode) || before.st_size<24 || before.st_size>(off_t)CacheLimit) { close(fd);return nil; }
    NSMutableData *file=[NSMutableData dataWithLength:(NSUInteger)before.st_size];size_t done=0;
    while(done<file.length) { ssize_t n=read(fd,(uint8_t *)file.mutableBytes+done,file.length-done);if(n<0 && errno==EINTR)continue;if(n<=0)break;done+=(size_t)n; }
    BOOL stable=!fstat(fd,&after) && [Stamp(&before) isEqual:Stamp(&after)];close(fd);
    if(done!=file.length || !stable || memcmp(file.bytes,"WKVERIFY",8))return nil;
    NSData *body=[file subdataWithRange:NSMakeRange(24,file.length-24)];
    if(![TKWoWMD5(body) isEqual:TKWoWHex((const uint8_t *)file.bytes+8,16)])return nil;
    id receipt=[NSPropertyListSerialization propertyListWithData:body options:NSPropertyListImmutable format:NULL error:NULL];
    if(![receipt isKindOfClass:NSDictionary.class] || ![receipt[@"version"] isEqual:@1] ||
       ![receipt[@"segments"] isKindOfClass:NSDictionary.class] || [receipt[@"segments"] count]>1024 ||
       ![receipt[@"buckets"] isKindOfClass:NSArray.class] || [receipt[@"buckets"] count]!=16)return nil;
    NSDictionary *segments=receipt[@"segments"];NSMutableDictionary *valid=[NSMutableDictionary new];BOOL allowed[1024]={NO};
    for(id name in segments) {
        if(![name isKindOfClass:NSString.class] || ![name isEqual:@([name integerValue]).stringValue] || [name integerValue]<0 || [name integerValue]>=1024)return nil;
        id stamp=segments[name];
        if(![stamp isKindOfClass:NSArray.class] || [stamp count]!=2 ||
           ![stamp[0] isKindOfClass:NSString.class] || ![stamp[1] isKindOfClass:NSString.class])return nil;
        if([stamp isEqual:SegmentStamp(directory,[name integerValue])]) { valid[name]=stamp;allowed[[name integerValue]]=YES; }
    }
    NSMutableArray *filtered=[NSMutableArray new];NSUInteger count=0;
    for(unsigned bucket=0;bucket<16;bucket++) {
        id entries=receipt[@"buckets"][bucket];
        if(![entries isKindOfClass:NSData.class] || [entries length]%ReceiptSize)return nil;
        count+=[entries length]/ReceiptSize;if(count>ReceiptLimit)return nil;
        const uint8_t *p=[entries bytes];NSMutableData *kept=[NSMutableData new];
        for(NSUInteger i=0;i<[entries length];i+=ReceiptSize) {
            uint64_t size=LE(p+i+21,4),offset=BE(p+i+16,5)&0x3fffffff;
            if(Bucket(p+i)!=bucket || size<39 || size>256*1024*1024+30 || offset+size>0x40000000 ||
               (i && memcmp(p+i-ReceiptSize,p+i,16)>=0))return nil;
            if(allowed[BE(p+i+16,5)>>30])[kept appendBytes:p+i length:ReceiptSize];
        }
        [filtered addObject:kept];
    }
    return @{@"version":@1,@"segments":valid,@"buckets":filtered};
}}
BOOL TKWoWCASCCloneVerification(NSDictionary *snapshot,NSString *source,NSString *destination,NSError **error) { @autoreleasepool {
    // The caller captured this snapshot before clonefile, and finished cloning
    // before calling here. A changed source cannot bless a stale/partial clone.
    NSMutableDictionary *segments=[NSMutableDictionary new];BOOL allowed[1024]={NO};
    for(NSString *name in snapshot[@"segments"]) {
        NSArray *before=snapshot[@"segments"][name],*now=SegmentStamp(source,name.integerValue);
        NSArray *cloned=SegmentStamp(destination,name.integerValue);
        if([before isEqual:now] && [before[1] isEqual:cloned[1]]) { segments[name]=cloned;allowed[name.integerValue]=YES; }
    }
    NSMutableArray *buckets=[NSMutableArray new];
    for(NSData *entries in snapshot[@"buckets"]?:EmptyReceipts()) {
        NSMutableData *kept=[NSMutableData new];const uint8_t *p=entries.bytes;
        for(NSUInteger i=0;i<entries.length;i+=ReceiptSize)if(allowed[BE(p+i+16,5)>>30])[kept appendBytes:p+i length:ReceiptSize];
        [buckets addObject:kept];
    }
    if(![NSFileManager.defaultManager fileExistsAtPath:destination])return YES;
    return WriteVerification(@{@"version":@1,@"segments":segments,@"buckets":buckets},destination,error);
}}
@implementation TKWoWCASCStore {
    NSString *_directory;
    NSMutableArray<NSMutableData *> *_buckets;
    uint32_t _generation[16];
    NSMutableDictionary<NSString *,NSData *> *_added;
    NSArray<NSData *> *_verified;
    NSArray<NSMutableData *> *_pendingVerification;
    NSMutableDictionary<NSString *,NSArray *> *_segmentStamps;
    BOOL _verificationChanged;
    int _fd; uint32_t _segment; uint64_t _offset;
}
- (instancetype)initWithDirectory:(NSString *)directory error:(NSError **)error {
    if(!(self=[super init]))return nil; _fd=-1; _directory=directory; _buckets=[NSMutableArray new]; _added=[NSMutableDictionary new];
    if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error])return nil;
    NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:error]; if(!names)return nil;
    NSMutableDictionary *latest=[NSMutableDictionary new]; _segment=0;
    for(NSString *name in names) {
        if([name hasPrefix:@"data."] && (name.length==8 || name.length==9)) { NSString *number=[name substringFromIndex:5]; if([number rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location==NSNotFound)_segment=MAX(_segment,(uint32_t)number.intValue+1); }
        if(name.length!=14 || ![name hasSuffix:@".idx"])continue;
        NSString *hex=[name substringToIndex:10]; if([hex rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound)continue;
        unsigned bucket=(unsigned)strtoul([[hex substringToIndex:2] UTF8String],NULL,16); if(bucket>=16)continue;
        uint32_t version=(uint32_t)strtoul([[hex substringFromIndex:2] UTF8String],NULL,16);
        if(!latest[@(bucket)] || version>_generation[bucket]) { _generation[bucket]=version; latest[@(bucket)]=name; }
    }
    for(unsigned bucket=0;bucket<16;bucket++) {
        NSMutableData *entries=[NSMutableData new]; NSString *name=latest[@(bucket)];
        if(name) {
            NSData *data=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name] options:NSDataReadingMappedIfSafe error:error];
            const uint8_t *p=data.bytes;
            if(data.length<40 || data.length>64*1024*1024 || LE(p,4)!=16 || LE(p+8,2)!=7 || p[10]!=bucket || p[12]!=4 || p[13]!=5 || p[14]!=9 || p[15]!=30 || TKWoWJenkins(p+8,16,NULL,0)!=LE(p+4,4))return Fail(error,@"Unsupported or damaged local CASC index.");
            NSUInteger size=(NSUInteger)LE(p+32,4); if(size%18 || size>data.length-40)return Fail(error,@"Truncated local CASC index.");
            uint32_t high=0,low=0;
            for(NSUInteger i=0;i<size;i+=18) {
                high=TKWoWJenkins(p+40+i,18,&low,high);
                if(i && memcmp(p+40+i-18,p+40+i,9)>0) return Fail(error,@"Unsorted or conflicting local CASC index.");
            }
            if(high!=LE(p+36,4))return Fail(error,@"Local CASC index checksum mismatch.");
            [entries appendBytes:p+40 length:size];
        }
        [_buckets addObject:entries];
    }
    NSDictionary *receipt=TKWoWCASCVerificationSnapshot(directory);
    _verified=receipt[@"buckets"]?:EmptyReceipts();
    _segmentStamps=[receipt[@"segments"] mutableCopy]?:[NSMutableDictionary new];
    _pendingVerification=EmptyReceipts();
    return self;
}
- (void)dealloc { if(_fd>=0)close(_fd); }
- (const uint8_t *)entryForKey:(NSString *)key hash:(const uint8_t *)hash {
    NSData *added=_added[key]; const uint8_t *entry=added.bytes;
    return entry?:[self indexedEntryForHash:hash];
}
- (const uint8_t *)indexedEntryForHash:(const uint8_t *)hash {
    NSData *bucket=_buckets[Bucket(hash)]; const uint8_t *p=bucket.bytes; NSUInteger lo=0,hi=bucket.length/18;
    while(lo<hi) { NSUInteger mid=lo+(hi-lo)/2; if(memcmp(p+mid*18,hash,9)<0)lo=mid+1;else hi=mid; }
    if(lo==bucket.length/18 || memcmp(p+lo*18,hash,9))return NULL;return p+lo*18;
}
- (void)discardVerification {
    _verified=EmptyReceipts();_pendingVerification=EmptyReceipts();[_segmentStamps removeAllObjects];
}
- (void)invalidateSegment:(NSString *)segment {
    NSMutableArray *keptBuckets=[NSMutableArray new];
    for(unsigned bucket=0;bucket<16;bucket++) {
        NSMutableData *kept=[NSMutableData new];
        for(NSData *entries in @[_verified[bucket],_pendingVerification[bucket]]) {
            const uint8_t *p=entries.bytes;
            for(NSUInteger i=0;i<entries.length;i+=ReceiptSize)if((BE(p+i+16,5)>>30)!=(uint64_t)segment.longLongValue)[kept appendBytes:p+i length:ReceiptSize];
        }
        // Pending records need not be sorted, so keep everything pending.
        [keptBuckets addObject:kept];
    }
    _verified=EmptyReceipts();_pendingVerification=keptBuckets;[_segmentStamps removeObjectForKey:segment];
}
- (void)rememberKey:(const uint8_t *)key entry:(const uint8_t *)entry stamp:(NSArray *)stamp {
    NSString *segment=@(BE(entry+9,5)>>30).stringValue;
    if(_segmentStamps[segment] && ![_segmentStamps[segment] isEqual:stamp]) {
        // Earlier planning may already have reused another object in this
        // segment. Verifying this one cannot authorize that earlier decision.
        _verificationChanged=YES;[self invalidateSegment:segment];
    }
    _segmentStamps[segment]=stamp;
    NSMutableData *pending=_pendingVerification[Bucket(key)];[pending appendBytes:key length:16];[pending appendBytes:entry+9 length:9];
}
- (BOOL)verifyKey:(NSString *)key size:(uint64_t)size {
    uint8_t hash[16];if(!TKWoWUnhex(key,hash) || size>256*1024*1024)return NO;
    const uint8_t *entry=[self entryForKey:key hash:hash];
    if(entry && (!size || LE(entry+14,4)==size+30)) {
        NSData *receipts=_verified[Bucket(hash)];const uint8_t *p=receipts.bytes;NSUInteger lo=0,hi=receipts.length/ReceiptSize;
        while(lo<hi) { NSUInteger mid=lo+(hi-lo)/2;if(memcmp(p+mid*ReceiptSize,hash,16)<0)lo=mid+1;else hi=mid; }
        if(lo<receipts.length/ReceiptSize && !memcmp(p+lo*ReceiptSize,hash,16) && !memcmp(p+lo*ReceiptSize+16,entry+9,9)) {
            _verificationBytesReused+=LE(entry+14,4)-30;return YES;
        }
    }
    return [self readKey:key size:size]!=nil;
}
- (NSData *)readKey:(NSString *)key size:(uint64_t)size {
    uint8_t hash[16]; if(!TKWoWUnhex(key,hash) || size>256*1024*1024)return nil;
    const uint8_t *entry=[self entryForKey:key hash:hash];if(!entry)return nil;
    uint64_t packed=BE(entry+9,5), fullSize=LE(entry+14,4);
    if(fullSize<39 || fullSize>256*1024*1024+30 || (size && fullSize!=size+30))return nil;
    NSString *path=SegmentPath(_directory,packed>>30);
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK); if(fd<0)return nil;
    struct stat before,after;
    if(fstat(fd,&before) || !S_ISREG(before.st_mode) || before.st_size<0 ||
       (packed&0x3fffffff)+fullSize>(uint64_t)before.st_size) { close(fd);return nil; }
    NSMutableData *raw=[NSMutableData dataWithLength:(NSUInteger)fullSize]; uint8_t *p=raw.mutableBytes; size_t done=0;
    while(done<fullSize) { ssize_t n=pread(fd,p+done,(size_t)fullSize-done,(off_t)((packed&0x3fffffff)+done)); if(n<0 && errno==EINTR)continue; if(n<=0)break; done+=(size_t)n; }
    BOOL stable=!fstat(fd,&after) && [Stamp(&before) isEqual:Stamp(&after)];close(fd);
    _verificationBytesRead+=done;
    if(!stable || done!=fullSize || LE(p+16,4)!=fullSize)return nil;
    // Agent may zero the seven unindexed hash bytes in this envelope.
    // The complete EKey is independently verified against BLTE below.
    for(int i=0;i<9;i++)if(p[15-i]!=hash[i])return nil;
    NSData *encoded=[NSData dataWithBytesNoCopy:p+30 length:(NSUInteger)fullSize-30 freeWhenDone:NO];
    if(!TKWoWEncodedValid(encoded,key,NULL))return nil;
    [self rememberKey:hash entry:entry stamp:Stamp(&after)];
    // Keep the parent allocation alive independently of the autorelease pool.
    return [NSData dataWithBytes:p+30 length:(NSUInteger)fullSize-30];
}
- (BOOL)addData:(NSData *)data key:(NSString *)key error:(NSError **)error {
    uint8_t hash[16]; if(!TKWoWUnhex(key,hash) || !TKWoWEncodedValid(data,key,error))return NO;
    uint64_t size=data.length+30;
    if(_fd>=0 && _offset+size>0x3fffffff) { if(fsync(_fd)) { Fail(error,@"Cannot sync CASC segment.");return NO; } close(_fd);_fd=-1;_segment++;_offset=0; }
    if(_segment>=1024) { Fail(error,@"CASC storage has no free segment numbers.");return NO; }
    if(_fd<0) {
        NSString *path=[_directory stringByAppendingPathComponent:[NSString stringWithFormat:@"data.%03u",_segment]];
        _fd=open(path.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0600);
        if(_fd<0) { Fail(error,@"Cannot create CASC segment.");return NO; }
    }
    struct stat previous;
    if(fstat(_fd,&previous) || (_segmentStamps[@(_segment).stringValue] &&
       ![_segmentStamps[@(_segment).stringValue] isEqual:Stamp(&previous)])) {
        Fail(error,@"CASC data changed during the update.");return NO;
    }
    uint8_t header[30]={0}; for(int i=0;i<16;i++)header[i]=hash[15-i]; PutLE(header+16,size,4);
    // Reserved header bytes remain zero, as in the public CASC storage format.
    if(!WriteAll(_fd,header,30) || !WriteAll(_fd,data.bytes,data.length)) { Fail(error,@"Cannot write CASC data; check free space.");return NO; }
    uint8_t entry[18]; memcpy(entry,hash,9);PutBE(entry+9,((uint64_t)_segment<<30)|_offset,5);PutLE(entry+14,size,4);
    _added[key]=[NSData dataWithBytes:entry length:18]; _offset+=size;
    // Only our append-only writer can advance a segment's stamp while keeping
    // its earlier receipts. No original segment is ever opened for writing.
    struct stat s;if(fstat(_fd,&s)) { Fail(error,@"Cannot inspect CASC data.");return NO; }
    _segmentStamps[@(_segment).stringValue]=Stamp(&s);
    [self rememberKey:hash entry:entry stamp:Stamp(&s)];return YES;
}
- (BOOL)saveVerification:(NSError **)error {
    if(_verificationChanged) { Fail(error,@"CASC data changed during the update. Reopen to retry.");return NO; }
    // Receipts describe durable, indexed content; never unpublished appends.
    if(![self checkpoint:error])return NO;
    // Recheck before persisting: a receipt must never silently bless a change.
    for(NSString *segment in _segmentStamps.allKeys)
        if(![_segmentStamps[segment] isEqual:SegmentStamp(_directory,segment.integerValue)]) {
            _verificationChanged=YES;
            [self invalidateSegment:segment];
            Fail(error,@"CASC data changed during the update. Reopen to retry.");return NO;
        }
    NSMutableArray *buckets=[NSMutableArray new];NSUInteger count=0;
    for(unsigned bucket=0;bucket<16;bucket++) {
        NSMutableData *records=[_verified[bucket] mutableCopy];[records appendData:_pendingVerification[bucket]];
        qsort(records.mutableBytes,records.length/ReceiptSize,ReceiptSize,CompareReceipt);
        uint8_t *p=records.mutableBytes;NSUInteger used=0;
        for(NSUInteger i=0;i<records.length;i+=ReceiptSize) {
            const uint8_t *entry=[self indexedEntryForHash:p+i];
            if(!entry || memcmp(entry+9,p+i+16,9) || (used && !memcmp(p+used-ReceiptSize,p+i,16)))continue;
            memmove(p+used,p+i,ReceiptSize);used+=ReceiptSize;
        }
        records.length=used;count+=used/ReceiptSize;
        if(count>ReceiptLimit) { Fail(error,@"Too many verified CASC objects.");return NO; }
        [buckets addObject:records];
    }
    if(!WriteVerification(@{@"version":@1,@"segments":_segmentStamps,@"buckets":buckets},_directory,error))return NO;
    _verified=buckets;_pendingVerification=EmptyReceipts();return YES;
}
- (BOOL)checkpoint:(NSError **)error {
    if(_fd>=0 && fsync(_fd)) { Fail(error,@"Cannot sync CASC segment.");return NO; }
    if(!_added.count)return YES;
    for(NSData *entry in _added.allValues) {
        const uint8_t *p=entry.bytes; NSMutableData *bucket=_buckets[Bucket(p)];
        [bucket appendData:entry];
    }
    for(unsigned bucket=0;bucket<16;bucket++) {
        NSMutableData *entries=_buckets[bucket]; qsort(entries.mutableBytes,entries.length/18,18,CompareLocal);
        uint8_t *records=entries.mutableBytes; NSUInteger used=0;
        for(NSUInteger i=0;i<entries.length;i+=18) {
            if(i+18<entries.length && !memcmp(records+i,records+i+18,9))continue;
            memmove(records+used,records+i,18);used+=18;
        }
        entries.length=used;
        NSMutableData *file=[NSMutableData dataWithLength:40];uint8_t *p=file.mutableBytes;
        PutLE(p,16,4);PutLE(p+8,7,2);p[10]=bucket;p[12]=4;p[13]=5;p[14]=9;p[15]=30;PutLE(p+16,0xffc0000000ULL,8);
        PutLE(p+4,TKWoWJenkins(p+8,16,NULL,0),4);PutLE(p+32,entries.length,4);
        uint32_t high=0,low=0;const uint8_t *e=entries.bytes;
        for(NSUInteger i=0;i<entries.length;i+=18)high=TKWoWJenkins(e+i,18,&low,high);
        PutLE(p+36,high,4);[file appendData:entries];file.length=((file.length+4095)&~(NSUInteger)4095)+0x8000;
        if(_generation[bucket]==UINT32_MAX) { Fail(error,@"CASC index generation exhausted.");return NO; }
        NSString *path=[_directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%02x%08x.idx",bucket,++_generation[bucket]]];
        if(![file writeToFile:path options:NSDataWritingAtomic error:error])return NO;
    }
    [_added removeAllObjects];
    // Bound checkpoint storage: keep the latest two generations per bucket.
    // The updater only checkpoints its private snapshot, never the active root.
    for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:_directory error:NULL]) {
        if(name.length!=14 || ![name hasSuffix:@".idx"])continue;
        NSString *hex=[name substringToIndex:10];
        if([hex rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound)continue;
        unsigned bucket=(unsigned)strtoul([[hex substringToIndex:2] UTF8String],NULL,16);
        uint32_t generation=(uint32_t)strtoul([[hex substringFromIndex:2] UTF8String],NULL,16);
        if(bucket<16 && _generation[bucket]>1 && generation<_generation[bucket]-1)
            [NSFileManager.defaultManager removeItemAtPath:[_directory stringByAppendingPathComponent:name] error:NULL];
    }
    // Only inside the staged copy. The client rebuilds this process-local cache.
    [NSFileManager.defaultManager removeItemAtPath:[_directory stringByAppendingPathComponent:@"shmem"] error:NULL];
    return YES;
}
@end
