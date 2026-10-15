#include <Security/cssm.h>
#include <Security/cssmapple.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define DECLARE(name) extern __typeof__(name) AK_##name
DECLARE(CSSM_Init);DECLARE(CSSM_ModuleLoad);DECLARE(CSSM_ModuleAttach);DECLARE(CSSM_ModuleDetach);
DECLARE(CSSM_CSP_CreateDeriveKeyContext);DECLARE(CSSM_DeriveKey);DECLARE(CSSM_CSP_CreateSymmetricContext);
DECLARE(CSSM_DeleteContext);DECLARE(CSSM_FreeKey);DECLARE(CSSM_EncryptData);DECLARE(CSSM_DecryptData);
static void *allocate(CSSM_SIZE n,void *ref){(void)ref;return malloc(n);}
static void release(void *p,void *ref){(void)ref;free(p);}
static void *resize(void *p,CSSM_SIZE n,void *ref){(void)ref;return realloc(p,n);}
static void *zero(uint32 n,CSSM_SIZE size,void *ref){(void)ref;return calloc(n,size);}
int main(void){
    CSSM_VERSION version={2,0};CSSM_PVC_MODE policy=CSSM_PVC_NONE;
    CSSM_API_MEMORY_FUNCS mem={allocate,release,resize,zero,NULL};
    assert(AK_CSSM_Init(&version,0,&gGuidAppleCSP,0,&policy,NULL)==0);
    assert(CSSM_Init(&version,0,&gGuidAppleCSP,0,&policy,NULL)==0);
    assert(CSSM_ModuleLoad(&gGuidAppleCSP,0,NULL,NULL)==0);
    assert(AK_CSSM_ModuleLoad(&gGuidAppleCSP,0,NULL,NULL)==0);
    CSSM_CSP_HANDLE native=0,adapted=0;
    assert(CSSM_ModuleAttach(&gGuidAppleCSP,&version,&mem,0,CSSM_SERVICE_CSP,0,0,NULL,0,NULL,&native)==0);
    assert(AK_CSSM_ModuleAttach(&gGuidAppleCSP,&version,&mem,0,CSSM_SERVICE_CSP,0,0,NULL,0,NULL,&adapted)==0);
    uint8 saltbytes[16]={0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
    uint8 ivbytes[16]={0,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1};
    CSSM_DATA salt={sizeof saltbytes,saltbytes},iv={sizeof ivbytes,ivbytes},label={4,(uint8 *)"test"};
    CSSM_PKCS5_PBKDF2_PARAMS params={{19,(uint8 *)"synthetic-test-only"},CSSM_PKCS5_PBKDF2_PRF_HMAC_SHA1};
    CSSM_DATA param={sizeof params,(uint8 *)&params};
    for(unsigned bits=128;bits<=256;bits+=64){
        CSSM_CC_HANDLE nc=0,ac=0;CSSM_KEY nk={0},ak={0};
        assert(CSSM_CSP_CreateDeriveKeyContext(native,CSSM_ALGID_PKCS5_PBKDF2,CSSM_ALGID_AES,bits,NULL,NULL,1000,&salt,NULL,&nc)==0);
        assert(AK_CSSM_CSP_CreateDeriveKeyContext(adapted,CSSM_ALGID_PKCS5_PBKDF2,CSSM_ALGID_AES,bits,NULL,NULL,1000,&salt,NULL,&ac)==0);
        assert(CSSM_DeriveKey(nc,&param,CSSM_KEYUSE_ANY,CSSM_KEYATTR_RETURN_DATA|CSSM_KEYATTR_EXTRACTABLE,&label,NULL,&nk)==0);
        assert(AK_CSSM_DeriveKey(ac,&param,CSSM_KEYUSE_ANY,CSSM_KEYATTR_RETURN_DATA|CSSM_KEYATTR_EXTRACTABLE,&label,NULL,&ak)==0);
        assert(nk.KeyData.Length==ak.KeyData.Length && !memcmp(nk.KeyData.Data,ak.KeyData.Data,ak.KeyData.Length));
        assert(CSSM_DeleteContext(nc)==0);assert(AK_CSSM_DeleteContext(ac)==0);
        assert(AK_CSSM_DeleteContext(ac)!=0);
        assert(CSSM_CSP_CreateSymmetricContext(native,CSSM_ALGID_AES,CSSM_ALGMODE_CBCPadIV8,NULL,&nk,&iv,CSSM_PADDING_PKCS7,NULL,&nc)==0);
        assert(AK_CSSM_CSP_CreateSymmetricContext(adapted,CSSM_ALGID_AES,CSSM_ALGMODE_CBCPadIV8,NULL,&ak,&iv,CSSM_PADDING_PKCS7,NULL,&ac)==0);
        CSSM_DATA plain={28,(uint8 *)"fictional launcher test value"},cipher={0},reference={0},decoded={0},remain={0};CSSM_SIZE actual=0;
        assert(CSSM_EncryptData(nc,&plain,1,&reference,1,&actual,&remain)==0 && remain.Length==0);
        assert(AK_CSSM_EncryptData(ac,&plain,1,&cipher,1,&actual,&remain)==0 && remain.Length==0);
        assert(reference.Length==cipher.Length && !memcmp(reference.Data,cipher.Data,cipher.Length));
        assert(AK_CSSM_DecryptData(ac,&reference,1,&decoded,1,&actual,&remain)==0);
        assert(actual==plain.Length && decoded.Length==plain.Length && !memcmp(decoded.Data,plain.Data,plain.Length));
        free(decoded.Data); decoded=(CSSM_DATA){0};
        reference.Data[reference.Length-17]^=4; // CBC makes the final padding byte zero.
        CSSM_RETURN corrupt=AK_CSSM_DecryptData(ac,&reference,1,&decoded,1,&actual,&remain); fprintf(stderr,"synthetic invalid padding: status=%d bytes=%zu cipher=%zu\n",corrupt,actual,reference.Length); assert(corrupt!=0 && !decoded.Data && actual==0);
        uint8 small[2]={42,43};CSSM_DATA short_output={sizeof small,small};
        assert(AK_CSSM_EncryptData(ac,&plain,1,&short_output,1,&actual,&remain)!=0 && small[0]==42);
        assert(AK_CSSM_EncryptData(ac,&plain,2,&decoded,1,&actual,&remain)!=0);
        free(cipher.Data);free(reference.Data);
        assert(CSSM_DeleteContext(nc)==0);assert(AK_CSSM_DeleteContext(ac)==0);
        assert(CSSM_FreeKey(native,NULL,&nk,0)==0);assert(AK_CSSM_FreeKey(adapted,NULL,&ak,0)==0 && !ak.KeyData.Data);
    }
    CSSM_CC_HANDLE bad=99;
    assert(AK_CSSM_CSP_CreateDeriveKeyContext(adapted,CSSM_ALGID_PKCS5_PBKDF2,CSSM_ALGID_AES,127,NULL,NULL,1000,&salt,NULL,&bad)!=0 && bad==0);
    assert(AK_CSSM_ModuleDetach(adapted)==0);assert(AK_CSSM_ModuleDetach(adapted)!=0);assert(CSSM_ModuleDetach(native)==0);
    puts("legacy crypto: ABI and PBKDF2/AES match native macOS CSSM; malformed inputs rejected");
}
