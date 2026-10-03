#import "Client.h"
NS_ASSUME_NONNULL_BEGIN
// One foreground update, with durable staged content and atomic directory swap.
// No installed file is changed until the whole selected build has been verified.
@interface TKWoWUpdater : NSObject
- (instancetype)initWithClient:(TKWoWClient *)client;
- (BOOL)updatePlan:(NSDictionary *)plan root:(NSString *)root
    progress:(void (^)(NSString *phase, uint64_t done, uint64_t total))progress error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
