// translation/Metal/BCTextures.m and BCDecode.c on the Mac's own GPU, which
// samples every BC format natively:
//
//   TOLKARA_BC_FALLBACK unset (auto): the Mac has BC, so nothing is installed
//   and textures stay native; the GPU then serves as the reference decoder for
//   random blocks of every format and every BC6H/BC7 mode.
//   TOLKARA_BC_FALLBACK=off: nothing is installed either.
//   TOLKARA_BC_FALLBACK=on: the fallback as an A16 iPhone gets it. This test
//   plays the guest: it sees the BC formats it asked for, while the GPU reads
//   decoded texels, through every upload route.
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "BCDecode.h"
#include "bc_gpu_reference.h"

void AKInstallBCTextureFallback(id<MTLDevice> device);
unsigned long AKBCStoredPixelFormat(id texture);

static uint32_t seed = 2026;
static uint8_t randomByte(void) { seed = seed * 1664525u + 1013904223u; return (uint8_t)(seed >> 24); }
static NSMutableData *randomBlocks(AKBCKind kind, size_t count) {
    NSMutableData *data = [NSMutableData dataWithLength:count * AKBCBlockBytes(kind)];
    uint8_t *bytes = data.mutableBytes;
    for (size_t i = 0; i < data.length; i++) bytes[i] = randomByte();
    // Spread BC7 over its eight modes and the reserved one, and BC6H over its
    // fourteen modes and two reserved codes; random bytes alone favour few.
    for (size_t i = 0; i < count; i++) {
        uint8_t *block = bytes + i * AKBCBlockBytes(kind);
        if (kind == AKBC7) { unsigned mode = i % 9; block[0] = mode < 8 ? (uint8_t)((block[0] & ~((2u << mode) - 1)) | 1u << mode) : 0; }
        if (kind == AKBC6H || kind == AKBC6HS) {
            static const unsigned codes[] = { 0, 1, 2, 6, 10, 14, 18, 22, 26, 30, 3, 7, 11, 15, 19, 31 };
            unsigned code = codes[i % 16];
            block[0] = code < 2 ? (uint8_t)((block[0] & ~3u) | code) : (uint8_t)((block[0] & ~31u) | code);
        }
    }
    return data;
}
static float halfToFloat(uint16_t bits) { __fp16 value; memcpy(&value, &bits, 2); return (float)value; }

// The largest difference between the GPU's texels (float4) and decoded ones, in
// 8-bit steps (unorm and snorm) or relative (BC6H).
static double difference(AKBCKind kind, const float *gpu, const uint8_t *decoded, size_t count) {
    double worst = 0;
    size_t texelBytes = AKBCTexelBytes(kind);
    for (size_t i = 0; i < count; i++)
        for (unsigned ch = 0; ch < 4; ch++) {
            double expected, actual = gpu[4 * i + ch];
            if (kind == AKBC6H || kind == AKBC6HS) {
                uint16_t bits; memcpy(&bits, decoded + i * 8 + 2 * ch, 2);
                expected = halfToFloat(bits);
                worst = fmax(worst, fabs(expected - actual) / fmax(1e-3, fabs(actual)));
                continue;
            }
            bool isSigned = kind == AKBC4S || kind == AKBC5S;
            if (ch >= texelBytes) expected = ch == 3 ? 1 : 0;
            else if (isSigned) expected = fmax(-1, (int8_t)decoded[i * texelBytes + ch] / 127.0);
            else expected = decoded[i * texelBytes + ch] / 255.0;
            worst = fmax(worst, fabs(expected - actual) * (isSigned ? 127 : 255));
        }
    return worst;
}

static const unsigned long formats[] = { 130, 132, 134, 140, 141, 142, 143, 150, 151, 152 };
static const char *names[] = { "BC1", "BC2", "BC3", "BC4", "BC4s", "BC5", "BC5s", "BC6Hs", "BC6Hu", "BC7" };

