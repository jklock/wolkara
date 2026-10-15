#import "CapturedShaderProbe.h"
#import "LibraryContainer.h"
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>

// Diagnostic only. The libraries under Documents/ShaderRequests are the ones
// the runtime wrote when a Mac translation was needed; this asks the iPad's
// own Metal for each of them, the way the adapter now does first.
static NSString *digest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString *result=[NSMutableString new];
    for(unsigned i=0;i<sizeof bytes;i++)[result appendFormat:@"%02x",bytes[i]];
    return result;
}
static NSString *airLabel(uint8_t container) {
    switch(container) {
        case 2: return @"AIR 2.0"; case 3: return @"AIR 2.1"; case 5: return @"AIR 2.3";
        case 7: return @"AIR 2.6"; case 8: return @"AIR 2.7"; default: return @"unknown";
    }
}
static NSString *headerHex(NSData *data) {
    const uint8_t *b=data.bytes;NSMutableString *hex=[NSMutableString new];
    for(unsigned i=4;i<16 && i<data.length;i++)[hex appendFormat:@"%02x",b[i]];
    return hex;
}
NSString *TKRunCapturedShaderProbe(NSString *requests,NSString *translations,NSString *runID) {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device)return @"No Metal device.";
    NSMutableString *report=[NSMutableString new];
    if(runID)[report appendFormat:@"run %@\n",runID];
    NSArray<NSString *> *names=[[NSFileManager.defaultManager contentsOfDirectoryAtPath:requests error:nil] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *labels=[NSMutableArray new];
    NSMutableDictionary<NSString *,NSMutableDictionary<NSString *,NSNumber *> *> *counters=[NSMutableDictionary new];
    NSMutableArray<NSString *> *failures=[NSMutableArray new];
    NSUInteger total=0,notLoaded=0,changed=0,sameFunctions=0,differentFunctions=0,untranslated=0;
    NSDate *start=[NSDate date];
    for(NSString *name in names) @autoreleasepool {
        if(![name hasSuffix:@".metallib"])continue;
        NSString *path=[requests stringByAppendingPathComponent:name];
        NSData *original=[NSData dataWithContentsOfFile:path];
        if(original.length<88 || original.length>64*1024*1024 || memcmp(original.bytes,"MTLB",4))continue;
        total++;
        NSString *before=digest(original),*shortName=[name substringToIndex:MIN(name.length,12)];
        uint8_t container=((const uint8_t *)original.bytes)[8];
        NSString *label=[NSString stringWithFormat:@"container %u (%@)",container,airLabel(container)];
        NSMutableDictionary<NSString *,NSNumber *> *c=counters[label];
        if(!c) { c=[NSMutableDictionary new];counters[label]=c;[labels addObject:label]; }
        void (^count)(NSString *)=^(NSString *key) { c[key]=@(c[key].unsignedIntegerValue+1); };
        count(@"files");
        NSData *derived=AKLocalMetalLibraryData(original);
        if(!derived) {
            count(@"unsupported");notLoaded++;
            [failures addObject:[NSString stringWithFormat:@"%@: container not rewrapped, header %@",shortName,headerHex(original)]];
        } else {
            dispatch_data_t input=dispatch_data_create(derived.bytes,derived.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            NSError *error=nil;
            id<MTLLibrary> library=[device newLibraryWithData:input error:&error];
            if(!library) {
                count(@"rejected");notLoaded++;
                [failures addObject:[NSString stringWithFormat:@"%@: rejected: %@",shortName,error.localizedDescription?:@"no error"]];
            } else {
                count(@"loaded");
                NSArray<NSString *> *functionNames=library.functionNames;
                for(NSString *functionName in functionNames) {
                    id<MTLFunction> function=[library newFunctionWithName:functionName];
                    if(!function) {
                        count(@"functions failed");
                        [failures addObject:[NSString stringWithFormat:@"%@: function %@ not created",shortName,functionName]];
                        continue;
                    }
                    count(function.functionType==MTLFunctionTypeVertex?@"vertex":function.functionType==MTLFunctionTypeFragment?@"fragment":function.functionType==MTLFunctionTypeKernel?@"kernel":@"other functions");
                    if(function.functionType!=MTLFunctionTypeKernel)continue;
                    // A compute pipeline needs no descriptor, so its GPU code
                    // can be built here; render pipelines need the game's.
                    error=nil;
                    id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:function error:&error];
                    if(pipeline)count(@"compute pipelines");
                    else {
                        count(@"compute pipelines failed");
                        [failures addObject:[NSString stringWithFormat:@"%@: compute pipeline %@: %@",shortName,functionName,error.localizedDescription?:@"no error"]];
                    }
                }
                NSData *translated=[NSData dataWithContentsOfFile:[translations stringByAppendingPathComponent:name]];
                if(!translated)untranslated++;
                else {
                    dispatch_data_t translatedInput=dispatch_data_create(translated.bytes,translated.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                    id<MTLLibrary> translatedLibrary=[device newLibraryWithData:translatedInput error:nil];
                    if(translatedLibrary && [[NSSet setWithArray:translatedLibrary.functionNames] isEqualToSet:[NSSet setWithArray:functionNames]])sameFunctions++;
                    else differentFunctions++;
                }
            }
        }
        if(![before isEqual:digest([NSData dataWithContentsOfFile:path])])changed++;
    }
    [report appendFormat:@"Captured shader libraries: %lu in %@\n",(unsigned long)total,requests.lastPathComponent];
    for(NSString *label in labels) {
        NSDictionary<NSString *,NSNumber *> *c=counters[label];
        [report appendFormat:@"%@: %@ files; loaded %@, rejected %@, not rewrapped %@; functions: vertex %@, fragment %@, kernel %@, other %@, failed %@; compute pipelines built %@, failed %@\n",
            label,c[@"files"]?:@0,c[@"loaded"]?:@0,c[@"rejected"]?:@0,c[@"unsupported"]?:@0,c[@"vertex"]?:@0,c[@"fragment"]?:@0,c[@"kernel"]?:@0,
            c[@"other functions"]?:@0,c[@"functions failed"]?:@0,c[@"compute pipelines"]?:@0,c[@"compute pipelines failed"]?:@0];
    }
    [report appendFormat:@"Mac translations in %@: %lu with the same function names, %lu differing, %lu libraries without one\n",
        translations.lastPathComponent,(unsigned long)sameFunctions,(unsigned long)differentFunctions,(unsigned long)untranslated];
    [report appendFormat:@"Inputs unchanged: %@\n",changed?@"NO":@"YES"];
    [report appendFormat:@"Time: %.1f s\n",-start.timeIntervalSinceNow];
#if TARGET_OS_SIMULATOR
    [report appendString:@"Simulator: its Metal builds no GPU code from desktop AIR (\"Target OS is incompatible\"); pipeline results count only on a device.\n"];
#endif
    if(!total)[report appendString:@"RESULT: NOTHING TO CHECK: no captured libraries. They appear when a game needs a Mac translation.\n"];
    else if(notLoaded || failures.count)[report appendFormat:@"RESULT: INCOMPLETE: %lu of %lu libraries did not load on this device, %lu problems below\n",(unsigned long)notLoaded,(unsigned long)total,(unsigned long)failures.count];
    else [report appendFormat:@"RESULT: PASS: all %lu captured libraries load, their functions are created and their compute pipelines build on this device\n",(unsigned long)total];
    NSUInteger shown=0;
    for(NSString *failure in failures) { [report appendFormat:@"  %@\n",failure];if(++shown==40 && failures.count>40) { [report appendFormat:@"  ... %lu more\n",(unsigned long)(failures.count-40)];break; } }
    return report;
}
