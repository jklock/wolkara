#import "LocalArenaPublisher.h"
// Submit once, then recover only the exact request's stored result. Each IPC
// message is short even when the host is stopped by its on-device debugger.
@interface TKLocalArenaPoller : NSObject
- (instancetype)initWithTransport:(TKArenaTransport)transport;
- (void)start:(NSData *)request completion:(void (^)(NSData *))completion;
@end
