#pragma once
#include "GuestImage.h"
// Resolve a Mach-O symbol (including its leading underscore). Return false for
// an unresolved required symbol. Weak imports may resolve successfully to zero.
// Lazy binds fill lazy pointers, which only calls use.
typedef bool (*GFResolve)(const char *symbol, int ordinal, bool weak, bool lazy, uint64_t *value, void *context);
typedef struct { size_t rebases, binds; } GFStats;
// Normal loader relocations in private runtime memory only. On failure discard
// the image; a prefix may have been relocated. Never changes the source file.
bool gf_apply(GuestImage *image, uint64_t slide, GFResolve resolve, void *context,
              GFStats *stats, char *error, size_t error_size);
// Diagnostics: as gf_apply, reporting every written pointer. `symbol` is the
// import name for a bind, valid during the call only, and NULL for a rebase.
typedef void (*GFObserve)(uint64_t address, uint64_t value, const char *symbol, void *context);
bool gf_apply_observed(GuestImage *image, uint64_t slide, GFResolve resolve, void *context,
                       GFObserve observe, void *observe_context, GFStats *stats, char *error, size_t error_size);
