#pragma once
#import <Foundation/Foundation.h>
#import <Security/Security.h>
OSStatus AKOpenSystemKeychain(const char *path,CFTypeRef *keychain);
OSStatus AKCopySystemCertificates(CFDictionaryRef query,CFTypeRef *result,BOOL *handled);
BOOL AKLoadSystemCertificateCandidates(NSString *path);
