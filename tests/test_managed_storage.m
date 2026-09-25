// translation/Metal/ManagedStorage.m on the Mac's own Metal device, where
// Managed storage is valid, so what the hooks change is visible. Run with
// --metal-managed-storage (hooks installed: Managed requests become Shared) and
// without it (hooks off: requests unchanged).
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void AKInstallManagedStorage(Class device);

int main(void) { @autoreleasepool {
    BOOL enabled = [NSProcessInfo.processInfo.arguments containsObject:@"--metal-managed-storage"];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { puts("Managed storage hooks: SKIP (no Metal device)"); return 0; }
    AKInstallManagedStorage(object_getClass(device));
    AKInstallManagedStorage(object_getClass(device));   // once only
    const MTLStorageMode managed = enabled ? MTLStorageModeShared : MTLStorageModeManaged;
    const MTLResourceOptions options = MTLResourceStorageModeManaged | MTLResourceCPUCacheModeWriteCombined;

    id<MTLBuffer> buffer = [device newBufferWithLength:256 options:options];
    assert(buffer.storageMode == managed && buffer.cpuCacheMode == MTLCPUCacheModeWriteCombined);
    [buffer didModifyRange:NSMakeRange(0, 16)];
    char bytes[64]; memset(bytes, 7, sizeof bytes);
    id<MTLBuffer> copied = [device newBufferWithBytes:bytes length:sizeof bytes options:options];
    assert(copied.storageMode == managed && !memcmp(copied.contents, bytes, sizeof bytes));
    size_t page = (size_t)getpagesize();
    void *memory = NULL;
    int failed = posix_memalign(&memory, page, page);
    assert(!failed && memory);
    @autoreleasepool {
        id<MTLBuffer> wrapped = [device newBufferWithBytesNoCopy:memory length:page options:options
                                                     deallocator:^(void *pointer, NSUInteger length) { (void)length; free(pointer); }];
        assert(wrapped.storageMode == managed && wrapped.contents == memory);
    }
    // Other modes are left alone.
    id<MTLBuffer> kept = [device newBufferWithLength:256 options:MTLResourceStorageModePrivate];
    assert(kept.storageMode == MTLStorageModePrivate);

    MTLTextureDescriptor *texture = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                       width:16 height:16 mipmapped:NO];
    texture.storageMode = MTLStorageModeManaged;
    assert([device newTextureWithDescriptor:texture].storageMode == managed);
    assert(texture.storageMode == MTLStorageModeManaged);   // the caller's descriptor is not changed

    if (enabled) {
        // A Managed heap becomes Shared, and so do the Managed requests made of it.
        MTLHeapDescriptor *heapDescriptor = [MTLHeapDescriptor new];
        heapDescriptor.size = 1 << 20;
        heapDescriptor.storageMode = MTLStorageModeManaged;
        id<MTLHeap> heap = [device newHeapWithDescriptor:heapDescriptor];
        assert(heap && heap.storageMode == MTLStorageModeShared);
        assert(heapDescriptor.storageMode == MTLStorageModeManaged);
        id<MTLBuffer> fromHeap = [heap newBufferWithLength:256 options:MTLResourceStorageModeManaged];
        assert(fromHeap && fromHeap.storageMode == MTLStorageModeShared && fromHeap.contents);
        [fromHeap didModifyRange:NSMakeRange(0, 16)];
        id<MTLTexture> heapTexture = [heap newTextureWithDescriptor:texture];
        assert(heapTexture && heapTexture.storageMode == MTLStorageModeShared && heapTexture.heap == heap);
    }
    printf("Managed storage hooks %s: PASS\n", enabled
           ? "on: device and heap buffers and textures, bytes and no-copy buffers become Shared"
           : "off: Managed requests unchanged");
} return 0; }
