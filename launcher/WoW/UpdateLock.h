#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Serializes all mutations beneath a World of Warcraft installation parent.
// The caller owns the returned descriptor and must release it.
FOUNDATION_EXPORT int TKWoWAcquireUpdateLock(NSString *installationRoot, NSError **error);
FOUNDATION_EXPORT void TKWoWReleaseUpdateLock(int descriptor);

NS_ASSUME_NONNULL_END
