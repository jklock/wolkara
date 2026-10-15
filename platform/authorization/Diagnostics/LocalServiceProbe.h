#pragma once
#import <Foundation/Foundation.h>
// Credential-free protocol identification. Completes on the main queue.
// Only fixed development endpoints are accepted; no debugger commands.
@interface TKLocalServiceProbe : NSObject
+ (void)probeService:(BOOL)remotePairing address:(NSString *)host completion:(void (^)(NSString *))completion;
@end
