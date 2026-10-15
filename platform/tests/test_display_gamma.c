#include "Gamma.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    CGGammaValue red[AKGammaTableCapacity], green[AKGammaTableCapacity], blue[AKGammaTableCapacity];
    uint32_t count = 0;
    assert(CGDisplayGammaTableCapacity(AKMainDisplay) == AKGammaTableCapacity && !CGDisplayGammaTableCapacity(2));
    // Linear to begin with.
    assert(CGGetDisplayTransferByTable(AKMainDisplay, AKGammaTableCapacity, red, green, blue, &count) == kCGErrorSuccess);
    assert(count == AKGammaTableCapacity && red[0] == 0 && blue[AKGammaTableCapacity - 1] == 1 && green[128] > 0.5f && green[128] < 0.51f);
    // What a program sets, it reads back.
    CGGammaValue ramp[3] = {0.25f, 0.5f, 0.75f};
    assert(CGSetDisplayTransferByTable(AKMainDisplay, 3, ramp, ramp, ramp) == kCGErrorSuccess);
    assert(CGGetDisplayTransferByTable(AKMainDisplay, AKGammaTableCapacity, red, green, blue, &count) == kCGErrorSuccess);
    assert(count == 3 && red[1] == 0.5f && blue[2] == 0.75f);
    // A shorter buffer gets the start; nothing is written past it.
    red[1] = -1;
    assert(CGGetDisplayTransferByTable(AKMainDisplay, 1, red, green, blue, &count) == kCGErrorSuccess && count == 1 && red[1] == -1);
    CGDisplayRestoreColorSyncSettings();
    assert(CGGetDisplayTransferByTable(AKMainDisplay, 2, red, green, blue, &count) == kCGErrorSuccess && count == 2 && red[1] == 1);
    // Nothing else is accepted.
    assert(CGSetDisplayTransferByTable(2, 3, ramp, ramp, ramp) == kCGErrorIllegalArgument);
    assert(CGSetDisplayTransferByTable(AKMainDisplay, AKGammaTableCapacity + 1, ramp, ramp, ramp) == kCGErrorIllegalArgument);
    assert(CGSetDisplayTransferByTable(AKMainDisplay, 3, ramp, NULL, ramp) == kCGErrorIllegalArgument);
    assert(CGGetDisplayTransferByTable(AKMainDisplay, 3, red, green, blue, NULL) == kCGErrorIllegalArgument);
    puts("PASS: display gamma tables are kept per program and read back; the physical display is left alone");
}
