#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#import "AKSupport.h"
#import "LibraryContainer.h"
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#include <stdatomic.h>
static atomic_uint shaderWaiters;
bool AKShaderWaitPending(void) { return atomic_load(&shaderWaiters)>0; }
static UIWindow *shaderPauseWindow;
static void updateShaderPause(void) {
    dispatch_async(dispatch_get_main_queue(),^{
        if(!AKShaderWaitPending()) { shaderPauseWindow.hidden=YES; shaderPauseWindow=nil; return; }
        if(shaderPauseWindow)return;
        UIWindowScene *scene=nil;
        for(UIScene *candidate in UIApplication.sharedApplication.connectedScenes)
            if([candidate isKindOfClass:UIWindowScene.class] && candidate.activationState==UISceneActivationStateForegroundActive) { scene=(UIWindowScene *)candidate; break; }
        if(!scene)return;
        shaderPauseWindow=[[UIWindow alloc] initWithWindowScene:scene];
        shaderPauseWindow.windowLevel=UIWindowLevelAlert+1;
        UIViewController *controller=[UIViewController new];
        controller.view.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:.8];
        UILabel *label=[UILabel new];label.translatesAutoresizingMaskIntoConstraints=NO;
        label.numberOfLines=0;label.textAlignment=NSTextAlignmentCenter;label.textColor=UIColor.whiteColor;
        label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
        label.text=getenv("TOLKARA_LOCAL_SHADERS_ONLY")
            ? @"Local shader test paused\n\nThe iPad compiler could not accept this shader. Close the app to end this test."
            : @"Game paused for an unsupported shader\n\nConnect to the Mac with the shader service running.\nThe game will resume when the translation is ready.";
        [controller.view addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
            [label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
            [label.widthAnchor constraintLessThanOrEqualToAnchor:controller.view.safeAreaLayoutGuide.widthAnchor constant:-64],
            [label.widthAnchor constraintLessThanOrEqualToConstant:640]]];
        shaderPauseWindow.rootViewController=controller;
        // Do not replace the game's key window or keyboard focus.
        shaderPauseWindow.hidden=NO;
    });
}
static void shaderWaitTick(void) {
    if(NSThread.isMainThread) CFRunLoopRunInMode(kCFRunLoopDefaultMode,.05,false);
    else [NSThread sleepForTimeInterval:.05];
}
// Apple Silicon has a fixed integrated GPU. Keep observer lifetime semantics,
// while returning the actual Metal device without emulating GPU capability.
@interface AKDeviceObserver : NSObject
@property(copy) void (^handler)(id<MTLDevice>,NSString *);
@end
@implementation AKDeviceObserver @end
static NSMutableSet *observers;
// Desktop topology queries have no iOS selector. They describe the fixed GPU;
// all actual capability queries and resource operations stay on native Metal.
static BOOL desktopFalse(id self,SEL selector) { (void)self; (void)selector; return NO; }
static NSUInteger builtInLocation(id self,SEL selector) { (void)self; (void)selector; return 0; }
static NSUInteger builtInNumber(id self,SEL selector) { (void)self; (void)selector; return 1; }
typedef id<MTLLibrary> (*LibraryLoader)(id,SEL,dispatch_data_t,NSError *__autoreleasing *) __attribute__((ns_returns_retained));
static LibraryLoader originalLibraryLoader;
static NSCache<NSString *,id<MTLLibrary>> *libraryCache(id<MTLDevice> device) {
    static NSMapTable *devices; static dispatch_once_t once;
    dispatch_once(&once,^{ devices=[NSMapTable weakToStrongObjectsMapTable]; });
    @synchronized(devices) {
        NSCache *cache=[devices objectForKey:device];
        if(!cache) {
            cache=[NSCache new]; cache.countLimit=1024;
            cache.totalCostLimit=64*1024*1024;
            [devices setObject:cache forKey:device];
        }
        return cache;
    }
}
static NSData *translatedLibraryData(NSString *path) {
    NSData *manifest=[NSData dataWithContentsOfFile:[path stringByAppendingString:@".json"]];
    NSDictionary *ready=manifest ? [NSJSONSerialization JSONObjectWithData:manifest options:0 error:nil] : nil;
    if(![ready isKindOfClass:NSDictionary.class]) return nil;
    NSData *bytes=[NSData dataWithContentsOfFile:path];
    if(!bytes || bytes.length!=[ready[@"length"] unsignedLongLongValue]) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    NSMutableString *hash=[NSMutableString new]; for(unsigned i=0;i<sizeof digest;i++) [hash appendFormat:@"%02x",digest[i]];
    return [hash isEqual:ready[@"sha256"]] ? bytes : nil;
}
static id<MTLLibrary> captureLibrary(id receiver,SEL selector,dispatch_data_t data,NSError *__autoreleasing *error) __attribute__((ns_returns_retained));
static id<MTLLibrary> captureLibrary(id receiver,SEL selector,dispatch_data_t data,NSError *__autoreleasing *error) {
    size_t length=dispatch_data_get_size(data);
    if(!length || length>64*1024*1024) return originalLibraryLoader(receiver,selector,data,error);
    NSMutableData *bytes=[NSMutableData dataWithLength:length];
    dispatch_data_apply(data,^bool(dispatch_data_t region,size_t offset,const void *buffer,size_t size) {
        (void)region; memcpy((char *)bytes.mutableBytes+offset,buffer,size); return true;
    });
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    NSMutableString *key=[NSMutableString new]; for(unsigned i=0;i<sizeof digest;i++) [key appendFormat:@"%02x",digest[i]];
    // Library contents are immutable. Reuse native library objects for identical
    // guest bytes on the same device, preserving this create method's +1 result.
    // NSCache bounds retention and can purge objects under memory pressure.
    NSCache *libraries=libraryCache(receiver);
    id<MTLLibrary> existing=[libraries objectForKey:key];
    if(existing) { if(error)*error=nil; return existing; }
    NSString *documents=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *name=[key stringByAppendingString:@".metallib"];
    NSString *cached=[[documents stringByAppendingPathComponent:@"TranslatedShaders"] stringByAppendingPathComponent:name];
    BOOL localOnly=getenv("TOLKARA_LOCAL_SHADERS_ONLY")!=NULL;
    NSData *translated=localOnly?nil:translatedLibraryData(cached);
    if(!translated) {
        NSData *local=AKLocalMetalLibraryData(bytes);
        if(local) {
            dispatch_data_t input=dispatch_data_create(local.bytes,local.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            NSError *localError=nil;
            id<MTLLibrary> library=originalLibraryLoader(receiver,selector,input,&localError);
            AKLog(@"On-device Metal library %@: %@%@",key,library?@"loaded":@"rejected",library?@"":[NSString stringWithFormat:@" error=%@",localError]);
            if(library) {
                [libraries setObject:library forKey:[key copy] cost:local.length];
                if(error)*error=nil;return library;
            }
        }
    }
    if(!translated && ([NSProcessInfo.processInfo.arguments containsObject:@"--translate-shaders"] || getenv("TOLKARA_WAIT_FOR_MISSING_SHADERS"))) {
        // Serialize misses so a single USB request file represents one job.
        // Cache hits and all draw/resource calls stay on the device.
        static NSLock *translationLock;static dispatch_once_t once;
        dispatch_once(&once,^{ translationLock=[NSLock new]; });
        atomic_fetch_add(&shaderWaiters,1);
        // Queue the notice after a short compile; ordinary cache misses need not
        // flash an overlay. A stalled guest job wait pumps this main queue too.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ updateShaderPause(); });
        while(![translationLock tryLock]) shaderWaitTick();
        @try {
            translated=localOnly?nil:translatedLibraryData(cached);
            if(!translated) {
                NSString *requests=[documents stringByAppendingPathComponent:@"ShaderRequests"];
                NSString *cache=[documents stringByAppendingPathComponent:@"TranslatedShaders"];
                [NSFileManager.defaultManager createDirectoryAtPath:requests withIntermediateDirectories:YES attributes:nil error:nil];
                [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
                if([bytes writeToFile:[requests stringByAppendingPathComponent:name] atomically:YES]) {
                    NSData *job=[NSJSONSerialization dataWithJSONObject:@{@"sha256":key} options:0 error:nil];
                    [job writeToFile:[documents stringByAppendingPathComponent:@"shader-request.json"] atomically:YES];
                    AKLog(@"Waiting for shader translation %@ (%zu bytes)",key,length);
                    NSString *failure=[cache stringByAppendingPathComponent:[key stringByAppendingString:@".error"]];
                    BOOL reportedFailure=NO;
                    for(;;) {
                        translated=localOnly?nil:translatedLibraryData(cached);
                        if(translated) break;
                        if(!reportedFailure && [NSFileManager.defaultManager fileExistsAtPath:failure]) {
                            AKLog(@"Shader translation failed; keeping game paused until a valid replacement arrives: %@",key);reportedFailure=YES;
                        }
                        shaderWaitTick();
                    }
                    AKLog(@"Shader pause resolved: %@",key);
                }
            }
        } @finally {
            [translationLock unlock];
            if(atomic_fetch_sub(&shaderWaiters,1)==1)updateShaderPause();
        }
    }
    if(translated) {
        dispatch_data_t input=dispatch_data_create(translated.bytes,translated.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        id<MTLLibrary> library=originalLibraryLoader(receiver,selector,input,error);
        AKLog(@"Translated Metal library %@: %@ (%zu bytes)%@",key,library?@"loaded":@"rejected",translated.length,library?@"":[NSString stringWithFormat:@" error=%@",error?*error:nil]);
        if(library) { [libraries setObject:library forKey:[key copy] cost:translated.length]; return library; }
    }
    NSError *localError=nil;
    id<MTLLibrary> library=originalLibraryLoader(receiver,selector,data,&localError);
    if(error) *error=localError;
    if(!library) {
        AKLog(@"Metal library %@ rejected: %@",key,localError);
        NSString *requests=[documents stringByAppendingPathComponent:@"ShaderRequests"];
        [NSFileManager.defaultManager createDirectoryAtPath:requests withIntermediateDirectories:YES attributes:nil error:nil];
        if([bytes writeToFile:[requests stringByAppendingPathComponent:name] atomically:YES])
            AKLog(@"Captured shader request %@: %zu bytes",key,length);
    }
    return library;
}
extern void AKInstallMetalPresentationDiagnostics(id<MTLDevice> device);
static void addDesktopProperties(id<MTLDevice> device) {
    AKInstallMetalPresentationDiagnostics(device);
    Class cls=object_getClass(device);
    static dispatch_once_t once;
    dispatch_once(&once,^{
        SEL selector=@selector(newLibraryWithData:error:);
        Method method=class_getInstanceMethod(cls,selector);
        originalLibraryLoader=(LibraryLoader)method_getImplementation(method);
        class_replaceMethod(cls,selector,(IMP)captureLibrary,method_getTypeEncoding(method));
    });
    for(NSString *name in @[@"isLowPower",@"isHeadless",@"isRemovable",@"isDepth24Stencil8PixelFormatSupported"])
        if(![device respondsToSelector:NSSelectorFromString(name)]) class_addMethod(cls,NSSelectorFromString(name),(IMP)desktopFalse,"B@:");
    if(![device respondsToSelector:NSSelectorFromString(@"location")]) class_addMethod(cls,NSSelectorFromString(@"location"),(IMP)builtInLocation,"Q@:");
    if(![device respondsToSelector:NSSelectorFromString(@"locationNumber")]) class_addMethod(cls,NSSelectorFromString(@"locationNumber"),(IMP)builtInNumber,"Q@:");
}
NSArray<id<MTLDevice>> *MTLCopyAllDevicesWithObserver(id<NSObject> __strong *observer,
    void (^handler)(id<MTLDevice>,NSString *)) __attribute__((ns_returns_retained));
NSArray<id<MTLDevice>> *MTLCopyAllDevicesWithObserver(id<NSObject> __strong *observer,
    void (^handler)(id<MTLDevice>,NSString *)) {
    AKDeviceObserver *token=[AKDeviceObserver new]; token.handler=handler;
    @synchronized(AKDeviceObserver.class) { if(!observers) observers=[NSMutableSet new]; [observers addObject:token]; }
    if(observer) *observer=token;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(device) addDesktopProperties(device);
    AKLog(@"Metal device enumeration: %@",device.name);
    return device ? @[device] : @[];
}
void MTLRemoveDeviceObserver(id<NSObject> observer) {
    @synchronized(AKDeviceObserver.class) { [observers removeObject:observer]; }
}
