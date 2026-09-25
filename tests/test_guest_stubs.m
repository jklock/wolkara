#include "GuestStubs.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <assert.h>
#include <string.h>

static unsigned occurrences(const char *text, const char *needle) {
    unsigned count = 0;
    for (const char *at = text; (at = strstr(at, needle)); at += strlen(needle)) count++;
    return count;
}

int main(void) {
    @autoreleasepool {
        assert(gs_kind("_CGDisplayCopyAllDisplayModes") == GS_FUNCTION);
        assert(gs_kind("_NSBeep") == GS_FUNCTION);
        assert(gs_kind("_kCGColorSpaceSRGB") == GS_DATA);
        assert(gs_kind("_NSApp") == GS_DATA);
        assert(gs_kind("_NSFontAttributeName") == GS_DATA);
        assert(gs_kind("_OBJC_CLASS_$_TKAbsentClass") == GS_CLASS);
        assert(gs_kind("_OBJC_METACLASS_$_TKAbsentClass") == GS_METACLASS);
        assert(gs_kind("_OBJC_IVAR_$_TKAbsentClass._field") == GS_DATA);
        // With lazy pointers the image decides, not the name.
        assert(gs_kind_bound("_kLooksLikeAConstant", true, true) == GS_FUNCTION);
        assert(gs_kind_bound("_NSBeep", true, false) == GS_DATA);
        assert(gs_kind_bound("_OBJC_CLASS_$_TKAbsentClass", true, false) == GS_CLASS);
        assert(gs_kind_bound("_OBJC_METACLASS_$_TKAbsentClass", true, true) == GS_METACLASS);
        // No lazy pointers: the name rules stand.
        assert(gs_kind_bound("_kCGColorSpaceSRGB", false, true) == GS_DATA);
        assert(gs_kind_bound("_NSBeep", false, false) == GS_FUNCTION);

        FILE *log = tmpfile();
        assert(log);
        gs_log(log);

        // A missing function binds to a trampoline and answers zero.
        long (*first)(void) = (long (*)(void))gs_bind("_CGDisplayCopyAllDisplayModes", GS_FUNCTION);
        long (*second)(void) = (long (*)(void))gs_bind("_CGDisplayModeGetWidth", GS_FUNCTION);
        assert(first && second && first != second);
        assert((void *)first == gs_bind("_CGDisplayCopyAllDisplayModes", GS_FUNCTION));
        assert(gs_used() == 2);
        assert(first() == 0 && first() == 0 && second() == 0);

        // Data reads as itself where the name says string constant.
        const void **constant = gs_bind("_kCGColorSpaceSRGB", GS_DATA);
        assert(constant && *constant);
        assert([(__bridge NSString *)(void *)*constant isEqualToString:@"kCGColorSpaceSRGB"]);
        const void **offset = gs_bind("_OBJC_IVAR_$_TKAbsentClass._field", GS_DATA);
        assert(offset && !*offset);

        // A class is made and answers unimplemented selectors with zero.
        Class absent = (__bridge Class)gs_bind("_OBJC_CLASS_$_TKAbsentClass", GS_CLASS);
        assert(absent && absent == objc_getClass("TKAbsentClass"));
        assert((__bridge Class)gs_bind("_OBJC_METACLASS_$_TKAbsentClass", GS_METACLASS) == object_getClass(absent));
        id instance = ((id (*)(id, SEL))objc_msgSend)(absent, @selector(new));
        assert(instance);
        assert(!((id (*)(id, SEL))objc_msgSend)(instance, @selector(thisSelectorExistsNowhere)));

        fflush(log);
        rewind(log);
        char text[8192];
        size_t length = fread(text, 1, sizeof text - 1, log);
        text[length] = 0;
        assert(occurrences(text, "CGDisplayCopyAllDisplayModes() called") == 1);   // once, not per call
        assert(occurrences(text, "CGDisplayModeGetWidth() called") == 1);
        assert(strstr(text, "thisSelectorExistsNowhere"));

        // The table is finite and says so.
        gs_reset();
        assert(!gs_used());
        char name[32];
        for (unsigned i = 0; i < gs_capacity(); i++) {
            snprintf(name, sizeof name, "_tk_absent_%u", i);
            assert(gs_bind(name, GS_FUNCTION));
        }
        assert(gs_used() == gs_capacity());
        assert(!gs_bind("_tk_absent_overflow", GS_FUNCTION));
        fclose(log);
    }
    puts("PASS: stub kinds by name and by where bound, function slots, data and class stubs, one report per stub, exhaustion");
}
