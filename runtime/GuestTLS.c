#include "GuestTLS.h"
#include <stdlib.h>
#include <string.h>
bool gt_create(GuestTLS *tls, const void *bytes, size_t size, size_t alignment,
               uintptr_t descriptors, size_t descriptors_size) {
    if (tls->initialized || !bytes || !size || size>16*1024*1024 || !alignment ||
        (alignment&(alignment-1)) || alignment>1024*1024 || descriptors_size%24 ||
        descriptors_size>UINTPTR_MAX-descriptors) return false;
    if (alignment<sizeof(void *)) alignment=sizeof(void *);
    GuestTLS staged={.size=size,.alignment=alignment,.descriptors=descriptors,.descriptors_size=descriptors_size};
    staged.bytes=malloc(size);
    if (!staged.bytes) return false;
    memcpy(staged.bytes,bytes,size);
    if (pthread_key_create(&staged.key,free)) { free(staged.bytes); return false; }
    staged.initialized=true; *tls=staged; return true;
}
void *gt_address(GuestTLS *tls, const uint64_t descriptor[3]) {
    uintptr_t address=(uintptr_t)descriptor;
    if (!tls->initialized || address<tls->descriptors || address-tls->descriptors>=tls->descriptors_size ||
        (address-tls->descriptors)%24 || descriptor[2]>=tls->size) return NULL;
    void *storage=pthread_getspecific(tls->key);
    if (!storage) {
        if (posix_memalign(&storage,tls->alignment,tls->size)) return NULL;
        memcpy(storage,tls->bytes,tls->size);
        if (pthread_setspecific(tls->key,storage)) { free(storage); return NULL; }
    }
    return (char *)storage+descriptor[2];
}
void gt_destroy(GuestTLS *tls) {
    if (tls->initialized) {
        free(pthread_getspecific(tls->key)); pthread_setspecific(tls->key,NULL);
        pthread_key_delete(tls->key); free(tls->bytes);
    }
    *tls=(GuestTLS){0};
}
