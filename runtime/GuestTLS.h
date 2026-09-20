#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <pthread.h>
typedef struct {
    void *bytes;
    size_t size, alignment;
    uintptr_t descriptors;
    size_t descriptors_size;
    pthread_key_t key;
    bool initialized;
} GuestTLS;
bool gt_create(GuestTLS *tls, const void *bytes, size_t size, size_t alignment,
               uintptr_t descriptors, size_t descriptors_size);
void *gt_address(GuestTLS *tls, const uint64_t descriptor[3]);
// Call only after all guest threads have exited. Frees current-thread storage.
void gt_destroy(GuestTLS *tls);
