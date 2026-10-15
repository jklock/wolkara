# Draft technical question: large virtual reservations on iPadOS

Not sent. This reproducer contains no game or system code, credentials, device
identifiers, or provisioning material.

## Question for Apple Developer Technical Support

We are developing an arm64 application compatibility runtime on iPadOS. It
needs to preserve the semantics of large anonymous mmap reservations used by
an unchanged macOS application. The reservations are mostly untouched virtual
address space; this is not a request for 112 GiB of resident RAM.

On an iPad Pro M5 running iPadOS 27, an app provisioned with both
`com.apple.developer.kernel.extended-virtual-addressing` and
`com.apple.developer.kernel.increased-memory-limit` produces:

1. Reserve 16 GiB: succeeds.
2. Retain it and reserve 64 GiB: fails with ENOMEM.
3. Retain the first mapping and reserve 32 GiB: succeeds.

A fresh run can reserve a single 64 GiB range. Cumulative 4 GiB reservations
stop at 64 GiB for read/write, PROT_NONE, and private file-backed mappings.
TASK_VM_INFO reports a maximum address of 0x8000000000 (512 GiB). A
nonoverwriting fixed 1 GiB scan finds usable windows only from 448 to 512 GiB.
Changing host malloc configuration does not increase that capacity. We also
tried the loader's `DYLD_SHARED_REGION=private` option in the standalone app;
iPadOS terminated it before main with CODESIGNING / Invalid Page in dyld.

Is there a supported API or provisionable capability for a third-party iPad
app to hold these separate 16, 64, and 32 GiB mappings, with additional space
for ordinary application allocations? Public XNU sources contain an
extra-jumbo path associated with `com.apple.kernel.large-file-virtual-addressing`.
Our profile does not grant that entitlement. Is that capability available for
this use case, or is there another supported mechanism?

## Minimal reproducer

`vm_capacity.c` performs the three mmap calls, retains each successful result,
prints addresses and errno, then releases them. It touches no mapped pages.
Call `tk_vm_capacity_report(stdout)` from a development-signed iPad app with
the two ordinary memory entitlements. No debugger is needed.

For a macOS comparison:

```sh
xcrun clang -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror \
  -DTK_VM_CAPACITY_MAIN support/vm_capacity.c -o /tmp/vm_capacity
/tmp/vm_capacity
```

## Separate question for the application publisher

Does the GOG macOS arm64 2.3.x build of Cyberpunk 2077 expose a supported setting
to reduce its initial 16, 64, and 32 GiB anonymous virtual reservations? These
occur during static initialization, before the game reads engine/config.
Changing the RAM size returned by `sysctlbyname("hw.memsize")` to 2 or 8 GiB
in a compatibility test did not change those requests. No pool-size setting
was found in the shipped text configuration files. We seek a supported
configuration that preserves the original executable, not a binary patch.
