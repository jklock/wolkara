// BC texture fallback for GPUs that cannot sample BC formats.
//
// Every Mac GPU samples BC1-BC7, so macOS games create BC textures without
// asking. On iOS that is per device (-[MTLDevice supportsBCTextureCompression],
// iOS 16.4): A17 Pro, M-series and later GPUs have it; an A16 does not, and
// Metal aborts at the first BC texture descriptor. When the device lacks BC
// (or TOLKARA_BC_FALLBACK forces it), a texture asked for in a BC format is
// created in the uncompressed format that holds its decoded texels
// (BCDecode.h), and the guest's uploads are decoded on the CPU:
//
//   - -replaceRegion: (both forms), decoded immediately;
//   - blit copies from a buffer, decoded into a staging buffer when the command
//     buffer is committed (the latest moment the guest may still write the
//     source), and the staging copy is what the GPU executes;
//   - texture-to-texture copies between two converted textures, clipped to the
//     mip extent (a compressed copy may round up to whole blocks);
//   - texture views and heap textures (sizes are asked in the stored format).
//
// The guest keeps seeing the BC format it asked for: -pixelFormat answers it to
// callers outside the system's shared cache (the guest, our adapters), while
// Metal's own code still sees the stored format. Not covered, logged once:
// reading a converted texture back (-getBytes: fills zeros, copies to a buffer
// are dropped), copies between a converted texture and another format's
// (bit reinterpretation), sources the CPU cannot read (Private buffers),
// MTLIOCommandQueue loads and Metal 4 command encoders. On a device with BC
// support nothing here is installed. See docs/IPHONE.md for the memory cost.
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <stdatomic.h>
#import "AKSupport.h"
#import "BCDecode.h"

#define RETAINED __attribute__((ns_returns_retained))

static void logOnce(atomic_flag *flag, NSString *message) {
    if (!atomic_flag_test_and_set(flag)) AKLog(@"%@", message);
}

// --- Callers inside the shared cache are the system's own code ---------------

static uintptr_t cacheStart = UINTPTR_MAX, cacheEnd;
static void findSharedCache(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64 || !(header->flags & MH_DYLIB_IN_CACHE)) continue;
        const struct load_command *command = (const struct load_command *)(header + 1);
        for (uint32_t c = 0; c < header->ncmds; c++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
            if (command->cmd != LC_SEGMENT_64) continue;
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strcmp(segment->segname, SEG_TEXT)) continue;
            uintptr_t start = (uintptr_t)header, end = start + (uintptr_t)segment->vmsize;
            if (start < cacheStart) cacheStart = start;
            if (end > cacheEnd) cacheEnd = end;
        }
    }
}
static bool calledBySystem(void *returnAddress) {
    uintptr_t address = (uintptr_t)returnAddress & (((uintptr_t)1 << 47) - 1);   // no pointer-authentication bits
    return address >= cacheStart && address < cacheEnd;
}

// --- Which textures are converted --------------------------------------------

@interface AKBCTextureInfo : NSObject
@property (nonatomic) MTLPixelFormat requested;   // what the guest asked for and sees
@property (nonatomic) AKBCKind kind;
@end
@implementation AKBCTextureInfo @end

static char infoKey;
enum { MaxSubclasses = 32 };
static _Atomic(Class) subclasses[MaxSubclasses];
static atomic_uint subclassCount;
static atomic_flag engagedLog, readBackLog, reinterpretLog, unreadableLog, tooManyClassesLog;

static AKBCTextureInfo *infoOf(id texture) {
    if (!texture) return nil;
    Class cls = object_getClass(texture);
    unsigned count = atomic_load(&subclassCount);
    for (unsigned i = 0; i < count; i++)
        if (atomic_load(&subclasses[i]) == cls) return objc_getAssociatedObject(texture, &infoKey);
    return nil;
}
unsigned long AKBCStoredPixelFormat(id texture);   // for tests and diagnostics
unsigned long AKBCStoredPixelFormat(id texture) {
    AKBCTextureInfo *info = infoOf(texture);
    return info ? AKBCDecodedPixelFormat(info.requested) : 0;
}

// The real class's implementation of a selector we override in the subclass.
static IMP superIMP(id self, SEL selector) {
    return class_getMethodImplementation(class_getSuperclass(object_getClass(self)), selector);
}
// Our overrides call the real implementation; anything it sends back to the
// texture is the system's business and passes straight through.
static _Thread_local unsigned insideTexture;