static void referenceDecoding(id<MTLDevice> device) {
    for (size_t f = 0; f < sizeof formats / sizeof *formats; f++) {
        AKBCKind kind = AKBCKindOfPixelFormat(formats[f]);
        const NSUInteger width = 64, height = 64, blockRow = width / 4 * AKBCBlockBytes(kind);
        NSData *blocks = randomBlocks(kind, (width / 4) * (height / 4));
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[f] width:width height:height mipmapped:NO];
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        assert(texture && texture.pixelFormat == formats[f] && !AKBCStoredPixelFormat(texture));
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:blocks.bytes bytesPerRow:blockRow];
        NSMutableData *decoded = [NSMutableData dataWithLength:width * height * AKBCTexelBytes(kind)];
        assert(AKBCDecodeRect(kind, blocks.bytes, blockRow, width, height, decoded.mutableBytes, width * AKBCTexelBytes(kind)));
        double worst = difference(kind, AKReadTexels(device, texture).bytes, decoded.bytes, width * height);
        // The GPU keeps BC3 alpha, BC4 and BC5 unrounded; 8-bit storage is within half a step.
        double allowed = (kind == AKBC4 || kind == AKBC4S || kind == AKBC5 || kind == AKBC5S || kind == AKBC3) ? 0.5 + 1e-3 : 1e-3;
        printf("  %-5s 256 random blocks against the GPU: largest difference %.3f%s\n", names[f], worst,
               kind == AKBC6H || kind == AKBC6HS ? " (relative)" : " (8-bit steps)");
        assert(worst <= allowed);
    }
}

// The texels the GPU reads from a converted texture equal the CPU decode of
// the blocks the guest uploaded.
static void expectContents(id<MTLDevice> device, id<MTLTexture> texture, AKBCKind kind, const uint8_t *blocks, size_t blockRow) {
    NSUInteger width = texture.width, height = texture.height;
    NSMutableData *decoded = [NSMutableData dataWithLength:width * height * AKBCTexelBytes(kind)];
    assert(AKBCDecodeRect(kind, blocks, blockRow, (uint32_t)width, (uint32_t)height, decoded.mutableBytes, width * AKBCTexelBytes(kind)));
    double worst = difference(kind, AKReadTexels(device, texture).bytes, decoded.bytes, width * height);
    if (worst > 0.5 + 1e-3) { fprintf(stderr, "converted texture differs by %f\n", worst); abort(); }
}
static id<MTLTexture> levelView(id<MTLTexture> texture, NSUInteger level, NSUInteger slice) {
    // A view in the BC format the guest knows; the fallback maps it.
    MTLTextureType type = texture.textureType == MTLTextureTypeCube || texture.textureType == MTLTextureType2DArray ? MTLTextureType2D : texture.textureType;
    id<MTLTexture> view = [texture newTextureViewWithPixelFormat:texture.pixelFormat textureType:type levels:NSMakeRange(level, 1) slices:NSMakeRange(slice, 1)];
    assert(view && view.pixelFormat == texture.pixelFormat && AKBCStoredPixelFormat(view) == AKBCStoredPixelFormat(texture));
    return view;
}
static void runBlit(id<MTLCommandQueue> queue, void (^encode)(id<MTLBlitCommandEncoder>), void (^beforeCommit)(void)) {
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    encode(blit);
    [blit endEncoding];
    if (beforeCommit) beforeCommit();
    [command commit];
    [command waitUntilCompleted];
    assert(command.status == MTLCommandBufferStatusCompleted);
}

