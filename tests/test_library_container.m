#import <Foundation/Foundation.h>
#import "LibraryContainer.h"
#include <assert.h>
int main(int argc,char **argv) {@autoreleasepool {
    assert(argc>=2);NSUInteger checked=0;
    for(int arg=1;arg<argc;arg++) {
        NSData *original=[NSData dataWithContentsOfFile:@(argv[arg])];assert(original);
        NSData *saved=[original copy],*derived=AKLocalMetalLibraryData(original);
        assert(derived && derived.length==original.length && [saved isEqual:original]);
        const uint8_t *a=original.bytes,*b=derived.bytes;
        for(NSUInteger i=0;i<original.length;i++)assert(b[i]==(i==5?0:i==11?0x82:a[i]));
        assert(!AKLocalMetalLibraryData(derived)); // Never reinterpret an already converted container.
        if(arg==1) {
            for(NSUInteger n=0;n<original.length;n++)assert(!AKLocalMetalLibraryData([original subdataWithRange:NSMakeRange(0,n)]));
            for(NSUInteger offset=24;offset<=80;offset+=8) {
                NSMutableData *bad=[original mutableCopy];memset((uint8_t *)bad.mutableBytes+offset,0xff,8);
                assert(!AKLocalMetalLibraryData(bad));
            }
            NSMutableData *bad=[original mutableCopy];((uint8_t *)bad.mutableBytes)[bad.length-1]^=1;
            assert(!AKLocalMetalLibraryData(bad));
            bad=[original mutableCopy];((uint8_t *)bad.mutableBytes)[8]=4;assert(!AKLocalMetalLibraryData(bad));
        }
        checked++;
    }
    printf("PASS: %lu immutable containers; bounded parsing, truncation, ranges, hash integrity and format rejection\n",(unsigned long)checked);
}}
