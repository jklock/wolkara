# Software-memory experiment

The user authorized a Cyberpunk-only exception on 2026-09-26 for runtime
memory emulation: fetching the faulting instruction and executing its memory
access against software backing. The general project restriction continues
to apply to all other applications. This does not authorize binary patches,
debugger attachment after guest entry, game reverse engineering, input
automation, or integrity/anti-cheat workarounds.

The `--sparse-memory-probe` diagnostic runs Tolkara's own assembly fixtures.
Normal game launches still use the existing native memory path.

The experimental game integration requires `--cyberpunk-software-vm` together
with `--app=cyberpunk-2077` and the matching executable path. It attempts native
anonymous mappings first, then supplies a full software range if a large
reservation fails with ENOMEM. It disables the old reservation-downsizing
adapter for that launch. `TOLKARA_SOFTWARE_VM_MB` sets the backing limit (default
4096 MiB; accepted range 64..8192). `TOLKARA_SOFTWARE_VM_FORCE_MB` is a comparison
control that forces eligible reservations at or above that size into software.
In the simulator, setting `SIMCTL_CHILD_TOLKARA_SOFTWARE_VM_FORCE_MB=65536`
on the diagnostic launch reproduces the failed 64 GiB native reservation's
software path. Prepare only the fresh zeroed executable arena and detach before
guest entry, as with other simulator native-startup runs.

The integration bridges bulk copies/fills, file read/write and stdio buffers,
paths, file-status output, and bounded string/comparison scans. Its handler fetches instructions only to execute
memory operations and bounded exclusive-access sequences; it does not dump instruction bytes. Failure
reports include an address, a memory error and aggregate counts. Signal actions
requested by the application are chained, with a bounded history of 127 changes
for SIGBUS/SIGSEGV.

## Mechanism

`GuestSparseMemory` reserves integer address ranges and supplies zero-filled,
16 KiB backing pages on first write. Its metadata and bounded backing arena
are allocated before execution. Mapping, protection and access operations do
not allocate host heap memory. A lock serializes access and atomic operations.
Failed accesses leave output buffers and backing data unchanged.

The diagnostic first obtains a native PROT_NONE guard for its software range.
If that reservation fails, it verifies that the selected software addresses
are above the task's reported maximum address. The signal handler accepts only
instructions inside our fixture. `GuestMemoryInstruction` executes supported
memory accesses and advances the saved PC only after success. Other faults
return to the previously installed handler.

