#pragma once
#import <Foundation/Foundation.h>
#include "NativeCodeMemory.h"

@interface TKLocalAuthorization : NSObject
@property(nonatomic,readonly) BOOL localSessionReady;
// Direct reachability only, no pairing/credentials/debugging. A TCP connection
// alone does not authenticate the service or grant execution permission.
+ (void)probeDirectAccess:(void (^)(NSString *))completion;
+ (void)probeDirectService:(void (^)(NSString *))completion;
+ (void)probeRemotePairingService:(void (^)(NSString *))completion;
+ (void)probeLocalRouteService:(void (^)(NSString *))completion;
- (void)startAndProbeLocalRoute:(void (^)(NSString *))completion;
- (void)startAndVerifyPairing:(void (^)(NSString *))completion;
- (void)startAndVerifyTunnel:(void (^)(NSString *))completion;
- (void)startAndPrepareLocalAuthorization:(void (^)(NSString *))completion;
// Explicit user action only: may display iPadOS's VPN configuration consent.
- (void)startLocalRoute:(void (^)(NSString *))completion;
- (void)stopLocalRoute;
@end
// Opt-in development loader only. No route is started or consent requested here.
// An unavailable/unconfigured helper rejects before any debugger attachment.
NCPreparation TKPrepareLocalArena(void *address,size_t size,void *context);
