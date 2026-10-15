/*
 * Freestanding 32-bit x86 test program for the Wine runtime under Tolkara
 * (docs/WINDOWS.md, "The 32-bit window"). It imports nothing, so it only
 * needs the 32-bit ntdll to start, and reports through its exit code: 0 when
 * every check passes, otherwise the number of the first failing check.
 *
 * Built with the LLVM mingw toolchain the runtime build downloads:
 *   build/windows-runtime/llvm-mingw/bin/i686-w64-mingw32-clang -O1 -nostdlib -nostartfiles \
 *       -Wl,--entry=_mainCRTStartup -Wl,--subsystem,console \
 *       testguest/windows/window32_probe.c -o build/windows-runtime/window32_probe.exe
 *
 * The checks cover what the address window changes in FEX's JIT: plain loads
 * and stores, the export-table style binary search with strcmp, string
 * instructions (rep movsb/stosb), 64-bit arithmetic, deep calls, push/pop,
 * fs-relative TEB reads and a locked read-modify-write.
 */
typedef unsigned int u32; typedef unsigned char u8; typedef unsigned long long u64;
static int __attribute__((noinline)) my_strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    if ((u8)*a > (u8)*b) return 1;
    if ((u8)*a < (u8)*b) return -1;
    return 0;
}
static const char *names[] = { "NtClose", "NtOpenFile", "RtlAllocateHeap", "RtlEnterCriticalSection", "RtlFreeHeap", "RtlLeaveCriticalSection", "strcmp", "wcslen" };
static int __attribute__((noinline)) bsearch_name(const char *name) {
    int min = 0, max = 7;
    while (min <= max) { int res, pos = (min + max) / 2; if (!(res = my_strcmp(names[pos], name))) return pos; if (res > 0) max = pos - 1; else min = pos + 1; }
    return -1;
}
static u32 __attribute__((noinline)) sum_array(const u32 *p, int n) { u32 s = 0; for (int i = 0; i < n; i++) s += p[i] * (i + 1); return s; }
static void __attribute__((noinline)) copy_bytes(u8 *dst, const u8 *src, u32 n) { __asm__ volatile("rep movsb" : "+D"(dst), "+S"(src), "+c"(n) : : "memory"); }
static void __attribute__((noinline)) set_bytes(u8 *dst, u8 v, u32 n) { __asm__ volatile("rep stosb" : "+D"(dst), "+c"(n) : "a"(v) : "memory"); }
static u64 __attribute__((noinline)) mul64(u64 a, u64 b) { return a * b + (a >> 3); }
static int __attribute__((noinline)) deep(int n) { volatile int local[8]; for (int i = 0; i < 8; i++) local[i] = n + i; return n ? deep(n - 1) + local[7] : 0; }
static u32 __attribute__((noinline)) pushpop(u32 a, u32 b) { u32 r; __asm__ volatile("pushl %1\n\tpushl %2\n\tpopl %%eax\n\tpopl %%edx\n\taddl %%edx, %%eax\n\tpushl %%eax\n\tpushl %%eax\n\tpopl %%eax\n\tpopl %%edx\n\tsubl %%edx, %%eax\n\tmovl %%eax, %0" : "=r"(r) : "r"(a), "r"(b) : "eax", "edx", "memory"); return r; }
static u32 __attribute__((noinline)) fs_teb_self(void) { u32 v; __asm__ volatile("movl %%fs:0x18, %0" : "=r"(v)); return v; }
static u32 __attribute__((noinline)) fs_stack_base(void) { u32 v; __asm__ volatile("movl %%fs:0x4, %0" : "=r"(v)); return v; }
static u32 __attribute__((noinline)) xchg_add(u32 *p, u32 v) { u32 r = v; __asm__ volatile("lock xaddl %0, %1" : "+r"(r), "+m"(*p) : : "memory"); return r; }
int __attribute__((noinline)) run(void) {
    static u32 arr[16]; static u8 buf1[64], buf2[64]; static u32 counter = 5;
    if (my_strcmp("abc", "abc") != 0 || my_strcmp("abc", "abd") != -1 || my_strcmp("abd", "abc") != 1) return 1;
    if (bsearch_name("RtlEnterCriticalSection") != 3) return 2;
    if (bsearch_name("NtClose") != 0 || bsearch_name("wcslen") != 7 || bsearch_name("zzz") != -1) return 3;
    for (int i = 0; i < 16; i++) arr[i] = i * 3;
    if (sum_array(arr, 16) != 4080) return 4;
    for (int i = 0; i < 64; i++) buf1[i] = (u8)(i * 7);
    copy_bytes(buf2, buf1, 64);
    for (int i = 0; i < 64; i++) if (buf2[i] != (u8)(i * 7)) return 5;
    set_bytes(buf2, 0xa5, 64);
    for (int i = 0; i < 64; i++) if (buf2[i] != 0xa5) return 6;
    if (mul64(0x100000001ULL, 0x300000007ULL) != 0x100000001ULL * 0x300000007ULL + (0x100000001ULL >> 3)) return 7;
    if (deep(10) != 10 + 9 + 8 + 7 + 6 + 5 + 4 + 3 + 2 + 1 + 70) return 8;
    if (pushpop(100, 23) != 0) return 9;
    u32 teb = fs_teb_self();
    if (teb == 0 || (teb & 0xfff) != 0) return 10;
    if (fs_stack_base() <= teb - 0x100000 && fs_stack_base() != 0) { /* stack base is a guest address; just require non-zero */ }
    if (fs_stack_base() == 0) return 11;
    if (xchg_add(&counter, 10) != 5 || counter != 15) return 12;
    return 0;
}
int __attribute__((noinline)) mainCRTStartup(void) { return run(); }
