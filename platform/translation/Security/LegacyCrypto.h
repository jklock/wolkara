#pragma once
// LP64 CDSA ABI from Apple's macOS Security headers. iOS has CommonCrypto,
// but does not ship the retired CDSA declarations or entry points.
#include <stdint.h>
#include <stddef.h>
typedef int32_t AKCSSMReturn;
typedef uintptr_t AKCSSMHandle;
typedef struct { size_t Length; uint8_t *Data; } AKCSSMData;
typedef struct { uint8_t bytes[16]; } AKCSSMGuid;
typedef struct { uint32_t Major,Minor; } AKCSSMVersion;
typedef struct {
    uint32_t HeaderVersion; AKCSSMGuid CspId;
    uint32_t BlobType,Format,AlgorithmId,KeyClass,LogicalKeySizeInBits,KeyAttr,KeyUsage;
    uint8_t StartDate[8],EndDate[8]; uint32_t WrapAlgorithmId,WrapMode,Reserved;
} AKCSSMKeyHeader;
typedef struct { AKCSSMKeyHeader KeyHeader; AKCSSMData KeyData; } AKCSSMKey;
typedef struct { AKCSSMData Passphrase; uint32_t PseudoRandomFunction; } AKCSSMPBKDF2;
typedef struct {
    void *(*malloc_func)(size_t,void *); void (*free_func)(void *,void *);
    void *(*realloc_func)(void *,size_t,void *); void *(*calloc_func)(uint32_t,size_t,void *);
    void *AllocRef;
} AKCSSMMemory;
extern const AKCSSMGuid gGuidAppleCSP;
AKCSSMReturn CSSM_Init(const AKCSSMVersion *,uint32_t,const AKCSSMGuid *,uint32_t,uint32_t *,const void *);
AKCSSMReturn CSSM_ModuleLoad(const AKCSSMGuid *,uint32_t,void *,void *);
AKCSSMReturn CSSM_ModuleAttach(const AKCSSMGuid *,const AKCSSMVersion *,const AKCSSMMemory *,uint32_t,uint32_t,uint32_t,uint32_t,void *,uint32_t,const void *,AKCSSMHandle *);
AKCSSMReturn CSSM_ModuleDetach(AKCSSMHandle);
AKCSSMReturn CSSM_CSP_CreateDeriveKeyContext(AKCSSMHandle,uint32_t,uint32_t,uint32_t,const void *,const AKCSSMKey *,uint32_t,const AKCSSMData *,const void *,AKCSSMHandle *);
AKCSSMReturn CSSM_DeriveKey(AKCSSMHandle,AKCSSMData *,uint32_t,uint32_t,const AKCSSMData *,const void *,AKCSSMKey *);
AKCSSMReturn CSSM_CSP_CreateSymmetricContext(AKCSSMHandle,uint32_t,uint32_t,const void *,const AKCSSMKey *,const AKCSSMData *,uint32_t,void *,AKCSSMHandle *);
AKCSSMReturn CSSM_DeleteContext(AKCSSMHandle);
AKCSSMReturn CSSM_FreeKey(AKCSSMHandle,const void *,AKCSSMKey *,uint32_t);
AKCSSMReturn CSSM_EncryptData(AKCSSMHandle,const AKCSSMData *,uint32_t,AKCSSMData *,uint32_t,size_t *,AKCSSMData *);
AKCSSMReturn CSSM_DecryptData(AKCSSMHandle,const AKCSSMData *,uint32_t,AKCSSMData *,uint32_t,size_t *,AKCSSMData *);
