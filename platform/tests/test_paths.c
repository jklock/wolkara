#include "GuestPaths.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// A case-sensitive file system in memory, as on iPadOS.
static const char *const entries[] = {
    "/r", "/r/archive", "/r/archive/Mac", "/r/archive/Mac/base.archive", "/r/Data", "/r/data", "/r/data/x",
    "/r/file", "rel", "rel/Sub", "rel/Sub/f",
};
enum { ENTRIES = sizeof entries / sizeof *entries };
static int fake_exists(const char *path, void *context) {
    (void)context;
    if (!strcmp(path, "/")) return 0;
    if (!strncmp(path, "/r/file/", 8)) return ENOTDIR;
    for (size_t i = 0; i < ENTRIES; i++) if (!strcmp(entries[i], path)) return 0;
    return ENOENT;
}
static bool fake_list(const char *directory, void (*found)(const char *, void *), void *state, void *context) {
    int *listed = context;
    (*listed)++;
    bool any = !strcmp(directory, "/") || !strcmp(directory, ".");
    for (size_t i = 0; i < ENTRIES; i++) {
        const char *slash = strrchr(entries[i], '/');
        size_t length = slash ? (size_t)(slash - entries[i]) : 0;
        const char *parent = slash ? (length ? entries[i] : "/") : ".";
        size_t parent_length = slash ? (length ? length : 1) : 1;
        if (!strcmp(directory, entries[i])) any = true;
        if (strlen(directory) == parent_length && !strncmp(directory, parent, parent_length)) found(slash ? slash + 1 : entries[i], state);
    }
    return any;
}
static bool found_as(const GPFiles *files, const char *path, const char *expected) {
    char out[256];
    return gp_case_insensitive(files, path, out, sizeof out) && !strcmp(out, expected);
}

int main(void) {
    int listed = 0;
    GPFiles files = {fake_exists, fake_list, &listed};
    char out[256];

    // Each missing component takes the one entry that matches it ignoring case.
    assert(found_as(&files, "/r/archive/mac/base.archive", "/r/archive/Mac/base.archive"));
    assert(found_as(&files, "/r/ARCHIVE/mac/BASE.ARCHIVE", "/r/archive/Mac/base.archive"));
    // Structure is kept: repeated and trailing separators, dot components.
    assert(found_as(&files, "/r/archive/mac/", "/r/archive/Mac/"));
    assert(found_as(&files, "REL/sub/F", "rel/Sub/f"));
    // Only a missing component is looked up.
    listed = 0;
    assert(found_as(&files, "/r/archive/mac", "/r/archive/Mac") && listed == 1);
    // Nothing to replace: the original answer stands.
    assert(!gp_case_insensitive(&files, "/r/archive/Mac/base.archive", out, sizeof out));
    assert(!gp_case_insensitive(&files, "/r/data/x", out, sizeof out));
    // Missing in every case, or two entries differing only in case.
    assert(!gp_case_insensitive(&files, "/r/archive/mac/missing", out, sizeof out));
    assert(!gp_case_insensitive(&files, "/r/DATA/x", out, sizeof out));
    assert(!gp_case_insensitive(&files, "/r/Data/x", out, sizeof out));
    // Through a file, or a different length, is no match.
    assert(!gp_case_insensitive(&files, "/r/file/x", out, sizeof out));
    assert(!gp_case_insensitive(&files, "/r/archive/macs", out, sizeof out));
    // Bounds.
    assert(!gp_case_insensitive(&files, "/r/archive/mac", out, 14));
    assert(gp_case_insensitive(&files, "/r/archive/mac", out, 15) && !strcmp(out, "/r/archive/Mac"));
    assert(!gp_case_insensitive(&files, "", out, sizeof out));
    assert(!gp_case_insensitive(&files, NULL, out, sizeof out));
    assert(!gp_case_insensitive(&files, "/r/archive/mac", NULL, 0));
    char long_name[400];
    memset(long_name, 'a', sizeof long_name - 1); long_name[0] = '/'; long_name[sizeof long_name - 1] = 0;
    char wide[1024];
    assert(!gp_case_insensitive(&files, long_name, wide, sizeof wide));   // longer than NAME_MAX

    // The real file system: a name that exists is never replaced; on a
    // case-sensitive volume the other case is found.
    const char *temporary = getenv("TMPDIR");
    char root[512], directory[600], file[700], other[700];
    snprintf(root, sizeof root, "%s/tolkara-paths-XXXXXX", temporary && *temporary ? temporary : "/tmp");
    assert(mkdtemp(root));
    snprintf(directory, sizeof directory, "%s/Mac", root);
    snprintf(file, sizeof file, "%s/base.archive", directory);
    snprintf(other, sizeof other, "%s/mac/base.archive", root);
    assert(!mkdir(directory, 0700));
    FILE *created = fopen(file, "w"); assert(created); fclose(created);
    char real[1024];
    assert(!gp_case_insensitive(NULL, file, real, sizeof real));
    snprintf(other + strlen(other) - 7, 8, "missing");
    assert(!gp_case_insensitive(NULL, other, real, sizeof real));
    snprintf(other, sizeof other, "%s/mac/base.archive", root);
    if (pathconf(root, _PC_CASE_SENSITIVE) == 1) assert(gp_case_insensitive(NULL, other, real, sizeof real) && !strcmp(real, file));
    else assert(!gp_case_insensitive(NULL, other, real, sizeof real));
    unlink(file); rmdir(directory); rmdir(root);

    puts("PASS: case-insensitive path lookup: unique matches only, structure kept, bounds, real file system");
}
