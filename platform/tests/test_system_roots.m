#import "SystemRoots.h"
#include <assert.h>
int main(int argc,const char **argv){@autoreleasepool{
    assert(argc==2);assert(AKLoadSystemCertificateCandidates(@(argv[1])));
    CFTypeRef handle=(void *)1;assert(AKOpenSystemKeychain("/not-a-system-keychain",&handle)==errSecUnimplemented && !handle);
    assert(AKOpenSystemKeychain("/System/Library/Keychains/SystemRootCertificates.keychain",&handle)==0 && handle);
    SecPolicyRef policy=SecPolicyCreateSSL(true,NULL);
    NSDictionary *query=@{(__bridge id)kSecClass:(__bridge id)kSecClassCertificate,
        (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitAll,(__bridge id)kSecReturnRef:@YES,
        (__bridge id)kSecMatchPolicy:(__bridge id)policy,(__bridge id)kSecMatchTrustedOnly:@YES,
        (__bridge id)kSecMatchSearchList:@[(__bridge id)handle]};
    BOOL handled=NO;CFTypeRef result=NULL;
    assert(AKCopySystemCertificates((__bridge CFDictionaryRef)query,&result,&handled)==0 && handled && result);
    assert(CFGetTypeID(result)==CFArrayGetTypeID() && CFArrayGetCount(result)>20);
    SecPolicyRef rootPolicy=SecPolicyCreateBasicX509();
    for(id certificate in (__bridge NSArray *)result){SecTrustRef trust=NULL;assert(SecTrustCreateWithCertificates((__bridge CFTypeRef)certificate,rootPolicy,&trust)==0);SecTrustSetNetworkFetchAllowed(trust,false);assert(SecTrustEvaluateWithError(trust,NULL));CFRelease(trust);}
    CFRelease(rootPolicy);CFRelease(result);result=NULL;
    NSMutableDictionary *bad=[query mutableCopy];bad[(__bridge id)kSecReturnData]=@YES;
    assert(AKCopySystemCertificates((__bridge CFDictionaryRef)bad,&result,&handled)!=0 && handled && !result);
    [bad removeObjectForKey:(__bridge id)kSecMatchSearchList];handled=YES;
    assert(AKCopySystemCertificates((__bridge CFDictionaryRef)bad,&result,&handled)!=0 && !handled);
    CFRelease(policy);CFRelease(handle);puts("system roots: typed enumeration, native trust filtering, query isolation and rejection pass");
}}