static MTLPixelFormat texturePixelFormat(id self, SEL selector) {
    MTLPixelFormat (*real)(id, SEL) = (MTLPixelFormat (*)(id, SEL))superIMP(self, selector);
    if (insideTexture || calledBySystem(__builtin_return_address(0))) return real(self, selector);
    AKBCTextureInfo *info = objc_getAssociatedObject(self, &infoKey);
    return info ? info.requested : real(self, selector);
}
static Class textureClass(id self, SEL selector) {   // as KVO does: hide the subclass
    (void)selector;
    return class_getSuperclass(object_getClass(self));
}

typedef void (*ReplaceRegion)(id, SEL, MTLRegion, NSUInteger, NSUInteger, const void *, NSUInteger, NSUInteger);
static SEL replaceSlice(void) { return @selector(replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:); }

// Decodes `bytes` (blocks, bytesPerRow per row of blocks, bytesPerImage per
// depth image of a 3D texture) into the converted texture, in bands so the
// temporary stays small.
static void uploadDecoded(id texture, AKBCKind kind, MTLRegion region, NSUInteger level, NSUInteger slice,
                          const uint8_t *bytes, NSUInteger bytesPerRow, NSUInteger bytesPerImage) {
    id<MTLTexture> t = texture;
    insideTexture++;
    NSUInteger width = MAX(t.width >> level, 1), height = MAX(t.height >> level, 1);
    BOOL volume = t.textureType == MTLTextureType3D;
    NSUInteger depth = volume ? MAX(t.depth >> level, 1) : 1;
    insideTexture--;
    if (region.origin.x >= width || region.origin.y >= height || region.origin.z >= depth) return;
    NSUInteger w = MIN(region.size.width, width - region.origin.x);
    NSUInteger h = MIN(region.size.height, height - region.origin.y);
    NSUInteger d = MIN(MAX(region.size.depth, 1), depth - region.origin.z);
    if (!w || !h || !bytes) return;
    size_t texelBytes = AKBCTexelBytes(kind), rowBytes = w * texelBytes;
    NSUInteger bandBlocks = MAX((NSUInteger)1, (4u << 20) / (rowBytes * 4));
    NSUInteger bandRows = MIN(bandBlocks * 4, (h + 3) & ~(NSUInteger)3);
    uint8_t *band = malloc(rowBytes * bandRows);
    if (!band) return;
    ReplaceRegion real = (ReplaceRegion)superIMP(texture, replaceSlice());
    for (NSUInteger z = 0; z < d; z++) {
        const uint8_t *image = bytes + z * bytesPerImage;
        for (NSUInteger y = 0; y < h; y += bandRows) {
            NSUInteger rows = MIN(bandRows, h - y);
            if (!AKBCDecodeRect(kind, image + (y / 4) * bytesPerRow, bytesPerRow, (uint32_t)w, (uint32_t)rows, band, rowBytes)) continue;
            MTLRegion part = MTLRegionMake3D(region.origin.x, region.origin.y + y, region.origin.z + z, w, rows, 1);
            insideTexture++;
            real(texture, replaceSlice(), part, level, slice, band, rowBytes, volume ? rowBytes * rows : 0);
            insideTexture--;
        }
    }
    free(band);
}
static void textureReplaceSlice(id self, SEL selector, MTLRegion region, NSUInteger level, NSUInteger slice,
                                const void *bytes, NSUInteger bytesPerRow, NSUInteger bytesPerImage) {
    AKBCTextureInfo *info = insideTexture ? nil : objc_getAssociatedObject(self, &infoKey);
    if (!info) { ((ReplaceRegion)superIMP(self, selector))(self, selector, region, level, slice, bytes, bytesPerRow, bytesPerImage); return; }
    uploadDecoded(self, info.kind, region, level, slice, bytes, bytesPerRow, bytesPerImage);
}
static void textureReplace(id self, SEL selector, MTLRegion region, NSUInteger level, const void *bytes, NSUInteger bytesPerRow) {
    AKBCTextureInfo *info = insideTexture ? nil : objc_getAssociatedObject(self, &infoKey);
    if (!info) {
        ((void (*)(id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger))superIMP(self, selector))(self, selector, region, level, bytes, bytesPerRow);
        return;
    }
    // A 3D texture's depth images follow each other, a whole image of blocks apart.
    NSUInteger bytesPerImage = bytesPerRow * ((MIN(region.size.height, MAX(((id<MTLTexture>)self).height >> level, 1)) + 3) / 4);
    uploadDecoded(self, info.kind, region, level, 0, bytes, bytesPerRow, bytesPerImage);
}

