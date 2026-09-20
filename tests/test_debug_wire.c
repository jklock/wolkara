#include "DebugWire.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>

static DWEvent receive(DWParser *p,const void *bytes,size_t length) {
    const uint8_t *b=bytes;DWEvent event=DW_MORE;
    for(size_t i=0;i<length;i++) {event=dw_feed(p,b[i]);if(i+1<length)assert(event==DW_MORE);}
    return event;
}
int main(void) {
    uint8_t buffer[1024],encoded[2048],input[256];DWParser p;dw_init(&p,buffer,sizeof buffer);
    assert(dw_feed(&p,'+')==DW_ACK && dw_feed(&p,'-')==DW_NACK);
    assert(receive(&p,"$OK#9a",6)==DW_PACKET && p.length==2 && !memcmp(buffer,"OK",2));
    assert(receive(&p,"$OK#9b",6)==DW_BAD_CHECKSUM && p.length==0);
    assert(receive(&p,"$#00",4)==DW_PACKET && p.length==0);
    for(unsigned i=0;i<256;i++)input[i]=(uint8_t)i;
    size_t n=dw_encode(input,sizeof input,encoded,sizeof encoded);assert(n==264);
    assert(receive(&p,encoded,n)==DW_PACKET && p.length==256 && !memcmp(buffer,input,256));
    // Standard RLE: 'A' followed by three more 'A's (32 = 3 + 29).
    assert(receive(&p,"$A* #8b",7)==DW_PACKET && p.length==4 && !memcmp(buffer,"AAAA",4));
    assert(dw_feed(&p,'$')==DW_MORE && dw_feed(&p,'*')==DW_MORE && dw_feed(&p,' ')==DW_MALFORMED);
    assert(receive(&p,"$OK#x",5)==DW_MALFORMED);
    encoded[0]='%';assert(receive(&p,encoded,n)==DW_NOTIFICATION && p.length==256);
    uint8_t small[4]={1,2,3,4},before[4];memcpy(before,small,4);
    assert(dw_encode("A",1,small,4)==0 && !memcmp(before,small,4));
    assert(dw_encode(NULL,0,small,4)==4 && !memcmp(small,"$#00",4));
    assert(!dw_encode(NULL,1,encoded,sizeof encoded));
    dw_init(&p,buffer,3);
    assert(receive(&p,"$A* ",4)==DW_OVERFLOW && !p.length);
    assert(receive(&p,"$ABCD",5)==DW_OVERFLOW && !p.length);
    assert(receive(&p,"$OK#9a",6)==DW_PACKET && p.length==2);
    assert(receive(&p,"$bad$",5)==DW_MALFORMED);
    assert(receive(&p,"OK#9a",5)==DW_PACKET && p.length==2);
    dw_init(&p,buffer,sizeof buffer);
    uint32_t state=42;
    for(unsigned i=0;i<200000;i++) {state=state*1664525u+1013904223u;(void)dw_feed(&p,(uint8_t)(state>>24));assert(p.length<=p.capacity);}
    puts("PASS: bounded debugger wire framing, checksum, binary escaping, RLE, notifications and stream recovery");
    return 0;
}
