#import "AppKit.h"
// Fonts. UIKit has a private class of this name: ours registers as AKFont, and
// ldflags exports AppKit's symbol names for it, which is what guests bind to.
// Without that alias a bare NSFont class reference binds to the private UIKit
// class, whose selectors are not AppKit's: +messageFontOfSize: then raises
// NSInvalidArgumentException and takes the whole launch down with it.
__attribute__((objc_runtime_name("AKFont"))) @interface NSFont : AKStubObject
@property(readonly, copy) NSString *fontName;
@property(readonly) CGFloat pointSize;
@property(readonly) CGFloat ascender;
@property(readonly) CGFloat descender;
@property(readonly) CGFloat capHeight;
@property(readonly) CGFloat xHeight;
@property(readonly) CGFloat leading;
@property(readonly, getter=isFixedPitch) BOOL fixedPitch;
@property(readonly) CGRect boundingRectForFont;
// macOS sizes. Names that resolve on iOS give that face; unknown names fall back
// to the system font, so a guest never gets nil where AppKit would give a font.
+ (NSFont *)fontWithName:(NSString *)fontName size:(CGFloat)fontSize;
+ (NSFont *)systemFontOfSize:(CGFloat)fontSize;
+ (NSFont *)systemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight;
+ (NSFont *)boldSystemFontOfSize:(CGFloat)fontSize;
+ (NSFont *)monospacedSystemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight;
+ (NSFont *)monospacedDigitSystemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight;
// The reconciliation fonts have no UIKit counterpart; they answer with the
// system font at the requested size.
+ (NSFont *)messageFontOfSize:(CGFloat)fontSize;
+ (NSFont *)menuFontOfSize:(CGFloat)fontSize;
+ (NSFont *)menuBarFontOfSize:(CGFloat)fontSize;
+ (NSFont *)labelFontOfSize:(CGFloat)fontSize;
+ (NSFont *)controlContentFontOfSize:(CGFloat)fontSize;
+ (NSFont *)titleBarFontOfSize:(CGFloat)fontSize;
+ (NSFont *)paletteFontOfSize:(CGFloat)fontSize;
+ (NSFont *)toolTipsFontOfSize:(CGFloat)fontSize;
+ (NSFont *)userFontOfSize:(CGFloat)fontSize;
+ (NSFont *)userFixedPitchFontOfSize:(CGFloat)fontSize;
+ (CGFloat)systemFontSize;
+ (CGFloat)smallSystemFontSize;
+ (CGFloat)labelFontSize;
@end
// AppKit's weight constants; the values match UIFontWeight, so guests may pass
// them straight to +systemFontOfSize:weight:.
extern const CGFloat NSFontWeightUltraLight, NSFontWeightThin, NSFontWeightLight, NSFontWeightRegular,
    NSFontWeightMedium, NSFontWeightSemibold, NSFontWeightBold, NSFontWeightHeavy, NSFontWeightBlack;
