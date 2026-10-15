#include "GuestLink.h"
#include <limits.h>
#include <mach-o/loader.h>
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

static bool known_path(const GuestLinkSet *set, const char *path) {
    for (size_t i = 0; i < set->count; i++) if (!strcmp(set->libraries[i].path, path)) return true;
    return false;
}
// One more carried library, read from `path` (resolved, inside the folder). One
// that cannot be read is counted and skipped; false only when the list is full.
static bool carry(GuestLinkSet *set, const char *path, const char *install_name, size_t loader_index,
                  char *error, size_t error_size) {
    if (set->count == GL_MAX_LIBRARIES)
        return fail(error, error_size, "the application carries more than %d libraries", GL_MAX_LIBRARIES);
    GuestLibrary *library = &set->libraries[set->count];
    if (!gi_load_library(path, &library->image, set->refusal, sizeof set->refusal)) {
        set->refused++;
        return true;
    }
    // Its thread-local storage cannot be set up: refused.
    if (library->image.tls_initializer_count) {
        snprintf(set->refusal, sizeof set->refusal, "%s needs thread-local constructors", install_name);
        gi_destroy(&library->image);
        set->refused++;
        return true;
    }
    library->path = strdup(path);
    library->install_name = strdup(install_name);
    library->loader = loader_index;
    if (!library->path || !library->install_name) {
        gi_destroy(&library->image);
        free(library->path); free(library->install_name);
        *library = (GuestLibrary){0};
        return fail(error, error_size, "cannot hold the library list");
    }
    set->count++;
    return true;
}
static bool carried_by(GuestLinkSet *set, const GuestImage *from, const char *from_path,
                       char *error, size_t error_size) {
    const GuestLibrary *loader = library_of(set, from);
    size_t loader_index = loader ? (size_t)(loader - set->libraries) : GL_MAX_LIBRARIES;
    for (size_t i = 0; i < from->dylib_count; i++) {
        char path[PATH_MAX];
        if (!gl_resolve(set, from, from_path, from->dylibs[i], path, sizeof path)) continue;
        if (known_path(set, path)) continue;
        if (!carry(set, path, from->dylibs[i], loader_index, error, error_size)) return false;
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

bool gl_carry(GuestLinkSet *set, const char *root, const char *const *paths, size_t count,
              char *error, size_t error_size) {
    if (error_size) error[0] = 0;
    if (!set || !set->executable || !set->root || (count && !paths)) return fail(error, error_size, "invalid link set request");
    if (root) {
        char resolved[PATH_MAX];
        if (!realpath(root, resolved)) return fail(error, error_size, "cannot resolve the runtime folder");
        if (!inside(resolved, set->root)) return fail(error, error_size, "the runtime folder does not hold the executable");
        char *wider = strdup(resolved);
        if (!wider) return fail(error, error_size, "cannot hold the link set");
        free(set->root);
        set->root = wider;
    }
    size_t first = set->count;
    for (size_t i = 0; i < count; i++) {
        char path[PATH_MAX];
        if (!paths[i] || paths[i][0] != '/' || !accept(set, paths[i], path, sizeof path))
            return fail(error, error_size, "%s is not a file inside the application", paths[i] ? paths[i] : "(null)");
        if (known_path(set, path)) continue;
        if (!carry(set, path, path, GL_MAX_LIBRARIES, error, error_size)) return false;
    }
    // Then what those link, as for the executable's own.
    for (size_t i = first; i < set->count; i++)
        if (!carried_by(set, &set->libraries[i].image, set->libraries[i].path, error, error_size)) return false;
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
// One image's answer: where the name is, whether it is a weak definition, and
// who answered (a carried library's install name, or GL_EXECUTABLE).
typedef struct { uint64_t value; bool weak; const char *name; } Answer;
_Static_assert(GL_MAX_LIBRARIES <= 64, "the visited set is a 64-bit mask");
static bool library_export(const GuestLinkSet *set, const GuestLibrary *library, const char *symbol,
                           bool shallow, Answer *answer, uint64_t *visited);
// What an image exports, following a trie re-export into the carried library it
// names. Unless shallow, also the libraries it re-exports whole
// (LC_REEXPORT_DYLIB); dyld's weak-definition lookup does not follow those.
static bool image_export(const GuestLinkSet *set, const GuestImage *image, const char *path, uint64_t slide,
                         const char *name, const char *symbol, bool shallow, Answer *answer, uint64_t *visited) {
    GIExport found;
    char ignored[256];
    GIExportResult result = gi_export(image, symbol, &found, ignored, sizeof ignored);
    if (result == GI_EXPORT_FOUND) {
        *answer = (Answer){found.absolute ? found.address : found.address + slide, found.weak, name};
        return true;
    }
    if (result == GI_EXPORT_REEXPORT) {
        const GuestLibrary *defines = carried_as(set, image, path, image->dylibs[found.ordinal - 1]);
        return defines && library_export(set, defines, found.name ? found.name : symbol, false, answer, visited);
    }
    for (size_t i = 0; !shallow && i < image->dylib_count; i++) {
        if (!image->dylib_reexports[i]) continue;
        const GuestLibrary *through = carried_as(set, image, path, image->dylibs[i]);
        if (through && library_export(set, through, symbol, false, answer, visited)) return true;
    }
    return false;
}
static bool library_export(const GuestLinkSet *set, const GuestLibrary *library, const char *symbol,
                           bool shallow, Answer *answer, uint64_t *visited) {
    uint64_t bit = 1ULL << (size_t)(library - set->libraries);
    if (*visited & bit) return false;
    *visited |= bit;
    return image_export(set, &library->image, library->path, library->slide, library->install_name,
                        symbol, shallow, answer, visited);
}
static bool executable_export(const GuestLinkSet *set, const char *symbol, bool shallow,
                              Answer *answer, uint64_t *visited) {
    return set->executable_image &&
           image_export(set, set->executable_image, set->executable, set->executable_slide, GL_EXECUTABLE,
                        symbol, shallow, answer, visited);
}
// dyld's weak-definition coalescing: of the images that have weak definitions,
// in load order (the executable first), the first non-weak definition wins,
// otherwise the first weak one. Failing both, the binding image's own export.
static bool coalesce(const GuestLinkSet *set, const GuestImage *from, const char *symbol, Answer *answer) {
    bool found = false;
    for (size_t i = 0; i <= set->count; i++) {
        const GuestImage *image = i ? &set->libraries[i - 1].image : set->executable_image;
        if (!image || !image->weak_defines) continue;
        Answer candidate;
        uint64_t visited = 0;
        if (!(i ? library_export(set, &set->libraries[i - 1], symbol, true, &candidate, &visited)
                : executable_export(set, symbol, true, &candidate, &visited))) continue;
        if (!candidate.weak) { *answer = candidate; return true; }
        if (!found) { *answer = candidate; found = true; }
    }
    if (found) return true;
    uint64_t visited = 0;
    if (from == set->executable_image) return executable_export(set, symbol, false, answer, &visited);
    const GuestLibrary *self = library_of(set, from);
    return self && library_export(set, self, symbol, false, answer, &visited);
}

const GuestLibrary *gl_carried(const GuestLinkSet *set, const GuestImage *from, const char *from_path,
                               const char *install_name) {
    return set && from ? carried_as(set, from, from_path, install_name) : NULL;
}

bool gl_lookup(const GuestLinkSet *set, const GuestImage *from, const char *from_path,
               int ordinal, const char *symbol, uint64_t *value, const char **answered_by) {
    const char *unused;
    if (!answered_by) answered_by = &unused;
    *answered_by = NULL;
    if (!set || !from || !symbol || !value) return false;
    Answer answer = {0};
    uint64_t visited = 0;
    bool found = false;
    // Two-level namespace: the library the bind names answers, or none of ours does.
    if (ordinal > 0) {
        if ((size_t)ordinal > from->dylib_count) return false;
        const GuestLibrary *named = carried_as(set, from, from_path, from->dylibs[ordinal - 1]);
        found = named && library_export(set, named, symbol, false, &answer, &visited);
    } else if (ordinal == BIND_SPECIAL_DYLIB_MAIN_EXECUTABLE ||
               (ordinal == BIND_SPECIAL_DYLIB_SELF && from == set->executable_image)) {
        found = executable_export(set, symbol, false, &answer, &visited);
    } else if (ordinal == BIND_SPECIAL_DYLIB_SELF) {
        // A carried library binding to itself.
        const GuestLibrary *self = library_of(set, from);
        found = self && library_export(set, self, symbol, false, &answer, &visited);
    } else if (ordinal == BIND_SPECIAL_DYLIB_FLAT_LOOKUP) {
        // dyld's load order: the executable first, then its libraries as loaded.
        found = executable_export(set, symbol, false, &answer, &visited);
        for (size_t i = 0; i < set->count && !found; i++)
            found = library_export(set, &set->libraries[i], symbol, false, &answer, &visited);
    } else if (ordinal == BIND_SPECIAL_DYLIB_WEAK_LOOKUP) {
        found = coalesce(set, from, symbol, &answer);
    }
    if (!found) return false;
    *value = answer.value;
    *answered_by = answer.name;
    return true;
}

// A library once its dependencies are in the order; `seen` cuts cycles.
static void initialize_after(const GuestLinkSet *set, size_t index, uint64_t *seen, size_t *order, size_t *count) {
    if (*seen & (1ULL << index)) return;
    *seen |= 1ULL << index;
    const GuestLibrary *library = &set->libraries[index];
    for (size_t i = 0; i < library->image.dylib_count; i++) {
        const GuestLibrary *needed = carried_as(set, &library->image, library->path, library->image.dylibs[i]);
        if (needed) initialize_after(set, (size_t)(needed - set->libraries), seen, order, count);
    }
    order[(*count)++] = index;
}

size_t gl_initialization_order(const GuestLinkSet *set, size_t order[GL_MAX_LIBRARIES]) {
    if (!set || !order) return 0;
    uint64_t seen = 0;
    size_t count = 0;
    const GuestImage *executable = set->executable_image;
    for (size_t i = 0; executable && i < executable->dylib_count; i++) {
        const GuestLibrary *needed = carried_as(set, executable, set->executable, executable->dylibs[i]);
        if (needed) initialize_after(set, (size_t)(needed - set->libraries), &seen, order, &count);
    }
    for (size_t i = 0; i < set->count; i++) initialize_after(set, i, &seen, order, &count);
    return count;
}

static bool same_leaf(const char *path, const char *leaf) {
    if (!path) return false;
    const char *slash = strrchr(path, '/');
    return !strcmp(slash ? slash + 1 : path, leaf);
}
bool gl_placed(const GuestLinkSet *set, const GuestImage *from, const char *from_path, const char *name, size_t *index) {
    if (!set || !set->executable || !name || !*name || !index) return false;
    if (!strchr(name, '/')) {
        for (size_t i = 0; i <= set->count; i++) {
            const GuestLibrary *library = i ? &set->libraries[i - 1] : NULL;
            if (same_leaf(library ? library->path : set->executable, name) ||
                (library && same_leaf(library->install_name, name))) { *index = i; return true; }
        }
        return false;
    }
    char resolved[PATH_MAX];
    if (!gl_resolve(set, from, from_path, name, resolved, sizeof resolved)) return false;
    for (size_t i = 0; i <= set->count; i++)
        if (!strcmp(i ? set->libraries[i - 1].path : set->executable, resolved)) { *index = i; return true; }
    return false;
}

bool gl_inside(const GuestLinkSet *set, const char *path) {
    if (!set || !set->root || !path) return false;
    if (path[0] == '@') return true;
    char real[PATH_MAX];
    return realpath(path, real) && inside(set->root, real);
}

const GuestLibrary *gl_library_at(const GuestLinkSet *set, uint64_t address) {
    for (size_t i = 0; set && i < set->count; i++) {
        const GuestLibrary *library = &set->libraries[i];
        uint64_t low, reach = gi_extent(&library->image, &low), base = low + library->slide;
        if (library->slide && address >= base && address - base < reach) return library;
    }
    return NULL;
}

// A framework binary's path without its /Versions/<v>/ parts.
static bool unversioned(const char *name, char *out, size_t size) {
    static const char marker[] = ".framework/Versions/";
    size_t used = 0;
    for (const char *at; (at = strstr(name, marker));) {
        const char *version = at + sizeof marker - 1, *rest = strchr(version, '/');
        if (!rest || rest == version) break;
        size_t keep = (size_t)(at - name) + strlen(".framework");
        if (used + keep >= size) return false;
        memcpy(out + used, name, keep);
        used += keep;
        name = rest;
    }
    return snprintf(out + used, size - used, "%s", name) < (int)(size - used);
}
bool gl_same_install_name(const char *a, const char *b) {
    if (!a || !b) return false;
    if (!strcmp(a, b)) return true;
    char plain_a[PATH_MAX], plain_b[PATH_MAX];
    return unversioned(a, plain_a, sizeof plain_a) && unversioned(b, plain_b, sizeof plain_b) && !strcmp(plain_a, plain_b);
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
