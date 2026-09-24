#include "GuestImage.h"
#include "GuestFixups.h"
#include "GuestLink.h"
#include <stdio.h>
#include <string.h>
// Only the application's own libraries answer; the rest is zero.
static struct { size_t answered, missing; } imports;
// The image whose fixups are walked; ordinals index its list.
typedef struct { GuestLinkSet *set; const GuestImage *image; const char *path; } Binder;
static bool inspect_import(const char *s, int o, bool w, bool l, uint64_t *v, void *c) {
    (void)w; (void)l;
    Binder *binder = c;
    const char *needed = o > 0 && (size_t)o <= binder->image->dylib_count ? binder->image->dylibs[o - 1] : NULL;
    const GuestLibrary *answer = gl_lookup(binder->set, binder->image, binder->path, needed, s, v);
    if (answer) { imports.answered++; printf("[import] %s <- %s\n", s, answer->install_name); return true; }
    imports.missing++; *v=0; return true;
}
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: guest_probe <original Mach-O> [--library] [--carried-libraries] [--validate-fixups] [--export symbol ...]\n"); return 2; }
    bool library = false, fixups = false, carried = false;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--library")) library = true;
        else if (!strcmp(argv[i], "--validate-fixups")) fixups = true;
        else if (!strcmp(argv[i], "--carried-libraries")) carried = true;
        else if (!strcmp(argv[i], "--export") && i + 1 < argc) i++;
        else { fprintf(stderr, "invalid probe option\n"); return 2; }
    }
    GuestImage image = {0}; char error[1024];
    bool loaded = library ? gi_load_library(argv[1], &image, error, sizeof error) : gi_load(argv[1], &image, error, sizeof error);
    if (!loaded) { fprintf(stderr, "%s\n", error); return 1; }
    gi_report(&image, stdout);
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--export")) continue;
        const char *symbol = argv[++i]; GIExport found;
        GIExportResult result = gi_export(&image, symbol, &found, error, sizeof error);
        if (result == GI_EXPORT_REEXPORT) {
            printf("[export] %s re-exported from %s as %s\n", symbol,
                   image.dylibs[found.ordinal - 1], found.name ? found.name : symbol);
            continue;
        }
        if (result != GI_EXPORT_FOUND) {
            fprintf(stderr, "export %s: %s\n", symbol, result == GI_EXPORT_MISSING ? "not found" : error);
            gi_destroy(&image); return 1;
        }
        printf("[export] %s=%#llx absolute=%d\n", symbol, (unsigned long long)found.address, found.absolute);
    }
    GuestLinkSet set = {0};
    if (carried) {
        if (!gl_load(&set, &image, argv[1], error, sizeof error)) {
            fprintf(stderr, "%s\n", error); gi_destroy(&image); return 1;
        }
        gl_report(&set, stdout);
    }
    if (fixups) {
        GFStats stats;
        // Carried libraries bind first: a miss here is real.
        for (size_t i = 0; i < set.count; i++) {
            Binder binder = {&set, &set.libraries[i].image, set.libraries[i].path};
            if (!gf_apply(&set.libraries[i].image, 0x200000, inspect_import, &binder, &stats, error, sizeof error)) {
                fprintf(stderr, "%s: %s\n", set.libraries[i].install_name, error);
                gl_destroy(&set); gi_destroy(&image); return 1;
            }
            printf("[fixups] %s rebases=%zu binds=%zu\n", set.libraries[i].install_name, stats.rebases, stats.binds);
        }
        Binder binder = {&set, &image, argv[1]};
        if (!gf_apply(&image, 0x200000, inspect_import, &binder, &stats, error, sizeof error)) {
            fprintf(stderr, "%s\n", error); gl_destroy(&set); gi_destroy(&image); return 1;
        }
        printf("[fixups] validated rebases=%zu binds=%zu (diagnostic addresses only; no execution)\n", stats.rebases, stats.binds);
        printf("[fixups] imports from carried libraries=%zu elsewhere=%zu\n", imports.answered, imports.missing);
    }
    gl_destroy(&set);
    gi_destroy(&image);
    return 0;
}
