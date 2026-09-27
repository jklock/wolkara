/*
 * Freestanding 32-bit x86 test program for the Wine runtime under Tolkara
 * (docs/WINDOWS.md, "On the iPad"). A program not marked NX-compatible runs
 * with data execution prevention off, as Windows runs old programs, so code
 * it writes into its own data runs: Heroes III's HotA and HD mod build code
 * that way. It imports nothing and reports through its exit code: 0 when the
 * code ran; with DEP wrongly on, the process ends with an access violation.
 *
 * Built with the LLVM mingw toolchain the runtime build downloads, without
 * the NX-compatible flag:
 *   build/windows-runtime/llvm-mingw/bin/i686-w64-mingw32-clang -O1 -nostdlib -nostartfiles \
 *       -Wl,--entry=_mainCRTStartup -Wl,--subsystem,console -Wl,--disable-nxcompat \
 *       testguest/windows/dep_probe.c -o build/windows-runtime/dep_probe.exe
 */
static unsigned char code[16] = { 0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3 };   /* mov eax, 42; ret */
int __attribute__((noinline)) mainCRTStartup(void) {
    int (*volatile written)(void) = (int (*)(void))(void *)code;
    return written() == 42 ? 0 : 1;
}
