#include "GuestPaths.h"
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

static int real_exists(const char *path, void *context) {
    (void)context;
    struct stat info;
    return lstat(path, &info) ? errno : 0;
}
static bool real_list(const char *directory, void (*found)(const char *, void *), void *state, void *context) {
    (void)context;
    DIR *listing = opendir(directory);
    if (!listing) return false;
    for (struct dirent *entry; (entry = readdir(listing));) found(entry->d_name, state);
    closedir(listing);
    return true;
}
static const GPFiles real_files = {real_exists, real_list, NULL};

// The entries of one directory that match a component ignoring case.
typedef struct { const char *name; size_t length; char match[NAME_MAX + 1]; unsigned matches; } Search;
static void consider(const char *name, void *state) {
    Search *search = state;
    if (strlen(name) != search->length || strncasecmp(name, search->name, search->length)) return;
    if (!search->matches++) memcpy(search->match, name, search->length + 1);
}

bool gp_case_insensitive(const GPFiles *files, const char *path, char *out, size_t size) {
    if (!files) files = &real_files;
    if (!path || !out || !size) return false;
    size_t total = strlen(path);
    if (!total || total >= size || total >= PATH_MAX) return false;
    memcpy(out, path, total + 1);
    bool changed = false;
    for (size_t start = 0; start < total;) {
        if (out[start] == '/') { start++; continue; }
        size_t end = start;
        while (end < total && out[end] != '/') end++;
        size_t length = end - start;
        bool dots = out[start] == '.' && (length == 1 || (length == 2 && out[start + 1] == '.'));
        if (!dots) {
            char saved = out[end];
            out[end] = 0;
            int error = files->exists(out, files->context);
            out[end] = saved;
            if (error == ENOENT) {
                // Look in the directory so far: "." when relative, "/" at the root.
                char directory[PATH_MAX];
                size_t prefix = start;
                while (prefix > 1 && out[prefix - 1] == '/') prefix--;
                if (!prefix) memcpy(directory, ".", 2);
                else { memcpy(directory, out, prefix); directory[prefix] = 0; }
                Search search = {out + start, length, {0}, 0};
                if (length > NAME_MAX || !files->list(directory, consider, &search, files->context) || search.matches != 1)
                    return false;
                memcpy(out + start, search.match, length);
                changed = true;
            } else if (error) return false;
        }
        start = end;
    }
    return changed;
}