// Reading back would need a BC encoder. Fill what the guest expects (whole
// blocks) with zeros instead of writing decoded texels past its buffer.
static void zeroBlocks(AKBCKind kind, MTLRegion region, void *bytes, NSUInteger bytesPerRow, NSUInteger bytesPerImage) {
    logOnce(&readBackLog, @"Metal BC fallback: the guest read back a converted BC texture; it gets zeros (no BC encoder)");
    if (!bytes) return;
    NSUInteger blocksWide = (region.size.width + 3) / 4, blocksHigh = (region.size.height + 3) / 4;
    for (NSUInteger z = 0; z < MAX(region.size.depth, 1); z++)
        for (NSUInteger y = 0; y < blocksHigh; y++)
            memset((uint8_t *)bytes + z * bytesPerImage + y * bytesPerRow, 0, blocksWide * AKBCBlockBytes(kind));
}
static void textureGetSlice(id self, SEL selector, void *bytes, NSUInteger bytesPerRow, NSUInteger bytesPerImage,
                            MTLRegion region, NSUInteger level, NSUInteger slice) {
    AKBCTextureInfo *info = insideTexture ? nil : objc_getAssociatedObject(self, &infoKey);
    if (!info) {
        ((void (*)(id, SEL, void *, NSUInteger, NSUInteger, MTLRegion, NSUInteger, NSUInteger))superIMP(self, selector))(self, selector, bytes, bytesPerRow, bytesPerImage, region, level, slice);
        return;
    }
    zeroBlocks(info.kind, region, bytes, bytesPerRow, bytesPerImage);
}
static void textureGet(id self, SEL selector, void *bytes, NSUInteger bytesPerRow, MTLRegion region, NSUInteger level) {
    AKBCTextureInfo *info = insideTexture ? nil : objc_getAssociatedObject(self, &infoKey);
    if (!info) {
        ((void (*)(id, SEL, void *, NSUInteger, MTLRegion, NSUInteger))superIMP(self, selector))(self, selector, bytes, bytesPerRow, region, level);
        return;
    }
    zeroBlocks(info.kind, region, bytes, bytesPerRow, bytesPerRow * ((region.size.height + 3) / 4));
}

static id converted(id texture, MTLPixelFormat requested);
typedef id (*ViewFormat)(id, SEL, MTLPixelFormat) RETAINED;
typedef id (*ViewRange)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange) RETAINED;
typedef id (*ViewSwizzle)(id, SEL, MTLPixelFormat, MTLTextureType, NSRange, NSRange, MTLTextureSwizzleChannels) RETAINED;
typedef id (*CreateWith)(id, SEL, id) RETAINED;
typedef id (*CreateAtOffset)(id, SEL, id, NSUInteger) RETAINED;

// Views: a BC format becomes its stored counterpart, and the view is converted too.
static id textureView(id self, SEL selector, MTLPixelFormat format) RETAINED;
static id textureView(id self, SEL selector, MTLPixelFormat format) {
    ViewFormat real = (ViewFormat)superIMP(self, selector);
    unsigned long stored = insideTexture ? 0 : AKBCDecodedPixelFormat(format);
    if (!stored) return real(self, selector, format);
    insideTexture++; id view = real(self, selector, (MTLPixelFormat)stored); insideTexture--;
    return converted(view, format);
}
static id textureViewRange(id self, SEL selector, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices) RETAINED;
static id textureViewRange(id self, SEL selector, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices) {
    ViewRange real = (ViewRange)superIMP(self, selector);
    unsigned long stored = insideTexture ? 0 : AKBCDecodedPixelFormat(format);
    if (!stored) return real(self, selector, format, type, levels, slices);
    insideTexture++; id view = real(self, selector, (MTLPixelFormat)stored, type, levels, slices); insideTexture--;
    return converted(view, format);
}
static id textureViewSwizzle(id self, SEL selector, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices,
                             MTLTextureSwizzleChannels swizzle) RETAINED;
static id textureViewSwizzle(id self, SEL selector, MTLPixelFormat format, MTLTextureType type, NSRange levels, NSRange slices,
                             MTLTextureSwizzleChannels swizzle) {
    ViewSwizzle real = (ViewSwizzle)superIMP(self, selector);
    unsigned long stored = insideTexture ? 0 : AKBCDecodedPixelFormat(format);
    if (!stored) return real(self, selector, format, type, levels, slices, swizzle);
    insideTexture++; id view = real(self, selector, (MTLPixelFormat)stored, type, levels, slices, swizzle); insideTexture--;
    return converted(view, format);
}
static id textureViewDescriptor(id self, SEL selector, id descriptor) RETAINED;
static id textureViewDescriptor(id self, SEL selector, id descriptor) {
    CreateWith real = (CreateWith)superIMP(self, selector);
#if !TARGET_OS_SIMULATOR   // the iOS Simulator SDK has no MTLTextureViewDescriptor
    if (@available(iOS 26.0, macOS 26.0, *)) {
        MTLTextureViewDescriptor *view = descriptor;
        unsigned long stored = insideTexture ? 0 : AKBCDecodedPixelFormat(view.pixelFormat);
        if (stored) {
            MTLTextureViewDescriptor *copy = [view copy]; copy.pixelFormat = (MTLPixelFormat)stored;
            insideTexture++; id result = real(self, selector, copy); insideTexture--;
            return converted(result, view.pixelFormat);
        }
    }
#endif
    return real(self, selector, descriptor);
}

