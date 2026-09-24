#pragma once
#include "GuestImage.h"
#include <stdio.h>

// The libraries an application carries, loaded as it is.
enum { GL_MAX_LIBRARIES = 64 };

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
    const GuestImage *executable_image;   // its rpaths; the caller outlives the set
} GuestLinkSet;

// Breadth first; one that cannot be read is counted.
bool gl_load(GuestLinkSet *set, const GuestImage *executable, const char *executable_path,
             char *error, size_t error_size);
// Where an install name points inside the application, if anywhere.
bool gl_resolve(const GuestLinkSet *set, const GuestImage *from, const char *from_path,
                const char *name, char *out, size_t size);
// The carried library that answers a symbol, slide applied.
const GuestLibrary *gl_lookup(const GuestLinkSet *set, const GuestImage *from, const char *from_path,
                              const char *install_name, const char *symbol, uint64_t *value);
// Memory all the libraries need together, page aligned.
uint64_t gl_span(const GuestLinkSet *set);
void gl_destroy(GuestLinkSet *set);
void gl_report(const GuestLinkSet *set, FILE *out);
