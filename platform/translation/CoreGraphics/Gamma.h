#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

// macOS CGDirectDisplay.h / CGDisplayConfiguration.h, which the iPhoneOS SDK does not have.
typedef uint32_t CGDirectDisplayID;
typedef float CGGammaValue;
// The iPad's one display, as the other display calls name it.
enum { AKMainDisplay = 1, AKGammaTableCapacity = 256 };

uint32_t CGDisplayGammaTableCapacity(CGDirectDisplayID display);
CGError CGSetDisplayTransferByTable(CGDirectDisplayID display, uint32_t size, const CGGammaValue *red,
                                    const CGGammaValue *green, const CGGammaValue *blue);
CGError CGGetDisplayTransferByTable(CGDirectDisplayID display, uint32_t capacity, CGGammaValue *red,
                                    CGGammaValue *green, CGGammaValue *blue, uint32_t *count);
void CGDisplayRestoreColorSyncSettings(void);
