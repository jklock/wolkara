#include "GuestLink.h"
#include <limits.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static bool fail(char *error, size_t size, const char *format, ...) {
    if (size) {
        va_list arguments;
        va_start(arguments, format);
        vsnprintf(error, size, format, arguments);
        va_end(arguments);
    }
    return false;
}
static void directory_of(const char *path, char *out, size_t size) {
    const char *slash = strrchr(path, '/');
    if (!slash || slash == path) { snprintf(out, size, "%s", slash ? "/" : "."); return; }
    size_t length = (size_t)(slash - path);
    if (length >= size) length = size - 1;
    memcpy(out, path, length);
    out[length] = 0;
}
// The application's folder: its bundle, or the executable's directory.
static void own_folder(const char *executable, char *out, size_t size) {
    const char *bundle = NULL;
    for (const char *at = executable; (at = strstr(at, "/Contents/MacOS/")); at++) bundle = at;
    if (!bundle) { directory_of(executable, out, size); return; }
    size_t length = (size_t)(bundle - executable);
    if (length >= size) length = size - 1;
    memcpy(out, executable, length);
    out[length] = 0;
}
static bool inside(const char *root, const char *path) {
    size_t length = strlen(root);
    if (strncmp(path, root, length)) return false;
    return path[length] == '/' || !path[length];
}
// The two prefixes a linker writes; @rpath is the caller's.
static bool expand(const GuestLinkSet *set, const char *from_path, const char *name,
                   char *out, size_t size) {
    char directory[PATH_MAX];
    // An rpath is often the prefix on its own.
    if (!strncmp(name, "@executable_path", 16) && (!name[16] || name[16] == '/')) {
        directory_of(set->executable, directory, sizeof directory);
        return snprintf(out, size, "%s%s", directory, name + 16) < (int)size;
    }
    if (!strncmp(name, "@loader_path", 12) && (!name[12] || name[12] == '/')) {
        directory_of(from_path ? from_path : set->executable, directory, sizeof directory);
        return snprintf(out, size, "%s%s", directory, name + 12) < (int)size;
    }
    if (name[0] == '@') return false;
    return snprintf(out, size, "%s", name) < (int)size;
}
// Resolve first: no link or ".." may leave the folder.
static bool accept(const GuestLinkSet *set, const char *candidate, char *out, size_t size) {
    char resolved[PATH_MAX];
    struct stat info;
    if (!realpath(candidate, resolved)) return false;
    if (stat(resolved, &info) || !S_ISREG(info.st_mode)) return false;
    if (!inside(set->root, resolved)) return false;
    return snprintf(out, size, "%s", resolved) < (int)size;
}

// Which carried library an image is; the set owns them.
static const GuestLibrary *library_of(const GuestLinkSet *set, const GuestImage *image) {
    for (size_t i = 0; i < set->count; i++)
        if (&set->libraries[i].image == image) return &set->libraries[i];
    return NULL;
}

bool gl_resolve(const GuestLinkSet *set, const GuestImage *from, const char *from_path,
                const char *name, char *out, size_t size) {
    if (!set || !set->root || !set->executable || !name || !out || !size) return false;
    char candidate[PATH_MAX];
    if (!strncmp(name, "@rpath/", 7)) {
        // The naming image's rpaths, then its loaders'.
        const GuestImage *image = from;
        const char *path = from_path;
        for (size_t step = 0; step <= set->count; step++) {
            for (size_t i = 0; image && i < image->rpath_count; i++) {
                char expanded[PATH_MAX];
                if (!expand(set, path, image->rpaths[i], expanded, sizeof expanded)) continue;
                if (snprintf(candidate, sizeof candidate, "%s/%s", expanded, name + 7) >= (int)sizeof candidate) continue;
                if (accept(set, candidate, out, size)) return true;
            }
            const GuestLibrary *library = library_of(set, image);
            if (!library) break;
            if (library->loader < set->count) {
                image = &set->libraries[library->loader].image;
                path = set->libraries[library->loader].path;
            } else {
                image = set->executable_image; path = set->executable;
            }
        }
        return false;
    }
    if (!expand(set, from_path, name, candidate, sizeof candidate)) return false;
    return accept(set, candidate, out, size);
}

static bool carried_by(GuestLinkSet *set, const GuestImage *from, const char *from_path,
                       char *error, size_t error_size) {
    const GuestLibrary *loader = library_of(set, from);
    size_t loader_index = loader ? (size_t)(loader - set->libraries) : GL_MAX_LIBRARIES;
    for (size_t i = 0; i < from->dylib_count; i++) {
        char path[PATH_MAX];
        if (!gl_resolve(set, from, from_path, from->dylibs[i], path, sizeof path)) continue;
        bool known = false;
        for (size_t j = 0; j < set->count && !known; j++) known = !strcmp(set->libraries[j].path, path);
        if (known) continue;
        if (set->count == GL_MAX_LIBRARIES)
            return fail(error, error_size, "the application carries more than %d libraries", GL_MAX_LIBRARIES);
        GuestLibrary *library = &set->libraries[set->count];
        if (!gi_load_library(path, &library->image, set->refusal, sizeof set->refusal)) {
            set->refused++;
            continue;
        }
        // Its thread-local storage cannot be set up: refused.
        if (library->image.tls_initializer_count) {
            snprintf(set->refusal, sizeof set->refusal, "%s needs thread-local constructors", from->dylibs[i]);
            gi_destroy(&library->image);
            set->refused++;
            continue;
        }
        library->path = strdup(path);
        library->install_name = strdup(from->dylibs[i]);
        library->loader = loader_index;
        if (!library->path || !library->install_name) {
            gi_destroy(&library->image);
            free(library->path); free(library->install_name);
            *library = (GuestLibrary){0};
            return fail(error, error_size, "cannot hold the library list");
        }
        set->count++;
    }
    return true;
}

