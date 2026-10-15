// The Mac's own GPU as the reference BC decoder: textures in a BC format are
// filled with the given blocks and every texel is read back as float4 by a
// compute kernel. Shared by tests/test_bc_textures.m.
#pragma once
#import <Metal/Metal.h>

// Reads every texel of a 2D texture (mip 0, slice 0) as float4, row-major.
static NSData *AKReadTexels(id<MTLDevice> device, id<MTLTexture> texture) {
    static id<MTLComputePipelineState> pipeline;
    static id<MTLCommandQueue> queue;
    if (!pipeline) {
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void readTexels(texture2d<float, access::sample> t [[texture(0)]], device float4 *out [[buffer(0)]],"
            " uint2 gid [[thread_position_in_grid]]) {\n"
            "  if (gid.x >= t.get_width() || gid.y >= t.get_height()) return;\n"
            "  constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);\n"
            "  out[gid.y * t.get_width() + gid.x] = t.sample(s, float2(gid) + 0.5);\n}\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { NSLog(@"reference kernel: %@", error); abort(); }
        pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"readTexels"] error:&error];
        if (!pipeline) { NSLog(@"reference pipeline: %@", error); abort(); }
        queue = [device newCommandQueue];
    }
    NSUInteger width = texture.width, height = texture.height;
    id<MTLBuffer> out = [device newBufferWithLength:width * height * 16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline];
    [encoder setTexture:texture atIndex:0];
    [encoder setBuffer:out offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) { NSLog(@"reference read failed: %@", command.error); abort(); }
    return [NSData dataWithBytes:out.contents length:width * height * 16];
}
