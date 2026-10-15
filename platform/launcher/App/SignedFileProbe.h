#ifndef SignedFileProbe_h
#define SignedFileProbe_h
#include <stdbool.h>
#include <stdio.h>

// Maps a Mach-O file from disk and exercises one execution strategy against its
// first __TEXT,__text function. Modes: inspect (map read-only, parse and log,
// no execution), exec (mmap RX + call), mprotect (mmap R + mprotect RX + call),
// write (mmap RX + mprotect RW + write + call), dlopen (control), remap,
// remapwrite, execafter, fcntl, self. An unknown mode fails without mapping.
// The result is logged as "[signed-file] result=PASS" or "=FAIL".
bool HostSignedFileProbe(const char *path, const char *mode, unsigned expected, FILE *log);

#endif
