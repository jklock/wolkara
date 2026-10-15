#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/emulation
names=(CSSM_Init CSSM_ModuleLoad CSSM_ModuleAttach CSSM_ModuleDetach
 CSSM_CSP_CreateDeriveKeyContext CSSM_DeriveKey CSSM_CSP_CreateSymmetricContext
 CSSM_DeleteContext CSSM_FreeKey CSSM_EncryptData CSSM_DecryptData gGuidAppleCSP)
renames=(); for name in "${names[@]}"; do renames+=("-D$name=AK_$name"); done
cc=(xcrun clang -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations
 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer)
"${cc[@]}" "${renames[@]}" -c translation/Security/LegacyCrypto.c -o build/emulation/legacy_crypto.o
"${cc[@]}" tests/test_legacy_crypto.c build/emulation/legacy_crypto.o -framework Security -o build/emulation/test_legacy_crypto
build/emulation/test_legacy_crypto
