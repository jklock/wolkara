#include "NativeCodeMemory.h"
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <mach/mach.h>

static vm_prot_t protection(void *pointer) {
    vm_address_t address=(vm_address_t)pointer; vm_size_t size=0;
    vm_region_basic_info_data_64_t info={0}; mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    assert(vm_region_64(mach_task_self(),&address,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object)==KERN_SUCCESS);
    if(object!=MACH_PORT_NULL)mach_port_deallocate(mach_task_self(),object);
    assert(address<=(vm_address_t)pointer && (vm_address_t)pointer-address<size);
    return info.protection;
}
// Whether anything is mapped at this address now.
static bool mapped(void *pointer) {
    vm_address_t address=(vm_address_t)pointer; vm_size_t size=0;
    vm_region_basic_info_data_64_t info={0}; mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    if(vm_region_64(mach_task_self(),&address,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object)!=KERN_SUCCESS) return false;
    if(object!=MACH_PORT_NULL)mach_port_deallocate(mach_task_self(),object);
    return address<=(vm_address_t)pointer && (vm_address_t)pointer-address<size;
}

static bool accept_zeroed_pages(void *address, size_t size, void *context) {
    unsigned *calls = context;
    (*calls)++;
    const unsigned char *bytes = address;
    for (size_t i = 0; i < size; i++) assert(bytes[i] == 0);
    // This fixture validates aliases only. It does not grant executable permission.
    return true;
}
static bool reject_pages(void *address, size_t size, void *context) {
    (void)address; (void)size; (void)context;
    return false;
}
// The mapping is the point, not its contents.
static NCPreparation accept_without_reading(void *address,size_t size,void *context) {
    (void)address; (void)size; (void)context; return NC_PREPARED;
}
static NCPreparation uncertain_pages(void *address,size_t size,void *context) {
    assert(accept_zeroed_pages(address,size,context)); return NC_UNCERTAIN;
}
int main(void) {
    NativeCodeMemory memory = {0};
    size_t page = (size_t)getpagesize(); unsigned calls = 0;
    assert(!nc_create(&memory, 0, accept_zeroed_pages, &calls) && errno == EINVAL);
    assert(!nc_create(&memory, page + 1, accept_zeroed_pages, &calls) && errno == EINVAL);
    assert(!nc_create(&memory, page, NULL, NULL) && errno == EINVAL);
    assert(!nc_create(&memory, page, reject_pages, NULL) && errno == EPERM);
    assert(!memory.executable && !memory.writable && !memory.size);
    assert(nc_create(&memory, 2 * page, accept_zeroed_pages, &calls));
    assert(calls == 1 && memory.executable != memory.writable);
    assert(!(protection(memory.executable)&VM_PROT_WRITE) && (protection(memory.writable)&VM_PROT_WRITE));
    assert(!nc_create(&memory, page, accept_zeroed_pages, &calls));
    unsigned char data[16]; memset(data, 0x53, sizeof data);
    assert(nc_write(&memory, page - 8, data, sizeof data));
    assert(!memcmp((char *)memory.executable + page - 8, data, sizeof data));
    assert(!nc_write(&memory, SIZE_MAX, data, sizeof data));
    assert(!nc_write(&memory, 2 * page - 8, data, sizeof data));
    assert(!nc_write(&memory, 0, NULL, 4));
    assert(nc_write(&memory, 2 * page, data, 0));
    nc_destroy(&memory);
    assert(!memory.executable && !memory.writable && !memory.size);
    nc_destroy(&memory);
    NativeCodeMemory quarantine={0};
    assert(!nc_create_managed(&memory,page,uncertain_pages,&calls,&quarantine) && errno==EINPROGRESS);
    assert(!memory.executable && !memory.published);
    assert(quarantine.executable && quarantine.writable && quarantine.quarantined && !quarantine.published);
    assert(!(protection(quarantine.executable)&VM_PROT_WRITE) && !(protection(quarantine.writable)&VM_PROT_WRITE));
    assert(!nc_write(&quarantine,0,data,sizeof data));
    void *retained=quarantine.executable;
    nc_destroy(&quarantine);
    assert(quarantine.executable==retained && ((unsigned char *)retained)[0]==0);
    // A mapping we did not make: nc_adopt adds the alias.
    void *foreign=mmap(NULL,2*page,PROT_READ|PROT_EXEC,MAP_PRIVATE|MAP_ANON,-1,0);
    if(foreign==MAP_FAILED) foreign=mmap(NULL,2*page,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    assert(foreign!=MAP_FAILED);
    NativeCodeMemory adopted={0};
    assert(!nc_adopt(&adopted,NULL,2*page) && errno==EINVAL);
    assert(!nc_adopt(&adopted,foreign,0) && errno==EINVAL);
    assert(!nc_adopt(&adopted,foreign,page+1) && errno==EINVAL);
    assert(!nc_adopt(&adopted,(char *)foreign+8,2*page) && errno==EINVAL);
    // The ceiling bounds an adoption; what the device has left does not.
    assert(!nc_adopt(&adopted,foreign,(size_t)NC_MAX_ARENA+page) && errno==EINVAL);
    assert(!adopted.executable && !adopted.writable);
    assert(nc_adopt(&adopted,foreign,2*page));
    assert(adopted.published && adopted.executable==foreign && adopted.writable!=foreign);
    assert(protection(adopted.writable)&VM_PROT_WRITE);
    assert(!nc_adopt(&adopted,foreign,2*page) && errno==EINVAL); // already owns a mapping
    assert(nc_write(&adopted,page,data,sizeof data));
    assert(!memcmp((char *)adopted.executable+page,data,sizeof data));
    void *alias=adopted.writable;
    nc_destroy(&adopted);
    assert(!adopted.executable && !adopted.writable);
    // Adopted, the region is ours: teardown unmaps it with the alias.
    assert(!mapped(foreign) && !mapped(alias));

    unsigned old_calls=calls;
    assert(!nc_create_managed(&memory,page,uncertain_pages,&calls,&quarantine) && errno==EINVAL);
    assert(calls==old_calls); // No second helper attempt or allocation.
    // Quarantined mappings intentionally live until process exit.

    // What may be prepared follows the device, not a constant.
    NativeCodeMemory large={0},spare={0};
    size_t big=160u*1024u*1024u;
    assert(nc_arena_limit()<=NC_MAX_ARENA && !(nc_arena_limit()%page));
    if(big<=nc_arena_limit()) {
        assert(nc_create_managed(&large,big,accept_without_reading,NULL,&spare));
        assert(large.size==big && large.published);
        nc_destroy(&large);
    }
    assert(!nc_create_managed(&large,(size_t)NC_MAX_ARENA+page,accept_without_reading,NULL,&spare) && errno==EINVAL);
    assert(!large.executable && !large.writable);
    puts("PASS: native alias coherence, bounds, device-sized limit, rejection cleanup, uncertain quarantine, write/retry denial (no generated code executed)");
}