static void fallback(id<MTLDevice> device) {
    id<MTLCommandQueue> queue = [device newCommandQueue];

    // Asked BC3, mipmapped: the guest sees BC3, the GPU stores RGBA8.
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC3_RGBA width:64 height:32 mipmapped:YES];
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    assert(texture && texture.pixelFormat == MTLPixelFormatBC3_RGBA && texture.mipmapLevelCount == 7);
    assert(AKBCStoredPixelFormat(texture) == MTLPixelFormatRGBA8Unorm && descriptor.pixelFormat == MTLPixelFormatBC3_RGBA);
    assert([texture class] == class_getSuperclass(object_getClass(texture)));   // the subclass stays hidden
    assert([texture conformsToProtocol:@protocol(MTLTexture)]);
    // replaceRegion: every level of the chain, the last ones smaller than a block.
    for (NSUInteger level = 0; level < texture.mipmapLevelCount; level++) {
        NSUInteger width = MAX(64u >> level, 1), height = MAX(32u >> level, 1);
        NSUInteger blocksWide = (width + 3) / 4, blocksHigh = (height + 3) / 4;
        NSData *blocks = randomBlocks(AKBC3, blocksWide * blocksHigh);
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:level withBytes:blocks.bytes bytesPerRow:blocksWide * 16];
        expectContents(device, levelView(texture, level, 0), AKBC3, blocks.bytes, blocksWide * 16);
    }
    printf("  replaceRegion: BC3 64x32, all 7 levels down to 1x1, read by the GPU through BC3 views\n");

    // Partial edge blocks: a 6x5 BC1 texture, the region given rounded up to whole
    // blocks (8x8), with padded rows; then a sub-region at a block offset.
    descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC1_RGBA width:6 height:5 mipmapped:NO];
    texture = [device newTextureWithDescriptor:descriptor];
    NSMutableData *blocks = randomBlocks(AKBC1, 6);   // 3 per row: 24 bytes, of which 16 are used
    [texture replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:blocks.bytes bytesPerRow:24];
    expectContents(device, texture, AKBC1, blocks.bytes, 24);
    NSData *corner = randomBlocks(AKBC1, 2);
    [texture replaceRegion:MTLRegionMake2D(4, 0, 2, 5) mipmapLevel:0 withBytes:corner.bytes bytesPerRow:8];
    memcpy((uint8_t *)blocks.mutableBytes + 8, corner.bytes, 8);
    memcpy((uint8_t *)blocks.mutableBytes + 24 + 8, (const uint8_t *)corner.bytes + 8, 8);
    expectContents(device, texture, AKBC1, blocks.bytes, 24);
    printf("  partial blocks: 6x5 BC1 from rounded-up and edge sub-regions, padded rows\n");

    // Array slices with the slice form; BC5 is stored as RG8.
    descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC5_RGUnorm width:16 height:8 mipmapped:NO];
    descriptor.textureType = MTLTextureType2DArray; descriptor.arrayLength = 3;
    texture = [device newTextureWithDescriptor:descriptor];
    assert(texture.pixelFormat == MTLPixelFormatBC5_RGUnorm && AKBCStoredPixelFormat(texture) == MTLPixelFormatRG8Unorm);
    for (NSUInteger slice = 0; slice < 3; slice++) {
        NSData *data = randomBlocks(AKBC5, 8);
        [texture replaceRegion:MTLRegionMake2D(0, 0, 16, 8) mipmapLevel:0 slice:slice withBytes:data.bytes bytesPerRow:64 bytesPerImage:128];
        expectContents(device, levelView(texture, 0, slice), AKBC5, data.bytes, 64);
    }
    printf("  array slices: BC5 2D array, three slices through replaceRegion:...slice:\n");

    // A 3D texture: depth images bytesPerImage apart, read back through the real
    // implementation (what the GPU stores).
    descriptor = [MTLTextureDescriptor new];
    descriptor.textureType = MTLTextureType3D; descriptor.pixelFormat = MTLPixelFormatBC4_RUnorm;
    descriptor.width = 8; descriptor.height = 8; descriptor.depth = 3;
    texture = [device newTextureWithDescriptor:descriptor];
    if (texture) {
        NSData *volume = randomBlocks(AKBC4, 4 * 3 + 4);   // 2x2 blocks per image, images 40 bytes apart
        [texture replaceRegion:MTLRegionMake3D(0, 0, 0, 8, 8, 3) mipmapLevel:0 slice:0 withBytes:volume.bytes bytesPerRow:16 bytesPerImage:40];
        uint8_t stored[8 * 8 * 3], expected[8 * 8];
        void (*realGet)(id, SEL, void *, NSUInteger, NSUInteger, MTLRegion, NSUInteger, NSUInteger) = (void *)class_getMethodImplementation(
            class_getSuperclass(object_getClass(texture)), @selector(getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice:));
        realGet(texture, @selector(getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice:), stored, 8, 64, MTLRegionMake3D(0, 0, 0, 8, 8, 3), 0, 0);
        for (unsigned z = 0; z < 3; z++) {
            AKBCDecodeRect(AKBC4, (const uint8_t *)volume.bytes + 40 * z, 16, 8, 8, expected, 8);
            assert(!memcmp(stored + 64 * z, expected, 64));
        }
        printf("  3D: BC4 8x8x3, depth images bytesPerImage apart\n");
    }

    // Blit from a buffer into a Private texture; the source is written after
    // encoding, before commit, so it must be decoded at commit.
    descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC7_RGBAUnorm width:18 height:11 mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    texture = [device newTextureWithDescriptor:descriptor];
    assert(texture.pixelFormat == MTLPixelFormatBC7_RGBAUnorm && texture.storageMode == MTLStorageModePrivate);
    NSData *bc7 = randomBlocks(AKBC7, 15);   // 18x11 is 5x3 blocks; rows of 80 bytes padded to 96
    id<MTLBuffer> source = [device newBufferWithLength:256 + 96 * 3 options:MTLResourceStorageModeShared];
    NSMutableData *padded = [NSMutableData dataWithLength:96 * 3];
    for (unsigned row = 0; row < 3; row++) memcpy((uint8_t *)padded.mutableBytes + 96 * row, (const uint8_t *)bc7.bytes + 80 * row, 80);
    runBlit(queue, ^(id<MTLBlitCommandEncoder> blit) {
        [blit copyFromBuffer:source sourceOffset:256 sourceBytesPerRow:96 sourceBytesPerImage:96 * 3 sourceSize:MTLSizeMake(20, 12, 1)
                   toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    }, ^{ memcpy((uint8_t *)source.contents + 256, padded.bytes, padded.length); });
    expectContents(device, texture, AKBC7, padded.bytes, 96);
    // The options form, into an edge sub-region given in whole blocks (4x8 where 2x7 remain),
    // on a command buffer that does not retain its resources.
    NSData *patch = randomBlocks(AKBC7, 2);
    id<MTLBuffer> small = [device newBufferWithBytes:patch.bytes length:patch.length options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> unretained = [queue commandBufferWithUnretainedReferences];
    id<MTLBlitCommandEncoder> blit = [unretained blitCommandEncoder];
    [blit copyFromBuffer:small sourceOffset:0 sourceBytesPerRow:16 sourceBytesPerImage:32 sourceSize:MTLSizeMake(4, 8, 1)
               toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(16, 4, 0) options:MTLBlitOptionNone];
    [blit endEncoding];
    [unretained commit];
    [unretained waitUntilCompleted];
    assert(unretained.status == MTLCommandBufferStatusCompleted);
    memcpy((uint8_t *)padded.mutableBytes + 96 * 1 + 64, patch.bytes, 16);
    memcpy((uint8_t *)padded.mutableBytes + 96 * 2 + 64, (const uint8_t *)patch.bytes + 16, 16);
    expectContents(device, texture, AKBC7, padded.bytes, 96);
    printf("  blit copyFromBuffer: BC7 18x11 into a Private texture, source written after encoding (decoded at commit), sizes rounded up to blocks, options form, unretained command buffer\n");

    // Texture to texture between converted BC1 textures: the size rounded up to
    // whole blocks at the edge is clipped to the mip.
    descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC1_RGBA width:6 height:5 mipmapped:NO];
    id<MTLTexture> from = [device newTextureWithDescriptor:descriptor], to = [device newTextureWithDescriptor:descriptor];
    NSData *bc1 = randomBlocks(AKBC1, 4);
    [from replaceRegion:MTLRegionMake2D(0, 0, 6, 5) mipmapLevel:0 withBytes:bc1.bytes bytesPerRow:16];
    runBlit(queue, ^(id<MTLBlitCommandEncoder> encoder) {
        [encoder copyFromTexture:from sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1)
                       toTexture:to destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    }, nil);
    expectContents(device, to, AKBC1, bc1.bytes, 16);
    id<MTLTexture> whole = [device newTextureWithDescriptor:descriptor];
    runBlit(queue, ^(id<MTLBlitCommandEncoder> encoder) { [encoder copyFromTexture:from toTexture:whole]; }, nil);
    expectContents(device, whole, AKBC1, bc1.bytes, 16);
    printf("  texture to texture: converted BC1 to BC1, region rounded up to blocks, and whole-texture copy\n");

    // A heap sized from the size the guest asks for holds the larger texture.
    descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC3_RGBA_sRGB width:128 height:128 mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    MTLTextureDescriptor *rgba = [descriptor copy]; rgba.pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
    MTLSizeAndAlign asked = [device heapTextureSizeAndAlignWithDescriptor:descriptor], stored = [device heapTextureSizeAndAlignWithDescriptor:rgba];
    assert(asked.size == stored.size && asked.size >= 128 * 128 * 4);
    MTLHeapDescriptor *heapDescriptor = [MTLHeapDescriptor new];
    heapDescriptor.size = asked.size; heapDescriptor.storageMode = MTLStorageModeShared;
    id<MTLHeap> heap = [device newHeapWithDescriptor:heapDescriptor];
    texture = [heap newTextureWithDescriptor:descriptor];
    assert(texture && texture.heap == heap && texture.pixelFormat == MTLPixelFormatBC3_RGBA_sRGB);
    assert(AKBCStoredPixelFormat(texture) == MTLPixelFormatRGBA8Unorm_sRGB);
    printf("  heap: size query in the stored format; BC3 sRGB heap texture stored as RGBA8 sRGB\n");

    // Reading back gets zeros, never decoded texels past the guest's buffer.
    descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC1_RGBA width:8 height:8 mipmapped:NO];
    texture = [device newTextureWithDescriptor:descriptor];
    [texture replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:randomBlocks(AKBC1, 4).bytes bytesPerRow:16];
    uint8_t *readBack = malloc(32);   // exactly 2x2 BC1 blocks; ASan catches any overrun
    memset(readBack, 0x5A, 32);
    [texture getBytes:readBack bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    for (unsigned i = 0; i < 32; i++) assert(!readBack[i]);
    free(readBack);
    id<MTLBuffer> target = [device newBufferWithLength:32 options:MTLResourceStorageModeShared];
    memset(target.contents, 0x5A, 32);
    runBlit(queue, ^(id<MTLBlitCommandEncoder> encoder) {
        [encoder copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1)
                        toBuffer:target destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:32];
    }, nil);
    assert(((uint8_t *)target.contents)[0] == 0x5A);
    printf("  read back: getBytes fills whole blocks with zeros; a copy to a buffer is dropped\n");

    // What is not BC is untouched; the guest is told BC is supported.
    texture = [device newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO]];
    assert(texture.pixelFormat == MTLPixelFormatRGBA8Unorm && !AKBCStoredPixelFormat(texture));
    assert(![NSStringFromClass(object_getClass(texture)) hasPrefix:@"AKBCTexture_"]);
    assert(device.supportsBCTextureCompression);
}

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { puts("BC textures: SKIP (no Metal device)"); return 0; }
    // Metal's own numbers for the formats BCDecode.h names.
    assert(AKPixelFormatR8Unorm == MTLPixelFormatR8Unorm && AKPixelFormatR8Snorm == MTLPixelFormatR8Snorm);
    assert(AKPixelFormatRG8Unorm == MTLPixelFormatRG8Unorm && AKPixelFormatRG8Snorm == MTLPixelFormatRG8Snorm);
    assert(AKPixelFormatRGBA8Unorm == MTLPixelFormatRGBA8Unorm && AKPixelFormatRGBA8Unorm_sRGB == MTLPixelFormatRGBA8Unorm_sRGB);
    assert(AKPixelFormatRGBA16Float == MTLPixelFormatRGBA16Float);
    assert(AKPixelFormatBC1_RGBA == MTLPixelFormatBC1_RGBA && AKPixelFormatBC1_RGBA_sRGB == MTLPixelFormatBC1_RGBA_sRGB);
    assert(AKPixelFormatBC2_RGBA == MTLPixelFormatBC2_RGBA && AKPixelFormatBC2_RGBA_sRGB == MTLPixelFormatBC2_RGBA_sRGB);
    assert(AKPixelFormatBC3_RGBA == MTLPixelFormatBC3_RGBA && AKPixelFormatBC3_RGBA_sRGB == MTLPixelFormatBC3_RGBA_sRGB);
    assert(AKPixelFormatBC4_RUnorm == MTLPixelFormatBC4_RUnorm && AKPixelFormatBC4_RSnorm == MTLPixelFormatBC4_RSnorm);
    assert(AKPixelFormatBC5_RGUnorm == MTLPixelFormatBC5_RGUnorm && AKPixelFormatBC5_RGSnorm == MTLPixelFormatBC5_RGSnorm);
    assert(AKPixelFormatBC6H_RGBFloat == MTLPixelFormatBC6H_RGBFloat && AKPixelFormatBC6H_RGBUfloat == MTLPixelFormatBC6H_RGBUfloat);
    assert(AKPixelFormatBC7_RGBAUnorm == MTLPixelFormatBC7_RGBAUnorm && AKPixelFormatBC7_RGBAUnorm_sRGB == MTLPixelFormatBC7_RGBAUnorm_sRGB);
    if (!device.supportsBCTextureCompression) { puts("BC textures: SKIP (this Mac's GPU has no BC to compare against)"); return 0; }

    const char *setting = getenv("TOLKARA_BC_FALLBACK");
    BOOL forced = setting && !strcmp(setting, "on");
    AKInstallBCTextureFallback(device);
    AKInstallBCTextureFallback(device);   // once only
    if (!forced) {
        // A device with BC keeps the native path: nothing is converted.
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC3_RGBA width:8 height:8 mipmapped:NO];
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        assert(texture.pixelFormat == MTLPixelFormatBC3_RGBA && !AKBCStoredPixelFormat(texture));
        assert(![NSStringFromClass(object_getClass(texture)) hasPrefix:@"AKBCTexture_"]);
        if (setting && !strcmp(setting, "off")) { puts("BC textures, TOLKARA_BC_FALLBACK=off: native BC textures, nothing installed: PASS"); return 0; }
        referenceDecoding(device);
        puts("BC textures, auto on a GPU with BC: native textures unchanged; CPU decoders match the GPU for BC1-BC7: PASS");
        return 0;
    }
    fallback(device);
    puts("BC textures, TOLKARA_BC_FALLBACK=on: guest sees BC formats; replaceRegion, slices, 3D, blit uploads, texture copies, views, heaps decoded or handled: PASS");
} return 0; }
