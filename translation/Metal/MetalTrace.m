// Development diagnostics, opt-in (launch argument --trace-metal): what the
// application asks Metal to create, and above all what iPadOS refuses.
//
// Every failed creation is logged with its description: a texture, buffer or
// heap that comes back nil, a library compiled from source that does not
// build (its source is kept in Documents/ShaderRequests/<SHA-256>.metal, as
// rejected libraries are), a function a library lacks, a pipeline that fails,
// synchronously or in its completion handler. Successful creations are logged
// once per distinct kind (format, storage mode, usage, sampler settings...),
// so a run shows which macOS habits (Managed storage, linear textures in
// buffers, tile pipelines) the application relies on. Nothing is changed: each
// call goes to the original method with the original arguments.
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import "AKSupport.h"

static NSMutableSet *seen;
static NSUInteger failures;
static void note(NSString *line, BOOL failed) {
    @synchronized(seen) {
        if (failed) { if (failures++ >= 800) return; }
        else if (seen.count >= 1500 || [seen containsObject:line]) return;
        else [seen addObject:line];
    }
    AKLog(@"metal %@%@", failed ? @"FAILED " : @"", line);
}
static NSString *hashed(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString new];
    for (unsigned i = 0; i < sizeof digest; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}
static NSString *firstLine(NSError *error) {
    NSString *text = error.localizedDescription ?: @"(no error)";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" | "];
    return text.length > 400 ? [[text substringToIndex:400] stringByAppendingString:@"…"] : text;
}
static NSString *texture(MTLTextureDescriptor *d, BOOL withSize) {
    NSString *base = [NSString stringWithFormat:@"type=%lu format=%lu storage=%lu usage=0x%lx samples=%lu mips=%@ swizzle=%@",
        (unsigned long)d.textureType, (unsigned long)d.pixelFormat, (unsigned long)d.storageMode, (unsigned long)d.usage,
        (unsigned long)d.sampleCount, d.mipmapLevelCount > 1 ? @"yes" : @"no",
        (d.swizzle.red == MTLTextureSwizzleRed && d.swizzle.green == MTLTextureSwizzleGreen &&
         d.swizzle.blue == MTLTextureSwizzleBlue && d.swizzle.alpha == MTLTextureSwizzleAlpha) ? @"identity" : @"custom"];
    return withSize ? [base stringByAppendingFormat:@" size=%lux%lux%lu mips=%lu array=%lu", (unsigned long)d.width,
                       (unsigned long)d.height, (unsigned long)d.depth, (unsigned long)d.mipmapLevelCount, (unsigned long)d.arrayLength] : base;
}
static NSString *sampler(MTLSamplerDescriptor *d) {
    return [NSString stringWithFormat:@"min=%lu mag=%lu mip=%lu aniso=%lu lod=%.2f..%.2f address=%lu,%lu,%lu compare=%lu normalized=%d border=%lu argument=%d",
        (unsigned long)d.minFilter, (unsigned long)d.magFilter, (unsigned long)d.mipFilter, (unsigned long)d.maxAnisotropy,
        d.lodMinClamp, d.lodMaxClamp, (unsigned long)d.sAddressMode, (unsigned long)d.tAddressMode, (unsigned long)d.rAddressMode,
        (unsigned long)d.compareFunction, d.normalizedCoordinates, (unsigned long)d.borderColor, d.supportArgumentBuffers];
}
static NSString *renderPipeline(MTLRenderPipelineDescriptor *d) {
    NSMutableArray *colors = [NSMutableArray new];
    for (NSUInteger i = 0; i < 8; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[i];
        if (c.pixelFormat) [colors addObject:[NSString stringWithFormat:@"%lu:%lu%@", (unsigned long)i, (unsigned long)c.pixelFormat, c.blendingEnabled ? @"+blend" : @""]];
    }
    return [NSString stringWithFormat:@"vertex=%@ fragment=%@ colors=[%@] depth=%lu stencil=%lu samples=%lu alphaToCoverage=%d",
        d.vertexFunction.name ?: @"-", d.fragmentFunction.name ?: @"-", [colors componentsJoinedByString:@" "],
        (unsigned long)d.depthAttachmentPixelFormat, (unsigned long)d.stencilAttachmentPixelFormat,
        (unsigned long)d.rasterSampleCount, d.alphaToCoverageEnabled];
}
static NSString *tilePipeline(MTLTileRenderPipelineDescriptor *d) {
    return [NSString stringWithFormat:@"tile=%@ samples=%lu threadgroupSizeMatchesTile=%d", d.tileFunction.name ?: @"-",
        (unsigned long)d.rasterSampleCount, d.threadgroupSizeMatchesTileSize];
}

