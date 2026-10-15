#include "Gamma.h"

// The display's gamma ramp. iPadOS lets no app change it; programs that set
// one (games do, for brightness) are told it took, and read back what they
// set, so their own bookkeeping stays consistent.
static CGGammaValue red_table[AKGammaTableCapacity], green_table[AKGammaTableCapacity], blue_table[AKGammaTableCapacity];
static uint32_t table_size;

uint32_t CGDisplayGammaTableCapacity(CGDirectDisplayID display) {
    return display == AKMainDisplay ? AKGammaTableCapacity : 0;
}

CGError CGSetDisplayTransferByTable(CGDirectDisplayID display, uint32_t size, const CGGammaValue *red,
                                    const CGGammaValue *green, const CGGammaValue *blue) {
    if (display != AKMainDisplay) return kCGErrorIllegalArgument;
    if (size > AKGammaTableCapacity || (size && (!red || !green || !blue))) return kCGErrorIllegalArgument;
    for (uint32_t i = 0; i < size; i++) { red_table[i] = red[i]; green_table[i] = green[i]; blue_table[i] = blue[i]; }
    table_size = size;
    return kCGErrorSuccess;
}

CGError CGGetDisplayTransferByTable(CGDirectDisplayID display, uint32_t capacity, CGGammaValue *red,
                                    CGGammaValue *green, CGGammaValue *blue, uint32_t *count) {
    if (display != AKMainDisplay || !count || (capacity && (!red || !green || !blue))) return kCGErrorIllegalArgument;
    // Linear until a program sets its own.
    uint32_t size = table_size ? table_size : AKGammaTableCapacity;
    if (capacity < size) size = capacity;
    for (uint32_t i = 0; i < size; i++) {
        CGGammaValue linear = size > 1 ? (CGGammaValue)i / (CGGammaValue)(size - 1) : 0;
        red[i] = table_size ? red_table[i] : linear;
        green[i] = table_size ? green_table[i] : linear;
        blue[i] = table_size ? blue_table[i] : linear;
    }
    *count = size;
    return kCGErrorSuccess;
}

void CGDisplayRestoreColorSyncSettings(void) { table_size = 0; }
