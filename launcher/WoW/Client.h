#import <Foundation/Foundation.h>
#import "Manifest.h"

NS_ASSUME_NONNULL_BEGIN
// Synchronous, bounded requests: call on a worker queue, never UIKit's main thread.
// A client performs one operation at a time. cancel is safe from another thread.
@interface TKWoWClient : NSObject
- (void)cancel;
- (nullable NSDictionary *)versionForProduct:(NSString *)product region:(NSString *)region error:(NSError **)error;
// Fetches and verifies the build configuration and install manifest. Does not install a game.
- (nullable NSDictionary *)planForProduct:(NSString *)product region:(NSString *)region
    locale:(NSString *)locale error:(NSError **)error;
// Experimental extraction of one original install file to an isolated staging directory.
// Fetches the encoding manifest (can be large). No archive-range fallback yet.
- (nullable NSString *)stageFile:(NSDictionary *)file plan:(NSDictionary *)plan
    directory:(NSString *)directory error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
