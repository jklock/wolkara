#include "HostDiagnostics.h"
#include "NativeCodeMemory.h"
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif

// Our own process status; the SDK header is not everywhere.
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif
#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

bool hd_may_run_unsigned_code(void) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags)) return false;
    return (flags & CS_DEBUGGED) != 0;
}
bool hd_debugger_attached(void) {
    struct kinfo_proc process;
    size_t size = sizeof process;
    int name[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(name, 4, &process, &size, NULL, 0) || size < sizeof process) return false;
    return (process.kp_proc.p_flag & P_TRACED) != 0;
}
static uint64_t footprint(void) {
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}
unsigned hd_protection(const void *address) {
    vm_address_t region = (vm_address_t)address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS) return 0;
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    // vm_region reports the next region at or above the address.
    if (region > (vm_address_t)address || (vm_address_t)address - region >= size) return 0;
    return (unsigned)info.protection;
}
bool hd_is_executable(const void *address) {
    return (hd_protection(address) & VM_PROT_EXECUTE) != 0;
}
void hd_collect(HostDiagnostics *report, bool probe_execution, FILE *log) {
    memset(report, 0, sizeof *report);
    report->debugger_attached = hd_debugger_attached();
    uint32_t flags = 0;
    if (!csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags)) {
        report->code_signing_known = true;
        report->code_signing_flags = flags;
        report->debugged = (flags & CS_DEBUGGED) != 0;
    }

    uint64_t memory = 0;
    size_t size = sizeof memory;
    if (!sysctlbyname("hw.memsize", &memory, &size, NULL, 0)) report->physical_memory = memory;
    report->footprint = footprint();
    report->page_size = (size_t)getpagesize();
    report->arena_limit = nc_arena_limit();
    report->available_memory = -1;
#if TARGET_OS_IPHONE
    report->available_memory = (int64_t)os_proc_available_memory();
#endif
    if (probe_execution && log) {
        report->execution_probed = true;
        report->write_then_execute = host_execution_probe(HP_WRITE_THEN_EXECUTE, log);
        report->read_write_execute = host_execution_probe(HP_READ_WRITE_EXECUTE, log);
        report->dual_mapping = host_execution_probe(HP_DUAL_MAPPING, log);
    }
}
__attribute__((format(printf, 4, 5)))
static size_t append(char *out, size_t size, size_t used, const char *format, ...) {
    size_t room = used < size ? size - used : 0;
    va_list arguments;
    va_start(arguments, format);
    int written = vsnprintf(room ? out + used : NULL, room, format, arguments);
    va_end(arguments);
    return written < 0 ? used : used + (size_t)written;
}
static double mib(uint64_t bytes) { return (double)bytes / (1024.0 * 1024.0); }
static size_t probe_line(char *out, size_t size, size_t used, const char *label, HPResult result) {
    return append(out, size, used, "  %-22s %s (execute again %s, alloc errno %d, protect errno %d)\n",
                  label, result.executable ? "PASS" : "DENIED",
                  result.rewrite_executable ? "PASS" : "DENIED",
                  result.allocation_errno, result.protection_errno);
}
size_t hd_format(const HostDiagnostics *report, char *out, size_t size) {
    if (out && size) out[0] = 0;
    size_t used = 0;
    used = append(out, size, used, "Process\n");
    used = append(out, size, used, "  debugger attached now  %s\n", report->debugger_attached ? "yes" : "no");
    if (report->code_signing_known)
        used = append(out, size, used, "  may run unsigned code  %s (flags %#x)\n",
                      report->debugged ? "yes, CS_DEBUGGED" : "no", report->code_signing_flags);
    else
        used = append(out, size, used, "  may run unsigned code  unknown\n");
    used = append(out, size, used, "\nMemory\n");
    used = append(out, size, used, "  physical               %.0f MiB\n", mib(report->physical_memory));
    used = append(out, size, used, "  this process now       %.1f MiB\n", mib(report->footprint));
    if (report->available_memory >= 0)
        used = append(out, size, used, "  left before we are killed %.1f MiB\n", mib((uint64_t)report->available_memory));
    else
        used = append(out, size, used, "  left before we are killed unknown here\n");
    used = append(out, size, used, "  page size              %zu bytes\n", report->page_size);
    used = append(out, size, used, "  largest guest arena    %.0f MiB\n", mib(report->arena_limit));
    used = append(out, size, used, "\nExecutable memory (our own two-instruction sample)\n");
    if (!report->execution_probed) return append(out, size, used, "  not probed\n");
    used = probe_line(out, size, used, "write then execute", report->write_then_execute);
    used = probe_line(out, size, used, "read/write/execute", report->read_write_execute);
    used = probe_line(out, size, used, "shared RW/RX views", report->dual_mapping);
    // Separate "the device refused" from "nobody prepared it".
    if (report->dual_mapping.executable)
        used = append(out, size, used, "\nThis process can run guest code now.\n");
    else if (report->debugged)
        used = append(out, size, used, "\nThis process may run unsigned code, but no debugger prepared the"
                                       " arena.\nIt needs one that answers the publication rendezvous.\n");
    else
        used = append(out, size, used, "\nThis process has not been prepared by a debugger, so guest code"
                                       " cannot run.\n");
    return used;
}
