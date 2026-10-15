#pragma once
#include "GuestImage.h"
#include <stdio.h>

// The libraries an application carries, loaded as it is.
enum { GL_MAX_LIBRARIES = 64 };
// What gl_lookup names when the executable itself answers.
#define GL_EXECUTABLE "<executable>"

typedef struct {
    GuestImage image;
    char *path;           // the file it was read from
    char *install_name;   // what the image that needed it calls it
    size_t loader;        // the library that first needed it, GL_MAX_LIBRARIES for the executable
    uint64_t slide;       // set when the arena is laid out; zero until then
} GuestLibrary;

typedef struct {
    GuestLibrary libraries[GL_MAX_LIBRARIES];
    size_t count;
    size_t refused;       // carried, but not readable as an image
    char refusal[256];    // why the last of those was refused
    char *root;           // nothing outside this folder is ever opened
    char *executable;
    const GuestImage *executable_image;   // its rpaths and exports; the caller outlives the set
    uint64_t executable_slide;            // set with the libraries' slides
} GuestLinkSet;

// Breadth first; one that cannot be read is counted.
bool gl_load(GuestLinkSet *set, const GuestImage *executable, const char *executable_path,
             char *error, size_t error_size);
// Libraries named beside the executable's own list, for a compatibility
// runtime that opens its libraries by path at run time rather than linking
// them: after gl_load, each absolute path (resolved, inside the folder) is
// carried like a library the executable links, then what it links. A non-NULL
// root, a folder that holds the executable, becomes the application folder.
// Unreadable ones are counted as for gl_load; false when a path is not inside,
// or the list is full.
bool gl_carry(GuestLinkSet *set, const char *root, const char *const *paths, size_t count,
              char *error, size_t error_size);
// Where an install name points inside the application, if anywhere.
bool gl_resolve(const GuestLinkSet *set, const GuestImage *from, const char *from_path,
                const char *name, char *out, size_t size);
// The carried library an install name of `from` points at, if any.
const GuestLibrary *gl_carried(const GuestLinkSet *set, const GuestImage *from, const char *from_path,
                               const char *install_name);
// Whether the application itself answers a bind of `from`, slide applied, and
// who: a carried library's install name or GL_EXECUTABLE. A positive ordinal
// asks only the carried library it names (two-level namespace); the main
// executable ordinal, and self in the executable, ask the executable; flat and
// weak lookups ask the executable, then every carried library in load order
// (weak ones as dyld coalesces: the first non-weak definition wins).
bool gl_lookup(const GuestLinkSet *set, const GuestImage *from, const char *from_path,
               int ordinal, const char *symbol, uint64_t *value, const char **answered_by);
// dyld's initialization order: each library after the carried libraries it
// links, depth first from the executable's list, each once (a cycle is cut
// where it closes); libraries nothing reaches follow in load order. Fills
// order with indices into libraries; returns how many, set->count.
size_t gl_initialization_order(const GuestLinkSet *set, size_t order[GL_MAX_LIBRARIES]);
// The application's own dlopen of an image this set holds, by any name dyld
// takes: a leaf name (of its file or, for a library, its install name), a
// path, or @rpath/@loader_path/@executable_path from `from`. *index: 0 the
// executable, n carried library n-1.
bool gl_placed(const GuestLinkSet *set, const GuestImage *from, const char *from_path, const char *name,
               size_t *index);
// Whether a dlopen names the application's own code, which only this loader
// places: an @ name (it resolves only against the application), or a path
// that resolves inside the application's folder.
bool gl_inside(const GuestLinkSet *set, const char *path);
// The carried library an address lies in, once the libraries are placed.
const GuestLibrary *gl_library_at(const GuestLinkSet *set, uint64_t address);
// Whether two install names name the same file, a framework's /Versions/<v>/
// aside (a dlopen may leave it out).
bool gl_same_install_name(const char *a, const char *b);
// Memory all the libraries need together, page aligned.
uint64_t gl_span(const GuestLinkSet *set);
void gl_destroy(GuestLinkSet *set);
void gl_report(const GuestLinkSet *set, FILE *out);
