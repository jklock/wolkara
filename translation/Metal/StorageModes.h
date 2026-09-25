// macOS's Managed storage mode has no iOS counterpart; on unified memory
// Shared is its CPU-visible equivalent. Pure mappings, tested on the Mac.
#pragma once
enum { AKStorageShared=0, AKStorageManaged=1, AKResourceStorageShift=4 };
// An MTLStorageMode: Managed becomes Shared, anything else is kept.
static inline unsigned long AKTranslatedStorageMode(unsigned long mode) {
    return mode==AKStorageManaged ? AKStorageShared : mode;
}
// MTLResourceOptions: the storage mode lives in bits 4-7; the other options are kept.
static inline unsigned long AKTranslatedResourceOptions(unsigned long options) {
    const unsigned long mask=0xFUL<<AKResourceStorageShift;
    unsigned long mode=(options&mask)>>AKResourceStorageShift;
    return (options&~mask)|(AKTranslatedStorageMode(mode)<<AKResourceStorageShift);
}
