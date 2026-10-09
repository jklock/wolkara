// IOKit registry queries, answered for the GPU as a Mac with Apple silicon
// answers them.
//
// Games identify the GPU through the I/O Registry: they find the accelerator
// (an IOAccelerator) and read its "vendor-id". On a Mac with Apple silicon that
// entry carries Apple's 0x106b. Every other query, and every other entry, goes
// to the iPad's own IOKit unchanged.
//
// --trace-iokit (launch argument) logs each distinct registry query the
// application makes, with the entry's class and a short form of the answer;
// values of identifying keys are never logged. --native-gpu-identity turns the
// Mac answers off, to compare with the iPad's own.
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import "AKSupport.h"
#import "GPUIdentity.h"
#import <Metal/Metal.h>
#include <dlfcn.h>

#define IOKIT_PATH "/System/Library/Frameworks/IOKit.framework/IOKit"

static void *realFunction(const char *name, void *wrapper) {
    void *function = dlsym(RTLD_NEXT, name);
    if (!function || function == wrapper) {
        void *handle = dlopen(IOKIT_PATH, RTLD_LAZY | RTLD_NOLOAD);
        function = handle ? dlsym(handle, name) : NULL;
        if (handle) dlclose(handle);
    }
    if (function == wrapper) function = NULL;
    if (!function) AKLog(@"IOKit: the system has no %s to forward to", name);
    return function;
}
// The system function behind the wrapper of the same name.
#define REAL(name) \
    static __typeof__(name) *real; static dispatch_once_t once; \
    dispatch_once(&once, ^{ real = (__typeof__(name) *)realFunction(#name, (void *)name); })

static BOOL tracing, macIdentity;
static void configure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *arguments = NSProcessInfo.processInfo.arguments;
        tracing = [arguments containsObject:@"--trace-iokit"];
        macIdentity = ![arguments containsObject:@"--native-gpu-identity"];
        if (tracing) AKLog(@"IOKit: tracing registry queries (--trace-iokit); Mac GPU identity %@",
                           macIdentity ? @"on" : @"off (--native-gpu-identity)");
    });
}
// Each distinct line once, at most 600 lines.
static void trace(NSString *line) {
    if (!tracing) return;
    static NSMutableSet *seen; static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet new]; });
    @synchronized(seen) {
        if (seen.count >= 600 || [seen containsObject:line]) return;
        [seen addObject:line];
    }
    AKLog(@"IOKit %@", line);
}
static NSString *className(io_object_t object) {
    if (!object) return @"(none)";
    io_name_t name = "";
    return IOObjectGetClass(object, name) == KERN_SUCCESS ? @(name) : @"(unknown class)";
}
static NSString *keyName(CFStringRef key) { return key ? (__bridge NSString *)key : @"(null)"; }
static NSString *summary(CFStringRef key, CFTypeRef value) {
    if (!value) return @"none";
    if (key && AKGPUIdentityPrivateKey((__bridge NSString *)key)) return @"(withheld)";
    id object = (__bridge id)value;
    if ([object isKindOfClass:NSData.class]) {
        NSData *data = object;
        if (data.length > 16) return [NSString stringWithFormat:@"data[%lu]", (unsigned long)data.length];
        NSMutableString *hex = [NSMutableString stringWithString:@"<"];
        for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", ((const uint8_t *)data.bytes)[i]];
        return [hex stringByAppendingString:@">"];
    }
    if ([object isKindOfClass:NSString.class]) {
        NSString *string = object;
        return string.length > 48 ? [NSString stringWithFormat:@"\"%@…\"", [string substringToIndex:48]]
                                  : [NSString stringWithFormat:@"\"%@\"", string];
    }
    if ([object isKindOfClass:NSNumber.class]) return [object description];
    if ([object isKindOfClass:NSDictionary.class]) return [NSString stringWithFormat:@"dictionary[%lu]", (unsigned long)[object count]];
    if ([object isKindOfClass:NSArray.class]) return [NSString stringWithFormat:@"array[%lu]", (unsigned long)[object count]];
    return NSStringFromClass([object class]);
}
static NSString *matchingSummary(CFDictionaryRef matching) {
    if (!matching) return @"(null)";
    NSMutableArray *parts = [NSMutableArray new];
    [(__bridge NSDictionary *)matching enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, summary((__bridge CFStringRef)key, (__bridge CFTypeRef)value)]];
    }];
    [parts sortUsingSelector:@selector(compare:)];
    return [parts componentsJoinedByString:@" "];
}
static BOOL AKGPUIsMetalDevice(uint64_t identifier) {
    static uint64_t device; static dispatch_once_t once;
    dispatch_once(&once, ^{ device = MTLCreateSystemDefaultDevice().registryID; });
    return identifier && identifier == device;
}
// The accelerator behind the Metal device: what a Mac reports as the GPU.
static BOOL isGPU(io_registry_entry_t entry) {
    return entry && (IOObjectConformsTo(entry, "IOAccelerator") || IOObjectConformsTo(entry, "IOGPU"));
}
// The Mac answer for one property of the GPU entry, or NULL to keep the iPad's.
static CFTypeRef macGPUProperty(io_registry_entry_t entry, CFStringRef key, CFTypeRef native) {
    if (!macIdentity || !key || !isGPU(entry)) return NULL;
    NSData *answer = AKGPUIdentityProperty((__bridge NSString *)key, (__bridge id)native);
    return answer ? CFBridgingRetain(answer) : NULL;
}

