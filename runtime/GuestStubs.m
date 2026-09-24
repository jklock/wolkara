#include "GuestStubs.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <ctype.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Slot n begins at eight times n, its index below.
extern char gs_slot_table[];

#define GS_BUCKETS (GS_SLOTS * 2)

static struct {
    char *name;
    void *address;
    atomic_bool reported;
} entries[GS_SLOTS];
static unsigned used;
static unsigned buckets[GS_BUCKETS];   // one-based entry number; zero is empty
static FILE *stub_log;

static FILE *log_file(void) { return stub_log ? stub_log : stderr; }
static const char *bare(const char *symbol) { return symbol[0] == '_' ? symbol + 1 : symbol; }

static size_t slot_of(const char *name) {
    // FNV-1a and linear probing; twice the slots, never full.
    size_t hash = 1469598103934665603ULL;
    for (const char *c = name; *c; c++) { hash ^= (unsigned char)*c; hash *= 1099511628211ULL; }
    size_t bucket = hash % GS_BUCKETS;
    while (buckets[bucket] && strcmp(entries[buckets[bucket] - 1].name, name)) {
        bucket = (bucket + 1) % GS_BUCKETS;
    }
    return bucket;
}

static bool ends_with(const char *name, const char *suffix) {
    size_t length = strlen(name), tail = strlen(suffix);
    return length >= tail && !strcmp(name + length - tail, suffix);
}

GSKind gs_kind(const char *symbol) {
    const char *name = bare(symbol);
    if (!strncmp(name, "OBJC_CLASS_$_", 13)) return GS_CLASS;
    if (!strncmp(name, "OBJC_METACLASS_$_", 17)) return GS_METACLASS;
    // Ivar offsets and exception types are read, not called.
    if (!strncmp(name, "OBJC_IVAR_$_", 12) || !strncmp(name, "OBJC_EHTYPE_$_", 14)) return GS_DATA;
    // As the build-time classifier: constants are named like constants.
    if ((name[0] == 'k' || name[0] == 'g') && isupper((unsigned char)name[1])) return GS_DATA;
    if (!strncmp(name, "NS", 2)) {
        if (!strcmp(name, "NSApp")) return GS_DATA;
        static const char *const constants[] = {"Key", "Notification", "Mode", "Name", "Type", "Number"};
        for (size_t i = 0; i < sizeof constants / sizeof *constants; i++)
            if (ends_with(name, constants[i])) return GS_DATA;
    }
    return GS_FUNCTION;
}

GSKind gs_kind_bound(const char *symbol, bool image_binds_lazily, bool bound_lazily) {
    GSKind named = gs_kind(symbol);
    if (!image_binds_lazily || named == GS_CLASS || named == GS_METACLASS) return named;
    return bound_lazily ? GS_FUNCTION : GS_DATA;
}

// An unknown selector is reported once and answered with zero.
static void report_selector(id receiver, SEL selector) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet new]; });
    NSString *key = [NSString stringWithFormat:@"%c[%@ %@]", object_isClass(receiver) ? '+' : '-',
                     NSStringFromClass(object_getClass(receiver)), NSStringFromSelector(selector)];
    @synchronized (seen) {
        if ([seen containsObject:key]) return;
        [seen addObject:key];
    }
    fprintf(log_file(), "[stub] %s\n", key.UTF8String);
    fflush(log_file());
}
static NSMethodSignature *stub_signature(id self, SEL command, SEL selector) {
    (void)self; (void)command; (void)selector;
    // Pretend every selector is `id f(id, SEL)`.
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
static void stub_forward(id self, SEL command, NSInvocation *invocation) {
    (void)command;
    report_selector(self, invocation.selector);
    id zero = nil;
    [invocation setReturnValue:&zero];
}

static Class stub_class(const char *name) {
    Class existing = objc_getClass(name);
    if (existing) return existing;
    // The support library has this where the build carries it.
    Class inherited = objc_getClass("AKStubObject");
    Class created = objc_allocateClassPair(inherited ?: [NSObject class], name, 0);
    if (!created) return objc_getClass(name);
    if (!inherited) {
        class_addMethod(created, @selector(methodSignatureForSelector:), (IMP)stub_signature, "@@::");
        class_addMethod(created, @selector(forwardInvocation:), (IMP)stub_forward, "v@:@");
        Class meta = object_getClass(created);
        class_addMethod(meta, @selector(methodSignatureForSelector:), (IMP)stub_signature, "@@::");
        class_addMethod(meta, @selector(forwardInvocation:), (IMP)stub_forward, "v@:@");
    }
    objc_registerClassPair(created);
    return created;
}

// Sixty-four bytes, as the generated stubs use.
static void *stub_data(const char *name) {
    struct { const void *pointer; char padding[56]; } *storage = calloc(1, sizeof *storage);
    if (!storage) return NULL;
    // A name shaped like a string constant gets one.
    if ((name[0] == 'k' && isupper((unsigned char)name[1])) || !strncmp(name, "NS", 2) ||
        !strncmp(name, "MTL", 3) || !strncmp(name, "AV", 2) || !strncmp(name, "CG", 2) ||
        !strncmp(name, "UI", 2))
        storage->pointer = (__bridge_retained const void *)[NSString stringWithUTF8String:name];
    return storage;
}

void *gs_bind(const char *symbol, GSKind kind) {
    if (!symbol || !*symbol) return NULL;
    const char *name = bare(symbol);
    size_t bucket = slot_of(name);
    if (buckets[bucket]) return entries[buckets[bucket] - 1].address;
    if (used == GS_SLOTS) return NULL;
    unsigned index = used;
    char *owned = strdup(name);
    if (!owned) return NULL;
    void *address = NULL;
    switch (kind) {
        case GS_FUNCTION: address = gs_slot_table + (size_t)index * 8; break;
        case GS_DATA: address = stub_data(name); break;
        case GS_CLASS: address = (__bridge void *)stub_class(name + sizeof "OBJC_CLASS_$_" - 1); break;
        case GS_METACLASS: {
            Class created = stub_class(name + sizeof "OBJC_METACLASS_$_" - 1);
            address = (__bridge void *)object_getClass(created);
            break;
        }
    }
    if (!address) { free(owned); return NULL; }
    entries[index].name = owned;
    entries[index].address = address;
    atomic_store(&entries[index].reported, false);
    buckets[bucket] = index + 1;
    used++;
    return address;
}

long gs_called(unsigned slot) {
    if (slot < GS_SLOTS && entries[slot].name && !atomic_exchange(&entries[slot].reported, true)) {
        fprintf(log_file(), "[stub] %s() called\n", entries[slot].name);
        fflush(log_file());
    }
    return 0;
}

unsigned gs_capacity(void) { return GS_SLOTS; }
unsigned gs_used(void) { return used; }
void gs_log(FILE *log) { stub_log = log; }
void gs_reset(void) {
    for (unsigned i = 0; i < used; i++) { free(entries[i].name); entries[i].name = NULL; }
    memset(buckets, 0, sizeof buckets);
    used = 0;
}
