#import "LocalAuthorization.h"
#import "Diagnostics/LocalServiceProbe.h"
#import "Protocol.h"
#import "LocalArenaPublisher.h"
#import "LocalArenaPoller.h"
#import "LocalServiceRetry.h"
#include "Control/ArenaControl.h"
#import <NetworkExtension/NetworkExtension.h>
#import <QuartzCore/QuartzCore.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

NSNotificationName const TKLocalServiceWaiting = @"TKLocalServiceWaiting";

NSNotificationName const TKLocalArenaWillPrepare = @"TKLocalArenaWillPrepare";
NSNotificationName const TKLocalArenaDidPrepare = @"TKLocalArenaDidPrepare";

static void announceArena(NSNotificationName name, NSDictionary *info) {
    void (^announce)(void) = ^{
        [NSNotificationCenter.defaultCenter postNotificationName:name object:nil userInfo:info];
        [CATransaction flush];
    };
    if (NSThread.isMainThread) announce();
    else dispatch_sync(dispatch_get_main_queue(), announce);
}

@interface TKLocalAuthorization ()
@property(nonatomic,strong) NETunnelProviderManager *manager;
@property(nonatomic,readwrite) BOOL localSessionReady;
@property(nonatomic,strong) TKLocalServiceRetry *serviceRetry;
@property(nonatomic) NSUInteger serviceGeneration;
@end

