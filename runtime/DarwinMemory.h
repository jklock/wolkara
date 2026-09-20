#pragma once
#include "GuestMemory.h"
// These are macOS ABI constants, independent of the build host's mmap headers.
enum { GD_MAP_SHARED = 1, GD_MAP_PRIVATE = 2, GD_MAP_FIXED = 0x10,
       GD_MAP_ANON = 0x1000, GD_MAP_JIT = 0x800 };
typedef struct { GuestMemory memory; GMThread thread; int error; } DarwinMemory;
uint64_t gd_mmap(DarwinMemory *d, uint64_t address, uint64_t size, unsigned prot,
                 unsigned flags, int fd, uint64_t offset);
int gd_mprotect(DarwinMemory *d, uint64_t address, uint64_t size, unsigned prot);
int gd_munmap(DarwinMemory *d, uint64_t address, uint64_t size);
void gd_jit_write_protect(DarwinMemory *d, bool enabled);
