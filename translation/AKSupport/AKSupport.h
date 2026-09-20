// Common support for all shim dylibs (libAKSupport.dylib).
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
// Root for shim and generated stub classes: unknown selectors are logged once
// and return zero instead of raising, so the log shows what the guest really uses.
@interface AKStubObject : NSObject
@end
void AKLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
#endif
// Called by generated C stubs on first use.
void AKStubHit(const char *symbol, void *caller);
void AKLogC(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// Shared cursor visibility for AppKit and Core Graphics adapters.
#include <stdbool.h>
bool AKCursorIsHidden(void);
void AKCursorHide(void);
void AKCursorUnhide(void);
bool AKMouseIsCaptured(void);
void AKMouseSetCaptured(bool captured);
