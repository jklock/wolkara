#import <Foundation/Foundation.h>
#import "KeyboardLayout.h"
#include <assert.h>
extern CFTypeRef TISCopyCurrentKeyboardLayoutInputSource(void);
extern void *TISGetInputSourceProperty(CFTypeRef, CFStringRef);
extern CFArrayRef TISCreateInputSourceList(CFDictionaryRef, Boolean);
extern int32_t CopySymbolicHotKeys(CFArrayRef *);
extern int32_t TISSelectInputSource(CFTypeRef);
extern const CFStringRef kTISPropertyUnicodeKeyLayoutData, kTISPropertyInputSourceID;
int main(void) { @autoreleasepool {
    CFTypeRef source = TISCopyCurrentKeyboardLayoutInputSource(); assert(source);
    CFDataRef data = TISGetInputSourceProperty(source,kTISPropertyUnicodeKeyLayoutData); assert(data);
    const void *layout = CFDataGetBytePtr(data);
    uint32_t state=0; unsigned long length=99; uint16_t out[4]={0};
    assert(UCKeyTranslate(layout,0,0,0,40,0,&state,4,&length,out)==0 && length==1 && out[0]=='a');
    assert(UCKeyTranslate(layout,0,0,2,40,0,&state,4,&length,out)==0 && out[0]=='A');
    assert(UCKeyTranslate(layout,18,0,2,40,0,&state,4,&length,out)==0 && out[0]=='!');
    assert(UCKeyTranslate(layout,14,0,8,40,0,&state,4,&length,out)==0 && length==0 && state);
    assert(UCKeyTranslate(layout,14,0,0,40,0,&state,4,&length,out)==0 && length==1 && out[0]==0xe9 && !state);
    assert(UCKeyTranslate(layout,0,0,10,40,1,&state,4,&length,out)==0 && out[0]==0xc5);
    assert(UCKeyTranslate(layout,0,0,16,40,1,&state,4,&length,out)==0 && out[0]==1);
    assert(UCKeyTranslate(layout,0,0,6,40,1,&state,4,&length,out)==0 && out[0]=='A');
    out[0]=0x1234;
    assert(UCKeyTranslate(layout,0,0,0,40,0,&state,0,&length,out)==-25340 && out[0]==0x1234);
    assert(UCKeyTranslate(layout,128,0,0,40,0,&state,4,&length,out)==-50);
    assert(UCKeyTranslate(NULL,0,0,0,40,0,&state,4,&length,out)==-50);
    CFArrayRef all=TISCreateInputSourceList(NULL,false); assert(CFArrayGetCount(all)==1); CFRelease(all);
    NSDictionary *filter=@{(__bridge id)kTISPropertyInputSourceID:@"unknown"};
    all=TISCreateInputSourceList((__bridge CFDictionaryRef)filter,false); assert(CFArrayGetCount(all)==0); CFRelease(all);
    assert(TISSelectInputSource(source)==0 && TISSelectInputSource(NULL)==-50);
    CFArrayRef hotkeys=NULL; assert(CopySymbolicHotKeys(&hotkeys)==-4 && hotkeys==NULL);
    assert(CopySymbolicHotKeys(NULL)==-50);
    CFRelease(source); puts("keyboard ABI, key translation, dead keys, buffers and input-source ownership: PASS");
} }
