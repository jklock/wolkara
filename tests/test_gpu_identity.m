#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#import "GPUIdentity.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    // The Mac answer is Apple's vendor ID in the registry's own encoding.
    NSData *vendor = AKGPUIdentityProperty(@"vendor-id", nil);
    const uint8_t apple[4] = { 0x6b, 0x10, 0x00, 0x00 };
    assert([vendor isEqualToData:[NSData dataWithBytes:apple length:4]]);
    assert(AKGPUIdentityProperty(@"vendor-id", [NSData dataWithBytes:"\x02\x10\x00\x00" length:4]) != nil);
    assert(AKGPUIdentityProperty(@"model", @"Apple M5") == nil);
    assert([AKGPUIdentityKeys() containsObject:@"vendor-id"]);
    // On a Mac with Apple silicon, the answer is the GPU's real registry value.
    io_service_t gpu = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    if (gpu) {
        CFTypeRef real = IORegistryEntryCreateCFProperty(gpu, CFSTR("vendor-id"), kCFAllocatorDefault, 0);
        NSString *model = CFBridgingRelease(IORegistryEntryCreateCFProperty(gpu, CFSTR("model"), kCFAllocatorDefault, 0));
        if ([model hasPrefix:@"Apple"]) assert(real && [(__bridge NSData *)real isEqualToData:vendor]);
        if (real) CFRelease(real);
        IOObjectRelease(gpu);
    }
    // The stand-in's whole entry: Apple's vendor ID and the chip in "model".
    NSDictionary *standIn = AKGPUStandInProperties(@"Apple M5 GPU");
    assert([standIn[@"vendor-id"] isEqualToData:vendor] && [standIn[@"model"] isEqual:@"Apple M5"]);
    assert([AKGPUStandInProperties(@"Apple M4 Pro")[@"model"] isEqual:@"Apple M4 Pro"]);
    // On this Mac, a stand-in made from Metal's name equals the real entry's model.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    io_service_t accelerator = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    if (device && accelerator) {
        NSString *real = CFBridgingRelease(IORegistryEntryCreateCFProperty(accelerator, CFSTR("model"), kCFAllocatorDefault, 0));
        if ([real hasPrefix:@"Apple"]) assert([AKGPUStandInProperties(device.name)[@"model"] isEqual:real]);
    }
    if (accelerator) IOObjectRelease(accelerator);
    // Identifying keys are withheld from traces.
    for (NSString *key in @[@"IOPlatformSerialNumber", @"IOPlatformUUID", @"unique-chip-id", @"mac-address-wifi0"])
        assert(AKGPUIdentityPrivateKey(key));
    for (NSString *key in @[@"vendor-id", @"model", @"IOClass", @"device-id"])
        assert(!AKGPUIdentityPrivateKey(key));
    puts("GPU identity: Apple's vendor ID as a Mac reports it, identifying keys withheld: PASS");
}
