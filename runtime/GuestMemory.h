#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Guest permissions only. Backing storage is ordinary, non-executable heap data.
enum { GM_READ = 1, GM_WRITE = 2, GM_EXEC = 4, GM_PAGE_SIZE = 16384 };
typedef enum { GM_OK, GM_INVALID, GM_OVERLAP, GM_UNMAPPED, GM_PROTECTION, GM_NOMEM } GMResult;
typedef struct {
    uint64_t address;
    unsigned char *bytes; // NULL is a demand-zero page.
    uint8_t prot, maxprot;
    bool jit;
} GMPage;
typedef struct {
    GMPage *pages;
    size_t count;
    uint64_t generation; // All mappings, protections and writes; memory-view consumers.
    uint64_t code_generation; // Mapping/protection changes or writes to executable pages.
    uint64_t fault_address;
} GuestMemory;
typedef struct { bool jit_write_protected; } GMThread;

void gm_destroy(GuestMemory *m);
// Ranges must be page aligned, nonempty, nonwrapping. Replacement is atomic.
GMResult gm_map(GuestMemory *m, uint64_t address, uint64_t size,
                unsigned prot, unsigned maxprot, bool jit, bool replace);
GMResult gm_unmap(GuestMemory *m, uint64_t address, uint64_t size);
GMResult gm_protect(GuestMemory *m, uint64_t address, uint64_t size, unsigned prot);
GMResult gm_read(GuestMemory *m, uint64_t address, void *out, size_t size);
GMResult gm_write(GuestMemory *m, const GMThread *thread, uint64_t address, const void *in, size_t size);
GMResult gm_fetch(GuestMemory *m, const GMThread *thread, uint64_t address, uint32_t *instruction);
// Loader-only copy: bypass guest protection, but never create missing mappings.
GMResult gm_populate(GuestMemory *m, uint64_t address, const void *in, size_t size);
GMResult gm_find_free(const GuestMemory *m, uint64_t hint, uint64_t size, uint64_t *address);
const char *gm_result_string(GMResult result);
