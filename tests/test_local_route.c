#include "LocalRoute.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static unsigned checksum(const unsigned char *p,size_t n,unsigned sum) {
    for(size_t i=0;i+1<n;i+=2)sum+=((unsigned)p[i]<<8)|p[i+1];
    if(n&1)sum+=(unsigned)p[n-1]<<8;
    while(sum>>16)sum=(sum&65535)+(sum>>16);
    return (~sum)&65535;
}
int main(void) {
    const LocalRoute r={{10,7,0,2},{10,7,0,1}};
    unsigned char packet[44]={0x45,0,0,44,0,0,0,0,64,6,0,0,10,7,0,2,10,7,0,1};
    packet[20]=0xc0;packet[21]=0x01;packet[22]=0xc0;packet[23]=0x00;packet[32]=0x50;packet[33]=2;
    packet[40]=0xde;packet[41]=0xad;packet[42]=0xbe;packet[43]=0xef;
    unsigned tcp=checksum(packet+20,24,(~checksum(packet+12,8,0)&65535)+6+24);
    packet[36]=(unsigned char)(tcp>>8);packet[37]=(unsigned char)tcp;
    unsigned ip=checksum(packet,20,0);packet[10]=(unsigned char)(ip>>8);packet[11]=(unsigned char)ip;
    unsigned char original[44];memcpy(original,packet,44);
    assert(lr_reflect(&r,packet,sizeof packet)==LR_REFLECTED);
    assert(!memcmp(packet+12,r.peer_address,4) && !memcmp(packet+16,r.interface_address,4));
    assert(!memcmp(packet+20,original+20,24));
    assert(checksum(packet,20,0)==0);
    assert(checksum(packet+20,24,(~checksum(packet+12,8,0)&65535)+6+24)==0);
    // Reply path has the same outbound interface -> peer direction.
    unsigned char address[4];memcpy(address,packet+12,4);memcpy(packet+12,packet+16,4);memcpy(packet+16,address,4);
    assert(lr_reflect(&r,packet,sizeof packet)==LR_REFLECTED);
    packet[16]=8;unsigned char unrelated[44];memcpy(unrelated,packet,44);
    assert(lr_reflect(&r,packet,sizeof packet)==LR_UNRELATED && !memcmp(packet,unrelated,44));
    assert(lr_reflect(NULL,packet,44)==LR_MALFORMED);
    assert(lr_reflect(&r,NULL,44)==LR_MALFORMED);
    for(size_t n=0;n<sizeof packet;n++)assert(lr_reflect(&r,packet,n)==LR_MALFORMED);
    packet[0]=0x65;assert(lr_reflect(&r,packet,44)==LR_MALFORMED);
    packet[0]=0x44;assert(lr_reflect(&r,packet,44)==LR_MALFORMED);
    packet[0]=0x4f;assert(lr_reflect(&r,packet,44)==LR_MALFORMED);
    // Fuzz malformed headers without touching beyond the supplied packet extent.
    for(unsigned i=0;i<256;i++) {packet[0]=(unsigned char)i;for(size_t n=0;n<=44;n++)(void)lr_reflect(&r,packet,n);}
    puts("PASS: local-only route, payload/checksum preservation, unrelated traffic and malformed bounds");
}
