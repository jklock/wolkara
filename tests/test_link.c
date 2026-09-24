#include "GuestLink.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void make(const char *path) { assert(!mkdir(path, 0700) || errno == EEXIST); }
static void touch(const char *path) { FILE *file = fopen(path, "w"); assert(file); fputc('x', file); fclose(file); }

int main(void) {
    // Temporary space from TMPDIR, as the suite sets it.
    const char *temporary = getenv("TMPDIR");
    char root[512];
    snprintf(root, sizeof root, "%s/tolkara-link-XXXXXX", temporary && *temporary ? temporary : "/tmp");
    assert(mkdtemp(root));
    char bundle[512], contents[512], macos[512], frameworks[512];
    char executable[512], carried[512], outside[512], out[512];
    snprintf(bundle, sizeof bundle, "%s/App.app", root);
    snprintf(contents, sizeof contents, "%s/Contents", bundle);
    snprintf(macos, sizeof macos, "%s/MacOS", contents);
    snprintf(frameworks, sizeof frameworks, "%s/Frameworks", contents);
    make(bundle); make(contents); make(macos); make(frameworks);
    snprintf(executable, sizeof executable, "%s/App", macos);
    snprintf(carried, sizeof carried, "%s/libcarried.dylib", frameworks);
    snprintf(outside, sizeof outside, "%s/elsewhere.dylib", root);
    touch(executable); touch(carried); touch(outside);

    // The root may be a link; resolve as gl_load does.
    char resolved_bundle[512], resolved_executable[512];
    assert(realpath(bundle, resolved_bundle) && realpath(executable, resolved_executable));
    GuestLinkSet set = {0};
    set.root = strdup(resolved_bundle);
    set.executable = strdup(resolved_executable);
    assert(set.root && set.executable);
    GuestImage from = {0};
    char rpath[] = "@executable_path/../Frameworks";
    from.rpath_count = 1;
    from.rpaths[0] = rpath;

    // The usual shape: @rpath expanded through the image's own rpath.
    char resolved_carried[512];
    assert(realpath(carried, resolved_carried));
    assert(gl_resolve(&set, &from, executable, "@rpath/libcarried.dylib", out, sizeof out));
    assert(!strcmp(out, resolved_carried));
    // Relative to whichever image is asking, and to the executable.
    assert(gl_resolve(&set, &from, carried, "@loader_path/libcarried.dylib", out, sizeof out));
    assert(!strcmp(out, resolved_carried));
    assert(gl_resolve(&set, &from, executable, "@executable_path/../Frameworks/libcarried.dylib", out, sizeof out));
    assert(!strcmp(out, resolved_carried));
    // An absolute path inside the application is still the application's.
    assert(gl_resolve(&set, &from, executable, carried, out, sizeof out));

    // Nothing outside the application is ever opened.
    assert(!gl_resolve(&set, &from, executable, "/usr/lib/libSystem.B.dylib", out, sizeof out));
    assert(!gl_resolve(&set, &from, executable, outside, out, sizeof out));
    assert(!gl_resolve(&set, &from, executable, "@executable_path/../../elsewhere.dylib", out, sizeof out));
    assert(!gl_resolve(&set, &from, executable, "@rpath/../../elsewhere.dylib", out, sizeof out));
    // Nor a directory, a name resolving nowhere, or bare @rpath.
    assert(!gl_resolve(&set, &from, executable, frameworks, out, sizeof out));
    assert(!gl_resolve(&set, &from, executable, "@rpath/absent.dylib", out, sizeof out));
    GuestImage bare = {0};
    assert(!gl_resolve(&set, &bare, executable, "@rpath/libcarried.dylib", out, sizeof out));
    // An unknown prefix is not guessed at.
    assert(!gl_resolve(&set, &from, executable, "@unknown_path/libcarried.dylib", out, sizeof out));
    // An rpath is often the prefix on its own.
    char loader[] = "@loader_path", own[] = "@executable_path";
    GuestImage prefix = {0};
    prefix.rpath_count = 1;
    prefix.rpaths[0] = loader;
    assert(gl_resolve(&set, &prefix, carried, "@rpath/libcarried.dylib", out, sizeof out));
    assert(!strcmp(out, resolved_carried));
    prefix.rpaths[0] = own;
    assert(gl_resolve(&set, &prefix, carried, "@rpath/App", out, sizeof out));
    assert(!strcmp(out, resolved_executable));

    // No rpath of its own: resolved through its loader's.
    GuestImage main_image = {0};
    main_image.rpath_count = 1;
    main_image.rpaths[0] = rpath;
    set.executable_image = &main_image;
    set.count = 1;
    set.libraries[0].path = strdup(resolved_carried);
    set.libraries[0].install_name = strdup("@rpath/libcarried.dylib");
    set.libraries[0].loader = GL_MAX_LIBRARIES;
    assert(set.libraries[0].path && set.libraries[0].install_name);
    assert(gl_resolve(&set, &set.libraries[0].image, set.libraries[0].path,
                      "@rpath/libcarried.dylib", out, sizeof out));
    assert(!strcmp(out, resolved_carried));
    // The chain ends at the executable and reaches nothing outside.
    assert(!gl_resolve(&set, &set.libraries[0].image, set.libraries[0].path,
                       "@rpath/elsewhere.dylib", out, sizeof out));

    gl_destroy(&set);
    assert(!set.root && !set.executable && !set.count && !set.executable_image);
    unlink(executable); unlink(carried); unlink(outside);
    rmdir(macos); rmdir(frameworks); rmdir(contents); rmdir(bundle); rmdir(root);

    // What an image occupies, measured from its lowest mapped segment.
    static GuestImage gap = {.header_address = 0, .segment_count = 2};
    gap.segments[0] = (GISegment){.name = "__TEXT", .address = 0, .size = 0x4000, .prot = 5};
    gap.segments[1] = (GISegment){.name = "__DATA", .address = 0x10000, .size = 0x4000, .prot = 3};
    uint64_t low = 1;
    assert(gi_extent(&gap, &low) == 0x14000 && low == 0);
    // A segment below the header still counts.
    static GuestImage below = {.header_address = 0x8000, .segment_count = 2};
    below.segments[0] = (GISegment){.name = "__DATA", .address = 0, .size = 0x4000, .prot = 3};
    below.segments[1] = (GISegment){.name = "__TEXT", .address = 0x8000, .size = 0x4000, .prot = 5};
    assert(gi_extent(&below, &low) == 0xC000 && low == 0);
    // Nothing mapped: nothing needed, measured from the header.
    static GuestImage empty = {.header_address = 0x4000, .segment_count = 1};
    empty.segments[0] = (GISegment){.name = "__PAGEZERO", .address = 0, .size = 0x100000000ULL};
    assert(gi_extent(&empty, &low) == 0 && low == 0x4000);
    // The report and the arena add up the same measure.
    static GuestLinkSet measured = {.count = 2};
    measured.libraries[0].image = gap; measured.libraries[1].image = below;
    assert(gl_span(&measured) == 0x14000 + 0xC000);

    puts("PASS: carried library paths resolve inside the application only (@rpath, @loader_path, @executable_path),"
         " extent from the lowest mapped segment");
}
