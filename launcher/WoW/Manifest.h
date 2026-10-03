#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Metadata only. These routines never open, modify, or execute an installed game.
NSArray<NSDictionary *> *TKWoWProducts(void);
BOOL TKWoWHashValid(NSString *value);
NSString *TKWoWMD5(NSData *data);
NSArray<NSDictionary<NSString *, NSString *> *> * _Nullable TKWoWTable(NSData *data, NSError **error);
NSDictionary<NSString *, NSString *> * _Nullable TKWoWConfig(NSData *data, NSError **error);
// Verifies the encoded header/chunks and decoded content, with an explicit size budget.
NSData * _Nullable TKWoWDecode(NSData *data, NSString *encodingKey, NSString *contentKey,
    NSUInteger expectedSize, NSUInteger limit, NSError **error);
NSArray<NSDictionary *> * _Nullable TKWoWInstall(NSData *data, NSError **error);
NSArray<NSDictionary *> *TKWoWMacFiles(NSArray<NSDictionary *> *entries, NSString *locale, NSString *region);
BOOL TKWoWBuildCurrent(NSArray<NSDictionary *> *installedRows, NSString *product, NSDictionary *latest);
// Looks up a content hash in an already verified encoding manifest.
NSString * _Nullable TKWoWEncodingKey(NSData *data, NSString *contentKey, NSError **error);
NSError *TKWoWError(NSString *message);

NS_ASSUME_NONNULL_END
