#import <Foundation/Foundation.h>
#import "Manifest.h"

NS_ASSUME_NONNULL_BEGIN
typedef struct { uint8_t key[16]; uint64_t size; } TKWoWDownloadEntry;
typedef struct { uint8_t key[16]; uint32_t size, offset, archive; } TKWoWArchiveEntry;
// Compact records keep multi-million-entry manifests within a bounded memory budget.
NSData * _Nullable TKWoWDownloads(NSData *data, NSString *locale, NSString *region, NSError **error);
NSData * _Nullable TKWoWArchiveEntries(NSData *data, uint32_t archive, NSError **error);
BOOL TKWoWEncodedValid(NSData *data, NSString *key, NSError **error);
NSString *TKWoWHex(const uint8_t *bytes, NSUInteger count);
BOOL TKWoWUnhex(NSString *text, uint8_t *key);
uint32_t TKWoWJenkins(const void *bytes, size_t length, uint32_t * _Nullable low, uint32_t seed);
// Capture before an APFS clone, then rebind only receipts whose source stayed
// unchanged throughout cloning. Missing/invalid receipts simply disable reuse.
NSDictionary * _Nullable TKWoWCASCVerificationSnapshot(NSString *directory);
BOOL TKWoWCASCCloneVerification(NSDictionary * _Nullable snapshot, NSString *source,
    NSString *destination, NSError **error);
// Writes only to the isolated update directory supplied by Updater. Existing
// data segments are immutable; new content is appended to new segments.
@interface TKWoWCASCStore : NSObject
- (nullable instancetype)initWithDirectory:(NSString *)directory error:(NSError **)error;
- (nullable NSData *)readKey:(NSString *)key size:(uint64_t)size;
// Uses a receipt only for the same full key, indexed extent and unchanged file.
// Otherwise reads and checks the original encoded bytes, recording the result.
- (BOOL)verifyKey:(NSString *)key size:(uint64_t)size;
- (void)discardVerification;
- (BOOL)saveVerification:(NSError **)error;
@property(nonatomic, readonly) uint64_t verificationBytesRead;
@property(nonatomic, readonly) uint64_t verificationBytesReused;
- (BOOL)addData:(NSData *)data key:(NSString *)key error:(NSError **)error;
- (BOOL)checkpoint:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
