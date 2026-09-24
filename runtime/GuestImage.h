#pragma once
#include "GuestMemory.h"
#include <stdio.h>

enum { GI_MAX_SEGMENTS = 64, GI_MAX_DYLIBS = 128, GI_MAX_RPATHS = 32 };
typedef struct {
    char name[17];
    uint64_t address, size, file_offset, file_size;
    unsigned prot, maxprot;
} GISegment;
typedef struct {
    GuestMemory memory;
    GISegment segments[GI_MAX_SEGMENTS];
    size_t segment_count;
    uint64_t slice_offset, slice_size, entry, first_initializer, initializer_count;
    uint64_t mapped_size, file_backed_size;
    uint32_t bind_size, lazy_bind_size, weak_bind_size, rebase_size;
    uint32_t bind_offset, lazy_bind_offset, weak_bind_offset, rebase_offset;
    uint32_t file_type, export_size;
    uint32_t chained_offset, chained_size;   // LC_DYLD_CHAINED_FIXUPS payload
    unsigned char *exports;
    uint64_t header_address, initializer_address;
    uint64_t tls_address, tls_size, tls_descriptors, tls_descriptors_size, tls_initializer_count;
    size_t tls_alignment;
    char *dylibs[GI_MAX_DYLIBS];
    bool dylib_reexports[GI_MAX_DYLIBS];   // LC_REEXPORT_DYLIB: this image answers for that one too
    size_t dylib_count;
    char *rpaths[GI_MAX_RPATHS];   // LC_RPATH, for expanding @rpath install names
    size_t rpath_count;
    bool chained_fixups, has_tls;
    bool initializer_offsets;     // S_INIT_FUNC_OFFSETS rather than pointers
    uint64_t *initializers;       // those offsets, as preferred addresses
} GuestImage;
// Reads a thin or universal original executable. Never dlopens or writes it.
// Maps at preferred guest addresses, so legacy rebases require zero slide.
// Does not bind imports, initialize ObjC/TLS, or execute guest code.
// `image` must be zero-initialized; on failure it is left unchanged.
bool gi_load(const char *path, GuestImage *image, char *error, size_t error_size);
// Explicit library entry point: accepts MH_DYLIB only, including a zero preferred
// base and no LC_MAIN. This is a data-only load, not native dlopen/execution.
bool gi_load_library(const char *path, GuestImage *image, char *error, size_t error_size);
typedef enum { GI_EXPORT_INVALID = -1, GI_EXPORT_MISSING = 0, GI_EXPORT_FOUND = 1,
               GI_EXPORT_REEXPORT = 2 } GIExportResult;
// What an export trie answers: an address, or another library.
typedef struct { uint64_t address; bool absolute; int ordinal; const char *name; } GIExport;
// Resolve an ordinary/absolute export at its preferred address. Apply the runtime
// slide only to non-absolute results. Unsupported export kinds fail explicitly.
GIExportResult gi_export(const GuestImage *image, const char *symbol, GIExport *out,
                         char *error, size_t error_size);
// Lowest mapped address and the page-aligned reach from it.
uint64_t gi_extent(const GuestImage *image, uint64_t *low);
// Initializer at slide; pointers are read from placed memory.
uint64_t gi_placed_initializer(const GuestImage *image, uint64_t slide, uint64_t index);
void gi_destroy(GuestImage *image);
void gi_report(const GuestImage *image, FILE *out);
