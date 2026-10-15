#import "ImageHints.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        assert([NSImageHintCTM isEqualToString:@"NSImageHintCTM"]);
        assert([NSImageHintInterpolation isEqualToString:@"NSImageHintInterpolation"]);
        assert([NSImageHintUserInterfaceLayoutDirection isEqualToString:@"NSImageHintUserInterfaceLayoutDirection"]);
        // A guest imports the address of each global, loads it, and uses it as a key.
        NSString *const *imports[] = { &NSImageHintCTM, &NSImageHintInterpolation,
                                      &NSImageHintUserInterfaceLayoutDirection };
        for (size_t i = 0; i < sizeof imports / sizeof *imports; i++) {
            NSDictionary *hints = @{ *imports[i]: @3 };
            assert([hints[*imports[i]] isEqual:@3]);
            assert([hints.allKeys.firstObject isKindOfClass:NSString.class]);
        }
    }
    puts("PASS: AppKit image hints export string globals usable as dictionary keys");
}
