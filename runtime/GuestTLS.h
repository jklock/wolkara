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
// One image's thread-locals; without a template none can be served.
typedef struct {
    GuestTLS tls;
    const char *name;
    uintptr_t descriptors;
    size_t descriptors_size;
} GTImage;
// Records an image's descriptors; storage only where a template exists.
bool gt_register(GTImage *image, const char *name, const void *bytes, size_t size, size_t alignment,
                 uintptr_t descriptors, size_t descriptors_size);
// Storage for a descriptor, and which image declared it.
void *gt_find(GTImage *images, size_t count, const uint64_t descriptor[3], const char **owner);
