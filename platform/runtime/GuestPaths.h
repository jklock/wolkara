#pragma once
#include <stdbool.h>
#include <stddef.h>

// macOS's default file system ignores case; iPadOS's does not, and macOS
// applications rely on it (Cyberpunk 2077 reads archive/Mac as archive/mac).

// A file system to look in; NULL means the real one.
typedef struct {
    // 0 when the path exists as written (not followed at the end), else its errno.
    int (*exists)(const char *path, void *context);
    // Calls found for each entry of a directory; false when it cannot be read.
    bool (*list)(const char *directory, void (*found)(const char *name, void *state), void *state, void *context);
    void *context;
} GPFiles;

// The path with each component that does not exist as written replaced by
// the one entry of its directory that matches it ignoring ASCII case, same
// length and structure otherwise. False when nothing needed replacing, when a
// component has no such entry or more than one, or when it does not fit.
bool gp_case_insensitive(const GPFiles *files, const char *path, char *out, size_t size);