static IMP swap(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    return class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method)) ?: method_getImplementation(method);
}
#define RETAINED __attribute__((ns_returns_retained))

// ---- device
static IMP oTexture, oSurfaceTexture, oBuffer, oBytes, oSampler, oDepth, oHeap, oSource, oRender, oRenderAsync,
           oCompute, oComputeAsync, oComputeFunction, oTile, oTileAsync, oFunction, oBufferTexture, oHeapBuffer,
           oHeapTexture, oPlacedBuffer, oPlacedTexture;
static void watchBuffer(id buffer);
static void watchHeap(id heap);
static void watchLibrary(id library);

static id newTexture(id self, SEL _cmd, MTLTextureDescriptor *d) RETAINED;
static id newTexture(id self, SEL _cmd, MTLTextureDescriptor *d) {
    id result = ((id (*)(id, SEL, id))oTexture)(self, _cmd, d);
    note([@"texture " stringByAppendingString:texture(d, !result)], !result);
    return result;
}
static id newSurfaceTexture(id self, SEL _cmd, MTLTextureDescriptor *d, id surface, NSUInteger plane) RETAINED;
static id newSurfaceTexture(id self, SEL _cmd, MTLTextureDescriptor *d, id surface, NSUInteger plane) {
    id result = ((id (*)(id, SEL, id, id, NSUInteger))oSurfaceTexture)(self, _cmd, d, surface, plane);
    note([NSString stringWithFormat:@"IOSurface texture plane=%lu %@", (unsigned long)plane, texture(d, !result)], !result);
    return result;
}
static id newBuffer(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options) RETAINED;
static id newBuffer(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options) {
    id result = ((id (*)(id, SEL, NSUInteger, MTLResourceOptions))oBuffer)(self, _cmd, length, options);
    note([NSString stringWithFormat:@"buffer options=0x%lx%@", (unsigned long)options, result ? @"" : [NSString stringWithFormat:@" length=%lu", (unsigned long)length]], !result);
    watchBuffer(result);
    return result;
}
static id newBytes(id self, SEL _cmd, const void *bytes, NSUInteger length, MTLResourceOptions options) RETAINED;
static id newBytes(id self, SEL _cmd, const void *bytes, NSUInteger length, MTLResourceOptions options) {
    id result = ((id (*)(id, SEL, const void *, NSUInteger, MTLResourceOptions))oBytes)(self, _cmd, bytes, length, options);
    note([NSString stringWithFormat:@"buffer with bytes options=0x%lx%@", (unsigned long)options, result ? @"" : [NSString stringWithFormat:@" length=%lu", (unsigned long)length]], !result);
    watchBuffer(result);
    return result;
}
static id newSampler(id self, SEL _cmd, MTLSamplerDescriptor *d) RETAINED;
static id newSampler(id self, SEL _cmd, MTLSamplerDescriptor *d) {
    id result = ((id (*)(id, SEL, id))oSampler)(self, _cmd, d);
    note([@"sampler " stringByAppendingString:sampler(d)], !result);
    return result;
}
static id newDepth(id self, SEL _cmd, MTLDepthStencilDescriptor *d) RETAINED;
static id newDepth(id self, SEL _cmd, MTLDepthStencilDescriptor *d) {
    id result = ((id (*)(id, SEL, id))oDepth)(self, _cmd, d);
    if (!result) note([NSString stringWithFormat:@"depth-stencil compare=%lu write=%d", (unsigned long)d.depthCompareFunction, d.depthWriteEnabled], YES);
    return result;
}
static id newHeap(id self, SEL _cmd, MTLHeapDescriptor *d) RETAINED;
static id newHeap(id self, SEL _cmd, MTLHeapDescriptor *d) {
    id result = ((id (*)(id, SEL, id))oHeap)(self, _cmd, d);
    note([NSString stringWithFormat:@"heap type=%lu storage=%lu cpuCache=%lu hazard=%lu%@", (unsigned long)d.type, (unsigned long)d.storageMode,
          (unsigned long)d.cpuCacheMode, (unsigned long)d.hazardTrackingMode, result ? @"" : [NSString stringWithFormat:@" size=%lu", (unsigned long)d.size]], !result);
    watchHeap(result);
    return result;
}
static id newSource(id self, SEL _cmd, NSString *source, MTLCompileOptions *options, NSError **error) RETAINED;
static id newSource(id self, SEL _cmd, NSString *source, MTLCompileOptions *options, NSError **error) {
    NSError *local = nil;
    id result = ((id (*)(id, SEL, id, id, NSError **))oSource)(self, _cmd, source, options, &local);
    if (error) *error = local;
    NSString *key = hashed(source ?: @"");
    NSString *summary = [NSString stringWithFormat:@"library from source %@ (%lu chars) language=0x%lx fastMath=%d macros=%lu",
        [key substringToIndex:16], (unsigned long)source.length, (unsigned long)options.languageVersion,
        options.fastMathEnabled, (unsigned long)options.preprocessorMacros.count];
    if (!result || local) {
        NSString *requests = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"ShaderRequests"];
        [NSFileManager.defaultManager createDirectoryAtPath:requests withIntermediateDirectories:YES attributes:nil error:nil];
        [source writeToFile:[requests stringByAppendingPathComponent:[key stringByAppendingString:@".metal"]] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        note([summary stringByAppendingFormat:@" %@: %@", result ? @"warnings" : @"error", firstLine(local)], !result);
    } else note(summary, NO);
    watchLibrary(result);
    return result;
}
static id newRender(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, MTLPipelineOption options, MTLAutoreleasedRenderPipelineReflection *reflection, NSError **error) RETAINED;
static id newRender(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, MTLPipelineOption options, MTLAutoreleasedRenderPipelineReflection *reflection, NSError **error) {
    NSError *local = nil;
    id result = ((id (*)(id, SEL, id, MTLPipelineOption, MTLAutoreleasedRenderPipelineReflection *, NSError **))oRender)(self, _cmd, d, options, reflection, &local);
    if (error) *error = local;
    if (!result) note([NSString stringWithFormat:@"render pipeline %@: %@", renderPipeline(d), firstLine(local)], YES);
    else note([@"render pipeline kinds " stringByAppendingFormat:@"samples=%lu alphaToCoverage=%d", (unsigned long)d.rasterSampleCount, d.alphaToCoverageEnabled], NO);
    return result;
}
static void newRenderAsync(id self, SEL _cmd, MTLRenderPipelineDescriptor *d, MTLPipelineOption options, MTLNewRenderPipelineStateWithReflectionCompletionHandler handler) {
    NSString *description = renderPipeline(d);
    ((void (*)(id, SEL, id, MTLPipelineOption, id))oRenderAsync)(self, _cmd, d, options, ^(id<MTLRenderPipelineState> state, MTLRenderPipelineReflection *reflection, NSError *error) {
        if (!state) note([NSString stringWithFormat:@"render pipeline (async) %@: %@", description, firstLine(error)], YES);
        handler(state, reflection, error);
    });
}
static id newTile(id self, SEL _cmd, MTLTileRenderPipelineDescriptor *d, MTLPipelineOption options, MTLAutoreleasedRenderPipelineReflection *reflection, NSError **error) RETAINED;
static id newTile(id self, SEL _cmd, MTLTileRenderPipelineDescriptor *d, MTLPipelineOption options, MTLAutoreleasedRenderPipelineReflection *reflection, NSError **error) {
    NSError *local = nil;
    id result = ((id (*)(id, SEL, id, MTLPipelineOption, MTLAutoreleasedRenderPipelineReflection *, NSError **))oTile)(self, _cmd, d, options, reflection, &local);
    if (error) *error = local;
    note([NSString stringWithFormat:@"tile pipeline %@%@", tilePipeline(d), result ? @"" : [@": " stringByAppendingString:firstLine(local)]], !result);
    return result;
}
static void newTileAsync(id self, SEL _cmd, MTLTileRenderPipelineDescriptor *d, MTLPipelineOption options, MTLNewRenderPipelineStateWithReflectionCompletionHandler handler) {
    NSString *description = tilePipeline(d);
    note([@"tile pipeline (async) requested " stringByAppendingString:description], NO);
    ((void (*)(id, SEL, id, MTLPipelineOption, id))oTileAsync)(self, _cmd, d, options, ^(id<MTLRenderPipelineState> state, MTLRenderPipelineReflection *reflection, NSError *error) {
        if (!state) note([NSString stringWithFormat:@"tile pipeline (async) %@: %@", description, firstLine(error)], YES);
        handler(state, reflection, error);
    });
}
static id newCompute(id self, SEL _cmd, MTLComputePipelineDescriptor *d, MTLPipelineOption options, MTLAutoreleasedComputePipelineReflection *reflection, NSError **error) RETAINED;
static id newCompute(id self, SEL _cmd, MTLComputePipelineDescriptor *d, MTLPipelineOption options, MTLAutoreleasedComputePipelineReflection *reflection, NSError **error) {
    NSError *local = nil;
    id result = ((id (*)(id, SEL, id, MTLPipelineOption, MTLAutoreleasedComputePipelineReflection *, NSError **))oCompute)(self, _cmd, d, options, reflection, &local);
    if (error) *error = local;
    if (!result) note([NSString stringWithFormat:@"compute pipeline %@: %@", d.computeFunction.name ?: @"-", firstLine(local)], YES);
    return result;
}
static void newComputeAsync(id self, SEL _cmd, MTLComputePipelineDescriptor *d, MTLPipelineOption options, MTLNewComputePipelineStateWithReflectionCompletionHandler handler) {
    NSString *name = d.computeFunction.name ?: @"-";
    ((void (*)(id, SEL, id, MTLPipelineOption, id))oComputeAsync)(self, _cmd, d, options, ^(id<MTLComputePipelineState> state, MTLComputePipelineReflection *reflection, NSError *error) {
        if (!state) note([NSString stringWithFormat:@"compute pipeline (async) %@: %@", name, firstLine(error)], YES);
        handler(state, reflection, error);
    });
}
static id newComputeFunction(id self, SEL _cmd, id<MTLFunction> function, NSError **error) RETAINED;
static id newComputeFunction(id self, SEL _cmd, id<MTLFunction> function, NSError **error) {
    NSError *local = nil;
    id result = ((id (*)(id, SEL, id, NSError **))oComputeFunction)(self, _cmd, function, &local);
    if (error) *error = local;
    if (!result) note([NSString stringWithFormat:@"compute pipeline %@: %@", function.name ?: @"-", firstLine(local)], YES);
    return result;
}
// ---- libraries, buffers, heaps
static id newFunction(id self, SEL _cmd, NSString *name) RETAINED;
static id newFunction(id self, SEL _cmd, NSString *name) {
    id result = ((id (*)(id, SEL, id))oFunction)(self, _cmd, name);
    if (!result) note([@"function missing from its library: " stringByAppendingString:name ?: @"(null)"], YES);
    return result;
}
static id newBufferTexture(id self, SEL _cmd, MTLTextureDescriptor *d, NSUInteger offset, NSUInteger bytesPerRow) RETAINED;
static id newBufferTexture(id self, SEL _cmd, MTLTextureDescriptor *d, NSUInteger offset, NSUInteger bytesPerRow) {
    id result = ((id (*)(id, SEL, id, NSUInteger, NSUInteger))oBufferTexture)(self, _cmd, d, offset, bytesPerRow);
    id<MTLDevice> device = [(id<MTLBuffer>)self device];
    NSUInteger alignment = [device minimumLinearTextureAlignmentForPixelFormat:d.pixelFormat];
    note([NSString stringWithFormat:@"linear texture in buffer %@ offset%%align=%lu bytesPerRow%%align=%lu (alignment %lu)%@", texture(d, !result),
          (unsigned long)(alignment ? offset % alignment : 0), (unsigned long)(alignment ? bytesPerRow % alignment : 0), (unsigned long)alignment,
          result ? @"" : [NSString stringWithFormat:@" offset=%lu bytesPerRow=%lu", (unsigned long)offset, (unsigned long)bytesPerRow]], !result);
    return result;
}
static id newHeapBuffer(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options) RETAINED;
static id newHeapBuffer(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options) {
    id result = ((id (*)(id, SEL, NSUInteger, MTLResourceOptions))oHeapBuffer)(self, _cmd, length, options);
    note([NSString stringWithFormat:@"heap buffer options=0x%lx%@", (unsigned long)options, result ? @"" : [NSString stringWithFormat:@" length=%lu", (unsigned long)length]], !result);
    watchBuffer(result);
    return result;
}
static id newHeapTexture(id self, SEL _cmd, MTLTextureDescriptor *d) RETAINED;
static id newHeapTexture(id self, SEL _cmd, MTLTextureDescriptor *d) {
    id result = ((id (*)(id, SEL, id))oHeapTexture)(self, _cmd, d);
    note([@"heap texture " stringByAppendingString:texture(d, !result)], !result);
    return result;
}
static id newPlacedBuffer(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options, NSUInteger offset) RETAINED;
static id newPlacedBuffer(id self, SEL _cmd, NSUInteger length, MTLResourceOptions options, NSUInteger offset) {
    id result = ((id (*)(id, SEL, NSUInteger, MTLResourceOptions, NSUInteger))oPlacedBuffer)(self, _cmd, length, options, offset);
    note([NSString stringWithFormat:@"placed buffer options=0x%lx%@", (unsigned long)options, result ? @"" : [NSString stringWithFormat:@" length=%lu offset=%lu", (unsigned long)length, (unsigned long)offset]], !result);
    watchBuffer(result);
    return result;
}
static id newPlacedTexture(id self, SEL _cmd, MTLTextureDescriptor *d, NSUInteger offset) RETAINED;
static id newPlacedTexture(id self, SEL _cmd, MTLTextureDescriptor *d, NSUInteger offset) {
    id result = ((id (*)(id, SEL, id, NSUInteger))oPlacedTexture)(self, _cmd, d, offset);
    note([NSString stringWithFormat:@"placed texture %@%@", texture(d, !result), result ? @"" : [NSString stringWithFormat:@" offset=%lu", (unsigned long)offset]], !result);
    return result;
}

