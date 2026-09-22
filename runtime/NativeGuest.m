#import <Foundation/Foundation.h>
#include "NativeGuest.h"
#include "NativeCodeMemory.h"
#if TOLKARA_INTEGRATED_AUTH
#import "LocalAuthorization.h"
static NativeCodeMemory local_quarantine;
#endif
#include "GuestFixups.h"
#include "GuestTLS.h"
#include "GuestWait.h"
#include "SignedImage.h"
#include <dlfcn.h>
#include <mach-o/loader.h>
#import <objc/objc-exception.h>
#import <objc/runtime.h>
#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#include <pthread.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <fcntl.h>
#include <stdatomic.h>
static atomic_bool initialization_attempted;
#if TOLKARA_INTEGRATED_AUTH
static atomic_bool use_local_authorization;
#endif
// Local signing: a page container signed with the user's own identity carries
// the guest's final (post-unpack) __TEXT. It is dlopened so dyld establishes
// kernel-validated executable pages; those pages are then vm_remap'd into the
// guest arena at their preferred addresses. No debugger or JIT is involved.
static char signed_container_path[1024];
static atomic_bool use_signed_image;
static bool refuse(char *error, size_t error_size, const char *reason) {
    if (error && error_size) snprintf(error,error_size,"%s",reason);
    return false;
}
bool ng_use_signed_image(const char *container_path, char *error, size_t error_size) {
    if (atomic_load(&initialization_attempted)) return refuse(error,error_size,"startup was already attempted; restart the app");
#if TOLKARA_INTEGRATED_AUTH
    if (atomic_load(&use_local_authorization)) return refuse(error,error_size,"Developer service is already selected");
#endif
    if (!container_path || !container_path[0]) return refuse(error,error_size,"no container path");
    if (strlen(container_path) >= sizeof signed_container_path) return refuse(error,error_size,"container path is too long");
    strcpy(signed_container_path, container_path);
    atomic_store(&use_signed_image,true);
    return true;
}
static struct {
    bool active, shadow;        // shadow: the rewritten range is still anonymous
    bool verified_write;        // a guest write into signed pages already matched
    void *handle;
    SIImage image;              // container's final __TEXT; arena offset 0 is guest.base
    uintptr_t shadow_size;      // leading __TEXT bytes held anonymously during unpack
} signed_image;
bool ng_use_local_authorization(void) {
#if TOLKARA_INTEGRATED_AUTH
    if(atomic_load(&initialization_attempted) || atomic_load(&use_signed_image)) return false;
    atomic_store(&use_local_authorization,true);return true;
#else
    return false;
#endif
}