static Class subclassFor(Class base) {
    unsigned count = atomic_load(&subclassCount);
    for (unsigned i = 0; i < count; i++) if (atomic_load(&subclasses[i]) == base) return base;   // already ours
    for (unsigned i = 0; i < count; i++) if (class_getSuperclass(atomic_load(&subclasses[i])) == base) return atomic_load(&subclasses[i]);
    @synchronized ([AKBCTextureInfo class]) {
        count = atomic_load(&subclassCount);
        for (unsigned i = 0; i < count; i++) if (class_getSuperclass(atomic_load(&subclasses[i])) == base) return atomic_load(&subclasses[i]);
        if (count == MaxSubclasses) { logOnce(&tooManyClassesLog, @"Metal BC fallback: too many texture classes"); return Nil; }
        NSString *name = [NSString stringWithFormat:@"AKBCTexture_%s", class_getName(base)];
        Class cls = objc_allocateClassPair(base, name.UTF8String, 0);
        if (!cls) return Nil;
        struct { SEL selector; IMP implementation; } methods[] = {
            { @selector(pixelFormat), (IMP)texturePixelFormat },
            { @selector(class), (IMP)textureClass },
            { @selector(replaceRegion:mipmapLevel:withBytes:bytesPerRow:), (IMP)textureReplace },
            { replaceSlice(), (IMP)textureReplaceSlice },
            { @selector(getBytes:bytesPerRow:fromRegion:mipmapLevel:), (IMP)textureGet },
            { @selector(getBytes:bytesPerRow:bytesPerImage:fromRegion:mipmapLevel:slice:), (IMP)textureGetSlice },
            { @selector(newTextureViewWithPixelFormat:), (IMP)textureView },
            { @selector(newTextureViewWithPixelFormat:textureType:levels:slices:), (IMP)textureViewRange },
            { @selector(newTextureViewWithPixelFormat:textureType:levels:slices:swizzle:), (IMP)textureViewSwizzle },
            { NSSelectorFromString(@"newTextureViewWithDescriptor:"), (IMP)textureViewDescriptor },
        };
        for (size_t i = 0; i < sizeof methods / sizeof *methods; i++) {
            Method method = class_getInstanceMethod(base, methods[i].selector);
            if (method) class_addMethod(cls, methods[i].selector, methods[i].implementation, method_getTypeEncoding(method));
        }
        objc_registerClassPair(cls);
        atomic_store(&subclasses[count], cls);
        atomic_store(&subclassCount, count + 1);
        return cls;
    }
}

static id converted(id texture, MTLPixelFormat requested) {
    if (!texture) return nil;
    Class cls = subclassFor(object_getClass(texture));
    if (!cls) return texture;
    AKBCTextureInfo *info = [AKBCTextureInfo new];
    info.requested = requested; info.kind = AKBCKindOfPixelFormat(requested);
    objc_setAssociatedObject(texture, &infoKey, info, OBJC_ASSOCIATION_RETAIN);
    object_setClass(texture, cls);
    if (!atomic_flag_test_and_set(&engagedLog)) {
        id<MTLTexture> t = texture;
        AKLog(@"Metal BC fallback engaged: BC format %lu (%lux%lu) stored as uncompressed format %lu; uploads are decoded on the CPU",
              (unsigned long)requested, (unsigned long)t.width, (unsigned long)t.height, AKBCDecodedPixelFormat(requested));
    }
    return texture;
}

// --- Hooks on classes found at run time ----------------------------------------

// The implementation each hooked class had before us, so classes whose methods
// we replace (devices, heaps, command buffers, blit encoders) chain correctly.
typedef struct { Class cls; SEL selector; IMP original; } Hook;
enum { MaxHooks = 96 };
static Hook hooks[MaxHooks];
static atomic_uint hookCount;
static IMP original(id self, SEL selector) {
    unsigned count = atomic_load(&hookCount);
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls))
        for (unsigned i = 0; i < count; i++)
            if (hooks[i].cls == cls && hooks[i].selector == selector) return hooks[i].original;
    return NULL;
}
static void hook(Class cls, SEL selector, IMP replacement) {
    @synchronized ([AKBCTextureInfo class]) {
        unsigned count = atomic_load(&hookCount);
        for (unsigned i = 0; i < count; i++) if (hooks[i].cls == cls && hooks[i].selector == selector) return;
        Method method = class_getInstanceMethod(cls, selector);
        // A subclass of a class already hooked inherits our replacement: keep it,
        // or its "original" would be ourselves.
        if (!method || count == MaxHooks || method_getImplementation(method) == replacement) return;
        hooks[count] = (Hook){ cls, selector, method_getImplementation(method) };
        atomic_store(&hookCount, count + 1);
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    }
}

