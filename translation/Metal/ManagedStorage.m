// Experimental and opt-in (launch argument --metal-managed-storage): resources
// the guest asks for in macOS's Managed storage mode are created Shared, from
// the device or from a heap, and buffers that lack didModifyRange: get an empty
// one (Shared memory needs no synchronization). Off by default: it replaces
// methods of the device class for the whole process, and no device run has yet
// shown that iPadOS rejects Managed requests. Not covered yet: the blit
// encoder's synchronizeResource: and synchronizeTexture:slice:level:,
// placement-heap creation with an offset, and heaps of more than one class.
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import "AKSupport.h"
#import "StorageModes.h"

#define RETAINED __attribute__((ns_returns_retained))
typedef id (*DescriptorCreator)(id,SEL,id) RETAINED;
typedef id (*LengthCreator)(id,SEL,NSUInteger,MTLResourceOptions) RETAINED;
typedef id (*BytesCreator)(id,SEL,const void *,NSUInteger,MTLResourceOptions) RETAINED;
typedef id (*NoCopyCreator)(id,SEL,void *,NSUInteger,MTLResourceOptions,id) RETAINED;
static DescriptorCreator deviceHeap, deviceTexture, heapTexture;
static LengthCreator deviceBuffer, heapBuffer;
static BytesCreator deviceBytes;
static NoCopyCreator deviceNoCopy;

static MTLResourceOptions shared(MTLResourceOptions options) { return (MTLResourceOptions)AKTranslatedResourceOptions(options); }
static void modifiedRange(id self, SEL selector, NSRange range) { (void)self; (void)selector; (void)range; }
static void allowModifiedRange(id buffer) {
    if (buffer && ![buffer respondsToSelector:@selector(didModifyRange:)])
        class_addMethod(object_getClass(buffer),@selector(didModifyRange:),(IMP)modifiedRange,"v@:{_NSRange=QQ}");
}
static void replace(Class cls, SEL selector, IMP replacement, void **original) {
    Method method=class_getInstanceMethod(cls,selector);
    if (!method) return;
    *original=(void *)method_getImplementation(method);
    class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));
}
static MTLTextureDescriptor *sharedTexture(MTLTextureDescriptor *descriptor) {
    MTLStorageMode mode=(MTLStorageMode)AKTranslatedStorageMode(descriptor.storageMode);
    if (mode==descriptor.storageMode) return descriptor;
    MTLTextureDescriptor *copy=[descriptor copy]; copy.storageMode=mode;
    return copy;
}

static id createHeapBuffer(id heap, SEL selector, NSUInteger length, MTLResourceOptions options) RETAINED;
static id createHeapBuffer(id heap, SEL selector, NSUInteger length, MTLResourceOptions options) {
    id buffer=heapBuffer(heap,selector,length,shared(options));
    allowModifiedRange(buffer);
    return buffer;
}
static id createHeapTexture(id heap, SEL selector, MTLTextureDescriptor *descriptor) RETAINED;
static id createHeapTexture(id heap, SEL selector, MTLTextureDescriptor *descriptor) {
    return heapTexture(heap,selector,sharedTexture(descriptor));
}
static id createDeviceHeap(id device, SEL selector, MTLHeapDescriptor *descriptor) RETAINED;
static id createDeviceHeap(id device, SEL selector, MTLHeapDescriptor *descriptor) {
    MTLStorageMode mode=(MTLStorageMode)AKTranslatedStorageMode(descriptor.storageMode);
    if (mode!=descriptor.storageMode) { descriptor=[descriptor copy]; descriptor.storageMode=mode; }
    id heap=deviceHeap(device,selector,descriptor);
    // A heap's resources must match its storage mode: translate those requests too.
    static dispatch_once_t once;
    if (heap) dispatch_once(&once,^{
        replace(object_getClass(heap),@selector(newBufferWithLength:options:),(IMP)createHeapBuffer,(void **)&heapBuffer);
        replace(object_getClass(heap),@selector(newTextureWithDescriptor:),(IMP)createHeapTexture,(void **)&heapTexture);
    });
    return heap;
}
static id createDeviceTexture(id device, SEL selector, MTLTextureDescriptor *descriptor) RETAINED;
static id createDeviceTexture(id device, SEL selector, MTLTextureDescriptor *descriptor) {
    return deviceTexture(device,selector,sharedTexture(descriptor));
}
static id createDeviceBuffer(id device, SEL selector, NSUInteger length, MTLResourceOptions options) RETAINED;
static id createDeviceBuffer(id device, SEL selector, NSUInteger length, MTLResourceOptions options) {
    id buffer=deviceBuffer(device,selector,length,shared(options));
    allowModifiedRange(buffer);
    return buffer;
}
static id createDeviceBytes(id device, SEL selector, const void *bytes, NSUInteger length, MTLResourceOptions options) RETAINED;
static id createDeviceBytes(id device, SEL selector, const void *bytes, NSUInteger length, MTLResourceOptions options) {
    id buffer=deviceBytes(device,selector,bytes,length,shared(options));
    allowModifiedRange(buffer);
    return buffer;
}
static id createDeviceNoCopy(id device, SEL selector, void *bytes, NSUInteger length, MTLResourceOptions options, id deallocator) RETAINED;
static id createDeviceNoCopy(id device, SEL selector, void *bytes, NSUInteger length, MTLResourceOptions options, id deallocator) {
    id buffer=deviceNoCopy(device,selector,bytes,length,shared(options),deallocator);
    allowModifiedRange(buffer);
    return buffer;
}

void AKInstallManagedStorage(Class device) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        if (![NSProcessInfo.processInfo.arguments containsObject:@"--metal-managed-storage"]) return;
        AKLog(@"Metal: Managed storage requests become Shared (--metal-managed-storage, experimental)");
        replace(device,@selector(newHeapWithDescriptor:),(IMP)createDeviceHeap,(void **)&deviceHeap);
        replace(device,@selector(newTextureWithDescriptor:),(IMP)createDeviceTexture,(void **)&deviceTexture);
        replace(device,@selector(newBufferWithLength:options:),(IMP)createDeviceBuffer,(void **)&deviceBuffer);
        replace(device,@selector(newBufferWithBytes:length:options:),(IMP)createDeviceBytes,(void **)&deviceBytes);
        replace(device,@selector(newBufferWithBytesNoCopy:length:options:deallocator:),(IMP)createDeviceNoCopy,(void **)&deviceNoCopy);
    });
}