kern_return_t IOServiceGetMatchingServices(mach_port_t port, CFDictionaryRef matching, io_iterator_t *existing) {
    REAL(IOServiceGetMatchingServices);
    configure();
    if (tracing && real && matching) {
        // List what the application will be given, from a second iterator: each
        // call consumes one reference to the matching dictionary.
        static io_object_t (*next)(io_iterator_t); static dispatch_once_t once;
        dispatch_once(&once, ^{ next = (io_object_t (*)(io_iterator_t))realFunction("IOIteratorNext", (void *)IOIteratorNext); });
        NSString *description = matchingSummary(matching);
        NSMutableOrderedSet *classes = [NSMutableOrderedSet new];
        unsigned count = 0; io_iterator_t copy = 0;
        CFRetain(matching);
        kern_return_t listed = real(port, matching, &copy);
        if (listed == KERN_SUCCESS && copy && next) {
            for (io_object_t object; (object = next(copy)); IOObjectRelease(object)) { count++; [classes addObject:className(object)]; }
            IOObjectRelease(copy);
        }
        trace([NSString stringWithFormat:@"IOServiceGetMatchingServices %@ -> 0x%x count=%u %@", description, listed, count,
               [classes.array componentsJoinedByString:@","]]);
    }
    return real ? real(port, matching, existing) : KERN_FAILURE;
}
io_service_t IOServiceGetMatchingService(mach_port_t port, CFDictionaryRef matching) {
    REAL(IOServiceGetMatchingService);
    configure();
    NSString *description = tracing ? matchingSummary(matching) : nil;
    io_service_t service = real ? real(port, matching) : 0;
    trace([NSString stringWithFormat:@"IOServiceGetMatchingService %@ -> %@", description, className(service)]);
    return service;
}
io_object_t IOIteratorNext(io_iterator_t iterator) {
    REAL(IOIteratorNext);
    configure();
    io_object_t object = real ? real(iterator) : 0;
    if (object) trace([NSString stringWithFormat:@"IOIteratorNext -> %@", className(object)]);
    return object;
}
CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    REAL(IORegistryEntryCreateCFProperty);
    configure();
    CFTypeRef value = real ? real(entry, key, allocator, options) : NULL;
    CFTypeRef mac = macGPUProperty(entry, key, value);
    trace([NSString stringWithFormat:@"CreateCFProperty %@ %@ -> %@%@", className(entry), keyName(key), summary(key, value),
           mac ? [@" (Mac: " stringByAppendingFormat:@"%@)", summary(key, mac)] : @""]);
    if (mac) { if (value) CFRelease(value); return mac; }
    return value;
}
CFTypeRef IORegistryEntrySearchCFProperty(io_registry_entry_t entry, const io_name_t plane, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    REAL(IORegistryEntrySearchCFProperty);
    configure();
    CFTypeRef value = real ? real(entry, plane, key, allocator, options) : NULL;
    CFTypeRef mac = macGPUProperty(entry, key, value);
    trace([NSString stringWithFormat:@"SearchCFProperty %@ %s %@ options=0x%x -> %@%@", className(entry), plane ? plane : "(null)",
           keyName(key), options, summary(key, value), mac ? [@" (Mac: " stringByAppendingFormat:@"%@)", summary(key, mac)] : @""]);
    if (mac) { if (value) CFRelease(value); return mac; }
    return value;
}
kern_return_t IORegistryEntryCreateCFProperties(io_registry_entry_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, IOOptionBits options) {
    REAL(IORegistryEntryCreateCFProperties);
    configure();
    kern_return_t result = real ? real(entry, properties, allocator, options) : KERN_FAILURE;
    if (result == KERN_SUCCESS && properties && *properties && macIdentity && isGPU(entry)) {
        for (NSString *key in AKGPUIdentityKeys()) {
            CFTypeRef native = CFDictionaryGetValue(*properties, (__bridge CFStringRef)key);
            NSData *answer = AKGPUIdentityProperty(key, (__bridge id)native);
            if (answer) CFDictionarySetValue(*properties, (__bridge CFStringRef)key, (__bridge CFTypeRef)answer);
        }
    }
    if (tracing) {
        NSDictionary *found = result == KERN_SUCCESS && properties ? (__bridge NSDictionary *)*properties : nil;
        NSMutableArray *parts = [NSMutableArray new];
        for (NSString *key in @[@"vendor-id", @"device-id", @"class-code", @"model", @"IOClass", @"IONameMatched"])
            if (found[key]) [parts addObject:[NSString stringWithFormat:@"%@=%@", key, summary((__bridge CFStringRef)key, (__bridge CFTypeRef)found[key])]];
        trace([NSString stringWithFormat:@"CreateCFProperties %@ -> 0x%x keys=%lu %@", className(entry), result,
               (unsigned long)found.count, [parts componentsJoinedByString:@" "]]);
    }
    return result;
}
kern_return_t IORegistryEntryGetParentEntry(io_registry_entry_t entry, const io_name_t plane, io_registry_entry_t *parent) {
    REAL(IORegistryEntryGetParentEntry);
    configure();
    kern_return_t result = real ? real(entry, plane, parent) : KERN_FAILURE;
    trace([NSString stringWithFormat:@"GetParentEntry %@ %s -> 0x%x %@", className(entry), plane ? plane : "(null)", result,
           result == KERN_SUCCESS && parent ? className(*parent) : @""]);
    return result;
}
kern_return_t IORegistryEntryGetParentIterator(io_registry_entry_t entry, const io_name_t plane, io_iterator_t *iterator) {
    REAL(IORegistryEntryGetParentIterator);
    configure();
    kern_return_t result = real ? real(entry, plane, iterator) : KERN_FAILURE;
    trace([NSString stringWithFormat:@"GetParentIterator %@ %s -> 0x%x", className(entry), plane ? plane : "(null)", result]);
    return result;
}
kern_return_t IORegistryEntryGetChildIterator(io_registry_entry_t entry, const io_name_t plane, io_iterator_t *iterator) {
    REAL(IORegistryEntryGetChildIterator);
    configure();
    kern_return_t result = real ? real(entry, plane, iterator) : KERN_FAILURE;
    trace([NSString stringWithFormat:@"GetChildIterator %@ %s -> 0x%x", className(entry), plane ? plane : "(null)", result]);
    return result;
}
kern_return_t IORegistryEntryGetRegistryEntryID(io_registry_entry_t entry, uint64_t *identifier) {
    REAL(IORegistryEntryGetRegistryEntryID);
    configure();
    kern_return_t result = real ? real(entry, identifier) : KERN_FAILURE;
    trace([NSString stringWithFormat:@"GetRegistryEntryID %@ -> 0x%x%@", className(entry), result,
           result == KERN_SUCCESS && identifier && AKGPUIsMetalDevice(*identifier) ? @" (the Metal device)" : @""]);
    return result;
}