static MTLTextureDescriptor *storedDescriptor(MTLTextureDescriptor *descriptor) {
    unsigned long stored = AKBCDecodedPixelFormat(descriptor.pixelFormat);
    if (!stored) return nil;
    MTLTextureDescriptor *copy = [descriptor copy];
    copy.pixelFormat = (MTLPixelFormat)stored;
    return copy;
}
static id newTexture(id owner, SEL selector, MTLTextureDescriptor *descriptor) RETAINED;
static id newTexture(id owner, SEL selector, MTLTextureDescriptor *descriptor) {
    CreateWith real = (CreateWith)original(owner, selector);
    MTLTextureDescriptor *stored = storedDescriptor(descriptor);
    if (!stored) return real(owner, selector, descriptor);
    return converted(real(owner, selector, stored), descriptor.pixelFormat);
}
static id newTextureAtOffset(id heap, SEL selector, MTLTextureDescriptor *descriptor, NSUInteger offset) RETAINED;
static id newTextureAtOffset(id heap, SEL selector, MTLTextureDescriptor *descriptor, NSUInteger offset) {
    CreateAtOffset real = (CreateAtOffset)original(heap, selector);
    MTLTextureDescriptor *stored = storedDescriptor(descriptor);
    if (!stored) return real(heap, selector, descriptor, offset);
    return converted(real(heap, selector, stored, offset), descriptor.pixelFormat);
}
static MTLSizeAndAlign heapTextureSize(id device, SEL selector, MTLTextureDescriptor *descriptor) {
    MTLSizeAndAlign (*real)(id, SEL, MTLTextureDescriptor *) = (MTLSizeAndAlign (*)(id, SEL, MTLTextureDescriptor *))original(device, selector);
    return real(device, selector, storedDescriptor(descriptor) ?: descriptor);
}
static void hookHeapClass(Class cls) {
    hook(cls, @selector(newTextureWithDescriptor:), (IMP)newTexture);
    hook(cls, @selector(newTextureWithDescriptor:offset:), (IMP)newTextureAtOffset);
}
static id newHeap(id device, SEL selector, MTLHeapDescriptor *descriptor) RETAINED;
static id newHeap(id device, SEL selector, MTLHeapDescriptor *descriptor) {
    id heap = ((CreateWith)original(device, selector))(device, selector, descriptor);
    if (heap) hookHeapClass(object_getClass(heap));
    return heap;
}
// The guest was written for Macs, where this is always YES; Metal itself still
// gets the device's answer.
static BOOL supportsBC(id device, SEL selector) {
    if (!calledBySystem(__builtin_return_address(0))) return YES;
    return ((BOOL (*)(id, SEL))original(device, selector))(device, selector);
}

// Blit uploads: decoded when the command buffer is committed.
@interface AKBCUpload : NSObject {
@public
    id<MTLBuffer> source, staging;
    NSUInteger offset, bytesPerRow, bytesPerImage;
    AKBCKind kind;
    uint32_t width, height, depth;
}
- (void)decode;
@end
@implementation AKBCUpload
- (void)decode {
    size_t blockBytes = AKBCBlockBytes(kind), texelBytes = AKBCTexelBytes(kind);
    size_t needed = offset + (depth - 1) * (size_t)bytesPerImage + ((height + 3) / 4 - 1) * (size_t)bytesPerRow + (width + 3) / 4 * blockBytes;
    const uint8_t *bytes = source.contents;
    if (!bytes || needed > source.length) {
        logOnce(&unreadableLog, @"Metal BC fallback: a blit source the CPU cannot read (Private storage or out of range); the texture region stays empty");
        return;
    }
    uint8_t *texels = staging.contents;
    size_t image = (size_t)width * texelBytes * height;
    for (uint32_t z = 0; z < depth; z++)
        AKBCDecodeRect(kind, bytes + offset + z * bytesPerImage, bytesPerRow, width, height, texels + z * image, width * texelBytes);
}
@end

static char uploadsKey, ownerKey;
@interface AKBCOwner : NSObject
@property (nonatomic, weak) id commandBuffer;
@end
@implementation AKBCOwner @end

