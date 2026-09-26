#pragma once
#include "GuestSparseMemory.h"
#include <signal.h>
#include <stdio.h>
#include <sys/types.h>

// Process-lifetime opt-in. The caller restricts this to the authorized Cyberpunk
// profile (or our test fixtures). No guest instructions are patched or logged.
bool gsv_start(size_t backing_bytes, size_t force_threshold, int log_fd);
void gsv_stop(void); // Only after every software-address user has stopped.
bool gsv_enabled(void);
bool gsv_address(const void *address);
// Startup-only allocation comparison: prefer one exact large reservation size
// for native placement and route other large reservations through software.
void gsv_prefer_native_pool(size_t size);
// Register the loader-owned shared arena before guest entry. Both views remain
// alive until gsv_stop. Fetches read current bytes; there is no instruction cache.
bool gsv_code_alias(const void *executable, const void *readable, size_t size);
void gsv_forget_code_alias(const void *address, size_t size);
bool gsv_fetch_instruction(uint64_t pc, uint32_t *instruction);
int gsv_sigaction(int number, const struct sigaction *action, struct sigaction *old);
void *gsv_map(void *address, size_t size, int prot, int flags, int fd, off_t offset);
int gsv_protect(void *address, size_t size, int prot);
int gsv_unmap(void *address, size_t size);
int gsv_advise(void *address, size_t size, int advice);
GMResult gsv_copy(void *destination, const void *source, size_t size);
GMResult gsv_fill(void *destination, int value, size_t size);
const char *gsv_string(const char *source, char *buffer, size_t capacity);
ssize_t gsv_read(int fd, void *buffer, size_t size);
ssize_t gsv_pread(int fd, void *buffer, size_t size, off_t offset);
ssize_t gsv_write(int fd, const void *buffer, size_t size);
ssize_t gsv_pwrite(int fd, const void *buffer, size_t size, off_t offset);
size_t gsv_fread(void *buffer, size_t size, size_t count, FILE *file);
size_t gsv_fwrite(const void *buffer, size_t size, size_t count, FILE *file);
GMSparseStats gsv_stats(void);
uint64_t gsv_fault_count(void);
