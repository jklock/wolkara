#import <NetworkExtension/NetworkExtension.h>
#import "Protocol.h"
#include "LocalRoute.h"
#include <sys/socket.h>
#import "Diagnostics/LocalServiceProbe.h"
#import "LocalAuthorizationTunnel-Swift.h"

@interface TKLocalPacketProvider : NEPacketTunnelProvider
@property(atomic) BOOL running;
@property(atomic) NSUInteger reflected;
@property(atomic) NSUInteger dropped;
@property(atomic) NSUInteger generation;
@property(atomic,strong) TKArenaPreparationService *arenaService;
@property(atomic,strong) TKPacketServiceProbe *packetProbe;
@property(atomic,strong) NSArray<TKPacketServiceProbe *> *retiredProbes;
@end

@implementation TKLocalPacketProvider
- (void)startTunnelWithOptions:(NSDictionary<NSString *,NSObject *> *)options completionHandler:(void (^)(NSError *))completion {
    (void)options;
    NEPacketTunnelNetworkSettings *settings=[[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:TK_AUTH_PEER];
    NEIPv4Settings *ipv4=[[NEIPv4Settings alloc] initWithAddresses:@[TK_AUTH_INTERFACE] subnetMasks:@[@"255.255.255.0"]];
    ipv4.includedRoutes=@[[[NEIPv4Route alloc] initWithDestinationAddress:TK_AUTH_PEER subnetMask:@"255.255.255.255"]];
    ipv4.excludedRoutes=@[NEIPv4Route.defaultRoute];
    settings.IPv4Settings=ipv4;
    settings.MTU=@1500;
    // No DNS override, default route, external endpoint, or traffic logging.
    __weak TKLocalPacketProvider *weakSelf=self;
    [self setTunnelNetworkSettings:settings completionHandler:^(NSError *error) {
        TKLocalPacketProvider *provider=weakSelf;
        if(!provider && !error)error=[NSError errorWithDomain:NSPOSIXErrorDomain code:ECANCELED userInfo:nil];
        if(!error) {
            [provider.arenaService invalidate];
            [provider.packetProbe cancel];
            provider.packetProbe=[TKPacketServiceProbe new];
            provider.retiredProbes=@[];
            provider.arenaService=provider.packetProbe.arenaService;
            provider.generation++;provider.running=YES;provider.reflected=0;provider.dropped=0;[provider receivePackets];
        }
        completion(error);
    }];
}
- (void)receivePackets {
    if(!self.running)return;
    NSUInteger generation=self.generation;
    __weak TKLocalPacketProvider *weakSelf=self;
    [self.packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets,NSArray<NSNumber *> *protocols) {
        TKLocalPacketProvider *self=weakSelf;if(!self || !self.running || self.generation!=generation)return;
        const LocalRoute route={{10,7,0,2},{10,7,0,1}};
        NSMutableArray<NSData *> *output=[NSMutableArray new];
        NSMutableArray<NSNumber *> *families=[NSMutableArray new];
        for(NSUInteger i=0;i<packets.count;i++) {
            if(i>=protocols.count || protocols[i].intValue!=AF_INET) {self.dropped++;continue;}
            if([self.packetProbe consume:packets[i]])continue;
            BOOL retired=NO;
            for(TKPacketServiceProbe *probe in self.retiredProbes) if([probe consume:packets[i]]) {retired=YES;break;}
            if(retired)continue;
            NSMutableData *data=[packets[i] mutableCopy];
            if(lr_reflect(&route,data.mutableBytes,data.length)!=LR_REFLECTED) {self.dropped++;continue;}
            [output addObject:data];[families addObject:@AF_INET];self.reflected++;
        }
        if(output.count && ![self.packetFlow writePackets:output withProtocols:families]) {
            self.running=NO;
            [self.arenaService invalidate];
            [self cancelTunnelWithError:[NSError errorWithDomain:@"Tolkara.LocalRoute" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The local development route stopped accepting packets."}]];
            return;
        }
        [self receivePackets];
    }];
}
- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completion {
    (void)reason;self.running=NO;self.generation++;[self.arenaService invalidate];[self.packetProbe cancel];completion();
}
- (void)handleAppMessage:(NSData *)message completionHandler:(void (^)(NSData *))completion {
    if(!completion)return;
    if(message.length>=4 && !memcmp(message.bytes,"TKAR",4)) {
        TKArenaPreparationService *service=self.arenaService;
        if(service) [service handleAsyncMessage:message completion:completion]; else completion(nil);
        return;
    }
    id request=message.length<=4096?[NSJSONSerialization JSONObjectWithData:message options:0 error:NULL]:nil;
    if([request isKindOfClass:NSDictionary.class] && [request[@"version"] isEqual:@TK_AUTH_PROTOCOL_VERSION] &&
       ([request[@"operation"] isEqual:@"verifyPairing"] || [request[@"operation"] isEqual:@"verifyTunnel"] || [request[@"operation"] isEqual:@"prepareAuthorization"])) {
        NSString *device=request[@"deviceIdentifier"];
        if(![device isKindOfClass:NSString.class] || !device.length || device.length>1024) {completion(nil);return;}
        // A mobile-network transition can make the local service available.
        // Recreate only a probe that failed before its first TCP connection;
        // its failure path has already invalidated and closed every resource.
        if([request[@"operation"] isEqual:@"prepareAuthorization"] && self.packetProbe.serviceUnavailable) {
            // Keep the old tuple reserved and discard its delayed packets for
            // this route's lifetime. Never let them reach the reflector.
            if(self.retiredProbes.count>=64) {
                NSMutableDictionary *response=[TKRouteStatus(self.running,self.reflected,self.dropped) mutableCopy];
                response[@"helperProbe"]=@"Local service retry limit reached.";
                response[@"readyForPreparation"]=@NO;
                completion([NSJSONSerialization dataWithJSONObject:response options:0 error:NULL]);return;
            }
            self.retiredProbes=[self.retiredProbes arrayByAddingObject:self.packetProbe];
            self.packetProbe=[TKPacketServiceProbe new];
            self.arenaService=self.packetProbe.arenaService;
        }
        TKPacketServiceProbe *probe=self.packetProbe;
        __weak TKLocalPacketProvider *weakSelf=self;
        BOOL (^output)(NSData *)=^BOOL(NSData *packet) {
            TKLocalPacketProvider *provider=weakSelf;
            return provider.running && [provider.packetFlow writePackets:@[packet] withProtocols:@[@AF_INET]];
        };
        void (^reply)(NSString *)=^(NSString *report) {
            NSMutableDictionary *response=[TKRouteStatus(self.running,self.reflected,self.dropped) mutableCopy];
            response[@"helperProbe"]=report;
            response[@"readyForPreparation"]=@(probe.authorizationReady);
            response[@"serviceUnavailable"]=@(probe.serviceUnavailable);
            completion([NSJSONSerialization dataWithJSONObject:response options:0 error:NULL]);
        };
        if([request[@"operation"] isEqual:@"prepareAuthorization"])
            [probe startAuthorizationWithDeviceIdentifier:device output:output completion:reply];
        else if([request[@"operation"] isEqual:@"verifyTunnel"])
            [probe startVerifiedTunnelWithDeviceIdentifier:device output:output completion:reply];
        else [probe startAuthenticatedWithDeviceIdentifier:device output:output completion:reply];
        return;
    }
    if([request isKindOfClass:NSDictionary.class] && [request[@"version"] isEqual:@TK_AUTH_PROTOCOL_VERSION] && [request[@"operation"] isEqual:@"probeService"]) {
        [TKLocalServiceProbe probeService:YES address:TK_AUTH_PEER completion:^(NSString *report) {
            __weak TKLocalPacketProvider *weakSelf=self;
            [self.packetProbe startWithOutput:^BOOL(NSData *packet) {
                TKLocalPacketProvider *provider=weakSelf;
                return provider.running && [provider.packetFlow writePackets:@[packet] withProtocols:@[@AF_INET]];
            } completion:^(NSString *packetReport) {
            NSMutableDictionary *response=[TKRouteStatus(self.running,self.reflected,self.dropped) mutableCopy];
            response[@"helperProbe"]=[report stringByAppendingFormat:@" %@",packetReport];
            completion([NSJSONSerialization dataWithJSONObject:response options:0 error:NULL]);
            }];
        }];
        return;
    }
    NSDictionary *response;
    if([request isKindOfClass:NSDictionary.class] && [request[@"version"] isEqual:@TK_AUTH_PROTOCOL_VERSION] && [request[@"operation"] isEqual:@"status"])
        response=TKRouteStatus(self.running,self.reflected,self.dropped);
    else response=@{@"version":@TK_AUTH_PROTOCOL_VERSION,@"error":@"Unsupported control message",@"nativeExecutionReady":@NO};
    completion([NSJSONSerialization dataWithJSONObject:response options:0 error:NULL]);
}
@end