static void hookBlitEncoderClass(Class cls);
static id blitEncoder(id commandBuffer, SEL selector) {
    id encoder = ((id (*)(id, SEL))original(commandBuffer, selector))(commandBuffer, selector);
    if (encoder) {
        hookBlitEncoderClass(object_getClass(encoder));
        AKBCOwner *owner = [AKBCOwner new]; owner.commandBuffer = commandBuffer;
        objc_setAssociatedObject(encoder, &ownerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return encoder;
}
static id blitEncoderWithDescriptor(id commandBuffer, SEL selector, id descriptor) {
    id encoder = ((id (*)(id, SEL, id))original(commandBuffer, selector))(commandBuffer, selector, descriptor);
    if (encoder) {
        hookBlitEncoderClass(object_getClass(encoder));
        AKBCOwner *owner = [AKBCOwner new]; owner.commandBuffer = commandBuffer;
        objc_setAssociatedObject(encoder, &ownerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return encoder;
}
static void commitCommandBuffer(id commandBuffer, SEL selector) {
    NSMutableArray<AKBCUpload *> *uploads = objc_getAssociatedObject(commandBuffer, &uploadsKey);
    if (uploads) {
        objc_setAssociatedObject(commandBuffer, &uploadsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSArray *pending;
        @synchronized (uploads) { pending = [uploads copy]; }
        for (AKBCUpload *upload in pending) [upload decode];
        // Keep the staging buffers until the GPU is done, also for a command
        // buffer that does not retain its resources.
        [(id<MTLCommandBuffer>)commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> done) { (void)done; (void)pending; }];
    }
    ((void (*)(id, SEL))original(commandBuffer, selector))(commandBuffer, selector);
}

// Blit copy from a buffer into a converted texture: the copy the GPU runs reads
// a staging buffer of decoded texels instead.
static bool stageUpload(id encoder, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger bytesPerRow, NSUInteger bytesPerImage,
                        MTLSize *size, id<MTLTexture> texture, NSUInteger level, MTLOrigin origin, AKBCTextureInfo *info,
                        id<MTLBuffer> *staging, NSUInteger *stagingRow, NSUInteger *stagingImage) {
    insideTexture++;
    NSUInteger width = MAX(texture.width >> level, 1), height = MAX(texture.height >> level, 1);
    NSUInteger depth = texture.textureType == MTLTextureType3D ? MAX(texture.depth >> level, 1) : 1;
    insideTexture--;
    if (origin.x >= width || origin.y >= height || origin.z >= depth) return false;
    NSUInteger w = MIN(size->width, width - origin.x), h = MIN(size->height, height - origin.y);
    NSUInteger d = MIN(MAX(size->depth, 1), depth - origin.z);
    if (!w || !h) return false;
    size_t texelBytes = AKBCTexelBytes(info.kind);
    AKBCUpload *upload = [AKBCUpload new];
    upload->source = buffer; upload->offset = offset; upload->bytesPerRow = bytesPerRow;
    upload->bytesPerImage = bytesPerImage; upload->kind = info.kind;
    upload->width = (uint32_t)w; upload->height = (uint32_t)h; upload->depth = (uint32_t)d;
    upload->staging = [((id<MTLCommandEncoder>)encoder).device newBufferWithLength:w * texelBytes * h * d options:MTLResourceStorageModeShared];
    if (!upload->staging) return false;
    *staging = upload->staging; *stagingRow = w * texelBytes; *stagingImage = w * texelBytes * h;
    *size = MTLSizeMake(w, h, d);
    id commandBuffer = ((AKBCOwner *)objc_getAssociatedObject(encoder, &ownerKey)).commandBuffer;
    if (!commandBuffer) { [upload decode]; return true; }   // no commit to wait for: decode now
    NSMutableArray *uploads;
    @synchronized (commandBuffer) {
        uploads = objc_getAssociatedObject(commandBuffer, &uploadsKey);
        if (!uploads) { uploads = [NSMutableArray new]; objc_setAssociatedObject(commandBuffer, &uploadsKey, uploads, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    }
    @synchronized (uploads) { [uploads addObject:upload]; }
    return true;
}
typedef void (*BufferToTexture)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin);
static void copyBufferToTexture(id encoder, SEL selector, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger bytesPerRow,
                                NSUInteger bytesPerImage, MTLSize size, id<MTLTexture> texture, NSUInteger slice, NSUInteger level, MTLOrigin origin) {
    BufferToTexture real = (BufferToTexture)original(encoder, selector);
    AKBCTextureInfo *info = infoOf(texture);
    if (!info) { real(encoder, selector, buffer, offset, bytesPerRow, bytesPerImage, size, texture, slice, level, origin); return; }
    id<MTLBuffer> staging; NSUInteger row, image;
    if (stageUpload(encoder, buffer, offset, bytesPerRow, bytesPerImage, &size, texture, level, origin, info, &staging, &row, &image))
        real(encoder, selector, staging, 0, row, image, size, texture, slice, level, origin);
}
typedef void (*BufferToTextureOptions)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin, MTLBlitOption);
static void copyBufferToTextureOptions(id encoder, SEL selector, id<MTLBuffer> buffer, NSUInteger offset, NSUInteger bytesPerRow,
                                       NSUInteger bytesPerImage, MTLSize size, id<MTLTexture> texture, NSUInteger slice, NSUInteger level,
                                       MTLOrigin origin, MTLBlitOption options) {
    BufferToTextureOptions real = (BufferToTextureOptions)original(encoder, selector);
    AKBCTextureInfo *info = infoOf(texture);
    if (!info) { real(encoder, selector, buffer, offset, bytesPerRow, bytesPerImage, size, texture, slice, level, origin, options); return; }
    id<MTLBuffer> staging; NSUInteger row, image;
    if (stageUpload(encoder, buffer, offset, bytesPerRow, bytesPerImage, &size, texture, level, origin, info, &staging, &row, &image))
        real(encoder, selector, staging, 0, row, image, size, texture, slice, level, origin, options);
}

// Texture to texture: both converted to the same texel size, or neither.
static bool reinterpreted(AKBCTextureInfo *source, AKBCTextureInfo *destination) {
    if (!source && !destination) return false;
    if (source && destination && AKBCTexelBytes(source.kind) == AKBCTexelBytes(destination.kind)) return false;
    logOnce(&reinterpretLog, @"Metal BC fallback: a copy between a converted BC texture and another format was dropped");
    return true;
}
typedef void (*TextureRegionCopy)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin);
static void copyTextureRegion(id encoder, SEL selector, id<MTLTexture> source, NSUInteger sourceSlice, NSUInteger sourceLevel,
                              MTLOrigin sourceOrigin, MTLSize size, id<MTLTexture> destination, NSUInteger destinationSlice,
                              NSUInteger destinationLevel, MTLOrigin destinationOrigin) {
    TextureRegionCopy real = (TextureRegionCopy)original(encoder, selector);
    AKBCTextureInfo *from = infoOf(source), *to = infoOf(destination);
    if (from || to) {
        if (reinterpreted(from, to)) return;
        // Whole blocks may overhang a mip edge; uncompressed copies may not.
        insideTexture++;
        NSUInteger sw = MAX(source.width >> sourceLevel, 1), sh = MAX(source.height >> sourceLevel, 1);
        NSUInteger dw = MAX(destination.width >> destinationLevel, 1), dh = MAX(destination.height >> destinationLevel, 1);
        insideTexture--;
        if (sourceOrigin.x >= sw || sourceOrigin.y >= sh || destinationOrigin.x >= dw || destinationOrigin.y >= dh) return;
        size.width = MIN(size.width, MIN(sw - sourceOrigin.x, dw - destinationOrigin.x));
        size.height = MIN(size.height, MIN(sh - sourceOrigin.y, dh - destinationOrigin.y));
    }
    real(encoder, selector, source, sourceSlice, sourceLevel, sourceOrigin, size, destination, destinationSlice, destinationLevel, destinationOrigin);
}
static void copyTextureLevels(id encoder, SEL selector, id source, NSUInteger sourceSlice, NSUInteger sourceLevel, id destination,
                              NSUInteger destinationSlice, NSUInteger destinationLevel, NSUInteger sliceCount, NSUInteger levelCount) {
    if (reinterpreted(infoOf(source), infoOf(destination))) return;
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger, id, NSUInteger, NSUInteger, NSUInteger, NSUInteger))original(encoder, selector))
        (encoder, selector, source, sourceSlice, sourceLevel, destination, destinationSlice, destinationLevel, sliceCount, levelCount);
}
static void copyTexture(id encoder, SEL selector, id source, id destination) {
    if (reinterpreted(infoOf(source), infoOf(destination))) return;
    ((void (*)(id, SEL, id, id))original(encoder, selector))(encoder, selector, source, destination);
}
static void readBackDropped(void) {
    logOnce(&readBackLog, @"Metal BC fallback: a copy from a converted BC texture to a buffer was dropped (no BC encoder)");
}
static void copyTextureToBuffer(id encoder, SEL selector, id source, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size,
                                id buffer, NSUInteger offset, NSUInteger bytesPerRow, NSUInteger bytesPerImage) {
    if (infoOf(source)) { readBackDropped(); return; }
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, NSUInteger))original(encoder, selector))
        (encoder, selector, source, slice, level, origin, size, buffer, offset, bytesPerRow, bytesPerImage);
}
static void copyTextureToBufferOptions(id encoder, SEL selector, id source, NSUInteger slice, NSUInteger level, MTLOrigin origin, MTLSize size,
                                       id buffer, NSUInteger offset, NSUInteger bytesPerRow, NSUInteger bytesPerImage, MTLBlitOption options) {
    if (infoOf(source)) { readBackDropped(); return; }
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, NSUInteger, MTLBlitOption))original(encoder, selector))
        (encoder, selector, source, slice, level, origin, size, buffer, offset, bytesPerRow, bytesPerImage, options);
}