static void TKWaitForRoute(NETunnelProviderManager *manager,CFTimeInterval deadline,void (^completion)(BOOL)) {
    if(manager.connection.status==NEVPNStatusConnected) {completion(YES);return;}
    if(CACurrentMediaTime()>=deadline) {completion(NO);return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        TKWaitForRoute(manager,deadline,completion);
    });
}
static void TKWaitForStoppedRoute(NETunnelProviderManager *manager,CFTimeInterval deadline,void (^completion)(BOOL)) {
    NEVPNStatus status=manager.connection.status;
    if(status==NEVPNStatusDisconnected || status==NEVPNStatusInvalid) {completion(YES);return;}
    if(CACurrentMediaTime()>=deadline) {completion(NO);return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        TKWaitForStoppedRoute(manager,deadline,completion);
    });
}
@implementation TKLocalAuthorization
- (void)startAndProbeLocalRoute:(void (^)(NSString *))completion {
    [self startAndProbeLocalRoute:0 completion:completion];
}
- (void)startAndVerifyPairing:(void (^)(NSString *))completion {
    [self startAndProbeLocalRoute:1 completion:completion];
}
- (void)startAndVerifyTunnel:(void (^)(NSString *))completion {
    [self startAndProbeLocalRoute:2 completion:completion];
}
- (void)startAndPrepareLocalAuthorization:(void (^)(NSString *))completion {
    [self startAndProbeLocalRoute:3 completion:completion];
}
- (void)startAndProbeLocalRoute:(NSUInteger)mode completion:(void (^)(NSString *))completion {
    [self.serviceRetry cancel];
    NSUInteger generation=++self.serviceGeneration;
    self.localSessionReady=NO;
    [self startLocalRoute:^(NSString *startResult) {
        if(self.serviceGeneration!=generation) {completion(@"Local service setup cancelled.");return;}
        TKWaitForRoute(self.manager,CACurrentMediaTime()+10,^(BOOL connected) {
            if(self.serviceGeneration!=generation) {completion(@"Local service setup cancelled.");return;}
            if(!connected) {
                completion([NSString stringWithFormat:@"Route did not connect (status %ld). %@",(long)self.manager.connection.status,startResult]);return;
            }
            __weak TKLocalAuthorization *weakSelf=self;
            __block __weak TKLocalServiceRetry *weakRetry;
            self.serviceRetry=[[TKLocalServiceRetry alloc] initWithTimeout:mode==3?120:60 interval:2 attempt:^(TKLocalServiceReply reply) {
                TKLocalAuthorization *self=weakSelf;
                if(!self) {reply(TKLocalServiceFailed,@"Local authorization owner unavailable.");return;}
                [TKLocalAuthorization probeLocalRouteService:^(NSString *result) {
                    if(!weakRetry || self.serviceRetry!=weakRetry || self.serviceGeneration!=generation)return;
                    if(self.manager.connection.status!=NEVPNStatusConnected) {
                        reply(TKLocalServiceFailed,@"Local route disconnected before service setup.");return;
                    }
                    NSString *device=[NSUserDefaults.standardUserDefaults stringForKey:@"TKEnrolledDeviceIdentifier"]?:@"";
                    NSData *request=[NSJSONSerialization dataWithJSONObject:@{@"version":@TK_AUTH_PROTOCOL_VERSION,
                        @"operation":mode==3?@"prepareAuthorization":mode==2?@"verifyTunnel":mode==1?@"verifyPairing":@"probeService",@"deviceIdentifier":device} options:0 error:NULL];
                    NSError *error=nil;
                    BOOL sent=[(NETunnelProviderSession *)self.manager.connection sendProviderMessage:request returnError:&error responseHandler:^(NSData *data) {
                        id state=data && data.length<=4096?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
                        BOOL valid=[state isKindOfClass:NSDictionary.class] && [state[@"version"] isEqual:@TK_AUTH_PROTOCOL_VERSION];
                        NSString *report=result;
                        NSString *helper=valid?state[@"helperProbe"]:nil;
                        if([helper isKindOfClass:NSString.class] && helper.length<=1024)report=[report stringByAppendingFormat:@" Helper: %@",helper];
                        if(valid) report=[report stringByAppendingFormat:@" Route status: running=%d, reflected=%llu, dropped=%llu.",[state[@"routeRunning"] boolValue],[state[@"reflectedPackets"] unsignedLongLongValue],[state[@"droppedPackets"] unsignedLongLongValue]];
                        BOOL ready=valid && [state[@"readyForPreparation"] isEqual:@YES];
                        // Only the helper can classify a failed initial TCP
                        // connection. Never infer retryability from report text.
                        BOOL retry=mode==3 && valid && !ready && [state[@"serviceUnavailable"] isEqual:@YES];
                        reply(ready || (mode!=3 && valid)?TKLocalServiceReady:retry?TKLocalServiceUnavailable:TKLocalServiceFailed,report);
                    }];
                    if(!sent)reply(TKLocalServiceFailed,[result stringByAppendingString:@" Provider status unavailable."]);
                }];
            }];
            weakRetry=self.serviceRetry;
            [self.serviceRetry startWithWaiting:^{
                [NSNotificationCenter.defaultCenter postNotificationName:TKLocalServiceWaiting object:weakSelf];
            } completion:^(BOOL ready,NSString *report) {
                TKLocalAuthorization *self=weakSelf;
                if(!self)return;
                self.localSessionReady=mode==3 && ready;
                self.serviceRetry=nil;
                if(!ready)[self.manager.connection stopVPNTunnel];
                completion(report);
            }];
        });
    }];
}
+ (void)probeDirectService:(void (^)(NSString *))completion {
    [TKLocalServiceProbe probeService:NO address:@"127.0.0.1" completion:completion];
}
+ (void)probeRemotePairingService:(void (^)(NSString *))completion {
    [TKLocalServiceProbe probeService:YES address:@"127.0.0.1" completion:completion];
}
+ (void)probeLocalRouteService:(void (^)(NSString *))completion {
    [TKLocalServiceProbe probeService:YES address:TK_AUTH_PEER completion:completion];
}
+ (void)probeDirectAccess:(void (^)(NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        int fd=socket(AF_INET,SOCK_STREAM,0),result=errno;
        if(fd>=0) {
            int flags=fcntl(fd,F_GETFL,0);
            if(flags<0 || fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0)result=errno;
            else {
                struct sockaddr_in address={.sin_len=sizeof address,.sin_family=AF_INET,.sin_port=htons(49152)};
                inet_pton(AF_INET,"127.0.0.1",&address.sin_addr);
                int rc=connect(fd,(struct sockaddr *)&address,sizeof address);result=rc==0?0:errno;
                if(rc<0 && result==EINPROGRESS) {
                    struct pollfd p={.fd=fd,.events=POLLOUT};rc=poll(&p,1,1500);
                    if(rc>0) {socklen_t n=sizeof result;if(getsockopt(fd,SOL_SOCKET,SO_ERROR,&result,&n))result=errno;}
                    else result=rc==0?ETIMEDOUT:errno;
                }
            }
            close(fd);
        }
        NSString *text=result?[NSString stringWithFormat:@"Direct loopback port 49152: %s (%d). This does not establish that every direct route is unavailable.",strerror(result),result]:@"Direct loopback port 49152 accepted a connection. Service identity, pairing and native authorization are not verified.";
        dispatch_async(dispatch_get_main_queue(),^{completion(text);});
    });
}
- (void)startLocalRoute:(void (^)(NSString *))completion {
    [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> *managers,NSError *error) {
        if(error) {dispatch_async(dispatch_get_main_queue(),^{completion(error.localizedDescription);});return;}
        NETunnelProviderManager *selected=nil;
        for(NETunnelProviderManager *candidate in managers) {
            if([candidate.protocolConfiguration isKindOfClass:NETunnelProviderProtocol.class] &&
               [((NETunnelProviderProtocol *)candidate.protocolConfiguration).providerBundleIdentifier isEqual:TK_AUTH_PROVIDER_ID]) {selected=candidate;break;}
        }
        self.manager=selected?:[NETunnelProviderManager new];
        NETunnelProviderProtocol *configuration=[NETunnelProviderProtocol new];
        configuration.providerBundleIdentifier=TK_AUTH_PROVIDER_ID;
        configuration.serverAddress=TK_AUTH_PEER;
        configuration.includeAllNetworks=NO;
        configuration.excludeLocalNetworks=NO;
        configuration.disconnectOnSleep=YES;
        self.manager.protocolConfiguration=configuration;
        self.manager.localizedDescription=@"Tolkara local development route";
        self.manager.enabled=YES;
        self.manager.onDemandEnabled=NO;
        [self.manager saveToPreferencesWithCompletionHandler:^(NSError *saveError) {
            if(saveError) {dispatch_async(dispatch_get_main_queue(),^{completion(saveError.localizedDescription);});return;}
            [self.manager loadFromPreferencesWithCompletionHandler:^(NSError *loadError) {
                if(loadError) {dispatch_async(dispatch_get_main_queue(),^{completion(loadError.localizedDescription);});return;}
                // Every cold app launch needs an unused helper transaction.
                // Stop only our own route and wait for actual OS teardown.
                [self.manager.connection stopVPNTunnel];
                TKWaitForStoppedRoute(self.manager,CACurrentMediaTime()+10,^(BOOL stopped) {
                    NSError *startError=nil;
                    BOOL requested=stopped && [self.manager.connection startVPNTunnelAndReturnError:&startError];
                    NSString *text=requested?@"Local route started; authentication is a separate step.":(startError.localizedDescription?:@"The previous local session did not stop in time.");
                    dispatch_async(dispatch_get_main_queue(),^{completion(text);});
                });
            }];
        }];
    }];
}
- (void)stopLocalRoute { self.serviceGeneration++; [self.serviceRetry cancel]; self.localSessionReady=NO; [self.manager.connection stopVPNTunnel]; }
@end

