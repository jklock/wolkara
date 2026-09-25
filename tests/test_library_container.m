#import <Foundation/Foundation.h>
#import "LibraryContainer.h"
#include <assert.h>
#include <string.h>
// Arguments: fixture containers, legacy (AIR 2.0, container 2) or current
// (AIR 2.7, container 8). tools/test_emulation.sh builds one of each.
int main(int argc,char **argv) {@autoreleasepool {
    assert(argc>=2);NSUInteger checked=0;
    for(int arg=1;arg<argc;arg++) {
        NSData *original=[NSData dataWithContentsOfFile:@(argv[arg])];assert(original);
        NSData *saved=[original copy],*derived=AKLocalMetalLibraryData(original);
        assert(derived && derived.length==original.length && [saved isEqual:original]);
        const uint8_t *a=original.bytes,*b=derived.bytes;
        BOOL legacy=a[8]<7;
        // Only the platform, the operating system and, in a current container,
        // the iOS release of its AIR revision change: 17 for AIR 2.6, 18 for 2.7.
        uint8_t os=legacy?a[12]:a[8]==8?18:17;
        for(NSUInteger i=0;i<original.length;i++)assert(b[i]==(i==5?0:i==11?0x82:i==12?os:a[i]));
        assert(!AKLocalMetalLibraryData(derived)); // Never reinterpret an already converted container.
        for(NSUInteger n=0;n<original.length;n++)assert(!AKLocalMetalLibraryData([original subdataWithRange:NSMakeRange(0,n)]));
        for(NSUInteger offset=24;offset<=80;offset+=8) {
            NSMutableData *bad=[original mutableCopy];memset((uint8_t *)bad.mutableBytes+offset,0xff,8);
            assert(!AKLocalMetalLibraryData(bad));
        }
        NSMutableData *bad=[original mutableCopy];((uint8_t *)bad.mutableBytes)[bad.length-1]^=1;
        assert(!AKLocalMetalLibraryData(bad));
        // Every other container version: unknown, or paired with another AIR revision.
        for(uint8_t version=0;version<16;version++) {
            bad=[original mutableCopy];((uint8_t *)bad.mutableBytes)[8]=version;
            assert((AKLocalMetalLibraryData(bad)!=nil)==(version==a[8]));
        }
        if(legacy) {
            bad=[original mutableCopy];((uint8_t *)bad.mutableBytes)[11]=0x81;assert(!AKLocalMetalLibraryData(bad));
        } else {
            bad=[original mutableCopy];((uint8_t *)bad.mutableBytes)[11]=0;assert(!AKLocalMetalLibraryData(bad));
            bad=[original mutableCopy];((uint8_t *)bad.mutableBytes)[12]=0;assert(!AKLocalMetalLibraryData(bad));
            bad=[original mutableCopy];((uint8_t *)bad.mutableBytes)[13]=1;assert(!AKLocalMetalLibraryData(bad));
        }
        checked++;
    }
    printf("PASS: %lu immutable containers; bounded parsing, truncation, ranges, hash integrity, version pairing and format rejection\n",(unsigned long)checked);
}}
