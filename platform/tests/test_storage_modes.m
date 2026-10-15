#import <Metal/Metal.h>
#import "StorageModes.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    // Managed becomes Shared; every other mode is kept.
    assert(AKTranslatedStorageMode(MTLStorageModeManaged)==MTLStorageModeShared);
    assert(AKTranslatedStorageMode(MTLStorageModeShared)==MTLStorageModeShared);
    assert(AKTranslatedStorageMode(MTLStorageModePrivate)==MTLStorageModePrivate);
    assert(AKTranslatedStorageMode(MTLStorageModeMemoryless)==MTLStorageModeMemoryless);
    // Resource options: only the storage bits change, matching Metal's own layout.
    assert(AKResourceStorageShift==MTLResourceStorageModeShift);
    MTLResourceOptions others=MTLResourceCPUCacheModeWriteCombined|MTLResourceHazardTrackingModeUntracked;
    assert(AKTranslatedResourceOptions(MTLResourceStorageModeManaged|others)==(MTLResourceStorageModeShared|others));
    assert(AKTranslatedResourceOptions(MTLResourceStorageModeManaged)==MTLResourceStorageModeShared);
    assert(AKTranslatedResourceOptions(MTLResourceStorageModePrivate|others)==(MTLResourceStorageModePrivate|others));
    assert(AKTranslatedResourceOptions(MTLResourceStorageModeMemoryless)==MTLResourceStorageModeMemoryless);
    assert(AKTranslatedResourceOptions(others)==others);
    assert(AKTranslatedResourceOptions(0)==0);
    puts("Managed storage becomes Shared; other modes and options unchanged: PASS");
}
