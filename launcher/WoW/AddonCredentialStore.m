#import "AddonCredentialStore.h"
#import <Security/Security.h>

static NSString *const Service=@"local.wolkara.addons.curseforge.v1";
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
    if(!key.length){if(error)*error=[NSError errorWithDomain:@"Wolkara.AddOns" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The stored CurseForge key is unreadable."}];return nil;} return key;
}
- (BOOL)storeCurseForgeKey:(NSString *)key error:(NSError **)error {
    NSString *clean=[key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!clean.length||clean.length>1024||[clean rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){if(error)*error=[NSError errorWithDomain:@"Wolkara.AddOns" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Enter a valid CurseForge Core API key."}];return NO;}
    if([clean hasPrefix:@"$2a$"] || [clean hasPrefix:@"cfc_pat_"]){if(error)*error=[NSError errorWithDomain:@"Wolkara.AddOns" code:1 userInfo:@{NSLocalizedDescriptionKey:@"This is a password hash or upload personal-access token, not a CurseForge Core API key. Create a Core API key in the CurseForge developer console."}];return NO;}
    NSData *data=[clean dataUsingEncoding:NSUTF8StringEncoding]; NSMutableDictionary *attributes=[[self query] mutableCopy];attributes[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;attributes[(__bridge id)kSecValueData]=data;
    OSStatus status=SecItemAdd((__bridge CFDictionaryRef)attributes,nil); if(status==errSecDuplicateItem)status=SecItemUpdate((__bridge CFDictionaryRef)[self query],(__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:data,(__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly});
    if(status==errSecSuccess)return YES;if(error)*error=[NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];return NO;
}
- (BOOL)removeCurseForgeKey:(NSError **)error { OSStatus status=SecItemDelete((__bridge CFDictionaryRef)[self query]);if(status==errSecSuccess||status==errSecItemNotFound)return YES;if(error)*error=[NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];return NO; }
@end