static void hookBlitEncoderClass(Class cls) {
    hook(cls, @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:), (IMP)copyBufferToTexture);
    hook(cls, @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:options:), (IMP)copyBufferToTextureOptions);
    hook(cls, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:), (IMP)copyTextureRegion);
    hook(cls, @selector(copyFromTexture:sourceSlice:sourceLevel:toTexture:destinationSlice:destinationLevel:sliceCount:levelCount:), (IMP)copyTextureLevels);
    hook(cls, @selector(copyFromTexture:toTexture:), (IMP)copyTexture);
    hook(cls, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:), (IMP)copyTextureToBuffer);
    hook(cls, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:options:), (IMP)copyTextureToBufferOptions);
}
static void hookCommandBufferClass(Class cls) {
    hook(cls, @selector(blitCommandEncoder), (IMP)blitEncoder);
    hook(cls, @selector(blitCommandEncoderWithDescriptor:), (IMP)blitEncoderWithDescriptor);
    hook(cls, @selector(commit), (IMP)commitCommandBuffer);
}

// --- Switch ----------------------------------------------------------------------

// TOLKARA_BC_FALLBACK: unset or "auto" engages only on a device without BC;
// "on" (or "1", "force") engages on any device, for testing on one with BC;
// "off" (or "0") never engages.
typedef enum { AKBCSettingAuto, AKBCSettingOn, AKBCSettingOff } AKBCSetting;
static AKBCSetting fallbackSetting(void) {
    const char *value = getenv("TOLKARA_BC_FALLBACK");
    if (!value || !*value || !strcasecmp(value, "auto")) return AKBCSettingAuto;
    if (!strcmp(value, "1") || !strcasecmp(value, "on") || !strcasecmp(value, "force") || !strcasecmp(value, "yes")) return AKBCSettingOn;
    if (!strcmp(value, "0") || !strcasecmp(value, "off") || !strcasecmp(value, "no")) return AKBCSettingOff;
    AKLog(@"Metal BC fallback: unknown TOLKARA_BC_FALLBACK=%s, using auto", value);
    return AKBCSettingAuto;
}
static BOOL deviceSamplesBC(id<MTLDevice> device) {
    if (@available(iOS 16.4, macOS 11.0, *)) return device.supportsBCTextureCompression;
    return NO;   // before iOS 16.4 no iOS GPU sampled BC
}

