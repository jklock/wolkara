#pragma once
#include <stdbool.h>
#include <stddef.h>

// Separate RX and RW views of shared pages. Guest addresses are not host pointers.
// This is storage for a future native loader/translator, not an execution engine.
typedef struct {
    void *executable;
    void *writable;
    size_t size;
    bool published;
    bool quarantined;
} NativeCodeMemory;

// Called once on newly allocated RX pages before the writable alias is enabled.
// The publisher must verify its own initialization handshake and return false if
// unavailable. Mapping success alone does not prove execution is permitted.
typedef bool (*NCPublish)(void *executable, size_t size, void *context);
// A ceiling on any one arena, whatever the device allows.
#define NC_MAX_ARENA (1024u * 1024u * 1024u)
// The largest arena this process may prepare now, page aligned.
size_t nc_arena_limit(void);
// What the system says this process may still allocate.
size_t nc_available_memory(void);
// Zero-initialize memory before use. On error returns false and sets errno.
bool nc_create(NativeCodeMemory *memory, size_t size, NCPublish publish, void *context);
typedef enum { NC_REJECTED, NC_PREPARED, NC_UNCERTAIN } NCPreparation;
typedef NCPreparation (*NCPrepare)(void *executable, size_t size, void *context);
// For asynchronous helper publication: uncertainty transfers both mappings to
// quarantine, without enabling the writable alias. Retain that owner until
// process exit, and do not retry. nc_destroy deliberately cannot release it.
// NC_REJECTED means the helper can no longer access these mappings; only a
// confirmed prepared-and-detached receipt may produce NC_PREPARED.
bool nc_create_managed(NativeCodeMemory *memory, size_t size, NCPrepare prepare,
                       void *context, NativeCodeMemory *quarantine);
// Adopt a region made outside; it is ours from then.
bool nc_adopt(NativeCodeMemory *memory, void *executable, size_t size);
// Caller must ensure no thread is executing the range while it is being changed.
// Copies through RW, flushes caches, and keeps the RX protection unchanged.
bool nc_write(NativeCodeMemory *memory, size_t offset, const void *bytes, size_t size);
// Unmaps both views, adopted ones too; quarantine is kept.
void nc_destroy(NativeCodeMemory *memory);
