#include "LocalRoute.h"
#include <string.h>

LRResult lr_reflect(const LocalRoute *r,void *packet,size_t length) {
    if(!r || !packet || length<20)return LR_MALFORMED;
    uint8_t *p=packet;
    size_t header=(p[0]&15u)*4u,total=((size_t)p[2]<<8)|p[3];
    if((p[0]>>4)!=4 || header<20 || header>length || total!=length)return LR_MALFORMED;
    if(memcmp(p+12,r->interface_address,4) || memcmp(p+16,r->peer_address,4))return LR_UNRELATED;
    // Swapping the two addresses preserves their one's-complement sum, so both
    // the IPv4 checksum and TCP/UDP pseudo-header checksums remain unchanged.
    uint8_t source[4];memcpy(source,p+12,4);memcpy(p+12,p+16,4);memcpy(p+16,source,4);
    return LR_REFLECTED;
}
