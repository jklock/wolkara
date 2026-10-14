#import "Fonts.h"

const CGFloat NSFontWeightUltraLight=-0.8, NSFontWeightThin=-0.6, NSFontWeightLight=-0.4, NSFontWeightRegular=0,
    NSFontWeightMedium=0.23, NSFontWeightSemibold=0.3, NSFontWeightBold=0.4, NSFontWeightHeavy=0.56, NSFontWeightBlack=0.62;

@interface NSFont ()
+ (NSFont *)ak_fontWithUIFont:(UIFont *)font;
@end

@implementation NSFont { UIFont *_font; }
+ (NSFont *)ak_fontWithUIFont:(UIFont *)font { if(!font) return nil; NSFont *result=[self new]; result->_font=font; return result; }
+ (NSFont *)fontWithName:(NSString *)fontName size:(CGFloat)fontSize {
    UIFont *font=fontName.length?[UIFont fontWithName:fontName size:fontSize]:nil;
    return [self ak_fontWithUIFont:font?:[UIFont systemFontOfSize:fontSize]];
}
+ (NSFont *)systemFontOfSize:(CGFloat)fontSize { return [self ak_fontWithUIFont:[UIFont systemFontOfSize:fontSize]]; }
+ (NSFont *)systemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight { return [self ak_fontWithUIFont:[UIFont systemFontOfSize:fontSize weight:(UIFontWeight)weight]]; }
+ (NSFont *)boldSystemFontOfSize:(CGFloat)fontSize { return [self ak_fontWithUIFont:[UIFont boldSystemFontOfSize:fontSize]]; }
+ (NSFont *)monospacedSystemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight { return [self ak_fontWithUIFont:[UIFont monospacedSystemFontOfSize:fontSize weight:(UIFontWeight)weight]]; }
+ (NSFont *)monospacedDigitSystemFontOfSize:(CGFloat)fontSize weight:(CGFloat)weight { return [self ak_fontWithUIFont:[UIFont monospacedDigitSystemFontOfSize:fontSize weight:(UIFontWeight)weight]]; }
// UIKit has no equivalent of these themed fonts: the system font at that size is
// the same face the guest's own controls would draw with.
+ (NSFont *)messageFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize]; }
+ (NSFont *)menuFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize]; }
+ (NSFont *)menuBarFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize]; }
+ (NSFont *)labelFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize]; }
+ (NSFont *)controlContentFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize]; }
+ (NSFont *)titleBarFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize]; }
+ (NSFont *)paletteFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize]; }
+ (NSFont *)toolTipsFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize]; }
+ (NSFont *)userFontOfSize:(CGFloat)fontSize { return [self systemFontOfSize:fontSize]; }
+ (NSFont *)userFixedPitchFontOfSize:(CGFloat)fontSize { return [self monospacedSystemFontOfSize:fontSize weight:0]; }
// AppKit's documented defaults.
+ (CGFloat)systemFontSize { return 13; }
+ (CGFloat)smallSystemFontSize { return 11; }
+ (CGFloat)labelFontSize { return 10; }
- (NSString *)fontName { return _font.fontName; }
- (CGFloat)pointSize { return _font.pointSize; }
- (CGFloat)ascender { return _font.ascender; }
- (CGFloat)descender { return _font.descender; }
- (CGFloat)capHeight { return _font.capHeight; }
- (CGFloat)xHeight { return _font.xHeight; }
- (CGFloat)leading { return _font.leading; }
- (BOOL)isFixedPitch { return (_font.fontDescriptor.symbolicTraits & UIFontDescriptorTraitMonoSpace)!=0; }
- (CGRect)boundingRectForFont { return CGRectMake(0,-_font.descender,0,_font.lineHeight); }
@end
