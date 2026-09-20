#import "LibraryContainer.h"
#import <CommonCrypto/CommonDigest.h>

static uint64_t number(const uint8_t *p,unsigned count) {
    uint64_t value=0;for(unsigned i=0;i<count;i++)value|=(uint64_t)p[i]<<(8*i);return value;
}
static BOOL section(uint64_t offset,uint64_t size,size_t length) {
    return offset>=88 && offset<=length && size<=length-offset;
}
NSData *AKLocalMetalLibraryData(NSData *original) {
    const uint8_t *b=original.bytes;size_t length=original.length;
    if(length<88 || length>64*1024*1024 || memcmp(b,"MTLB\1\200\2\0",8))return nil;
    // These are the actual legacy containers emitted for AIR 2.0, 2.1, 2.3.
    // Do not change AIR revisions, instructions, resource bindings or hashes.
    if((b[8]!=2 && b[8]!=3 && b[8]!=5) || number(b+9,7)!=0 || number(b+16,8)!=length)return nil;
    uint64_t table=number(b+24,8),tableSize=number(b+32,8);
    uint64_t pub=number(b+40,8),pubSize=number(b+48,8);
    uint64_t priv=number(b+56,8),privSize=number(b+64,8);
    uint64_t code=number(b+72,8),codeSize=number(b+80,8);
    if(!section(table,tableSize,length) || !section(pub,pubSize,length) ||
       !section(priv,privSize,length) || !section(code,codeSize,length) ||
       table>pub || pub-table<4 || tableSize>pub-table || priv<pub || pubSize>priv-pub ||
       code<priv || privSize>code-priv)return nil;
    uint64_t count=number(b+table,4),pos=table+4;
    if(!count || count>65536)return nil;
    for(uint64_t i=0;i<count;i++) {
        if(pos>pub || pub-pos<4)return nil;
        uint64_t size=number(b+pos,4);
        if(size<8 || size>pub-pos)return nil;
        uint64_t end=pos+size;pos+=4;
        const uint8_t *hash=NULL,*offsets=NULL,*moduleSize=NULL,*version=NULL;
        BOOL terminated=NO;
        while(end-pos>=4) {
            const uint8_t *tag=b+pos;pos+=4;
            if(!memcmp(tag,"ENDT",4)){terminated=YES;break;}
            if(end-pos<2)return nil;
            uint64_t n=number(b+pos,2);pos+=2;
            if(n>end-pos)return nil;
            const uint8_t **field=NULL;uint64_t required=0;
            if(!memcmp(tag,"HASH",4)){field=&hash;required=32;}
            else if(!memcmp(tag,"OFFT",4)){field=&offsets;required=24;}
            else if(!memcmp(tag,"MDSZ",4)){field=&moduleSize;required=8;}
            else if(!memcmp(tag,"VERS",4)){field=&version;required=8;}
            if(field){if(*field || n!=required)return nil;*field=b+pos;}
            pos+=n;
        }
        if(!terminated || pos!=end || !hash || !offsets || !moduleSize || !version)return nil;
        if(number(version,2)!=2 || number(version+2,2)!=(uint64_t)b[8]-2)return nil;
        uint64_t offset=number(offsets+16,8),n=number(moduleSize,8);
        if(offset>codeSize || n>codeSize-offset || n<24)return nil;
        const uint8_t *module=b+code+offset;
        uint64_t start=number(module+8,4),bitcode=number(module+12,4);
        if(number(module,4)!=0x0b17c0de || number(module+4,4)!=0 || start<20 || start>n ||
           bitcode<4 || bitcode>n-start || memcmp(module+start,"BC\300\336",4))return nil;
        uint8_t actual[CC_SHA256_DIGEST_LENGTH];CC_SHA256(module,(CC_LONG)n,actual);
        if(memcmp(actual,hash,sizeof actual))return nil;
    }
    NSMutableData *derived=[original mutableCopy];uint8_t *header=derived.mutableBytes;
    header[5]=0;header[11]=0x82;
    return [derived copy];
}
