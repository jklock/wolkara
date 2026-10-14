#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TKCurseForgeCompletion)(id _Nullable value, NSError *_Nullable error);

// Official CurseForge REST v1 client. The key is sent to the API and, per
// CurseForge's current CDN-auth requirement, only to HTTPS *.forgecdn.net URLs
// returned by that API.
@interface TKCurseForgeClient : NSObject
- (instancetype)initWithAPIKey:(NSString *)key;
- (void)categoriesForGameID:(NSInteger)gameID completion:(TKCurseForgeCompletion)completion;
- (void)browseModsWithQuery:(NSString *)query sortField:(NSInteger)sortField sortOrder:(NSString *)sortOrder categoryID:(nullable NSNumber *)categoryID index:(NSUInteger)index completion:(TKCurseForgeCompletion)completion;
- (void)latestFileForModID:(NSNumber *)modID gameVersion:(NSString *)gameVersion completion:(TKCurseForgeCompletion)completion;
- (void)downloadURLForModID:(NSNumber *)modID fileID:(NSNumber *)fileID completion:(TKCurseForgeCompletion)completion;
- (nullable NSURLRequest *)assetRequestForURL:(NSString *)url error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
