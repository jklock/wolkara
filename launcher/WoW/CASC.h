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
// Writes only to the isolated update directory supplied by Updater. Existing
// data segments are immutable; new content is appended to new segments.
@interface TKWoWCASCStore : NSObject
- (nullable instancetype)initWithDirectory:(NSString *)directory error:(NSError **)error;
- (nullable NSData *)readKey:(NSString *)key size:(uint64_t)size;
- (BOOL)addData:(NSData *)data key:(NSString *)key error:(NSError **)error;
- (BOOL)checkpoint:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
