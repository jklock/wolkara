#include "DebugWire.h"
#include <string.h>

enum { SEEK, BODY, ESCAPE, REPEAT, CHECK_HIGH, CHECK_LOW };
static int hex(uint8_t c) {
    return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:c>='A'&&c<='F'?c-'A'+10:-1;
}
void dw_init(DWParser *p,void *buffer,size_t capacity) {
    *p=(DWParser){.payload=buffer,.capacity=buffer?capacity:0};
}
static DWEvent fail(DWParser *p,DWEvent event) {p->state=SEEK;p->length=0;return event;}
static DWEvent append(DWParser *p,uint8_t byte) {
    if(p->length==p->capacity)return fail(p,DW_OVERFLOW);
    p->payload[p->length++]=byte;return DW_MORE;
}
DWEvent dw_feed(DWParser *p,uint8_t b) {
    switch(p->state) {
        case SEEK:
            if(b=='+')return DW_ACK;
            if(b=='-')return DW_NACK;
            if(b=='$'||b=='%') {p->state=BODY;p->length=0;p->sum=0;p->notification=b=='%';}
            return DW_MORE;
        case BODY:
            if(b=='$') {p->length=0;p->sum=0;p->notification=false;return DW_MALFORMED;}
            if(b=='#') {p->state=CHECK_HIGH;return DW_MORE;}
            p->sum+=b;
            if(b=='}') {p->state=ESCAPE;return DW_MORE;}
            if(b=='*') {p->state=REPEAT;return DW_MORE;}
            return append(p,b);
        case ESCAPE:
            p->sum+=b;p->state=BODY;return append(p,b^0x20);
        case REPEAT: {
            p->sum+=b;p->state=BODY;
            if(!p->length || b<32 || b>126 || b=='$'||b=='#'||b=='+'||b=='-')return fail(p,DW_MALFORMED);
            size_t count=b-29;
            if(count>p->capacity-p->length)return fail(p,DW_OVERFLOW);
            memset(p->payload+p->length,p->payload[p->length-1],count);p->length+=count;return DW_MORE;
        }
        case CHECK_HIGH: {
            int digit=hex(b);if(digit<0)return fail(p,DW_MALFORMED);
            p->expected=(uint8_t)(digit<<4);p->state=CHECK_LOW;return DW_MORE;
        }
        case CHECK_LOW: {
            int digit=hex(b);if(digit<0)return fail(p,DW_MALFORMED);
            p->state=SEEK;
            if((p->expected|(unsigned)digit)!=p->sum)return fail(p,DW_BAD_CHECKSUM);
            return p->notification?DW_NOTIFICATION:DW_PACKET;
        }
    }
    return fail(p,DW_MALFORMED);
}
static bool needs_escape(uint8_t b) {return b=='$'||b=='#'||b=='}'||b=='*';}
size_t dw_encode(const void *payload,size_t length,void *destination,size_t capacity) {
    if(!destination || (length && !payload) || capacity<4 || length>capacity-4)return 0;
    const uint8_t *input=payload;uint8_t *out=destination;size_t needed=length+4;
    for(size_t i=0;i<length;i++)if(needs_escape(input[i])) {if(needed==capacity)return 0;needed++;}
    size_t at=0;uint8_t sum=0;out[at++]='$';
    for(size_t i=0;i<length;i++) {
        uint8_t b=input[i];
        if(needs_escape(b)) {out[at++]='}';sum+='}';b^=0x20;}
        out[at++]=b;sum+=b;
    }
    static const char digits[]="0123456789abcdef";
    out[at++]='#';out[at++]=(uint8_t)digits[sum>>4];out[at++]=(uint8_t)digits[sum&15];return at;
}