static void watchClass(id object, NSMutableSet *classes, void (^install)(Class)) {
    if (!object) return;
    Class cls = object_getClass(object);
    @synchronized(classes) {
        if ([classes containsObject:cls]) return;
        [classes addObject:cls];
    }
    install(cls);
}
static void watchBuffer(id buffer) {
    static NSMutableSet *classes; static dispatch_once_t once; dispatch_once(&once, ^{ classes = [NSMutableSet new]; });
    watchClass(buffer, classes, ^(Class cls) {
        IMP old = swap(cls, @selector(newTextureWithDescriptor:offset:bytesPerRow:), (IMP)newBufferTexture);
        if (old && old != (IMP)newBufferTexture) oBufferTexture = old;
    });
}
static void watchHeap(id heap) {
    static NSMutableSet *classes; static dispatch_once_t once; dispatch_once(&once, ^{ classes = [NSMutableSet new]; });
    watchClass(heap, classes, ^(Class cls) {
        IMP old = swap(cls, @selector(newBufferWithLength:options:), (IMP)newHeapBuffer);
        if (old && old != (IMP)newHeapBuffer) oHeapBuffer = old;
        old = swap(cls, @selector(newTextureWithDescriptor:), (IMP)newHeapTexture);
        if (old && old != (IMP)newHeapTexture) oHeapTexture = old;
        old = swap(cls, @selector(newBufferWithLength:options:offset:), (IMP)newPlacedBuffer);
        if (old && old != (IMP)newPlacedBuffer) oPlacedBuffer = old;
        old = swap(cls, @selector(newTextureWithDescriptor:offset:), (IMP)newPlacedTexture);
        if (old && old != (IMP)newPlacedTexture) oPlacedTexture = old;
    });
}
static void watchLibrary(id library) {
    static NSMutableSet *classes; static dispatch_once_t once; dispatch_once(&once, ^{ classes = [NSMutableSet new]; });
    watchClass(library, classes, ^(Class cls) {
        IMP old = swap(cls, @selector(newFunctionWithName:), (IMP)newFunction);
        if (old && old != (IMP)newFunction) oFunction = old;
    });
}