bool gl_load(GuestLinkSet *set, const GuestImage *executable, const char *executable_path,
             char *error, size_t error_size) {
    if (error_size) error[0] = 0;
    if (!set || !executable || !executable_path) return fail(error, error_size, "invalid link set request");
    memset(set, 0, sizeof *set);
    char resolved[PATH_MAX], folder[PATH_MAX];
    if (!realpath(executable_path, resolved)) return fail(error, error_size, "cannot resolve the executable's own path");
    own_folder(resolved, folder, sizeof folder);
    set->executable = strdup(resolved);
    if (!realpath(folder, resolved)) { gl_destroy(set); return fail(error, error_size, "cannot resolve the application folder"); }
    set->root = strdup(resolved);
    set->executable_image = executable;
    if (!set->executable || !set->root) { gl_destroy(set); return fail(error, error_size, "cannot hold the link set"); }
    // The executable's list first, then each library's, as loaded.
    if (!carried_by(set, executable, set->executable, error, error_size)) { gl_destroy(set); return false; }
    for (size_t i = 0; i < set->count; i++)
        if (!carried_by(set, &set->libraries[i].image, set->libraries[i].path, error, error_size)) {
            gl_destroy(set); return false;
        }
    return true;
}

// Which carried library an install name of `from` points at.
static const GuestLibrary *carried_as(const GuestLinkSet *set, const GuestImage *from,
                                      const char *from_path, const char *install_name) {
    char path[PATH_MAX];
    if (!install_name || !gl_resolve(set, from, from_path, install_name, path, sizeof path)) return NULL;
    for (size_t i = 0; i < set->count; i++)
        if (!strcmp(set->libraries[i].path, path)) return &set->libraries[i];
    return NULL;
}
// What a library answers, following the re-exports it declares.
_Static_assert(GL_MAX_LIBRARIES <= 64, "the visited set is a 64-bit mask");
static const GuestLibrary *exported_by(const GuestLinkSet *set, const GuestLibrary *library,
                                       const char *symbol, uint64_t *value, uint64_t *visited) {
    uint64_t bit = 1ULL << (size_t)(library - set->libraries);
    if (*visited & bit) return NULL;
    *visited |= bit;
    GIExport found;
    char ignored[256];
    GIExportResult result = gi_export(&library->image, symbol, &found, ignored, sizeof ignored);
    if (result == GI_EXPORT_FOUND) {
        *value = found.absolute ? found.address : found.address + library->slide;
        return library;
    }
    if (result == GI_EXPORT_REEXPORT) {
        const GuestLibrary *defines = carried_as(set, &library->image, library->path,
                                                 library->image.dylibs[found.ordinal - 1]);
        return defines ? exported_by(set, defines, found.name ? found.name : symbol, value, visited) : NULL;
    }
    for (size_t i = 0; i < library->image.dylib_count; i++) {
        if (!library->image.dylib_reexports[i]) continue;
        const GuestLibrary *through = carried_as(set, &library->image, library->path, library->image.dylibs[i]);
        const GuestLibrary *answer = through ? exported_by(set, through, symbol, value, visited) : NULL;
        if (answer) return answer;
    }
    return NULL;
}

const GuestLibrary *gl_lookup(const GuestLinkSet *set, const GuestImage *from, const char *from_path,
                              const char *install_name, const char *symbol, uint64_t *value) {
    if (!set || !symbol || !value) return NULL;
    // The library the bind was linked against answers first.
    uint64_t visited = 0;
    const GuestLibrary *named = carried_as(set, from, from_path, install_name), *answer;
    if (named && (answer = exported_by(set, named, symbol, value, &visited))) return answer;
    // One already searched does not have the name either.
    for (size_t i = 0; i < set->count; i++)
        if ((answer = exported_by(set, &set->libraries[i], symbol, value, &visited))) return answer;
    return NULL;
}

uint64_t gl_span(const GuestLinkSet *set) {
    uint64_t total = 0;
    for (size_t i = 0; i < set->count; i++) total += gi_extent(&set->libraries[i].image, NULL);
    return total;
}

void gl_destroy(GuestLinkSet *set) {
    if (!set) return;
    for (size_t i = 0; i < set->count; i++) {
        gi_destroy(&set->libraries[i].image);
        free(set->libraries[i].path);
        free(set->libraries[i].install_name);
    }
    free(set->root);
    free(set->executable);
    memset(set, 0, sizeof *set);
}

void gl_report(const GuestLinkSet *set, FILE *out) {
    fprintf(out, "[link] the application carries %zu libraries of its own, %zu refused, needing %llu bytes\n",
            set->count, set->refused, (unsigned long long)gl_span(set));
    for (size_t i = 0; i < set->count; i++)
        fprintf(out, "[link] %-40s %s\n", set->libraries[i].install_name, set->libraries[i].path + strlen(set->root) + 1);
    if (set->refused) fprintf(out, "[link] last refusal: %s\n", set->refusal);
}
