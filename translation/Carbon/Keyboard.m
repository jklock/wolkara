#import <Foundation/Foundation.h>
#import "KeyboardLayout.h"

#define TIS_CONSTANT(name) const CFStringRef name = CFSTR(#name)
TIS_CONSTANT(kTISCategoryKeyboardInputSource);
TIS_CONSTANT(kTISNotifySelectedKeyboardInputSourceChanged);
TIS_CONSTANT(kTISPropertyInputSourceCategory);
TIS_CONSTANT(kTISPropertyInputSourceID);
TIS_CONSTANT(kTISPropertyInputSourceIsEnabled);
TIS_CONSTANT(kTISPropertyInputSourceIsSelectCapable);
TIS_CONSTANT(kTISPropertyInputSourceIsSelected);
TIS_CONSTANT(kTISPropertyInputSourceLanguages);
TIS_CONSTANT(kTISPropertyLocalizedName);
TIS_CONSTANT(kTISPropertyUnicodeKeyLayoutData);

static NSDictionary *keyboardSource(void) {
    static NSDictionary *source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        source = @{
            (__bridge id)kTISPropertyInputSourceCategory: (__bridge id)kTISCategoryKeyboardInputSource,
            (__bridge id)kTISPropertyInputSourceID: @"local.tolkara.keyboard.US",
            (__bridge id)kTISPropertyInputSourceIsEnabled: @YES,
            (__bridge id)kTISPropertyInputSourceIsSelectCapable: @YES,
            (__bridge id)kTISPropertyInputSourceIsSelected: @YES,
            (__bridge id)kTISPropertyInputSourceLanguages: @[@"en"],
            (__bridge id)kTISPropertyLocalizedName: @"U.S.",
            (__bridge id)kTISPropertyUnicodeKeyLayoutData: [NSData dataWithBytes:&AKUSLayout length:sizeof(AKUSLayout)]
        };
    });
    return source;
}
CFTypeRef TISCopyCurrentKeyboardLayoutInputSource(void) { return CFRetain((__bridge CFTypeRef)keyboardSource()); }
CFTypeRef TISCopyCurrentKeyboardInputSource(void) { return TISCopyCurrentKeyboardLayoutInputSource(); }
CFTypeRef TISCopyCurrentASCIICapableKeyboardLayoutInputSource(void) { return TISCopyCurrentKeyboardLayoutInputSource(); }
void *TISGetInputSourceProperty(CFTypeRef source, CFStringRef key) {
    if (source != (__bridge CFTypeRef)keyboardSource() || !key) return NULL;
    return (__bridge void *)keyboardSource()[(__bridge NSString *)key];
}
CFArrayRef TISCreateInputSourceList(CFDictionaryRef filter, Boolean includeAllInstalled) {
    (void)includeAllInstalled;
    NSDictionary *source = keyboardSource();
    for (id key in (__bridge NSDictionary *)filter) {
        if (![source[key] isEqual:((__bridge NSDictionary *)filter)[key]])
            return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    }
    const void *value = (__bridge CFTypeRef)source;
    return CFArrayCreate(NULL, &value, 1, &kCFTypeArrayCallBacks);
}
int32_t TISSelectInputSource(CFTypeRef source) { return source == (__bridge CFTypeRef)keyboardSource() ? 0 : -50; }
uint8_t LMGetKbdType(void) { return 40; } // ANSI keyboard family
int16_t KBGetLayoutType(int16_t keyboardType) { (void)keyboardType; return 0; } // kKeyboardANSI

// iPadOS has no Carbon symbolic-hotkey registry. Report unimpErr through the
// API's error contract; callers must not index a nonexistent macOS registry.
int32_t CopySymbolicHotKeys(CFArrayRef *hotKeys) {
    if(!hotKeys) return -50;
    *hotKeys=NULL;
    return -4;
}