// Libraries from data come through Devices.m's loader: watch their functions too.
void AKTraceMetalLibrary(id library) { if (seen) watchLibrary(library); }

void AKInstallMetalTrace(Class device) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (![NSProcessInfo.processInfo.arguments containsObject:@"--trace-metal"]) return;
        seen = [NSMutableSet new];
        AKLog(@"Metal: tracing creations and failures (--trace-metal)");
        struct { SEL selector; IMP replacement; IMP *original; } hooks[] = {
            {@selector(newTextureWithDescriptor:), (IMP)newTexture, &oTexture},
            {@selector(newTextureWithDescriptor:iosurface:plane:), (IMP)newSurfaceTexture, &oSurfaceTexture},
            {@selector(newBufferWithLength:options:), (IMP)newBuffer, &oBuffer},
            {@selector(newBufferWithBytes:length:options:), (IMP)newBytes, &oBytes},
            {@selector(newSamplerStateWithDescriptor:), (IMP)newSampler, &oSampler},
            {@selector(newDepthStencilStateWithDescriptor:), (IMP)newDepth, &oDepth},
            {@selector(newHeapWithDescriptor:), (IMP)newHeap, &oHeap},
            {@selector(newLibraryWithSource:options:error:), (IMP)newSource, &oSource},
            {@selector(newRenderPipelineStateWithDescriptor:options:reflection:error:), (IMP)newRender, &oRender},
            {@selector(newRenderPipelineStateWithDescriptor:options:completionHandler:), (IMP)newRenderAsync, &oRenderAsync},
            {@selector(newRenderPipelineStateWithTileDescriptor:options:reflection:error:), (IMP)newTile, &oTile},
            {@selector(newRenderPipelineStateWithTileDescriptor:options:completionHandler:), (IMP)newTileAsync, &oTileAsync},
            {@selector(newComputePipelineStateWithDescriptor:options:reflection:error:), (IMP)newCompute, &oCompute},
            {@selector(newComputePipelineStateWithDescriptor:options:completionHandler:), (IMP)newComputeAsync, &oComputeAsync},
            {@selector(newComputePipelineStateWithFunction:error:), (IMP)newComputeFunction, &oComputeFunction},
        };
        for (size_t i = 0; i < sizeof hooks / sizeof *hooks; i++) {
            IMP old = swap(device, hooks[i].selector, hooks[i].replacement);
            if (old) *hooks[i].original = old;
            else AKLog(@"Metal trace: the device has no %@", NSStringFromSelector(hooks[i].selector));
        }
    });
}
