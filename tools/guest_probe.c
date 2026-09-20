#include "GuestImage.h"
#include "GuestFixups.h"
#include <string.h>
static bool inspect_import(const char *s, int o, bool w, uint64_t *v, void *c) {
    (void)s; (void)o; (void)w; (void)c; *v=0; return true;
}
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: guest_probe <original Mach-O> [--library] [--validate-fixups] [--export symbol ...]\n"); return 2; }
    bool library = false, fixups = false;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--library")) library = true;
        else if (!strcmp(argv[i], "--validate-fixups")) fixups = true;
        else if (!strcmp(argv[i], "--export") && i + 1 < argc) i++;
        else { fprintf(stderr, "invalid probe option\n"); return 2; }
    }
    GuestImage image = {0}; char error[1024];
    bool loaded = library ? gi_load_library(argv[1], &image, error, sizeof error) : gi_load(argv[1], &image, error, sizeof error);
    if (!loaded) { fprintf(stderr, "%s\n", error); return 1; }
    gi_report(&image, stdout);
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--export")) continue;
        const char *symbol = argv[++i]; uint64_t address; bool absolute;
        GIExportResult result = gi_export(&image, symbol, &address, &absolute, error, sizeof error);
        if (result != GI_EXPORT_FOUND) {
            fprintf(stderr, "export %s: %s\n", symbol, result == GI_EXPORT_MISSING ? "not found" : error);
            gi_destroy(&image); return 1;
        }
        printf("[export] %s=%#llx absolute=%d\n", symbol, (unsigned long long)address, absolute);
    }
    if (fixups) {
        GFStats stats;
        if (!gf_apply(&image, 0x200000, inspect_import, NULL, &stats, error, sizeof error)) {
            fprintf(stderr, "%s\n", error); gi_destroy(&image); return 1;
        }
        printf("[fixups] validated rebases=%zu binds=%zu (diagnostic addresses only; no execution)\n", stats.rebases, stats.binds);
    }
    gi_destroy(&image);
    return 0;
}
