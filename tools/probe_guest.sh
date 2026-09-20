#!/bin/bash
# Inspect an original executable through the same soft-MMU loader used on iPad.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/emulation
xcrun clang -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -O2 -Iruntime \
  runtime/GuestMemory.c runtime/GuestImage.c runtime/GuestFixups.c tools/guest_probe.c -o build/emulation/guest_probe
exec build/emulation/guest_probe "$@"
