#import "GuestModule.h"
#import "GuestImage.h"
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static BOOL module_error(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"GuestModule" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSString *hash_file(NSString *path, uint64_t *length, NSError **error) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    struct stat st;
    if (fd < 0) { module_error(error,@"Cannot open the module file."); return nil; }
    if (fstat(fd,&st) || !S_ISREG(st.st_mode)) {
        close(fd); module_error(error,@"The module must be a regular file."); return nil;
    }
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    unsigned char buffer[65536], hash[CC_SHA256_DIGEST_LENGTH];
    uint64_t total=0; ssize_t n;
    while ((n=read(fd,buffer,sizeof buffer)) > 0) { CC_SHA256_Update(&ctx,buffer,(CC_LONG)n); total+=(uint64_t)n; }
    close(fd);
    if (n < 0 || total != (uint64_t)st.st_size) { module_error(error,@"Module read failed or its size changed."); return nil; }
    CC_SHA256_Final(hash,&ctx);
    NSMutableString *result=[NSMutableString stringWithCapacity:64];
    for (size_t i=0;i<sizeof hash;i++) [result appendFormat:@"%02x",hash[i]];
    if (length) *length=total;
    return result;
}
static NSDictionary *read_json(NSString *path) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
    if (fd<0) return nil;
    struct stat st;
    if (fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_size<1 || st.st_size>16384) {close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];
    ssize_t n=read(fd,data.mutableBytes,data.length);close(fd);
    if(n!=(ssize_t)data.length)return nil;
    id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static BOOL valid_hash(id hash) {
    if (![hash isKindOfClass:NSString.class] || [hash length]!=64) return NO;
    return [hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static BOOL write_json(NSDictionary *value,NSString *path,NSError **error) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}
static NSString *verify(NSString *root, NSString *hash, NSError **error) {
    NSString *directory=[root stringByAppendingPathComponent:hash];
    struct stat st;
    if (lstat(directory.fileSystemRepresentation,&st) || !S_ISDIR(st.st_mode)) {
        module_error(error,@"The selected module directory is missing or invalid."); return nil;
    }
    NSDictionary *manifest=read_json([directory stringByAppendingPathComponent:@"manifest.json"]);
    NSString *path=[directory stringByAppendingPathComponent:@"OriginalExecutable.bin"];
    uint64_t size=0; NSString *actual=hash_file(path,&size,error);
    if (!actual) return nil;
    if (![manifest[@"format"] isEqual:@2] || ![manifest[@"sha256"] isEqual:hash] ||
        ![manifest[@"size"] isEqual:@(size)] || ![actual isEqual:hash]) {
        module_error(error,@"Module integrity check failed. Import the original file again."); return nil;
    }
    return path;
}
NSString *guest_module_selected(NSString *root,NSError **error) {
    id hash=read_json([root stringByAppendingPathComponent:@"current.json"])[@"sha256"];
    if (!valid_hash(hash)) { module_error(error,@"Import the original game executable to begin."); return nil; }
    return verify(root,hash,error);
}
BOOL guest_module_import(NSString *source,NSString *root,NSError **error) {
    NSFileManager *fm=NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSString *stage=[root stringByAppendingPathComponent:[@".import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtPath:stage withIntermediateDirectories:NO attributes:nil error:error]) return NO;
    BOOL success=NO;
    @try {
        NSString *target=[stage stringByAppendingPathComponent:@"OriginalExecutable.bin"];
        uint64_t sourceSize=0,copySize=0;
        NSString *before=hash_file(source,&sourceSize,error);
        if (!before || ![fm copyItemAtPath:source toPath:target error:error]) return NO;
        NSString *copied=hash_file(target,&copySize,error);
        if (![before isEqual:copied] || sourceSize!=copySize || ![before isEqual:hash_file(source,NULL,error)])
            return module_error(error,@"The executable changed during import. Please retry.");
        GuestImage image={0}; char reason[2048];
        if (!gi_load(target.fileSystemRepresentation,&image,reason,sizeof reason))
            return module_error(error,[NSString stringWithFormat:@"Unsupported executable: %s",reason]);
        gi_destroy(&image);
        if (chmod(target.fileSystemRepresentation,0600)) return module_error(error,@"Cannot set module data permissions.");
        if (!write_json(@{@"format":@2,@"runtime":@"data-module",@"source_name":source.lastPathComponent,
            @"sha256":copied,@"size":@(copySize),@"modified":@NO},[stage stringByAppendingPathComponent:@"manifest.json"],error)) return NO;
        NSString *final=[root stringByAppendingPathComponent:copied];
        if ([fm fileExistsAtPath:final]) {
            if (!verify(root,copied,NULL)) {
                NSString *damaged=[root stringByAppendingPathComponent:[@".damaged-" stringByAppendingString:NSUUID.UUID.UUIDString]];
                if (![fm moveItemAtPath:final toPath:damaged error:error]) return NO;
                if (![fm moveItemAtPath:stage toPath:final error:error]) {
                    [fm moveItemAtPath:damaged toPath:final error:NULL];
                    return NO;
                }
            }
        } else if (![fm moveItemAtPath:stage toPath:final error:error]) return NO;
        success=write_json(@{@"sha256":copied},[root stringByAppendingPathComponent:@"current.json"],error);
    } @finally { [fm removeItemAtPath:stage error:NULL]; }
    return success;
}
