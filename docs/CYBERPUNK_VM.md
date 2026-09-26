# Cyberpunk virtual-memory investigation — 2026-09-26

The archive crash is reproducible by enabling the experimental VM budget in
the simulator. Preventing counted reservations from overlapping earlier
requested ranges removes that crash there. It does not make Cyberpunk run on
the iPad: the device cannot place the separate ranges and now reports ENOMEM
during initialization.

## Controlled runs

All runs used the unchanged GOG arm64 application, Developer service, and
`--native-startup --app=cyberpunk-2077 --trace-guest`. The debugger detached
before guest entry. Diagnosis used runtime logs and crash reports only.

| Environment | Budget / implementation | Result |
| --- | --- | --- |
| Simulator, previous baseline | Budget off | Opens 32 archives and `final.redscripts`; later Metal simulator failure. |
| iPad Pro M5, iPadOS 27, previous baseline | 49152 MiB, old adapter, CPU-brand fallback active | Opens one archive; SIGSEGV at preferred guest address `0x10000ec4c`, reading `0x18`. |
| Simulator, controlled reproduction | 49152 MiB, old adapter | Same one-archive failure, same preferred instruction and `0x18` fault. |
| Simulator, corrected placement | 49152 MiB | Opens all 32 archives and `final.redscripts`; later shader-cache load faults beyond a 256 MiB grant. |
| iPad Pro M5, iPadOS 27, corrected placement | 49152 MiB | Arena preparation completes in 213 s. The third large reservation (32 GiB), then two 1 GiB reservations, fail with ENOMEM. Startup attempts to write OOM reports. |

Changing the CPU-brand fallback did not remove the original device crash.
The controlled simulator reproduction does not need the iPad's CPU, GOG
network behavior, GameController class duplication, or filesystem differences.

## The placement defect

The old adapter reports these successful allocations:

| Requested | Returned base | Actually granted with the budget |
| --- | --- | --- |
| 16 GiB | `0x7000000000` | 16 GiB |
| 64 GiB | `0x7400000000` | 32 GiB plus a guard |
| 32 GiB | `0x7c00004000` | 256 MiB plus a guard |

The second call tells the guest that it owns
`[0x7400000000, 0x8400000000)`. The third allocation is inside that range.
The kernel sees no collision because the second mapping is smaller than the
length the guest requested. A guest that classifies pointers by its pool
ranges can consequently assign a pointer to the wrong pool. That explanation
is an inference from the API results and controlled runs, not an analysis of
the game's instructions.

`GuestVMBudget` now includes previously requested spans in its placement
search, including their missing tails. A new counted reservation cannot reuse
one of those ranges, even when the new reservation is granted in full. It
searches lower address space too, uses nonfixed hints, and fails with ENOMEM
if the selected hole cannot be mapped. It never overwrites a competing mapping.

The adapter remains experimental. Returning less memory than requested cannot
provide full mmap semantics. This change prevents this particular collision;
it does not provide the missing capacity or prevent unrelated host allocations
from entering an unmapped tail.

## Device address-space evidence

A standalone Tolkara `--vm-probe` ran without guest code. Temporary diagnostic
additions queried `TASK_VM_INFO` and tried low fixed reservations without
`VM_FLAGS_OVERWRITE`. Both extended-virtual-addressing and increased-memory-limit
entitlements were present in the signed app.

- The task's maximum address was `0x8000000000` (512 GiB).
- A single 64 GiB reservation worked; 112 GiB failed.
- Cumulative 4 GiB mappings reached 64 GiB for read/write, PROT_NONE, and
  private file-backed mappings alike.
- Fixed 16 GiB mappings at and above the maximum failed with
  KERN_INVALID_ADDRESS. Middle-range probes also failed.
- Fixed 8 GiB mappings starting at 8, 16, 32, and 48 GiB all failed without
  replacing existing mappings.

This is address-space exhaustion, not evidence that 64 GiB of physical RAM
is required. In the failing guest launch, the first three requests alone ask
for 112 GiB. Raising the budget variable cannot raise the task's maximum
address. The earlier description of this as a reservation charge/quota was
too strong: these measurements show the available address-space constraint.

## Follow-up device probe

A fresh, labelled standalone run on 2026-09-26 reproduced the constraint
without loading any guest code. The installed probe build succeeded.

| Probe | Result |
| --- | --- |
| First request, 16 GiB, retained | Success at `0x7000000000` |
| Second request, 64 GiB, while retaining the first | ENOMEM |
| Third request, 32 GiB, while retaining the first | Success at `0x7400000000` |
| Nonoverwriting fixed 1 GiB scan from 4 to 512 GiB | Successful windows only from 448 to 512 GiB |
| `mach_vm_range_create`, empty recipe | `KERN_NOT_SUPPORTED` (46) |

The scan establishes availability at its 1 GiB granularity, not that every
smaller address is occupied. The empty recipe creates no mappings. Apple's
[XNU implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_user.c)
returns this status when the task does not use user VM ranges. The API is not
an available route to additional space for this installed app.

The provisioning profile grants both
`com.apple.developer.kernel.extended-virtual-addressing` and
`com.apple.developer.kernel.increased-memory-limit`. It does not grant
`com.apple.kernel.large-file-virtual-addressing`. Public
[XNU process setup](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c)
distinguishes the last entitlement's larger address-space path from the
ordinary extended-address-space path. This source is context, not proof that
Apple grants the capability to third-party iPad apps, nor that the public
kernel revision exactly matches this device.

No supported pool-size option was found in the shipped `engine/config` and
`r6/config` text files. Those files and the game executable were not changed.
There is currently no verified configuration or entitlement available to this
build that supplies the requested ranges. Full guest address translation would
be a separate runtime architecture project, not a small mmap adapter change.

## Validation and next work

The focused ASan/UBSan test mixes shortened 16 MiB pools with fully granted
1 MiB pools and checks their reported ranges pairwise. It fails against the
old implementation and passes with this change. The complete
`tools/test_emulation.sh` suite passed outside the filesystem sandbox; the
initial sandboxed run stopped because `/usr/bin/time` could not query
`kern.clockrate` in an unrelated memory-usage test. Existing optional skips
remain in the suite.

The next step needs a supported way to obtain sufficient guest address space,
or an application-supported configuration that reduces these reservations.
Further CPU-brand or GOG shims are not supported as fixes for this crash by
these experiments. Do not describe the placement safeguard as a working iPad
port, and do not overwrite system mappings to make the pools fit.
