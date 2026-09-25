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
    // Temporary space from TMPDIR, else /tmp.
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

    // The application's own dlopen: what it carries is the placed image, by
    // leaf, path, or a prefix from the calling image; 0 is the executable.
    size_t index = 99;
    assert(gl_placed(&set, &main_image, executable, "libcarried.dylib", &index) && index == 1);
    assert(gl_placed(&set, &main_image, executable, "App", &index) && index == 0);
    assert(gl_placed(&set, &main_image, executable, "@rpath/libcarried.dylib", &index) && index == 1);
    assert(gl_placed(&set, &main_image, executable, carried, &index) && index == 1);
    assert(gl_placed(&set, &main_image, executable, executable, &index) && index == 0);
    assert(gl_placed(&set, &main_image, executable, "@executable_path/App", &index) && index == 0);
    assert(gl_placed(&set, &set.libraries[0].image, set.libraries[0].path, "@loader_path/../MacOS/App", &index) &&
           index == 0);
    // The leaf of an install name that differs from the file's.
    free(set.libraries[0].install_name);
    set.libraries[0].install_name = strdup("@rpath/libnamed.1.dylib");
    assert(set.libraries[0].install_name);
    assert(gl_placed(&set, &main_image, executable, "libnamed.1.dylib", &index) && index == 1);
    // Anything else is not placed: another name, a file outside, the system, nothing.
    index = 99;
    assert(!gl_placed(&set, &main_image, executable, "libother.dylib", &index));
    assert(!gl_placed(&set, &main_image, executable, outside, &index));
    assert(!gl_placed(&set, &main_image, executable, "/usr/lib/libSystem.B.dylib", &index));
    assert(!gl_placed(&set, &main_image, executable, "@rpath/absent.dylib", &index));
    assert(!gl_placed(&set, &main_image, executable, "", &index) && !gl_placed(&set, &main_image, executable, NULL, &index));
    assert(!gl_placed(NULL, &main_image, executable, "App", &index) && index == 99);
    // Code inside the application is only ever placed: @ names and paths that
    // resolve inside, even through a link, are its own; the rest is not.
    char inward[512], outward[512];
    snprintf(inward, sizeof inward, "%s/inward.dylib", root);
    snprintf(outward, sizeof outward, "%s/outward.dylib", frameworks);
    assert(!symlink(carried, inward) && !symlink(outside, outward));
    assert(gl_inside(&set, "@rpath/anything.dylib") && gl_inside(&set, "@executable_path/../Frameworks/x.dylib"));
    assert(gl_inside(&set, carried) && gl_inside(&set, executable) && gl_inside(&set, frameworks) && gl_inside(&set, inward));
    assert(!gl_inside(&set, outside) && !gl_inside(&set, outward) && !gl_inside(&set, root));
    assert(!gl_inside(&set, "/usr/lib/libSystem.B.dylib") && !gl_inside(&set, "/nonexistent/lib.dylib"));
    assert(!gl_inside(&set, NULL) && !gl_inside(NULL, carried));
    unlink(inward); unlink(outward);

    // A framework's /Versions/<v>/ may be left out of a dlopen.
    assert(gl_same_install_name("/System/Library/Frameworks/Metal.framework/Versions/A/Metal",
                                "/System/Library/Frameworks/Metal.framework/Metal"));
    assert(gl_same_install_name("/S/OpenGL.framework/Versions/Current/OpenGL", "/S/OpenGL.framework/Versions/A/OpenGL"));
    assert(gl_same_install_name("/S/A.framework/Versions/B/Frameworks/C.framework/Versions/D/C",
                                "/S/A.framework/Frameworks/C.framework/C"));
    assert(gl_same_install_name("/usr/lib/libz.1.dylib", "/usr/lib/libz.1.dylib"));
    assert(!gl_same_install_name("/usr/lib/libz.1.dylib", "/usr/lib/libz.dylib"));
    assert(!gl_same_install_name("/S/Metal.framework/Versions/A/Metal", "/S/MetalFX.framework/MetalFX"));
    assert(!gl_same_install_name("/S/Metal.framework/Versions/A/Metal", "/S/Metal.framework/Versions/A/Metal2"));
    assert(!gl_same_install_name("/S/Metal.framework/Versions/A", "/S/Metal.framework"));
    assert(!gl_same_install_name(NULL, "/S/Metal.framework/Metal") && !gl_same_install_name("x", NULL));

    gl_destroy(&set);
    assert(!set.root && !set.executable && !set.count && !set.executable_image);

    // Initialization order: a library after those it links. The executable
    // lists A and C; A links B, B links A back, C links A and the system;
    // nothing links D. Loaded breadth first (A, C, B, D), initialized B, A, C, D.
    static const char *const names[] = {"A", "C", "B", "D"};
    char library_paths[4][512];
    static GuestLinkSet ordered;
    static GuestImage program;
    ordered.root = strdup(resolved_bundle);
    ordered.executable = strdup(resolved_executable);
    assert(ordered.root && ordered.executable);
    for (size_t i = 0; i < 4; i++) {
        char file[512];
        snprintf(file, sizeof file, "%s/lib%s.dylib", frameworks, names[i]);
        touch(file);
        assert(realpath(file, library_paths[i]));
        ordered.libraries[i].path = strdup(library_paths[i]);
        ordered.libraries[i].install_name = strdup(file);
        assert(ordered.libraries[i].path && ordered.libraries[i].install_name);
    }
    ordered.count = 4;
    ordered.executable_image = &program;
    program.dylibs[program.dylib_count++] = strdup("@executable_path/../Frameworks/libA.dylib");
    program.dylibs[program.dylib_count++] = strdup("@executable_path/../Frameworks/libC.dylib");
    GuestImage *a = &ordered.libraries[0].image, *c = &ordered.libraries[1].image, *b = &ordered.libraries[2].image;
    a->dylibs[a->dylib_count++] = strdup("@loader_path/libB.dylib");
    b->dylibs[b->dylib_count++] = strdup("@loader_path/libA.dylib");
    c->dylibs[c->dylib_count++] = strdup("@loader_path/libA.dylib");
    c->dylibs[c->dylib_count++] = strdup("/usr/lib/libSystem.B.dylib");
    size_t order[GL_MAX_LIBRARIES];
    assert(gl_initialization_order(&ordered, order) == 4);
    assert(order[0] == 2 && order[1] == 0 && order[2] == 1 && order[3] == 3);
    // The executable's list decides first: listing C first puts it before A's
    // branch, although A was loaded first.
    char *swap = program.dylibs[0]; program.dylibs[0] = program.dylibs[1]; program.dylibs[1] = swap;
    free(c->dylibs[0]); c->dylibs[0] = c->dylibs[1]; c->dylib_count = 1;
    assert(gl_initialization_order(&ordered, order) == 4);
    assert(order[0] == 1 && order[1] == 2 && order[2] == 0 && order[3] == 3);
    assert(gl_initialization_order(NULL, order) == 0);
    gi_destroy(&program);
    gl_destroy(&ordered);
    for (size_t i = 0; i < 4; i++) unlink(library_paths[i]);

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
    // Which placed library an address lies in (dladdr, a dlopen's caller);
    // nothing until the libraries are placed.
    assert(!gl_library_at(&measured, 0) && !gl_library_at(&measured, 0x8000));
    measured.libraries[0].slide = 0x100000; measured.libraries[1].slide = 0x200000;
    assert(gl_library_at(&measured, 0x100000) == &measured.libraries[0]);
    assert(gl_library_at(&measured, 0x108000) == &measured.libraries[0]);   // the gap between its segments
    assert(gl_library_at(&measured, 0x113fff) == &measured.libraries[0] && !gl_library_at(&measured, 0x114000));
    assert(!gl_library_at(&measured, 0xfffff) && gl_library_at(&measured, 0x20bfff) == &measured.libraries[1]);
    assert(!gl_library_at(&measured, 0x20c000) && !gl_library_at(NULL, 0x100000));

    puts("PASS: carried library paths resolve inside the application only (@rpath, @loader_path, @executable_path),"
         " extent from the lowest mapped segment, initialization after linked libraries,"
         " the application's own dlopen and dladdr");
}
