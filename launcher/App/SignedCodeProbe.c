#include "SignedCodeProbe.h"
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
extern int HostSignedPageA(void),HostSignedPageB(void);
static bool map_page(void *destination,void *source,size_t size,FILE *log) {
    vm_address_t target=(vm_address_t)destination;
    vm_prot_t current=VM_PROT_READ|VM_PROT_EXECUTE,maximum=VM_PROT_READ|VM_PROT_EXECUTE;
    kern_return_t result=vm_remap_new(mach_task_self(),&target,size,0,VM_FLAGS_FIXED|VM_FLAGS_OVERWRITE,
        mach_task_self(),(vm_address_t)source,false,&current,&maximum,VM_INHERIT_NONE);
    fprintf(log,"[signed-probe] remap result=%d same_address=%d protection=%d maximum=%d\n",result,target==(vm_address_t)destination,current,maximum);fflush(log);
    if(result!=KERN_SUCCESS) {
        target=(vm_address_t)destination;current=maximum=VM_PROT_READ|VM_PROT_EXECUTE;
        result=vm_remap_new(mach_task_self(),&target,size,0,VM_FLAGS_FIXED|VM_FLAGS_OVERWRITE,
            mach_task_self(),(vm_address_t)source,true,&current,&maximum,VM_INHERIT_NONE);
        fprintf(log,"[signed-probe] COW remap result=%d same_address=%d protection=%d maximum=%d\n",result,target==(vm_address_t)destination,current,maximum);fflush(log);
    }
    return result==KERN_SUCCESS && target==(vm_address_t)destination && (current&VM_PROT_EXECUTE) && !(current&VM_PROT_WRITE);
}
bool HostSignedCodeProbe(FILE *log) {
    size_t page=(size_t)getpagesize();
    if(page!=16384 || (uintptr_t)HostSignedPageA%page || (uintptr_t)HostSignedPageB%page)return false;
    void *arena=mmap(NULL,page*2,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);
    if(arena==MAP_FAILED)return false;
    uint64_t *data=(void *)((char *)arena+page);*data=0x12345678;
    bool ok=false;
    fprintf(log,"[signed-probe] ordinary signed pages; no debugger, JIT or guest execution\n");fflush(log);
    fprintf(log,"[signed-probe] sourceA=%p sourceB=%p nativeA=%d nativeB=%d\n",(void *)HostSignedPageA,(void *)HostSignedPageB,HostSignedPageA(),HostSignedPageB());fflush(log);
    void *fresh=mmap(NULL,page,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);
    if(fresh!=MAP_FAILED) {
        if(map_page(fresh,(void *)HostSignedPageB,page,log)) {
            int value=((int (*)(void))fresh)();
            fprintf(log,"[signed-probe] fresh B=%d expected=1337\n",value);fflush(log);
        }
        munmap(fresh,page);
    }
    if(!map_page(arena,(void *)HostSignedPageA,page,log))goto done;
    int first=((int (*)(void))arena)();
    fprintf(log,"[signed-probe] first=%d expected=42\n",first);fflush(log);
    if(first!=42)goto done;
    int unmap=munmap(arena,page);
    fprintf(log,"[signed-probe] explicit unmap=%d\n",unmap);fflush(log);
    if(unmap)goto done;
    if(!map_page(arena,(void *)HostSignedPageB,page,log))goto done;
    int second=((int (*)(void))arena)();
    fprintf(log,"[signed-probe] second=%d expected=1337 data_unchanged=%d\n",second,*data==0x12345678);fflush(log);
    ok=second==1337 && *data==0x12345678;
done:
    munmap(arena,page*2);
    fprintf(log,"[signed-probe] result=%s\n",ok?"PASS":"FAIL");fflush(log);
    return ok;
}