NCPreparation TKPrepareLocalArena(void *address,size_t size,void *context) {
    (void)context;
    static TKLocalArenaPublisher *publisher;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        publisher=[[TKLocalArenaPublisher alloc] initWithTransport:^BOOL(NSData *request,void (^completion)(NSData *)) {
            // Loading preferences is asynchronous. Once queued, loss of its
            // callback is uncertainty, even if no provider message was sent yet.
            [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> *managers,NSError *error) {
                NETunnelProviderSession *session=nil;
                if(!error) for(NETunnelProviderManager *candidate in managers) {
                    if([candidate.protocolConfiguration isKindOfClass:NETunnelProviderProtocol.class] &&
                       [((NETunnelProviderProtocol *)candidate.protocolConfiguration).providerBundleIdentifier isEqual:TK_AUTH_PROVIDER_ID] &&
                       candidate.connection.status==NEVPNStatusConnected) {
                        session=(NETunnelProviderSession *)candidate.connection; break;
                    }
                }
                if(!session) {
                    uint8_t reply[TKAC_SIZE];
                    BOOL valid=tkac_reply(request.bytes,request.length,TKAC_REJECTED,reply,sizeof reply);
                    completion(valid?[NSData dataWithBytes:reply length:sizeof reply]:nil); return;
                }
                TKLocalArenaPoller *poller=[[TKLocalArenaPoller alloc] initWithTransport:^BOOL(NSData *message,void (^reply)(NSData *)) {
                    NSError *sendError=nil;
                    return [session sendProviderMessage:message returnError:&sendError responseHandler:reply];
                }];
                [poller start:request completion:completion];
            }];
            return YES;
        }];
    });
    CFTimeInterval began=CACurrentMediaTime();
    announceArena(TKLocalArenaWillPrepare, @{@"bytes":@(size)});
    NCPreparation result=[publisher prepare:address size:size timeout:930];
    announceArena(TKLocalArenaDidPrepare, @{@"prepared":@(result == NC_PREPARED)});
    fprintf(stderr,"[local-launch] arena result=%u bytes=%zu elapsed=%.3fs\n",(unsigned)result,size,CACurrentMediaTime()-began);
    return result;
}