Supported fixture instructions include scalar and SIMD immediate/register
loads and stores, pairs, LDAR/STLR, LDAPR, single-register CAS, CASP, and the nine
scalar LSE read-modify-write operations. SIMD LD/ST1–4 multiple-structure, single-lane and load-replicate forms support 64/128-bit vectors and post-index addressing. Unsupported instructions are rejected.
Exclusive accesses execute as a bounded sequence: at most 32 instructions in
a 128-byte window, including supported register arithmetic, branches and scalar
reads from software memory. A store-exclusive, other supported write or CLREX
ends the sequence. No software monitor survives a
return to native execution; an isolated store-exclusive fails. Unsupported
sequences leave registers and backing data unchanged. Each backing page has a write generation. Writes on other pages do not
invalidate a monitor; mapping changes invalidate all monitors to cover
protection and backing-page reuse. Writes elsewhere on the same page may
conservatively cause extra exclusive-store failures.
See section 3.2.4 of Arm's
[synchronization guide](https://documentation-service.arm.com/static/68c223238a337a2bc6645c0a?token=)
for monitor clearing by CLREX and exception return.

## Evidence and limits

On an iPad Pro M5 running iPadOS 27, the expanded scalar/SIMD/addressing/atomic
fixture successfully used three distinct 16, 64 and 32 GiB software ranges.
It handled 18,600 faults, touching six backing pages (96 KiB) in 0.036765 seconds.
The same process refused a native 112 GiB reservation and reported its maximum
address as 512 GiB; the software ranges began at 1 TiB. These are small fixture
accesses, not a game-performance measurement. The diagnostic checks hardware
LSE support before running the atomic fixture.

Mac sanitizer tests also compare randomized mapping operations against the
existing dense memory model, test page recycling and capacity failures, and
contend on atomic-add, compare-and-swap and exclusive counters from eight
threads. Original native assembly supplies an independent reference for all
nine scalar LSE operations at byte, halfword, word and doubleword widths.
The full `tools/test_emulation.sh` suite passed on 2026-09-26, including the
new sparse-memory tests. The focused instruction test was also rerun after
adding the explicit Armv8.1 assembly target and hardware feature check.

Additional kernel/framework pointer bridges and instruction coverage may be
needed. Memory is bounded by the preallocated backing arena; there is no disk
eviction. There is no Cyberpunk gameplay result from this experiment yet.

## Game startup evidence

The initial integrated iPad run completed all 6,540 initializers and entered
the original main function with the full 64 GiB software reservation. It
handled about 829,000 faults before requiring LDAPR. With LDAPR implemented,
the next run handled about 3.16 million faults and used 334 backing pages
(5.2 MiB), then stopped at an exclusive-access operation. Both runs preserved
the original executable and detached the Developer service before guest entry.
The exclusive sequence implementation passes native differential fixtures,
six-thread counter contention, and failure-atomicity tests on the Mac. A forced
64 GiB software reservation reproduced the same failure in the simulator:
a memory access inside an exclusive sequence needed support. With that support
added, the simulator opens all 32 archives and handles over 16 million faults.
The matching iPad run also opens all 32 archives and `final.redscripts`, then
reports an engine watchdog timeout after over 33 million handled faults.
This clears the original null-plus-0x18 archive crash, but is not a menu or
gameplay result.

Instruction fetch can now read the current word through the loader-owned
shared arena, avoiding a Mach read syscall for every access. There is no code
cache and no copied block execution; mutation of the shared bytes is visible
on the next fetch. Remapping or revoking read access disables this shortcut.
Bounds, fresh bytes and invalidation are covered by synthetic tests.

A placement probe on the iPad retains a 233 MiB arena and a native 64 GiB pool
alongside a 64 or 256 MiB bank; 1 or 4 GiB banks fail in either allocation order.
`TOLKARA_SOFTWARE_VM_NATIVE_POOL_MB` selects one exact large size for native
placement and routes other eligible reservations of at least 64 MiB to
software. This is a comparison control, not the default: the simulator with
256 MiB backing and a 65536 MiB preferred pool times out earlier, during
archive loading. The matching iPad run keeps the 64 GiB pool native but reaches over 67 million
faults and the same watchdog failure. The native-first default is retained.

A separate `engine/config/platform/mac/tolkara-memory-test.ini` on both the
simulator sets `[Engine/Watchdog] TimeoutSeconds = 600`; the iPad now sets
`TimeoutSeconds = 3600` to distinguish slow startup from
its next functional failure. No binary patch or third-party mod is installed.
The INI experiment follows the setting described by the
[watchdog configuration mod's author](https://www.nexusmods.com/cyberpunk2077/mods/16297).
With the 600-second setting, both simulator and iPad finish scripts and load shader caches.
The simulator then reaches its known private-heap assertion. The iPad passes
that heap operation and reached an unsupported SIMD structure instruction;
implementing those forms clears that fault. Telemetry shows the iPad continues substantial computation after display
setup, with about ten workers active. Rendering is not validated. Remove the separate INI to restore the default timeout.

The SIMD structure decoder is compared against 164 original native assembly
fixtures, with three input patterns and aligned/unaligned page-crossing cases.
Tests cover register wrap, post-index updates, permissions and rejected
encodings. A signal/resume fixture also matches native output. String bridges
cover page edges, unsigned comparisons, native/software combinations and
zero-length operations. The full sanitizer suite passes with these additions.

Current experiments build the runtime with `GCC_OPTIMIZATION_LEVEL=2`.
Simulator launch-to-heap-assertion time improved only from about 6m20s to 6m10s
(including arena preparation), so this has not solved the fault overhead.
A false-returning `CGDisplayModeIsUsableForDesktopGUI` stub was replaced with
an implementation for the UIKit screen mode; its physical-device test is in
progress.

With `--trace-guest`, the runtime reports fault totals and increments, backing
page counts and kernel thread states every ten seconds for at most one hour.
It also reports active imported mutex, condition, rwlock and semaphore wait
boundaries. These diagnostics use runtime-owned counters and kernel metadata;
they do not read application registers, stacks or memory. The display usability
fix removed the stub call on the iPad. The apparently quiet phase after a
worker's memory-capacity query is active computation: fault totals keep rising.
The 600-second run reached about 219 million handled faults before the watchdog
fired, with about 354 MiB of sparse backing. Single-threaded script loading ran
at about 630,000 faults/sec; the following worker phase slowed to 140,000–170,000
faults/sec in total.

The sparse lock now waits with atomic reads and an ARM yield hint instead of
repeated atomic writes to the lock's cache line. An original eight-thread
backend benchmark improved from about 2.4M to 7.1–9.0M operations/sec on the Mac;
this is not yet a measured iPad game improvement. Focused signal/resume and
page-local monitor tests and the full sanitizer suite pass. The next iPad run
combines these changes with the longer watchdog timeout.

`TOLKARA_SOFTWARE_VM_CPUS=1..64` is an optional comparison control for guest
CPU-count `sysctlbyname`, numeric `sysctl`, and `sysconf` queries. It caps successful CPU counts without
increasing them, and leaves other queries and the default launch unchanged.
It does not set host thread affinity. This is intended to test whether fewer
guest workers reduce fault overhead. The first device test capped `hw.ncpu` at 2
but still ran about ten workers at the original throughput; it covered only
`sysctlbyname`. Numeric `sysctl` and `sysconf` coverage is built for the next run.
A separate original assembly loop on the Mac, with distinct data per thread,
measured aggregate fault/resume throughput of 448K/s with one thread, 432K/s
with two, 341K/s with four and 176K/s with eight. The iPad's first worker samples
with the lock changes remain close to the earlier baseline. The direct-backend
benchmark improvement therefore does not establish a game improvement.

## Window-initialization checkpoint

The 3600-second iPad run reached audio plug-in discovery and language selection,
then crashed in CoreFoundation dictionary construction after 273,212,724 handled
faults. The invalid key `0x394d4109b00000a8` exactly matched the first eight bytes
of Tolkara's own generated `NSImageHintInterpolation` function stub. Apple's SDK
declares this symbol as an NSString global. No game instructions were examined.
The adapter now supplies typed image-hint string constants, and the build-time
and runtime classifiers recognize all three hint names. Synthetic chained-fixup
and dictionary tests cover the error. The display bridge also answers pixel
width and the single integrated screen's mirror/built-in status. Physical-device
validation is in progress with a two-CPU query cap and presentation timestamps.

The image-hint fix passed the physical-device checkpoint: at 274.6 million
handled accesses, Cyberpunk created its window at 1210×834 logical pixels.
The invalid dictionary-key crash is cleared. Metal presentation and the game
menu have not yet been observed. This run uses the first, sysctlbyname-only
CPU cap; the additional numeric CPU-query adapters are built but not installed.

Progress telemetry also exposes the sparse backend's existing successful-write
counter. It counts nonempty writes and successful atomic updates; reads, failed
compare-exchanges, rejected writes and mapping changes do not increment it.
This adds no per-access work and does not inspect application data. Its purpose
is to distinguish repeated read faults from workloads that keep writing data.

The window run later reached GOG Update and about 405 million handled accesses,
then hit a native stack guard. The crash report identifies `gsv_copy` allocating
its 64 KiB scratch buffer on a worker with a 64 KiB stack. Transfer scratch is
now 4 KiB. A synthetic worker with an explicitly supplied, guarded 64 KiB stack
reproduces SIGBUS with the old buffer and passes copy, overlapping copy, fill,
and file/stdio bridges with the new one. The suite runs this case both with
sanitizers and without them, because ASan enlarges pthread stacks. Device
validation cleared this stack failure and reached Metal presentation.

The expanded CPU-query experiment reached the first worker phase on the iPad.
`sysconf(_SC_NPROCESSORS_ONLN)` now returns 2; startup creates eight fewer
threads. That phase processes roughly 570K–630K faults/sec, compared with
140K–170K in the prior run. These are approximate rates from ten-second
samples. This is a startup improvement, not a frame-rate result.

The small-stack fix reached at least 60 presented Metal frames on the iPad.
Timing samples were 4.7–5.3 FPS, with a 14.6-second pause; this does not establish
menu content or gameplay. The run then raised NSMallocException in a native
Bluetooth-audio plug-in while allocating a Foundation object. Its last native
4 GiB mapping ended just 1 GiB below the task address ceiling. The next comparison
uses `TOLKARA_SOFTWARE_VM_FORCE_POOL_MB=4096` to put exact-size, anonymous,
nonfixed 4 GiB reservations in software without shortening them. Default
placement is unchanged. Kernel footprint, resident/virtual sizes and remaining
physical-memory allowance are now logged to test whether host address-space
pressure explains the failure. The exception alone does not prove that cause.
