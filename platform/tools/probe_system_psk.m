// Local compatibility experiment only. Public, synthetic PSK, no device pairing
// records, no trust overrides and no Apple development service connections.
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import "TunnelTLS.h"
#import <Security/SecProtocolMetadata.h>

int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=2 && !(argc==3 && strcmp(argv[2],"--wrong-key")==0))return 64;
    char *end=NULL; long port=strtol(argv[1],&end,10);
    if(!end || *end || port<1 || port>65535)return 64;
    dispatch_queue_t queue=dispatch_queue_create("local.tolkara.psk-probe",DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t complete=dispatch_semaphore_create(0);
    __block int result=1;
    uint8_t fixture[32]; for(unsigned i=0;i<sizeof fixture;i++)fixture[i]=(uint8_t)i;
    if(argc==3)fixture[0]^=1;
    nw_parameters_t parameters=TKPairingTLSParameters([NSData dataWithBytes:fixture length:sizeof fixture]);
    if(!parameters)return 65;
    nw_connection_t connection=nw_connection_create(nw_endpoint_create_host("127.0.0.1",argv[1]),parameters);
    nw_connection_set_queue(connection,queue);
    nw_connection_set_state_changed_handler(connection,^(nw_connection_state_t state,nw_error_t error) {
        if(state==nw_connection_state_ready) {
            nw_protocol_metadata_t tls=nw_connection_copy_protocol_metadata(connection,nw_protocol_copy_tls_definition());
            sec_protocol_metadata_t metadata=nw_tls_copy_sec_protocol_metadata(tls);
            unsigned suite=sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata);
            unsigned version=sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata);
            printf("TLS version=%04x cipher=%04x\n",version,suite);
            if(version!=0x0303 || !TKPairingTLSCipherAllowed(suite)) {
                result=2; dispatch_semaphore_signal(complete); return;
            }
            static const char request[]="GET / HTTP/1.0\r\n\r\n";
            dispatch_data_t data=dispatch_data_create(request,sizeof request-1,queue,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
            nw_connection_send(connection,data,NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,true,^(nw_error_t sendError) {
                if(sendError) { dispatch_semaphore_signal(complete); return; }
                nw_connection_receive(connection,12,4096,^(dispatch_data_t response,nw_content_context_t context,bool done,nw_error_t receiveError) {
                    (void)context; (void)done;
                    if(response && !receiveError) {
                        const void *dataBytes=NULL;size_t count=0;
                        dispatch_data_t mapped=dispatch_data_create_map(response,&dataBytes,&count);
                        if(mapped && count>=12 && memcmp(dataBytes,"HTTP/1.0 200",12)==0) {
                            puts("Authenticated application data received"); result=0;
                        }
                    }
                    dispatch_semaphore_signal(complete);
                });
            });
        } else if(state==nw_connection_state_failed || state==nw_connection_state_waiting) {
            printf("System TLS failure domain=%d code=%d\n",error?(int)nw_error_get_error_domain(error):0,error?nw_error_get_error_code(error):0);
            dispatch_semaphore_signal(complete);
        }
    });
    nw_connection_start(connection);
    if(dispatch_semaphore_wait(complete,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))) {
        puts("System TLS compatibility probe timed out"); result=3;
    }
    nw_connection_cancel(connection);
    return result;
}}
