#import "LocalShaderProbe.h"
#import <Metal/Metal.h>
#include <TargetConditionals.h>
#include <CommonCrypto/CommonDigest.h>
#include <math.h>

// Diagnostic only. Inputs are separately staged copies of our own add-one
// fixture and captured shader copies, never the game executable or cache entries.
static NSString *digest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString *result=[NSMutableString new];
    for(unsigned i=0;i<sizeof bytes;i++)[result appendFormat:@"%02x",bytes[i]];
    return result;
}
static NSString *run(id<MTLDevice> device,id<MTLLibrary> library,NSError *error) {
    if(!library)return [NSString stringWithFormat:@"library rejected: %@",error];
    id<MTLFunction> function=[library newFunctionWithName:@"add_one"];
    if(!function)return @"add_one function missing";
    id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:function error:&error];
    if(!pipeline)return [NSString stringWithFormat:@"pipeline rejected: %@",error];
    float input[64];for(unsigned i=0;i<64;i++)input[i]=(float)i*0.25f-8.0f;
    id<MTLBuffer> buffer=[device newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue=[device newCommandQueue];
    id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    if(!buffer || !encoder)return @"GPU resources unavailable";
    [encoder setComputePipelineState:pipeline];[encoder setBuffer:buffer offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(MIN(64,pipeline.maxTotalThreadsPerThreadgroup),1,1)];
    [encoder endEncoding];[command commit];[command waitUntilCompleted];
    if(command.status!=MTLCommandBufferStatusCompleted)return [NSString stringWithFormat:@"GPU command failed: %@",command.error];
    float *output=buffer.contents;
    for(unsigned i=0;i<64;i++)if(output[i]!=input[i]+1.0f)return @"GPU output mismatch";
    return @"PASS: compiled pipeline and all 64 output values match";
}
// Own numerical render fixture covering a desktop resource binding above 31.
static NSString *runTexture33(id<MTLDevice> device,id<MTLLibrary> library,NSError *error) {
    if(!library)return [NSString stringWithFormat:@"library rejected: %@",error];
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 probe_vertex(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }";
    id<MTLLibrary> vertex=[device newLibraryWithSource:source options:nil error:&error];
    MTLRenderPipelineDescriptor *description=[MTLRenderPipelineDescriptor new];
    description.vertexFunction=[vertex newFunctionWithName:@"probe_vertex"];
    description.fragmentFunction=[library newFunctionWithName:@"sample33"];
    description.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    if(!description.vertexFunction || !description.fragmentFunction)return @"render function unavailable";
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:description error:&error];
    if(!pipeline)return [NSString stringWithFormat:@"render pipeline rejected: %@",error];
    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    descriptor.storageMode=MTLStorageModeShared;descriptor.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> input=[device newTextureWithDescriptor:descriptor];
    descriptor.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> output=[device newTextureWithDescriptor:descriptor];
    if(!input || !output)return @"render textures unavailable";
    const uint8_t expected[4]={64,128,192,255};
    [input replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:expected bytesPerRow:4];
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture=output;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLCommandBuffer> command=[[device newCommandQueue] commandBuffer];
    id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
    if(!encoder)return @"render encoder unavailable";
    [encoder setRenderPipelineState:pipeline];[encoder setFragmentTexture:input atIndex:33];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[encoder endEncoding];
    [command commit];[command waitUntilCompleted];
    if(command.status!=MTLCommandBufferStatusCompleted)return [NSString stringWithFormat:@"render command failed: %@",command.error];
    uint8_t actual[4]={0};[output getBytes:actual bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    return memcmp(expected,actual,4)?@"render pixel mismatch":@"PASS: texture slot 33 pipeline and all RGBA pixel values match";
}
NSString *TKRunLocalShaderProbe(NSString *directory) {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if(!device)return @"No Metal device.";
    NSMutableString *report=[NSMutableString new];NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\nkernel void add_one(device float *v [[buffer(0)]],uint i [[thread_position_in_grid]]) {v[i]+=1.0f;}\n";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    [report appendFormat:@"On-device source: %@\n",run(device,library,error)];
    for(NSString *name in @[@"probe.mac.metallib",@"probe.ios.metallib",@"probe.mac21.metallib",@"probe.mac21legacy.metallib",@"sample.mac.metallib",@"probe.texture33.mac21.metallib"]) {
        NSString *path=[directory stringByAppendingPathComponent:name];
        NSData *original=[NSData dataWithContentsOfFile:path];
        if(original.length<88 || original.length>1024*1024 || memcmp(original.bytes,"MTLB",4)) {
            [report appendFormat:@"%@: missing/invalid fixture\n",name];continue;
        }
        NSString *before=digest(original);
        for(unsigned mode=0;mode<([name containsString:@".mac"]?2:1);mode++) {
            NSMutableData *derived=[original mutableCopy];
            if(mode) {
                // Test whether the on-device compiler can consume the same AIR
                // in an iOS container. This does not establish shader semantics
                // or justify metadata-only translation for arbitrary game AIR.
                uint8_t *header=derived.mutableBytes;
                header[4]=1;header[5]=0;header[11]=TARGET_OS_SIMULATOR?0x87:0x82;
            }
            dispatch_data_t data=dispatch_data_create(derived.bytes,derived.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            error=nil;library=[device newLibraryWithData:data error:&error];
            NSString *result;
            if([name hasPrefix:@"sample."]) {
                // Acceptance/function creation only. A game pipeline and its
                // resource semantics still need independent validation.
                result=library?[NSString stringWithFormat:@"library accepted, functions=%@",library.functionNames]:[NSString stringWithFormat:@"library rejected: %@",error];
                for(NSString *functionName in library.functionNames) {
                    id<MTLFunction> function=[library newFunctionWithName:functionName];
                    result=[result stringByAppendingFormat:@"; %@ function=%@ type=%lu",functionName,function?@"created":@"rejected",(unsigned long)function.functionType];
                }
            } else if([name containsString:@"texture33"]) result=runTexture33(device,library,error);
            else result=run(device,library,error);
            [report appendFormat:@"%@ %@: %@\n",name,mode?@"derived container":@"unchanged",result];
        }
        [report appendFormat:@"Input unchanged: %@ (%@)\n",[before isEqual:digest([NSData dataWithContentsOfFile:path])]?@"YES":@"NO",before];
    }
    return report;
}
