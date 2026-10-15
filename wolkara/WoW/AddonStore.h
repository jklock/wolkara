#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TKAddonRecord : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) NSString *source;
@property(nonatomic, copy) NSArray<NSString *> *folders;
@property(nonatomic) BOOL managed;
@property(nonatomic) BOOL disabled;
@property(nonatomic) BOOL pinned;
@end

// Owns only packages explicitly imported by Wolkara. Existing add-ons are
// discovered and displayed but cannot be removed by this store.
@interface TKAddonStore : NSObject
- (instancetype)initWithAddOnsDirectory:(NSString *)directory product:(NSString *)product gameVersion:(nullable NSString *)version;
@property(nonatomic, readonly, copy) NSArray<TKAddonRecord *> *records;
- (void)reload;
- (BOOL)importZIPAtURL:(NSURL *)url error:(NSError **)error;
- (BOOL)setDisabled:(BOOL)disabled record:(TKAddonRecord *)record error:(NSError **)error;
- (BOOL)removeRecord:(TKAddonRecord *)record error:(NSError **)error;
- (BOOL)setPinned:(BOOL)pinned record:(TKAddonRecord *)record error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
