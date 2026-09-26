/*
 * Windows test program for the Wine runtime under Tolkara (docs/WINDOWS.md).
 *
 * Built for x86-64 with the LLVM mingw toolchain the runtime build downloads:
 *   build/windows-runtime/llvm-mingw/bin/x86_64-w64-mingw32-clang -O1 -fms-extensions \
 *       testguest/windows/shared_data_probe.c -o build/windows-runtime/shared_data_probe.exe
 *
 * It checks what a program sees when KUSER_SHARED_DATA is not at 0x7ffe0000:
 * the APIs that read it through Wine's own pointer (GetTickCount64,
 * QueryPerformanceCounter, GetSystemTimeAsFileTime) must work, and a direct
 * read of 0x7ffe0000, which some programs hardcode, is reported rather than
 * assumed: on a host where nothing can be mapped there it faults, and that
 * tells us whether the emulator has to catch it.
 */
#include <windows.h>
#include <stdio.h>

static int read_fixed_address(void)
{
    __try
    {
        volatile const unsigned int *tick = (const unsigned int *)0x7ffe0320;  /* TickCount.LowPart */
        printf("direct read of 0x7ffe0000: ok, TickCount.LowPart=%u\n", *tick);
        return 1;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        printf("direct read of 0x7ffe0000: exception %08lx\n", GetExceptionCode());
        return 0;
    }
}

int main(void)
{
    LARGE_INTEGER counter, frequency;
    FILETIME time;
    ULONGLONG tick = GetTickCount64();

    printf("shared_data_probe: hello from x86-64 Windows code\n");
    printf("GetTickCount64: %llu ms\n", tick);
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&counter);
    printf("QueryPerformanceCounter: %lld at %lld Hz\n", counter.QuadPart, frequency.QuadPart);
    GetSystemTimeAsFileTime(&time);
    printf("GetSystemTimeAsFileTime: %08lx%08lx\n", time.dwHighDateTime, time.dwLowDateTime);
    Sleep(15);
    printf("GetTickCount64 after Sleep(15): +%llu ms\n", GetTickCount64() - tick);
    read_fixed_address();
    printf("shared_data_probe: done\n");
    return 0;
}
