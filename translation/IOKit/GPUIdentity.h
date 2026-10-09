// What a Mac with Apple silicon says about its GPU in the I/O Registry, where
// the iPad's own entry differs. Pure functions, tested on the Mac.
#pragma once
#import <Foundation/Foundation.h>

// The properties answered as a Mac answers them.
static inline NSArray<NSString *> *AKGPUIdentityKeys(void) { return @[@"vendor-id"]; }
// A Mac's answer for key, or nil to keep the iPad's own (native).
static inline NSData *AKGPUIdentityProperty(NSString *key, id native) {
    (void)native;
    if ([key isEqualToString:@"vendor-id"]) {
        static const uint8_t apple[4] = { 0x6b, 0x10, 0x00, 0x00 };   // 0x106b, little endian, as on a Mac
        return [NSData dataWithBytes:apple length:sizeof apple];
    }
    return nil;
}
// Keys whose values identify a device or a person: never logged.
static inline BOOL AKGPUIdentityPrivateKey(NSString *key) {
    NSString *lower = key.lowercaseString;
    for (NSString *word in @[@"serial", @"uuid", @"udid", @"unique", @"ecid", @"chip-id", @"mac-address",
                             @"imei", @"meid", @"iccid", @"wifi", @"bluetooth", @"ethernet", @"region-info", @"mlb"])
        if ([lower containsString:word]) return YES;
    return NO;
}
