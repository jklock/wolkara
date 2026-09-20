#import "TunnelTLS.h"

BOOL TKPairingTLSCipherAllowed(uint16_t cipher) {
    return cipher==0x00a8 || cipher==0x00a9 || cipher==0x00af || cipher==0x008c;
}

BOOL TKConfigurePairingTLS(sec_protocol_options_t options,NSData *sessionKey) {
    if(!options || (sessionKey.length!=32 && sessionKey.length!=64))return NO;
    sec_protocol_options_set_min_tls_protocol_version(options,tls_protocol_version_TLSv12);
    sec_protocol_options_set_max_tls_protocol_version(options,tls_protocol_version_TLSv12);
    // RFC 5487 AES-GCM PSK suites are selected by the actual iPadOS 27 service.
    // Retain the two CBC PSK suites for older peers; never accept NULL encryption
    // or certificate-only suites as proof of the authenticated pairing key.
    sec_protocol_options_append_tls_ciphersuite(options,(tls_ciphersuite_t)0x00a9);
    sec_protocol_options_append_tls_ciphersuite(options,(tls_ciphersuite_t)0x00a8);
    sec_protocol_options_append_tls_ciphersuite(options,(tls_ciphersuite_t)0x00af);
    sec_protocol_options_append_tls_ciphersuite(options,(tls_ciphersuite_t)0x008c);
    dispatch_data_t key=dispatch_data_create(sessionKey.bytes,sessionKey.length,
        dispatch_get_global_queue(QOS_CLASS_UTILITY,0),DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    sec_protocol_options_add_pre_shared_key(options,key,dispatch_data_empty);
    return YES;
}

nw_parameters_t TKPairingTLSParameters(NSData *sessionKey) {
    // Pair-verify X25519 gives 32 bytes; initial SRP/SHA512 gives 64 bytes.
    if(sessionKey.length!=32 && sessionKey.length!=64)return nil;
    NSData *keyCopy=[sessionKey copy];
    return nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
        TKConfigurePairingTLS(nw_tls_copy_sec_protocol_options(tls),keyCopy);
    },NW_PARAMETERS_DEFAULT_CONFIGURATION);
}
