#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/SecProtocolOptions.h>

NS_ASSUME_NONNULL_BEGIN
// Creates a TLS 1.2 PSK configuration for a session established by authenticated
// Remote Pairing. No sockets opened, trust overrides installed, or readiness
// asserted. Caller must bound connection/receive times and cancel on failure.
BOOL TKConfigurePairingTLS(sec_protocol_options_t options, NSData *sessionKey);
BOOL TKPairingTLSCipherAllowed(uint16_t cipher);
nw_parameters_t _Nullable TKPairingTLSParameters(NSData *sessionKey);
NS_ASSUME_NONNULL_END