static struct {
    GuestImage image;
    GuestTLS tls;
    NativeCodeMemory arena;
    void *libraries[GI_MAX_DYLIBS];
    uint64_t base, slide;
    FILE *log;
    const char *path;
} guest;
#define LOG(...) do { fprintf(guest.log, __VA_ARGS__); fflush(guest.log); } while (0)
__attribute__((noinline,used,visibility("default")))
void host_debugger_publish_arena(void *address, size_t size, volatile uint64_t *completion) {
    __asm__ volatile("" : : "r"(address), "r"(size), "r"(completion) : "memory");
}
static objc_exception_preprocessor previous_exception_preprocessor;
static id log_exception(id exception) {
    if ([exception isKindOfClass:NSException.class]) {
        NSException *error=exception;
        LOG("[native] Objective-C exception %s: %s\n",error.name.UTF8String,error.reason.UTF8String);
        unsigned index=0;
        for(NSNumber *frame in NSThread.callStackReturnAddresses) {
            uintptr_t address=frame.unsignedLongLongValue;
            uintptr_t base=(uintptr_t)guest.arena.executable;
            BOOL isGuest=address>=base && address-base<guest.arena.size;
            Dl_info symbol={0}; dladdr((void *)address,&symbol);
            LOG("[native] exception frame %u native=%#lx preferred=%#llx symbol=%s\n",index++,address,isGuest?address-guest.slide:0,symbol.dli_sname?:"unknown");
            if(index>=24) break;
        }
    } else LOG("[native] Objective-C exception object class=%s\n",object_getClassName(exception));
    return previous_exception_preprocessor ? previous_exception_preprocessor(exception) : exception;
}
// Opt-in crash diagnostics use only a preopened fd and raw memory reads in the
// signal handler. Chain the client's handler unchanged after saving evidence.
static int signal_log_fd=-1;
static struct sigaction guest_signal_actions[NSIG];
static void signal_hex(const char *label, uintptr_t value) {
    char buffer[128]; size_t n=0; while(label[n] && n<96) { buffer[n]=label[n]; n++; }
    buffer[n++]='0'; buffer[n++]='x';
    for(int shift=60;shift>=0;shift-=4) buffer[n++]="0123456789abcdef"[(value>>shift)&15];
    buffer[n++]='\n'; (void)write(signal_log_fd,buffer,n);
}
static void diagnostic_signal(int number,siginfo_t *info,void *context) {
    ucontext_t *uc=context;
    signal_hex("signal=",number); signal_hex("fault=",(uintptr_t)info->si_addr);
    arm_thread_state64_t state=uc->uc_mcontext->__ss;
    uintptr_t pc=arm_thread_state64_get_pc(state),fp=arm_thread_state64_get_fp(state);
    signal_hex("pc=",pc); signal_hex("lr=",arm_thread_state64_get_lr(state));
    for(unsigned i=0;i<32 && fp && !(fp&7);i++) {
        uintptr_t frame[2]; vm_size_t actual=0;
        if(vm_read_overwrite(mach_task_self(),fp,sizeof frame,(vm_address_t)frame,&actual)!=KERN_SUCCESS || actual!=sizeof frame) break;
        uintptr_t lr=frame[1]&0x0000ffffffffffffULL;
        signal_hex("frame=",lr);
        uintptr_t base=(uintptr_t)guest.arena.executable;
        if(lr>=base && lr-base<guest.arena.size) signal_hex("preferred=",lr-guest.slide);
        if(frame[0]<=fp || frame[0]-fp>8*1024*1024) break; fp=frame[0];
    }
    struct sigaction action=guest_signal_actions[number];
    if(action.sa_flags&SA_SIGINFO) action.sa_sigaction(number,info,context);
    else action.sa_handler(number);
}
static int guest_sigaction(int number,const struct sigaction *action,struct sigaction *old) {
    if(signal_log_fd<0 || number<=0 || number>=NSIG) return sigaction(number,action,old);
    struct sigaction installed={0},replacement;
    const struct sigaction *requested=action;
    if(action && (number==SIGABRT || number==SIGSEGV || number==SIGBUS || number==SIGILL || number==SIGTRAP) && action->sa_handler!=SIG_DFL && action->sa_handler!=SIG_IGN) {
        replacement=*action; replacement.sa_sigaction=diagnostic_signal; replacement.sa_flags|=SA_SIGINFO; requested=&replacement;
    }
    int result=sigaction(number,requested,&installed);
    if(result==0) {
        if(old) *old=installed.sa_sigaction==diagnostic_signal ? guest_signal_actions[number] : installed;
        if(action) guest_signal_actions[number]=*action;
    }
    return result;
}
static bool publish(void *address, size_t size, void *context) {
    (void)context;
    volatile uint64_t completion = 0;
    LOG("[native] publish fresh zeroed arena address=%p size=%zu\n", address, size);
    host_debugger_publish_arena(address, size, &completion);
    return completion == 0x49504144434f4445ULL;
}
static bool inside(const void *address, size_t size) {
    uintptr_t a = (uintptr_t)address, base = (uintptr_t)guest.arena.executable;
    return a >= base && a - base <= guest.arena.size && size <= guest.arena.size - (a - base);
}
// Optional diagnostics after debugger detachment. Log our own main thread's
// return addresses and symbols only; never copy guest code or data, attach,
// suspend the thread, or modify guest registers/instructions.
static void schedule_native_sample(thread_t thread, unsigned number) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        arm_thread_state64_t state={0}; mach_msg_type_number_t count=ARM_THREAD_STATE64_COUNT;
        kern_return_t kr=thread_get_state(thread,ARM_THREAD_STATE64,(thread_state_t)&state,&count);
        if(kr==KERN_SUCCESS) {
            uintptr_t pc=arm_thread_state64_get_pc(state), fp=arm_thread_state64_get_fp(state);
            flockfile(guest.log);
            LOG("[native] sample %u pc=%#lx preferred=%#llx\n",number,pc,inside((void *)pc,1)?pc-guest.slide:0);
            Dl_info info={0}; dladdr((void *)pc,&info);
            LOG("[native] sample symbol=%s image=%s\n",info.dli_sname?:"unknown",info.dli_fname?:"unknown");
            for(unsigned i=0;i<24 && fp && !(fp&7);i++) {
                uintptr_t frame[2]; vm_size_t actual=0;
                if(vm_read_overwrite(mach_task_self(),fp,sizeof frame,(vm_address_t)frame,&actual)!=KERN_SUCCESS || actual!=sizeof frame) break;
                uintptr_t lr=frame[1] & 0x0000ffffffffffffULL; info=(Dl_info){0}; dladdr((void *)lr,&info);
                LOG("[native] sample frame %u lr=%#lx preferred=%#llx symbol=%s image=%s\n",i,lr,inside((void *)lr,1)?lr-guest.slide:0,info.dli_sname?:"unknown",info.dli_fname?:"unknown");
                if(frame[0]<=fp || frame[0]-fp>8*1024*1024) break; fp=frame[0];
            }
            funlockfile(guest.log);
        } else LOG("[native] sample unavailable kr=%d\n",kr);
        if(number<3) schedule_native_sample(thread,number+1);
        else mach_port_deallocate(mach_task_self(),thread);
    });
}
static NSBundle *guest_bundle;
static CFBundleRef guest_cf_bundle;
static NSArray<NSString *> *guest_arguments;
static NSArray<NSString *> *(*original_arguments)(id,SEL);
static NSArray<NSString *> *guest_process_arguments(id receiver,SEL selector) {
    if(guest_arguments && inside(__builtin_return_address(0),1)) {
        static BOOL reported;
        if(!reported){reported=YES;LOG("[native] guest NSProcessInfo arguments count=%lu\n",(unsigned long)guest_arguments.count);}
        return guest_arguments;
    }
    return original_arguments(receiver,selector);
}
static NSBundle *(*original_main_bundle)(id,SEL);
static NSBundle *guest_main_bundle(id receiver, SEL selector) {
    if (guest_bundle && inside(__builtin_return_address(0),1)) return guest_bundle;
    return original_main_bundle(receiver,selector);
}
static CFBundleRef guest_cf_main_bundle(void) {
    if (guest_cf_bundle) return guest_cf_bundle;
    return CFBundleGetMainBundle();
}
// A guest write into signed __TEXT pages must reproduce the baked bytes
// exactly: the guest's unpacking initializer re-derives the same unpacked code
// every launch. Any mismatch proves non-determinism (or a stale container) and
// is logged with the exact address before the hook aborts.
static void explain_exec_mismatch(void) {
    if (signed_image.shadow_size || signed_image.verified_write) return;
    LOG("[signed-image] FATAL: the container holds this guest's on-disk __TEXT, but the guest rewrites its code at startup; "
        "build the container from a capture of the final pages\n");
}
static bool verify_exec_write(const void *destination, const void *source, size_t size) {
    const unsigned char *d=destination,*s=source;
    for (size_t i=0;i<size;i++) if (d[i]!=s[i]) {
        uintptr_t offset=(uintptr_t)destination-(uintptr_t)guest.arena.executable+i;
        LOG("[signed-image] FATAL: regenerated code mismatch at preferred=%#llx baked=%02x regenerated=%02x (write size=%zu)\n",
            (unsigned long long)(guest.base+offset),d[i],s[i],size);
        explain_exec_mismatch();
        return false;
    }
    if (size) signed_image.verified_write=true;
    return true;
}
static bool inside_exec(const void *address, size_t size) {
    if (!signed_image.active || !inside(address,size)) return false;
    uintptr_t offset=(uintptr_t)address-(uintptr_t)guest.arena.executable;
    return offset<signed_image.image.size && size<=signed_image.image.size-offset;
}
// The leading [0, shadow_size) __TEXT pages hold the packed bytes on writable
// anonymous memory while the unpacking initializer runs; the remaining pages
// are already the kernel-validated signed ones.
static bool inside_shadow(const void *address, size_t size) {
    if (!signed_image.shadow || !inside_exec(address,size)) return false;
    uintptr_t offset=(uintptr_t)address-(uintptr_t)guest.arena.executable;
    return offset<signed_image.shadow_size && size<=signed_image.shadow_size-offset;
}
// Leading bytes of a __TEXT write that land in the still-anonymous shadow.
static size_t shadow_part(const void *destination, size_t size) {
    uintptr_t offset=(uintptr_t)destination-(uintptr_t)guest.arena.executable;
    if (!signed_image.shadow || offset>=signed_image.shadow_size) return 0;
    return signed_image.shadow_size-offset<size ? signed_image.shadow_size-offset : size;
}
// Guest memcpy/memmove into __TEXT: shadow bytes are written, signed bytes must
// regenerate identically. The signed part is verified first, before the shadow
// write can overwrite its overlapping source; memmove handles overlap.
static bool final_image_write(void *destination, const void *source, size_t size) {
    size_t shadow=shadow_part(destination,size);
    if (shadow<size && !verify_exec_write((char *)destination+shadow,(const char *)source+shadow,size-shadow)) return false;
    if (shadow) memmove(destination,source,shadow);
    return true;
}
static bool final_image_memset(void *destination, int value, size_t size) {
    size_t shadow=shadow_part(destination,size);
    const unsigned char *d=destination;
    for (size_t i=shadow;i<size;i++) if (d[i]!=(unsigned char)value) {
        uintptr_t at=(uintptr_t)destination-(uintptr_t)guest.arena.executable+i;
        LOG("[signed-image] FATAL: memset verification mismatch at preferred=%#llx baked=%02x value=%02x\n",
            (unsigned long long)(guest.base+at),d[i],(unsigned)value&0xff);
        explain_exec_mismatch();
        return false;
    }
    if (shadow<size) signed_image.verified_write=true;
    if (shadow) memset(destination,value,shadow);
    return true;
}
static void *write_view(void *destination, size_t size) {
    // Local signing: the mem* hooks shadow or verify writes into __TEXT.
    if (signed_image.active) return destination;
    if (inside(destination, size)) return (char *)guest.arena.writable + ((uintptr_t)destination - (uintptr_t)guest.arena.executable);
    return destination;
}
static void *guest_memcpy(void *destination, const void *source, size_t size) {
    if (inside_exec(destination,size)) {
        if (!final_image_write(destination,source,size)) abort();
        return destination;
    }
    void *alias = write_view(destination, size);
    memcpy(alias, source, size);
    if (alias != destination) { sys_dcache_flush(alias,size); sys_icache_invalidate(destination,size); }
    return destination;
}
static void *guest_memmove(void *destination, const void *source, size_t size) {
    if (inside_exec(destination,size)) {
        if (!final_image_write(destination,source,size)) abort();
        return destination;
    }
    void *alias = write_view(destination, size);
    // Use the same view for overlapping guest source and destination.
    if (alias != destination && inside(source,size)) source = write_view((void *)source,size);
    memmove(alias, source, size);
    if (alias != destination) { sys_dcache_flush(alias,size); sys_icache_invalidate(destination,size); }
    return destination;
}
static void *guest_memset(void *destination, int value, size_t size) {
    if (inside_exec(destination,size)) {
        if (!final_image_memset(destination,value,size)) abort();
        return destination;
    }
    void *alias = write_view(destination,size); memset(alias,value,size);
    if (alias != destination) { sys_dcache_flush(alias,size); sys_icache_invalidate(destination,size); }
    return destination;
}
static int guest_dladdr(const void *address, Dl_info *info) {
    if (inside(address,1)) {
        *info = (Dl_info){.dli_fname=guest.path,.dli_fbase=guest.arena.executable};
        LOG("[native] dladdr(%p) -> original image base=%p\n",address,info->dli_fbase); return 1;
    }
    return dladdr(address,info);
}
static int guest_mprotect(void *address, size_t size, int prot) {
    LOG("[native] mprotect(%p,%#zx,%d)\n",address,size,prot);
    // Local signing: shadow pages are plain writable anonymous memory; signed
    // pages already have their final protection by construction.
    if (inside_exec(address,size)) {
        if (inside_shadow(address,size)) return mprotect(address,size,PROT_READ|PROT_WRITE);
        return 0;
    }
    // Keep executable backing RX; imported stores/copies use its shared RW view.
    if (inside(address,size) && (prot & PROT_EXEC)) prot &= ~PROT_WRITE;
    int result = mprotect(address,size,prot);
    if (result) LOG("[native] mprotect failed errno=%d\n",errno);
    return result;
}
static int guest_munmap(void *address, size_t size) {
    LOG("[native] munmap(%p,%#zx)\n",address,size);
    // Local signing: keep validated pages; shadow pages stay mapped+writable.
    if (inside_exec(address,size)) {
        if (inside_shadow(address,size)) return mprotect(address,size,PROT_READ|PROT_WRITE);
        return 0;
    }
    // Reserve the runtime arena so a later fixed/hinted remap preserves the RX
    // backing established before guest execution. Inaccessible until remapped.
    if (inside(address,size)) return mprotect(address,size,PROT_NONE);
    return munmap(address,size);
}
static void *guest_mmap(void *address, size_t size, int prot, int flags, int fd, off_t offset) {
    LOG("[native] mmap(%p,%#zx,%d,%#x,%d,%lld)\n",address,size,prot,flags,fd,(long long)offset);
    if (inside_exec(address,size) && (flags & MAP_ANON) && (flags & MAP_PRIVATE) &&
        fd == -1 && offset == 0 && !((uintptr_t)address % GM_PAGE_SIZE) && size && !(size % GM_PAGE_SIZE)) {
        if (inside_shadow(address,size)) {
            memset(address,0,size);
            return address;
        }
        // The unpacker's MAP_JIT re-map of a signed range is a no-op: the
        // signed pages already hold the final bytes and the following memcpy
        // verifies them.
        LOG("[signed-image] MAP_JIT remap of signed range satisfied in place\n");
        return address;
    }
    if (inside(address,size) && (flags & MAP_ANON) && (flags & MAP_PRIVATE) && fd == -1 && offset == 0 &&
        !((uintptr_t)address % GM_PAGE_SIZE) && size && !(size % GM_PAGE_SIZE)) {
        void *alias = write_view(address,size); memset(alias,0,size);
        if (guest_mprotect(address,size,prot)) return MAP_FAILED;
        sys_dcache_flush(alias,size); sys_icache_invalidate(address,size);
        return address;
    }
    void *result = mmap(address,size,prot,flags,fd,offset);
    LOG("[native] mmap -> %p errno=%d\n",result,result==MAP_FAILED?errno:0); return result;
}
static void guest_jit_protect(int enabled) { LOG("[native] jit write protection=%d (separate RW/RX views)\n",enabled); }
static void guest_unexpected_lazy_bind(void) {
    LOG("[native] unexpected lazy binder call after eager binding\n"); __builtin_trap();
}
__attribute__((noinline,used,visibility("default")))
void host_debugger_guest_complete(bool ok) { __asm__ volatile("" : : "r"(ok) : "memory"); }
extern void *guest_tlv_bootstrap(const uint64_t descriptor[3]);
void *guest_tlv_address(const uint64_t descriptor[3]) {
    void *value=gt_address(&guest.tls,descriptor);
    if (!value) { LOG("[native] invalid TLS descriptor %p\n",descriptor); abort(); }
    return value;
}
static int guest_executable_path(char *buffer, uint32_t *size) {
    size_t required=strlen(guest.path)+1;
    if (!size) { errno=EINVAL; return -1; }
    if (!buffer || *size<required) { *size=(uint32_t)required; return -1; }
    memcpy(buffer,guest.path,required); return 0;
}
static void *guest_dlsym(void *, const char *);
extern int __ulock_wait(uint32_t,void *,uint64_t,uint32_t);
static bool (*shader_wait_pending)(void);
static bool shader_pending(void) { return shader_wait_pending && shader_wait_pending(); }
static void pump_shader_wait(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode,.001,true); }
static int guest_ulock_wait(uint32_t operation,void *address,uint64_t value,uint32_t timeout) {
    static _Thread_local bool pumping;
    if(pumping) return __ulock_wait(operation,address,value,timeout);
    pumping=true;
    int result=gw_wait(__ulock_wait,operation,address,value,timeout,pthread_main_np()!=0,shader_pending,pump_shader_wait);
    pumping=false; return result;
}
static void *hook(const char *name) {
#define HOOK(n,f) if (!strcmp(name,n)) return (void *)&f
    HOOK("sigaction",guest_sigaction);
    HOOK("__ulock_wait",guest_ulock_wait);
    HOOK("CFBundleGetMainBundle",guest_cf_main_bundle);
    HOOK("_NSGetExecutablePath",guest_executable_path);
    HOOK("_tlv_bootstrap",guest_tlv_bootstrap);
    HOOK("dyld_stub_binder",guest_unexpected_lazy_bind);
    HOOK("dladdr",guest_dladdr); HOOK("dlsym",guest_dlsym);
    HOOK("mmap",guest_mmap); HOOK("mprotect",guest_mprotect); HOOK("munmap",guest_munmap);
    HOOK("memcpy",guest_memcpy); HOOK("memmove",guest_memmove); HOOK("memset",guest_memset);
    HOOK("pthread_jit_write_protect_np",guest_jit_protect);
#undef HOOK
    return NULL;
}
static void *guest_dlsym(void *handle, const char *name) {
    void *value = hook(name); if (!value) value = dlsym(handle,name);
    LOG("[native] dlsym(%s) -> %p\n",name,value); return value;
}
// Logs leave the device: show app-container paths relative to the home
// directory, whose absolute form carries a per-install UUID.
static void home_relative(const char *text, char *out, size_t size) {
    NSString *home=NSHomeDirectory(), *value=text?[NSString stringWithUTF8String:text]:nil;
    if (value && home.length>1) {
        value=[value stringByReplacingOccurrencesOfString:[@"/private" stringByAppendingString:home] withString:@"~"];
        value=[value stringByReplacingOccurrencesOfString:home withString:@"~"];
    }
    snprintf(out,size,"%s",value?value.UTF8String:"(unavailable)");
}
static void loggable_path(const char *path, char *out, size_t size) {
    home_relative(path,out,size);
    const char *name=strrchr(path,'/');
    if (out[0]=='/') snprintf(out,size,".../%s",name?name+1:path);
}
// dlopen the signed container (dyld validates its CodeDirectory and maps its
// pages), check its layout and bind it to this guest before anything is
// mapped, then reserve the guest arena anonymously. Pages after the rewritten
// range equal the original ones and are remapped from the container at once.
// The rewritten range is remapped only AFTER the unpacking initializer has
// re-derived its bytes on the anonymous pages (the shadow phase): an anonymous
// overwrite of validated pages is rejected by the kernel, while the reverse
// direction, validated pages over anonymous, is allowed.
static bool signed_image_prepare(uint64_t end, char *error, size_t error_size) {
    char shown[1024];
    loggable_path(signed_container_path, shown, sizeof shown);
    LOG("[signed-image] container %s\n", shown);
    void *handle = dlopen(signed_container_path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        home_relative(dlerror(), shown, sizeof shown);
        snprintf(error, error_size, "container dlopen failed: %s", shown); return false;
    }
    size_t span = (size_t)(end - guest.base);
    void *arena = MAP_FAILED;
    SIImage image = {0};
    uint64_t shadow_size = 0;
    Dl_info info = {0};
    uintptr_t v1 = (uintptr_t)dlsym(handle, "tolkara_container_v1"), final = (uintptr_t)dlsym(handle, "tolkara_container_final");
    // No mapping changes and no guest code until the container matches.
    if (v1 && !dladdr((void *)v1, &info)) { snprintf(error, error_size, "container marker lies outside any loaded image"); goto fail; }
    if (!si_locate_image(info.dli_fbase, v1, final, &image, error, error_size) ||
        !si_match_guest(&image, &guest.image, error, error_size) ||
        !si_shadow_size(&image, &guest.image, &shadow_size, error, error_size)) goto fail;
    LOG("[signed-image] container matches the guest: %llu __TEXT pages, header and load commands identical\n",
        (unsigned long long)(image.size / GM_PAGE_SIZE));
    arena = mmap(NULL, span, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (arena == MAP_FAILED) { snprintf(error, error_size, "arena reservation failed errno=%d", errno); goto fail; }
    guest.arena = (NativeCodeMemory){ .executable = arena, .writable = arena, .size = span, .published = true };
    LOG("[signed-image] dlopen ok; shadow region %llu pages, signed suffix %llu pages\n",
        (unsigned long long)(shadow_size / GM_PAGE_SIZE),
        (unsigned long long)((image.size - shadow_size) / GM_PAGE_SIZE));
    if (shadow_size < image.size) {
        vm_address_t target = (vm_address_t)arena + shadow_size;
        vm_prot_t current = VM_PROT_READ | VM_PROT_EXECUTE, maximum = current;
        kern_return_t result = vm_remap_new(mach_task_self(), &target, image.size - shadow_size, 0,
            VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)image.bytes + shadow_size, false,
            &current, &maximum, VM_INHERIT_NONE);
        LOG("[signed-image] signed suffix remap result=%d protection=%d\n", result, current);
        if (result != KERN_SUCCESS || target != (vm_address_t)arena + shadow_size ||
            !(current & VM_PROT_EXECUTE) || (current & VM_PROT_WRITE)) {
            snprintf(error, error_size, "signed suffix remap failed kr=%d", result); goto fail;
        }
    }
    signed_image = (typeof(signed_image)){ .active = true, .shadow = shadow_size != 0, .handle = handle,
        .image = image, .shadow_size = shadow_size };
    return true;
fail:
    if (arena != MAP_FAILED) munmap(arena, span);
    guest.arena = (NativeCodeMemory){0};
    dlclose(handle);
    return false;
}
static bool resolve(const char *symbol, int ordinal, bool weak, uint64_t *value, void *context) {
    (void)context;
    const char *name = symbol[0]=='_' ? symbol+1 : symbol;
    void *pointer = hook(name);
    if (!pointer && ordinal>0 && guest.libraries[ordinal-1]) pointer=dlsym(guest.libraries[ordinal-1],name);
    if (!pointer) pointer=dlsym(RTLD_DEFAULT,name);
    if (!pointer && !weak) LOG("[native] unresolved %s ordinal=%d\n",symbol,ordinal);
    *value=(uintptr_t)pointer; return pointer || weak;
}
bool ng_initialize(const char *path, const char *frameworks, const char *library_map, FILE *log, bool full_startup) {
    // Failure can leave installed Objective-C hooks and an uncertain helper.
    // Do not reinstall hooks recursively or attempt another attachment in this
    // process, even if failure happened before the arena became writable.
    if (atomic_exchange(&initialization_attempted,true)) {
        fprintf(log,"[native] startup was already attempted; restart the app\n"); return false;
    }
    guest.log=log; guest.path=strdup(path);
    guest_arguments=@[@(path)];
    Method arguments_method=class_getInstanceMethod(NSProcessInfo.class,@selector(arguments));
    original_arguments=(void *)method_setImplementation(arguments_method,(IMP)guest_process_arguments);
    previous_exception_preprocessor=objc_setExceptionPreprocessor(log_exception);
    if (full_startup) {
        NSString *bundle_path=[[[@(path) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        if ([bundle_path.pathExtension isEqual:@"app"]) {
            guest_bundle=[NSBundle bundleWithPath:bundle_path];
            guest_cf_bundle=CFBundleCreate(kCFAllocatorDefault,(__bridge CFURLRef)[NSURL fileURLWithPath:bundle_path isDirectory:YES]);
            LOG("[native] guest bundle path=%s identifier=%s CFBundle=%s\n",bundle_path.UTF8String,guest_bundle.bundleIdentifier.UTF8String,guest_cf_bundle?"present":"missing");
            if (guest_bundle) {
                Method method=class_getClassMethod(NSBundle.class,@selector(mainBundle));
                original_main_bundle=(void *)method_setImplementation(method,(IMP)guest_main_bundle);
            }
        }
    }
    char error[2048]; bool ok=false; GFStats stats;
    if (!gi_load(path,&guest.image,error,sizeof error)) { LOG("[native] load failed: %s\n",error); goto done; }
    guest.base=guest.image.header_address;
    uint64_t end=guest.base;
    for(size_t i=0;i<guest.image.segment_count;i++) {
        GISegment *s=&guest.image.segments[i]; if(s->prot && s->address+s->size>end) end=s->address+s->size;
    }
    bool arena_ready;
    bool signed_backend=atomic_load(&use_signed_image);
    if (signed_backend)
        arena_ready=signed_image_prepare(end,error,sizeof error);
    else {
#if TOLKARA_INTEGRATED_AUTH
    if(atomic_load(&use_local_authorization) || [NSProcessInfo.processInfo.arguments containsObject:@"--local-native-authorization"])
        arena_ready=nc_create_managed(&guest.arena,(size_t)(end-guest.base),TKPrepareLocalArena,NULL,&local_quarantine);
    else
#endif
        arena_ready=nc_create(&guest.arena,(size_t)(end-guest.base),publish,NULL);
    }
    if (!arena_ready) { LOG("[native] arena preparation failed errno=%d %s; guest entry blocked\n",errno,signed_backend?error:""); goto done; }
    guest.slide=(uintptr_t)guest.arena.executable-guest.base;
    LOG("[native] arena ready base=%p slide=%#llx\n",guest.arena.executable,(unsigned long long)guest.slide);
    {
        NSData *data=[NSData dataWithContentsOfFile:@(library_map)];
        NSDictionary *mapping=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
        if (![mapping isKindOfClass:NSDictionary.class]) { LOG("[native] missing library map\n"); goto done; }
        NSString *support=[@(frameworks) stringByAppendingPathComponent:@"libAKSupport.dylib"];
        if (!dlopen(support.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL)) { LOG("[native] support load failed: %s\n",dlerror()); goto done; }
        for(size_t i=0;i<guest.image.dylib_count;i++) {
            NSString *original=@(guest.image.dylibs[i]); NSString *target=mapping[original]?:original;
            if ([target hasPrefix:@"@rpath/"]) target=[@(frameworks) stringByAppendingPathComponent:target.lastPathComponent];
            guest.libraries[i]=dlopen(target.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL);
            if (!guest.libraries[i]) LOG("[native] library %s unavailable: %s\n",target.UTF8String,dlerror());
        }
    }
    {
        void (*set_nibs)(const char *)=dlsym(RTLD_DEFAULT,"AKSetGuestNibDirectory");
        if(set_nibs) set_nibs([NSHomeDirectory() stringByAppendingPathComponent:@"Documents/GuestCompatibility/Nibs"].fileSystemRepresentation);
    }
    if([NSProcessInfo.processInfo.arguments containsObject:@"--sample-native"]) signal_log_fd=open([[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/native-signal.log"] fileSystemRepresentation],O_WRONLY|O_CREAT|O_TRUNC,0600);
    shader_wait_pending=dlsym(RTLD_DEFAULT,"AKShaderWaitPending");
    if (!gf_apply(&guest.image,guest.slide,resolve,NULL,&stats,error,sizeof error)) { LOG("[native] fixups failed: %s\n",error); goto done; }
    LOG("[native] resolved rebases=%zu binds=%zu\n",stats.rebases,stats.binds);
    if (guest.image.has_tls) {
        if (guest.image.tls_initializer_count) { LOG("[native] TLS constructors unsupported\n"); goto done; }
        void *template=malloc((size_t)guest.image.tls_size);
        bool ready=template && gm_read(&guest.image.memory,guest.image.tls_address,template,(size_t)guest.image.tls_size)==GM_OK &&
            gt_create(&guest.tls,template,(size_t)guest.image.tls_size,guest.image.tls_alignment,
                (uintptr_t)(guest.image.tls_descriptors+guest.slide),(size_t)guest.image.tls_descriptors_size);
        free(template);
        if (!ready) { LOG("[native] TLS template setup failed\n"); goto done; }
        LOG("[native] TLS template size=%zu alignment=%zu descriptors=%zu\n",guest.tls.size,guest.tls.alignment,guest.tls.descriptors_size/24);
    }
    size_t signed_pages_skipped=0;
    for(size_t i=0;i<guest.image.memory.count;i++) {
        GMPage *page=&guest.image.memory.pages[i];
        if(!page->bytes) continue;
        size_t offset=(size_t)(page->address-guest.base);
        if (signed_image.active) {
            // __TEXT pages after the rewritten range are already backed by the
            // signed container: never overwrite validated pages. Only the
            // rewritten range (original packed bytes) is staged onto anonymous
            // pages, with the bounds check nc_write applies in the other backend.
            if (offset>=signed_image.shadow_size && offset<signed_image.image.size) { signed_pages_skipped++; continue; }
            if (offset>guest.arena.size || GM_PAGE_SIZE>guest.arena.size-offset) {
                LOG("[signed-image] staged page %#llx lies outside the arena\n",(unsigned long long)page->address); goto done;
            }
            memcpy((char *)guest.arena.executable+offset,page->bytes,GM_PAGE_SIZE);
        }
        else if(!nc_write(&guest.arena,offset,page->bytes,GM_PAGE_SIZE)) goto done;
    }
    if (signed_image.active) LOG("[signed-image] %zu staged executable pages left to the signed container\n",signed_pages_skipped);
    for(size_t i=0;i<guest.image.segment_count;i++) {
        GISegment *s=&guest.image.segments[i]; if(!s->prot) continue;
        if (signed_image.active && (s->prot & GM_EXEC)) continue;  // remap already established RX
        if (mprotect((void *)(s->address+guest.slide),s->size,s->prot & ((s->prot&GM_EXEC)?~GM_WRITE:~0u))) {
            LOG("[native] segment protection failed: %s errno=%d\n",s->name,errno); goto done;
        }
    }
    {
        // The unpacking initializer runs in both backends. With Local signing
        // its code-writing operations verify the signed pages byte-for-byte
        // instead of writing through an RW alias.
        uintptr_t initializer=guest.image.first_initializer+guest.slide;
        gm_destroy(&guest.image.memory);
        LOG("[native] entering original initializer preferred=%#llx native=%p\n",(unsigned long long)guest.image.first_initializer,(void *)initializer);
        char *executable_argument=NULL;
        asprintf(&executable_argument,"executable_path=%s",guest.path);
        const char *argv[]={guest.path,NULL}, *env[]={NULL}, *apple[]={executable_argument,NULL};
        int argc=1;
        ((void (*)(int,const char **,const char **,const char **))initializer)(argc,argv,env,apple);
        LOG("[native] first original initializer returned\n"); ok=true;
        if (signed_image.active && !signed_image.shadow)
            LOG("[signed-image] no rewritten range: every __TEXT page was signed before the initializer; no unpack verification or restore needed\n");
        if (signed_image.shadow) {
            // Determinism evidence: the regenerated range must equal the signed
            // container before its pages replace it. Any difference means the
            // container came from another capture: stop before running more code.
            size_t first=0, mismatched=si_count_mismatches(guest.arena.executable,signed_image.image.bytes,signed_image.shadow_size,&first);
            if (mismatched) {
                const unsigned char *regenerated=guest.arena.executable, *baked=signed_image.image.bytes;
                LOG("[signed-image] FATAL: unpack verification: %zu differing bytes of %zu; first at preferred=%#llx regenerated=%02x baked=%02x\n",
                    mismatched,(size_t)signed_image.shadow_size,(unsigned long long)(guest.base+first),regenerated[first],baked[first]);
                LOG("[signed-image] FATAL: the container was built from a different capture of this executable; rebuild it. Guest entry blocked.\n");
                ok=false; goto done;
            }
            LOG("[signed-image] unpack verification: regenerated shadow image identical to the signed container (%zu bytes)\n",
                (size_t)signed_image.shadow_size);
            signed_image.shadow=false;
            // Restore the kernel-validated signed pages for execution.
            vm_address_t target=(vm_address_t)guest.arena.executable;
            vm_prot_t current=VM_PROT_READ|VM_PROT_EXECUTE,maximum=current;
            kern_return_t result=vm_remap_new(mach_task_self(),&target,signed_image.shadow_size,0,
                VM_FLAGS_FIXED|VM_FLAGS_OVERWRITE,mach_task_self(),(vm_address_t)signed_image.image.bytes,false,&current,&maximum,VM_INHERIT_NONE);
            LOG("[signed-image] signed pages restored result=%d protection=%d\n",result,current);
            if (result!=KERN_SUCCESS || target!=(vm_address_t)guest.arena.executable ||
                !(current&VM_PROT_EXECUTE) || (current&VM_PROT_WRITE)) { LOG("[signed-image] restore failed\n"); ok=false; goto done; }
        }
        if (full_startup) {
            // Apple's ObjC SPI explicitly supports images created outside dyld.
            // Invoke after the client's unpacking initializer restores its code.
            void (*map_images)(unsigned,const char *const *,const struct mach_header *const *)=dlsym(RTLD_DEFAULT,"_objc_map_images");
            void (*load_image)(const char *,const struct mach_header *)=dlsym(RTLD_DEFAULT,"_objc_load_image");
            if (!map_images || !load_image) { LOG("[native] ObjC image registration unavailable\n"); ok=false; goto done; }
            const struct mach_header *header=guest.arena.executable;
            const char *names[]={path};
            LOG("[native] registering original ObjC image\n");
            map_images(1,names,&header);
            load_image(path,header);
            LOG("[native] ObjC image registration returned\n");
            uint64_t *initializers=(uint64_t *)(guest.image.initializer_address+guest.slide);
            for(uint64_t i=1;i<guest.image.initializer_count;i++) {
                uintptr_t function=initializers[i];
                if (!inside((void *)function,4) || (function&3)) { LOG("[native] invalid initializer %llu=%p\n",(unsigned long long)i,(void *)function); ok=false; goto done; }
                LOG("[native] initializer %llu preferred=%#llx native=%p\n",(unsigned long long)i,(unsigned long long)(function-guest.slide),(void *)function);
                ((void (*)(int,const char **,const char **,const char **))function)(argc,argv,env,apple);
            }
            LOG("[native] all %llu initializers returned; entering original main=%p\n",(unsigned long long)guest.image.initializer_count,(void *)(guest.image.entry+guest.slide));
            if([NSProcessInfo.processInfo.arguments containsObject:@"--sample-native"]) schedule_native_sample(mach_thread_self(),1);
            int result=((int (*)(int,const char **,const char **,const char **))(guest.image.entry+guest.slide))(argc,argv,env,apple);
            LOG("[native] original main returned %d\n",result);
            ok=(result==0);
        }
    }
done:
    LOG("[native] result %s=%s\n",full_startup?"startup_return":"first_initializer",ok?"PASS":"FAIL");
    // Retain live mappings and library handles: initializer-created pointers and
    // worker threads may outlive this call. Only one guest per app process.
    host_debugger_guest_complete(ok);
    return ok;
}
