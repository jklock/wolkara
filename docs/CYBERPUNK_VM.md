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

## Further controlled tests

The following follow-up experiments also ran on 2026-09-26:

- Standalone iPad probe with default malloc, `MallocNanoZone=0`, and both
  `MallocNanoZone=0` / `MallocSecureAllocator=0`: each retained the same
  64 GiB large-mapping capacity and 448..512 GiB scan window. The environment
  switches were requested at launch; no claim is made that the OS honored
  every allocator switch internally.
- Standalone mapping metadata showed a large reserved read-only mapping
  from `0x2da000000` to `0xfc0000000`, followed by inaccessible ranges through
  448 GiB. These were inspected as mapping metadata only; no contents were
  read and no existing mappings were replaced.
- Requested dyld's own `DYLD_SHARED_REGION=private` mode in the standalone
  probe. The OS terminated it before probe entry with CODESIGNING / Invalid
  Page in dyld. The previous report file was stale, not a private-cache
  capacity measurement. Relaunching without that option restored the probe.
- A temporary simulator-only sysctl hook reported 2 GiB or 8 GiB for
  `hw.memsize`. In both cases the first three requests remained 16, 64, and
  32 GiB. This does not establish that every conceivable memory setting is
  ignored. The hook was removed after the experiment.
- The existing getenv trace showed only `OPENSSL_armcap` before those
  reservations. No memory-related environment lookup or configuration-file
  read was observed before the three requests.
- An iPad launch with the downsizing adapter disabled completed arena
  preparation in 219.882 seconds and detached. Its 16 GiB request succeeded,
  64 GiB failed with ENOMEM, and 32 GiB succeeded. It later crashed during
  initializer 5680, before main, in `_platform_strnlen` reading address `0x20`.
  That failure is distinct from the original first-archive crash; this run
  demonstrates no working fallback from the failed 64 GiB allocation.

The initial 8 GiB simulator build accidentally omitted the configured
GameController/MetalFX adapter settings. Its initial allocation trace is
usable, but its later GameController callback crash is not a like-for-like
baseline comparison. The 2 GiB run used the corrected adapter configuration.
Repeating the 8 GiB run with the corrected configuration was abandoned after simulator
termination/LLDB attachment stalled. No guest instructions ran in that retry.

A minimal independent C reproducer and draft technical questions are in
[`support/IPAD_VM_QUESTION.md`](../support/IPAD_VM_QUESTION.md). They have not
been sent. The C code builds for arm64 iOS and macOS; all three requests
succeed when run on the Mac. The equivalent sequence was already tested in
the standalone iPad probe above. A larger provisionable address space or a
publisher-supported reservation setting remains unverified.

## Software-memory fixture

A separate `--sparse-memory-probe` now demonstrates access to distinct
16, 64 and 32 GiB software ranges using only Tolkara's own assembly. The expanded
fixture passed on the iPad with 18,600 fault/resume operations, including scalar,
SIMD and single-instruction atomics. See
[Software-memory experiment](SOFTWARE_MEMORY.md) for details and limitations.
It is not connected to the native guest mapping hooks, so the Cyberpunk result
above remains unchanged.

## Validation and next work

The follow-up `tools/test_emulation.sh` run also passed (exit 0, with existing
optional skips). Its first attempt stopped at a Swift module cache that still
referenced the worktree's former `/private/tmp` location. Moving that generated
cache aside resolved the build failure. The standalone reproducer compiled
with `-Wall -Wextra -Werror` for both macOS and arm64 iOS and ran successfully
on the Mac.

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
