#include "LegacyCrypto.h"
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

_Static_assert(sizeof(AKCSSMKeyHeader)==76 && sizeof(AKCSSMKey)==96,"macOS key ABI");
_Static_assert(offsetof(AKCSSMKey,KeyData)==80 && sizeof(AKCSSMPBKDF2)==24,"macOS crypto ABI");
const AKCSSMGuid gGuidAppleCSP={{0x87,0x19,0x1c,0xa2,0x0f,0xc9,0x11,0xd4,0x84,0x9a,0,5,2,0xb5,0x21,0x22}};
enum { OK=0, MEMORY=-2147416062, POINTER=-2147416060, UNSUPPORTED=-2147416057,
    CONTEXT=-2147416000, DATA=-2147415994, OUTPUT=-2147415806, KEY=-2147415792 };
#define AES_ID UINT32_C(0x80000001)
#define MAX_DATA (1024*1024)
typedef struct Module { AKCSSMHandle id; AKCSSMMemory memory; struct Module *next; } Module;
typedef struct Context {
    AKCSSMHandle id,module; unsigned kind,bits,rounds,padding;
    uint8_t key[32],iv[16],*salt; size_t key_size,salt_size;
    struct Context *next;
} Context;
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static Module *modules; static Context *contexts; static uintptr_t serial=1;
static Module *module(AKCSSMHandle id) { for(Module *p=modules;p;p=p->next) if(p->id==id)return p; return NULL; }
static Context *context(AKCSSMHandle id) { for(Context *p=contexts;p;p=p->next) if(p->id==id)return p; return NULL; }
static bool valid_guid(const AKCSSMGuid *g) { return g && !memcmp(g,&gGuidAppleCSP,sizeof *g); }
static bool valid_data(const AKCSSMData *d) { return d && d->Length<=MAX_DATA && (!d->Length || d->Data); }
static void wipe(void *p,size_t n) { volatile uint8_t *v=p; while(n--)*v++=0; }
AKCSSMReturn CSSM_Init(const AKCSSMVersion *v,uint32_t scope,const AKCSSMGuid *g,uint32_t hierarchy,uint32_t *policy,const void *reserved) {
    (void)g; (void)policy;
    return v && v->Major==2 && v->Minor==0 && !scope && !hierarchy && !reserved ? OK:UNSUPPORTED;
}
AKCSSMReturn CSSM_ModuleLoad(const AKCSSMGuid *g,uint32_t hierarchy,void *callback,void *ctx) {
    (void)ctx; return valid_guid(g) && !hierarchy && !callback ? OK:UNSUPPORTED;
}
AKCSSMReturn CSSM_ModuleAttach(const AKCSSMGuid *g,const AKCSSMVersion *v,const AKCSSMMemory *mem,uint32_t sub,uint32_t service,uint32_t flags,uint32_t hierarchy,void *table,uint32_t count,const void *reserved,AKCSSMHandle *out) {
    if(!out)return POINTER; *out=0;
    if(!valid_guid(g)||!v||v->Major!=2||v->Minor||sub||service!=2||flags||hierarchy||table||count||reserved)return UNSUPPORTED;
    if(!mem||!mem->malloc_func||!mem->free_func)return POINTER;
    Module *p=calloc(1,sizeof *p); if(!p)return MEMORY; p->memory=*mem;
    pthread_mutex_lock(&lock);p->id=serial++;p->next=modules;modules=p;*out=p->id;pthread_mutex_unlock(&lock);return OK;
}
AKCSSMReturn CSSM_ModuleDetach(AKCSSMHandle id) {
    pthread_mutex_lock(&lock);
    for(Context *p=contexts;p;p=p->next)if(p->module==id){pthread_mutex_unlock(&lock);return CONTEXT;}
    Module **p=&modules;while(*p&&(*p)->id!=id)p=&(*p)->next;
    Module *old=*p;if(old)*p=old->next;pthread_mutex_unlock(&lock);free(old);return old?OK:CONTEXT;
}
static AKCSSMReturn add_context(Context *c,AKCSSMHandle id,AKCSSMHandle *out) {
    pthread_mutex_lock(&lock);
    if(!module(id)){pthread_mutex_unlock(&lock);free(c->salt);free(c);return CONTEXT;}
    c->id=serial++;c->module=id;c->next=contexts;contexts=c;*out=c->id;pthread_mutex_unlock(&lock);return OK;
}
AKCSSMReturn CSSM_CSP_CreateDeriveKeyContext(AKCSSMHandle id,uint32_t algorithm,uint32_t type,uint32_t bits,const void *credentials,const AKCSSMKey *base,uint32_t rounds,const AKCSSMData *salt,const void *seed,AKCSSMHandle *out) {
    (void)credentials;
    if(!out)return POINTER;*out=0;
    if(algorithm!=103||type!=AES_ID||(bits!=128&&bits!=192&&bits!=256)||!rounds||rounds>10000000||base||seed)return UNSUPPORTED;
    if(!valid_data(salt))return DATA;
    Context *c=calloc(1,sizeof *c);if(!c)return MEMORY;
    c->kind=1;c->bits=bits;c->rounds=rounds;c->salt_size=salt->Length;
    if(salt->Length){c->salt=malloc(salt->Length);if(!c->salt){free(c);return MEMORY;}memcpy(c->salt,salt->Data,salt->Length);}
    return add_context(c,id,out);
}
AKCSSMReturn CSSM_DeriveKey(AKCSSMHandle id,AKCSSMData *param,uint32_t usage,uint32_t attrs,const AKCSSMData *label,const void *acl,AKCSSMKey *key) {
    (void)label;
    if(!key)return POINTER;
    if(!valid_data(param)||param->Length!=sizeof(AKCSSMPBKDF2))return DATA;
    AKCSSMPBKDF2 params;memcpy(&params,param->Data,sizeof params);
    if(!valid_data(&params.Passphrase)||params.PseudoRandomFunction||acl || !(attrs&0x10000000) || (attrs&0x60000000))return UNSUPPORTED;
    pthread_mutex_lock(&lock);Context *c=context(id);Module *m=c?module(c->module):NULL;
    if(!c||c->kind!=1||!m){pthread_mutex_unlock(&lock);return CONTEXT;}
    size_t n=c->bits/8;uint8_t *bytes=m->memory.malloc_func(n,m->memory.AllocRef);
    if(!bytes){pthread_mutex_unlock(&lock);return MEMORY;}
    int result=CCKeyDerivationPBKDF(kCCPBKDF2,(const char *)params.Passphrase.Data,params.Passphrase.Length,c->salt,c->salt_size,kCCPRFHmacAlgSHA1,c->rounds,bytes,n);
    if(result){wipe(bytes,n);m->memory.free_func(bytes,m->memory.AllocRef);pthread_mutex_unlock(&lock);return DATA;}
    *key=(AKCSSMKey){.KeyHeader={.HeaderVersion=2,.CspId=gGuidAppleCSP,.BlobType=0,.Format=12,.AlgorithmId=AES_ID,.KeyClass=2,.LogicalKeySizeInBits=c->bits,.KeyAttr=attrs&0x0fffffff,.KeyUsage=usage},.KeyData={n,bytes}};
    pthread_mutex_unlock(&lock);return OK;
}
AKCSSMReturn CSSM_CSP_CreateSymmetricContext(AKCSSMHandle id,uint32_t algorithm,uint32_t mode,const void *credentials,const AKCSSMKey *key,const AKCSSMData *iv,uint32_t padding,void *reserved,AKCSSMHandle *out) {
    (void)credentials;
    if(!out)return POINTER;*out=0;
    if(algorithm!=AES_ID||mode!=6||padding!=7||reserved)return UNSUPPORTED;
    if(!key||key->KeyHeader.AlgorithmId!=AES_ID||key->KeyHeader.BlobType!=0||key->KeyHeader.Format!=12||key->KeyHeader.KeyClass!=2||!valid_data(&key->KeyData))return KEY;
    size_t n=key->KeyData.Length;if((n!=16&&n!=24&&n!=32)||key->KeyHeader.LogicalKeySizeInBits!=n*8)return KEY;
    if(!valid_data(iv)||iv->Length!=16)return DATA;
    Context *c=calloc(1,sizeof *c);if(!c)return MEMORY;
    c->kind=2;c->key_size=n;c->padding=padding;memcpy(c->key,key->KeyData.Data,n);memcpy(c->iv,iv->Data,16);
    return add_context(c,id,out);
}
AKCSSMReturn CSSM_DeleteContext(AKCSSMHandle id) {
    pthread_mutex_lock(&lock);Context **p=&contexts;while(*p&&(*p)->id!=id)p=&(*p)->next;Context *old=*p;if(old)*p=old->next;pthread_mutex_unlock(&lock);
    if(!old)return CONTEXT;free(old->salt);wipe(old,sizeof *old);free(old);return OK;
}
AKCSSMReturn CSSM_FreeKey(AKCSSMHandle id,const void *credentials,AKCSSMKey *key,uint32_t permanent) {
    (void)credentials;if(!key)return POINTER;if(permanent)return UNSUPPORTED;
    if(key->KeyHeader.BlobType!=0||!valid_data(&key->KeyData))return KEY;
    pthread_mutex_lock(&lock);Module *m=module(id);if(!m){pthread_mutex_unlock(&lock);return CONTEXT;}
    if(key->KeyData.Data){wipe(key->KeyData.Data,key->KeyData.Length);m->memory.free_func(key->KeyData.Data,m->memory.AllocRef);}memset(key,0,sizeof *key);pthread_mutex_unlock(&lock);return OK;
}
static AKCSSMReturn crypt_data(AKCSSMHandle id,const AKCSSMData *input,uint32_t input_count,AKCSSMData *output,uint32_t output_count,size_t *actual,AKCSSMData *remaining,CCOperation operation) {
    if(!actual||!remaining||!output)return POINTER;*actual=0;*remaining=(AKCSSMData){0};
    if(input_count!=1||output_count!=1)return UNSUPPORTED;
    if(!valid_data(input)||!valid_data(output))return DATA;
    pthread_mutex_lock(&lock);Context *c=context(id);Module *m=c?module(c->module):NULL;
    if(!c||c->kind!=2||!m){pthread_mutex_unlock(&lock);return CONTEXT;}
    size_t capacity=input->Length+16,n=0;uint8_t *scratch=malloc(capacity);if(!scratch){pthread_mutex_unlock(&lock);return MEMORY;}
    int result=CCCrypt(operation,kCCAlgorithmAES,operation==kCCEncrypt?kCCOptionPKCS7Padding:0,c->key,c->key_size,c->iv,input->Data,input->Length,scratch,capacity,&n);
    // CommonCrypto on some OS versions accepts a zero padding length. Require
    // the complete PKCS#7 padding block before publishing any cleartext.
    if(!result && operation==kCCDecrypt) {
        if(n<16) result=kCCDecodeError;
        else {
            unsigned padding=scratch[n-1],invalid=(padding==0 || padding>16);
            for(unsigned i=0;i<16;i++) invalid|=(i<padding)*(scratch[n-1-i]^padding);
            if(invalid)result=kCCDecodeError;else n-=padding;
        }
    }
    AKCSSMReturn status=OK;
    if(result)status=DATA;
    else if(output->Data&&output->Length<n)status=OUTPUT;
    else {
        if(!output->Data)output->Data=m->memory.malloc_func(n?n:1,m->memory.AllocRef);
        if(!output->Data)status=MEMORY;
        else {memcpy(output->Data,scratch,n);output->Length=n;*actual=n;}
    }
    wipe(scratch,capacity);free(scratch);pthread_mutex_unlock(&lock);
    if(operation==kCCDecrypt)fprintf(stderr,"[legacy-crypto] decrypt status=%d\n",status);
    return status;
}
AKCSSMReturn CSSM_EncryptData(AKCSSMHandle c,const AKCSSMData *i,uint32_t ni,AKCSSMData *o,uint32_t no,size_t *n,AKCSSMData *r){return crypt_data(c,i,ni,o,no,n,r,kCCEncrypt);}
AKCSSMReturn CSSM_DecryptData(AKCSSMHandle c,const AKCSSMData *i,uint32_t ni,AKCSSMData *o,uint32_t no,size_t *n,AKCSSMData *r){return crypt_data(c,i,ni,o,no,n,r,kCCDecrypt);}
