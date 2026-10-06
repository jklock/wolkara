// Only synthetic CASC objects. No installed games, network or credentials.
#import <Foundation/Foundation.h>
#import "../launcher/WoW/CASC.h"
#include <assert.h>
#include <fcntl.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <unistd.h>

static NSData *Object(NSString *text) {
    NSMutableData *data=[NSMutableData dataWithBytes:"BLTE\0\0\0\0N" length:9];
    [data appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];return data;
}
static TKWoWCASCStore *Open(NSString *directory) {
    NSError *error=nil;TKWoWCASCStore *store=[[TKWoWCASCStore alloc] initWithDirectory:directory error:&error];
    if(!store)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);assert(store);return store;
}
static void Persist(TKWoWCASCStore *store) {
    assert([store checkpoint:NULL]);assert([store saveVerification:NULL]);
}
static void Clone(NSString *source,NSString *destination) {
    NSFileManager *fm=NSFileManager.defaultManager;
    assert([fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:NULL]);
    for(NSString *name in [fm contentsOfDirectoryAtPath:source error:NULL])
        assert(!clonefile([source stringByAppendingPathComponent:name].fileSystemRepresentation,
            [destination stringByAppendingPathComponent:name].fileSystemRepresentation,CLONE_NOFOLLOW));
}
static void FlipAndRestoreMtime(NSString *path) {
    int fd=open(path.fileSystemRepresentation,O_RDWR);assert(fd>=0);struct stat before,after;assert(!fstat(fd,&before));
    uint8_t byte;assert(pread(fd,&byte,1,before.st_size-1)==1);byte^=1;
    assert(pwrite(fd,&byte,1,before.st_size-1)==1);
    struct timespec times[2]={before.st_atimespec,before.st_mtimespec};assert(!futimens(fd,times));
    assert(!fstat(fd,&after));assert(before.st_size==after.st_size);
    assert(before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec);
    assert(before.st_ctimespec.tv_sec!=after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec!=after.st_ctimespec.tv_nsec);
    close(fd);
}
static NSData *ReceiptFile(NSDictionary *receipt) {
    NSData *body=[NSPropertyListSerialization dataWithPropertyList:receipt format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];assert(body);
    NSMutableData *data=[NSMutableData dataWithBytes:"WKVERIFY" length:8];uint8_t digest[16];
    assert(TKWoWUnhex(TKWoWMD5(body),digest));[data appendBytes:digest length:16];[data appendData:body];return data;
}
int main(void) {@autoreleasepool {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *base=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *directory=[base stringByAppendingPathComponent:@"original"];
    NSString *cache=[directory stringByAppendingPathComponent:@".wolkara-verified"];
    NSData *a=Object(@"synthetic A"),*b=Object(@"synthetic B");NSString *ka=TKWoWMD5(a),*kb=TKWoWMD5(b);
    TKWoWCASCStore *store=Open(directory);
    assert([store addData:a key:ka error:NULL]);Persist(store);store=nil;
    store=Open(directory);assert([store addData:b key:kb error:NULL]);Persist(store);store=nil;
    // Cold adoption checks the payload; subsequent processes use full-key receipts.
    assert([fm removeItemAtPath:cache error:NULL]);store=Open(directory);
    assert([store verifyKey:ka size:a.length] && [store verifyKey:kb size:b.length]);
    uint64_t cold=store.verificationBytesRead;assert(cold==a.length+b.length+60 && store.verificationBytesReused==0);
    Persist(store);store=nil;store=Open(directory);
    assert([store verifyKey:ka size:a.length] && [store verifyKey:kb size:b.length]);
    assert(store.verificationBytesRead==0 && store.verificationBytesReused==a.length+b.length);
    // Neither a wrong size nor a colliding nine-byte index prefix is sufficient.
    assert(![store verifyKey:ka size:a.length+1]);
    uint8_t key[16];assert(TKWoWUnhex(ka,key));key[15]^=1;
    assert(![store verifyKey:TKWoWHex(key,16) size:a.length]);
    // Fetching bytes (e.g. executable extraction) always verifies the payload.
    assert([[store readKey:ka size:a.length] isEqual:a]);store=nil;
    // APFS cloning changes inodes: carry trust only over our completed clone.
    NSDictionary *snapshot=TKWoWCASCVerificationSnapshot(directory);assert(snapshot);
    NSString *cloned=[base stringByAppendingPathComponent:@"cloned"];Clone(directory,cloned);
    store=Open(cloned);assert([store verifyKey:ka size:a.length]);assert(store.verificationBytesRead>0);store=nil;
    assert(TKWoWCASCCloneVerification(snapshot,directory,cloned,NULL));
    store=Open(cloned);assert([store verifyKey:ka size:a.length] && [store verifyKey:kb size:b.length]);
    assert(store.verificationBytesRead==0);store=nil;
    // A same-size edit with restored mtime invalidates only its segment, via ctime.
    NSString *first=[directory stringByAppendingPathComponent:@"data.000"];
    FlipAndRestoreMtime(first);store=Open(directory);
    assert([store verifyKey:kb size:b.length] && store.verificationBytesRead==0);
    assert(![store verifyKey:ka size:a.length] && store.verificationBytesRead>0);store=nil;
    // A pre-clone snapshot cannot authorize content whose source changed meanwhile.
    NSString *changedClone=[base stringByAppendingPathComponent:@"changed-clone"];Clone(directory,changedClone);
    assert(TKWoWCASCCloneVerification(snapshot,directory,changedClone,NULL));store=Open(changedClone);
    assert([store verifyKey:kb size:b.length] && store.verificationBytesRead==0);
    assert(![store verifyKey:ka size:a.length]);store=nil;
    // Repair ignores all receipts, even for healthy unchanged data.
    store=Open(cloned);[store discardVerification];
    assert([store verifyKey:ka size:a.length] && [store verifyKey:kb size:b.length]);
    assert(store.verificationBytesReused==0 && store.verificationBytesRead==cold);Persist(store);store=nil;
    // Index remapping must not reuse the old extent's receipt for the same key.
    store=Open(cloned);assert([store addData:a key:ka error:NULL]);assert([store checkpoint:NULL]);store=nil;
    store=Open(cloned);assert([store verifyKey:ka size:a.length]);assert(store.verificationBytesRead==a.length+30);Persist(store);store=nil;
    // Metadata is rechecked before saving/activation, including concurrent edits.
    store=Open(cloned);NSString *second=[cloned stringByAppendingPathComponent:@"data.001"];
    FlipAndRestoreMtime(second);NSError *error=nil;
    assert(![store saveVerification:&error] && [error.localizedDescription containsString:@"changed"]);store=nil;
    // Deletions, truncation and symlinks never reuse a receipt.
    NSString *last=[cloned stringByAppendingPathComponent:@"data.002"];
    assert([fm removeItemAtPath:last error:NULL]);store=Open(cloned);assert(![store verifyKey:ka size:a.length]);store=nil;
    NSString *other=[directory stringByAppendingPathComponent:@"data.001"];
    assert(!truncate(other.fileSystemRepresentation,5));store=Open(directory);assert(![store verifyKey:kb size:b.length]);store=nil;
    assert([fm removeItemAtPath:other error:NULL]);assert([fm createSymbolicLinkAtPath:other withDestinationPath:first error:NULL]);
    store=Open(directory);assert(![store verifyKey:kb size:b.length]);store=nil;
    // Damaged or malformed optional records fall back, rather than authorizing data.
    NSData *valid=[NSData dataWithContentsOfFile:cache];assert(valid);
    for(NSUInteger n=0;n<MIN(valid.length,32);n++) {
        assert([[valid subdataWithRange:NSMakeRange(0,n)] writeToFile:cache atomically:YES]);
        assert(!TKWoWCASCVerificationSnapshot(directory));
    }
    NSMutableData *bad=[valid mutableCopy];((uint8_t *)bad.mutableBytes)[bad.length-1]^=1;
    assert([bad writeToFile:cache atomically:YES]);assert(!TKWoWCASCVerificationSnapshot(directory));
    for(NSDictionary *malformed in @[@{@"version":@2},@{@"version":@1,@"segments":@[],@"buckets":@[]},
        @{@"version":@1,@"segments":@{},@"buckets":@[@1]}]) {
        assert([ReceiptFile(malformed) writeToFile:cache atomically:YES]);assert(!TKWoWCASCVerificationSnapshot(directory));
    }
    NSMutableDictionary *malformed=[snapshot mutableCopy];NSMutableArray *buckets=[snapshot[@"buckets"] mutableCopy];
    for(NSUInteger i=0;i<buckets.count;i++)if([buckets[i] length]) { NSMutableData *duplicate=[buckets[i] mutableCopy];[duplicate appendData:buckets[i]];buckets[i]=duplicate;break; }
    malformed[@"buckets"]=buckets;assert([ReceiptFile(malformed) writeToFile:cache atomically:YES]);assert(!TKWoWCASCVerificationSnapshot(directory));
    int fd=open(cache.fileSystemRepresentation,O_WRONLY|O_TRUNC);assert(fd>=0);assert(!ftruncate(fd,160*1024*1024+1));close(fd);
    assert(!TKWoWCASCVerificationSnapshot(directory));
    assert([fm removeItemAtPath:cache error:NULL]);assert([fm createSymbolicLinkAtPath:cache withDestinationPath:first error:NULL]);
    assert(!TKWoWCASCVerificationSnapshot(directory));
    // A later valid read must not silently refresh the stamp and bless an
    // earlier cached decision about a different object in the changed segment.
    NSString *concurrent=[base stringByAppendingPathComponent:@"concurrent"];
    store=Open(concurrent);assert([store addData:a key:ka error:NULL] && [store addData:b key:kb error:NULL]);Persist(store);store=nil;
    store=Open(concurrent);assert([store verifyKey:kb size:b.length]);
    FlipAndRestoreMtime([concurrent stringByAppendingPathComponent:@"data.000"]);
    assert([[store readKey:ka size:a.length] isEqual:a]);
    assert(![store saveVerification:NULL]);assert(![store saveVerification:NULL]);store=nil;
    // A larger fixture proves the fast path avoids payload I/O, not merely
    // network requests. Timings are informational; byte counts are assertions.
    NSString *large=[base stringByAppendingPathComponent:@"large"];
    NSMutableArray *keys=[NSMutableArray new];store=Open(large);
    const NSUInteger objectSize=128*1024,objectCount=128;
    for(NSUInteger i=0;i<objectCount;i++) { @autoreleasepool {
        NSMutableData *data=[Object([NSString stringWithFormat:@"fixture-%lu",(unsigned long)i]) mutableCopy];data.length=objectSize;
        NSString *key=TKWoWMD5(data);[keys addObject:key];assert([store addData:data key:key error:NULL]);
    }}
    Persist(store);store=nil;
    store=Open(large);[store discardVerification];NSTimeInterval start=NSDate.timeIntervalSinceReferenceDate;
    for(NSString *key in keys) { @autoreleasepool { assert([store verifyKey:key size:objectSize]); }}
    NSTimeInterval coldTime=NSDate.timeIntervalSinceReferenceDate-start;
    uint64_t largeRead=store.verificationBytesRead;assert(largeRead==objectCount*(objectSize+30));Persist(store);store=nil;
    store=Open(large);start=NSDate.timeIntervalSinceReferenceDate;
    for(NSString *key in keys)assert([store verifyKey:key size:objectSize]);
    NSTimeInterval warmTime=NSDate.timeIntervalSinceReferenceDate-start;
    assert(store.verificationBytesRead==0 && store.verificationBytesReused==objectCount*objectSize);
    printf("Synthetic 16 MiB: cold read=%llu bytes (%.4fs), warm read=0 bytes (%.4fs).\n",largeRead,coldTime,warmTime);
    store=nil;
    assert([fm removeItemAtPath:base error:NULL]);
    printf("WoW verification PASS: cold payload reads=%llu; warm payload reads=0; clone rebinding, full keys/extents, repair, changed/deleted/truncated/symlink data, malformed records.\n",cold);
}return 0;}