void AKInstallBCTextureFallback(id<MTLDevice> device);
void AKInstallBCTextureFallback(id<MTLDevice> device) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!device) return;
        AKBCSetting setting = fallbackSetting();
        BOOL native = deviceSamplesBC(device);
        if (setting == AKBCSettingOff || (setting == AKBCSettingAuto && native)) {
            if (!native) AKLog(@"Metal BC fallback: off (TOLKARA_BC_FALLBACK=off) although %@ cannot sample BC textures", device.name);
            return;
        }
        findSharedCache();
        AKLog(@"Metal BC fallback on: %@ %@; BC textures are stored uncompressed and decoded on the CPU",
              device.name, native ? @"samples BC, forced by TOLKARA_BC_FALLBACK" : @"cannot sample BC textures");
        Class deviceClass = object_getClass(device);
        hook(deviceClass, @selector(newTextureWithDescriptor:), (IMP)newTexture);
        hook(deviceClass, @selector(heapTextureSizeAndAlignWithDescriptor:), (IMP)heapTextureSize);
        hook(deviceClass, @selector(newHeapWithDescriptor:), (IMP)newHeap);
        hook(deviceClass, @selector(supportsBCTextureCompression), (IMP)supportsBC);
        // Command buffers and blit encoders: their classes, from real ones.
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> retaining = [queue commandBuffer], unretaining = [queue commandBufferWithUnretainedReferences];
        for (id<MTLCommandBuffer> commandBuffer in @[(id)retaining ?: NSNull.null, (id)unretaining ?: NSNull.null]) {
            if ((id)commandBuffer == NSNull.null) continue;
            hookCommandBufferClass(object_getClass(commandBuffer));
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            [blit endEncoding];
        }
    });
}
