#include "NativeCodeMemory.h"
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

void nc_destroy(NativeCodeMemory *memory) {
    if (memory->quarantined) return;
    if (memory->writable) vm_deallocate(mach_task_self(), (vm_address_t)memory->writable, memory->size);
    if (memory->executable) munmap(memory->executable, memory->size);
    *memory = (NativeCodeMemory){0};
}
bool nc_create_managed(NativeCodeMemory *memory, size_t size, NCPrepare prepare,
                       void *context, NativeCodeMemory *quarantine) {
    size_t page = (size_t)getpagesize();
    if (!memory || !quarantine || memory == quarantine ||
        memory->size || memory->executable || memory->writable ||
        quarantine->size || quarantine->executable || quarantine->writable || !size ||
        size % page || size > 128 * 1024 * 1024 || !prepare) {
        errno = EINVAL; return false;
    }
    NativeCodeMemory staged = {.size = size};
    staged.executable = mmap(NULL, size, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (staged.executable == MAP_FAILED) return false;
    vm_address_t alias = 0;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t result = vm_remap(mach_task_self(), &alias, size, 0, VM_FLAGS_ANYWHERE,
                                   mach_task_self(), (vm_address_t)staged.executable, false,
                                   &current, &maximum, VM_INHERIT_NONE);
    if (result != KERN_SUCCESS) {
        nc_destroy(&staged); errno = result == KERN_NO_SPACE ? ENOMEM : EACCES; return false;
    }
    staged.writable = (void *)alias;
    NCPreparation outcome = prepare(staged.executable, size, context);
    if (outcome != NC_PREPARED && outcome != NC_REJECTED) {
        staged.quarantined = true; *quarantine = staged;
        errno = EINPROGRESS; return false;
    }
    if (outcome == NC_REJECTED) {
        nc_destroy(&staged); errno = EPERM; return false;
    }
    if (mprotect(staged.writable, size, PROT_READ | PROT_WRITE)) {
        int saved = errno; nc_destroy(&staged); errno = saved; return false;
    }
    staged.published = true; *memory = staged;
    return true;
}
typedef struct { NCPublish function; void *context; } LegacyPublisher;
static NCPreparation legacy_prepare(void *address, size_t size, void *opaque) {
    LegacyPublisher *publisher = opaque;
    return publisher->function(address,size,publisher->context) ? NC_PREPARED : NC_REJECTED;
}
bool nc_create(NativeCodeMemory *memory, size_t size, NCPublish publish, void *context) {
    if (!publish) { errno = EINVAL; return false; }
    LegacyPublisher publisher = {publish,context}; NativeCodeMemory unused = {0};
    return nc_create_managed(memory,size,legacy_prepare,&publisher,&unused);
}
bool nc_write(NativeCodeMemory *memory, size_t offset, const void *bytes, size_t size) {
    if (!memory->published || memory->quarantined || !memory->executable || !memory->writable || !bytes || offset > memory->size ||
        size > memory->size - offset) { errno = EINVAL; return false; }
    if (!size) return true;
    char *destination = (char *)memory->writable + offset;
    memcpy(destination, bytes, size);
    sys_dcache_flush(destination, size);
    sys_icache_invalidate((char *)memory->executable + offset, size);
    return true;
}
