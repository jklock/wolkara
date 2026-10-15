#include "HostExecutionProbe.h"
#include <assert.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// The arena stage of --jit-probe on a dual mapping of our own: an RX view and
// a shared RW alias, as a prepared arena has. The Mac allows what the iPad
// refuses (the direct stage), so this checks the stages and their reporting.
int main(void) {
    size_t page = (size_t)getpagesize();
    void *rx = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(rx != MAP_FAILED);
    vm_address_t alias = 0;
    vm_prot_t current = 0, maximum = 0;
    assert(vm_remap(mach_task_self(), &alias, page, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)rx,
                    false, &current, &maximum, VM_INHERIT_NONE) == KERN_SUCCESS);
    assert(!mprotect(rx, page, PROT_READ | PROT_EXEC));
    assert(!mprotect((void *)alias, page, PROT_READ | PROT_WRITE));
    char path[] = "/tmp/tolkara-arena-probe-XXXXXX";
    int fd = mkstemp(path);
    assert(fd != -1);
    FILE *log = fdopen(fd, "w+");
    assert(log);
    HPArenaResult result = arena_execution_probe(rx, (void *)alias, page, log);
    assert(result.alias_execute && result.alias_rewrite);
    // Each stage the probe reaches is logged before it runs.
    rewind(log);
    char text[4096] = {0};
    fread(text, 1, sizeof text - 1, log);
    assert(strstr(text, "alias write: calling sample, expected=42") && strstr(text, "alias rewrite: returned 1337"));
    assert(strstr(text, "direct: RX view to RW") && strstr(text, "rwx: RX view to RWX") && strstr(text, "[arena-probe] result"));
    assert(result.direct_rewrite == !result.direct_errno);
    fclose(log); unlink(path);
    munmap(rx, page); vm_deallocate(mach_task_self(), alias, page);
    printf("PASS: arena execution probe stages (alias %s, direct %s, rwx errno %d on this Mac)\n",
           result.alias_rewrite ? "PASS" : "FAIL", result.direct_rewrite ? "PASS" : "FAIL", result.rwx_errno);
}
