#import <Foundation/Foundation.h>
#import <Security/Security.h>
// Public default trust anchors only. Never opens a user's keychain or exports
// a private key. iOS evaluates these certificates with its own native policies.
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=2)return 2;
    SecKeychainRef system=NULL;
    OSStatus status=SecKeychainOpen("/System/Library/Keychains/SystemRootCertificates.keychain",&system);
    if(status || !system)return 1;
    SecPolicyRef policy=SecPolicyCreateSSL(true,NULL);
    NSDictionary *query=@{(__bridge id)kSecClass:(__bridge id)kSecClassCertificate,
        (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitAll,(__bridge id)kSecReturnRef:@YES,
        (__bridge id)kSecMatchTrustedOnly:@YES,(__bridge id)kSecMatchPolicy:(__bridge id)policy,
        (__bridge id)kSecMatchSearchList:@[(__bridge id)system]};
    CFTypeRef anchors=NULL;status=SecItemCopyMatching((__bridge CFDictionaryRef)query,&anchors);
    CFRelease(policy);CFRelease(system);
    if(status || !anchors || CFGetTypeID(anchors)!=CFArrayGetTypeID())return 1;
    NSMutableArray *encoded=[NSMutableArray array];
    for(id certificate in (__bridge NSArray *)anchors){
        NSData *der=CFBridgingRelease(SecCertificateCopyData((__bridge SecCertificateRef)certificate));
        if(der)[encoded addObject:der];
    }
    CFRelease(anchors);
    if(!encoded.count)return 1;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:encoded format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if(![data writeToFile:@(argv[1]) atomically:YES])return 1;
    printf("Packaged %lu public system certificates matching native SSL policy\n",(unsigned long)encoded.count);return 0;
}}
