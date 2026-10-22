#import "AddonCredentialStore.h"
#import <Security/Security.h>

static NSString *const Service=@"local.wolkaraforever.addons.curseforge.v1";
static NSString *const Account=@"api-key";

@implementation TKAddonCredentialStore
- (NSDictionary *)query {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:Service,(__bridge id)kSecAttrAccount:Account,
        (__bridge id)kSecAttrSynchronizable:@NO,(__bridge id)kSecUseDataProtectionKeychain:@YES};
}
- (nullable NSString *)curseForgeKey:(NSError **)error {
    NSMutableDictionary *query=[[self query] mutableCopy]; query[(__bridge id)kSecReturnData]=@YES; query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    CFTypeRef result=nil; OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)query,&result);
    if(status==errSecItemNotFound)return nil;
    if(status!=errSecSuccess){if(error)*error=[NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];return nil;}
    NSData *data=CFBridgingRelease(result);NSString *key=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!key.length){if(error)*error=[NSError errorWithDomain:@"WolkaraForever.AddOns" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The stored CurseForge key is unreadable."}];return nil;} return key;
}
- (BOOL)storeCurseForgeKey:(NSString *)key error:(NSError **)error {
    NSString *clean=[key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!clean.length||clean.length>1024||[clean rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){if(error)*error=[NSError errorWithDomain:@"WolkaraForever.AddOns" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Enter a valid CurseForge Core API key."}];return NO;}
    // CurseForge's approved Core API keys are issued in bcrypt's textual shape
    // ($2a$10$...) - that is the credential, not a password hash, and refusing
    // it rejected a real approved key. An upload personal-access token is a
    // different credential and does not work with the Core API.
    if([clean hasPrefix:@"cfc_pat_"]){if(error)*error=[NSError errorWithDomain:@"WolkaraForever.AddOns" code:1 userInfo:@{NSLocalizedDescriptionKey:@"This is a CurseForge upload personal-access token, not a Core API key. Paste the $2a$... key from the developer console."}];return NO;}
    NSData *data=[clean dataUsingEncoding:NSUTF8StringEncoding]; NSMutableDictionary *attributes=[[self query] mutableCopy];attributes[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;attributes[(__bridge id)kSecValueData]=data;
    OSStatus status=SecItemAdd((__bridge CFDictionaryRef)attributes,nil); if(status==errSecDuplicateItem)status=SecItemUpdate((__bridge CFDictionaryRef)[self query],(__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:data,(__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly});
    if(status==errSecSuccess)return YES;if(error)*error=[NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];return NO;
}
- (BOOL)removeCurseForgeKey:(NSError **)error { OSStatus status=SecItemDelete((__bridge CFDictionaryRef)[self query]);if(status==errSecSuccess||status==errSecItemNotFound)return YES;if(error)*error=[NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];return NO; }
@end
