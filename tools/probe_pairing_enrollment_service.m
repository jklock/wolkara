// Read-only discovery of the one-time enrollment channel over the Mac's existing
// trusted USB session. No pairing record, private key or device metadata logged.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <unistd.h>
#include <arpa/inet.h>

static int (*serviceSend)(void *,const void *,size_t);
static int (*serviceReceive)(void *,void *,size_t);
static BOOL transfer(void *connection,void *bytes,size_t size,BOOL writing) {
    size_t at=0;
    while(at<size) {
        int n=writing?serviceSend(connection,(char *)bytes+at,size-at):serviceReceive(connection,(char *)bytes+at,size-at);
        if(n<=0 || (size_t)n>size-at)return NO;
        at+=(size_t)n;
    }
    return YES;
}
// Private pipe protocol for our one-time enrollment coordinator. Never invoke
// this mode with stdout attached to a terminal or collect its stdout as a log.
static int enrollmentPipe(void *connection) {
    if(isatty(STDIN_FILENO)||isatty(STDOUT_FILENO))return 1;
    for(unsigned i=0;i<12;i++) {
        uint32_t count;size_t n=fread(&count,1,4,stdin);
        if(!n && feof(stdin))return 0;
        if(n!=4)return 1;
        size_t length=ntohl(count);if(length>16384)return 1;
        uint8_t header[11]={'R','P','P','a','i','r','i','n','g',0,0};
        if(length) {
            NSMutableData *body=[NSMutableData dataWithLength:length];
            if(fread(body.mutableBytes,1,length,stdin)!=length)return 1;
            id object=[NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
            id message=[object isKindOfClass:NSDictionary.class]?object[@"message"]:nil;
            id plain=[message isKindOfClass:NSDictionary.class]?message[@"plain"]:nil;
            if(![plain isKindOfClass:NSDictionary.class])return 1;
            header[9]=(uint8_t)(length>>8);header[10]=(uint8_t)length;
            if(!transfer(connection,header,11,YES)||!transfer(connection,body.mutableBytes,length,YES))return 1;
        }
        if(!transfer(connection,header,11,NO)||memcmp(header,"RPPairing",9))return 1;
        length=((size_t)header[9]<<8)|header[10];if(!length||length>16384)return 1;
        NSMutableData *reply=[NSMutableData dataWithLength:length];
        if(!transfer(connection,reply.mutableBytes,length,NO))return 1;
        count=htonl((uint32_t)length);
        if(fwrite(&count,1,4,stdout)!=4 || fwrite(reply.bytes,1,length,stdout)!=length || fflush(stdout))return 1;
    }
    return 1;
}
int main(int argc,char **argv) { @autoreleasepool {
    BOOL enroll=argc==3 && !strcmp(argv[2],"--enroll-stdio");
    if(argc!=2 && !enroll) {fprintf(stderr,"Usage: probe_pairing_enrollment_service DEVICE_UDID [--enroll-stdio]\n");return 2;}
    alarm(enroll?120:20);
    void *library=dlopen("/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",RTLD_NOW|RTLD_LOCAL);
    if(!library) {fprintf(stderr,"MobileDevice framework unavailable.\n");return 1;}
    CFArrayRef (*devices)(void)=dlsym(library,"AMDCreateDeviceList");
    CFStringRef (*identifier)(void *)=dlsym(library,"AMDeviceCopyDeviceIdentifier");
    int (*connectDevice)(void *)=dlsym(library,"AMDeviceConnect");
    int (*validate)(void *)=dlsym(library,"AMDeviceValidatePairing");
    int (*startSession)(void *)=dlsym(library,"AMDeviceStartSession");
    int (*stopSession)(void *)=dlsym(library,"AMDeviceStopSession");
    int (*disconnect)(void *)=dlsym(library,"AMDeviceDisconnect");
    int (*startService)(void *,CFStringRef,CFDictionaryRef,void **)=dlsym(library,"AMDeviceSecureStartService");
    int (*serviceSocket)(void *)=dlsym(library,"AMDServiceConnectionGetSocket");
    int (*invalidate)(void *)=dlsym(library,"AMDServiceConnectionInvalidate");
    serviceSend=dlsym(library,"AMDServiceConnectionSend"); serviceReceive=dlsym(library,"AMDServiceConnectionReceive");
    if(!devices||!identifier||!connectDevice||!validate||!startSession||!stopSession||!disconnect||!startService||!serviceSocket||!invalidate||!serviceSend||!serviceReceive) {
        fprintf(stderr,"Required system device-service entry point unavailable.\n");return 1;
    }
    CFArrayRef list=devices(); void *device=NULL;
    if(list)for(CFIndex i=0;i<CFArrayGetCount(list);i++) {
        void *candidate=(void *)CFArrayGetValueAtIndex(list,i);
        CFStringRef value=identifier(candidate);
        BOOL matches=value && [(__bridge NSString *)value isEqualToString:[NSString stringWithUTF8String:argv[1]]];
        if(value)CFRelease(value);
        if(matches) {device=candidate;break;}
    }
    if(!device) {fprintf(stderr,"Selected device unavailable.\n");if(list)CFRelease(list);return 1;}
    int result=1,status=connectDevice(device);BOOL connected=status==0,session=NO;
    void *connection=NULL;
    if(connected && !(status=validate(device)) && !(status=startSession(device))) {
        session=YES;
        status=startService(device,CFSTR("com.apple.dt.remotepairingdeviced.lockdown"),NULL,&connection);
        if(!status && connection) {
            struct timeval timeout={.tv_sec=enroll?60:5};int fd=serviceSocket(connection);
            setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout);
            setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof timeout);
            if(enroll) {result=enrollmentPipe(connection);goto cleanup;}
            NSDictionary *query=@{@"message":@{@"plain":@{@"_0":@{@"request":@{@"_0":@{@"handshake":@{@"_0":@{
                @"hostOptions":@{@"attemptPairVerify":@YES},@"wireProtocolVersion":@19}}}}}}},@"originatedBy":@"host",@"sequenceNumber":@0};
            NSData *body=[NSJSONSerialization dataWithJSONObject:query options:0 error:NULL];
            uint8_t header[11]={'R','P','P','a','i','r','i','n','g',0,0};
            header[9]=(uint8_t)(body.length>>8);header[10]=(uint8_t)body.length;
            if(transfer(connection,header,sizeof header,YES) && transfer(connection,(void *)body.bytes,body.length,YES) &&
               transfer(connection,header,sizeof header,NO) && !memcmp(header,"RPPairing",9)) {
                size_t length=((size_t)header[9]<<8)|header[10];
                if(length && length<=16384) {
                    NSMutableData *reply=[NSMutableData dataWithLength:length];
                    if(transfer(connection,reply.mutableBytes,length,NO)) {
                        id value=[NSJSONSerialization JSONObjectWithData:reply options:0 error:NULL];
                        BOOL valid=[value isKindOfClass:NSDictionary.class] && [value[@"originatedBy"] isEqual:@"device"];
                        for(NSString *key in @[@"message",@"plain",@"_0",@"response",@"_1",@"handshake",@"_0"])
                            value=[value isKindOfClass:NSDictionary.class]?value[key]:nil;
                        if(valid && [value isKindOfClass:NSDictionary.class]) {
                            puts("Trusted USB Remote Pairing enrollment channel answered its read-only handshake. No new pairing created or credentials exported.");result=0;
                        }
                    }
                }
            }
        }
    }
cleanup:
    if(result)fprintf(stderr,"Enrollment service probe failed (system status 0x%x).\n",status);
    if(connection)invalidate(connection);
    if(session)stopSession(device);
    if(connected)disconnect(device);
    CFRelease(list);return result;
} }
