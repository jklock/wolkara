#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The key is intentionally kept out of preferences, manifests, diagnostics,
// and download requests. It is sent only to api.curseforge.com metadata APIs.
@interface TKAddonCredentialStore : NSObject
- (nullable NSString *)curseForgeKey:(NSError **)error;
- (BOOL)storeCurseForgeKey:(NSString *)key error:(NSError **)error;
- (BOOL)removeCurseForgeKey:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
