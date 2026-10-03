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
@implementation TKWoWCASCStore {
    NSString *_directory;
    NSMutableArray<NSMutableData *> *_buckets;
    uint32_t _generation[16];
    NSMutableDictionary<NSString *,NSData *> *_added;
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
    return self;
}
- (void)dealloc { if(_fd>=0)close(_fd); }
- (NSData *)readKey:(NSString *)key size:(uint64_t)size {
    uint8_t hash[16]; if(!TKWoWUnhex(key,hash) || size>256*1024*1024)return nil;
    NSData *added=_added[key]; const uint8_t *entry=added.bytes;
    if(!entry) {
        NSData *bucket=_buckets[Bucket(hash)]; const uint8_t *p=bucket.bytes; NSUInteger lo=0,hi=bucket.length/18;
        while(lo<hi) { NSUInteger mid=lo+(hi-lo)/2; if(memcmp(p+mid*18,hash,9)<0)lo=mid+1;else hi=mid; }
        if(lo==bucket.length/18 || memcmp(p+lo*18,hash,9))return nil; entry=p+lo*18;
    }
    uint64_t packed=BE(entry+9,5), fullSize=LE(entry+14,4);
    if(fullSize<39 || fullSize>256*1024*1024+30 || (size && fullSize!=size+30))return nil;
    NSString *path=[_directory stringByAppendingPathComponent:[NSString stringWithFormat:@"data.%03llu",packed>>30]];
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW); if(fd<0)return nil;
    NSMutableData *raw=[NSMutableData dataWithLength:(NSUInteger)fullSize]; uint8_t *p=raw.mutableBytes; size_t done=0;
    while(done<fullSize) { ssize_t n=pread(fd,p+done,(size_t)fullSize-done,(off_t)((packed&0x3fffffff)+done)); if(n<0 && errno==EINTR)continue; if(n<=0)break; done+=(size_t)n; } close(fd);
    if(done!=fullSize || LE(p+16,4)!=fullSize)return nil;
    // Agent may zero the seven unindexed hash bytes in this envelope.
    // The complete EKey is independently verified against BLTE below.
    for(int i=0;i<9;i++)if(p[15-i]!=hash[i])return nil;
    NSData *encoded=[NSData dataWithBytesNoCopy:p+30 length:(NSUInteger)fullSize-30 freeWhenDone:NO];
    if(!TKWoWEncodedValid(encoded,key,NULL))return nil;
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
    uint8_t header[30]={0}; for(int i=0;i<16;i++)header[i]=hash[15-i]; PutLE(header+16,size,4);
    // Reserved header bytes remain zero, as in the public CASC storage format.
    if(!WriteAll(_fd,header,30) || !WriteAll(_fd,data.bytes,data.length)) { Fail(error,@"Cannot write CASC data; check free space.");return NO; }
    uint8_t entry[18]; memcpy(entry,hash,9);PutBE(entry+9,((uint64_t)_segment<<30)|_offset,5);PutLE(entry+14,size,4);
    _added[key]=[NSData dataWithBytes:entry length:18]; _offset+=size;return YES;
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
