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
paths and file-status output. Its handler fetches instructions only to execute
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
scalar LSE read-modify-write operations. Unsupported instructions are rejected.
Exclusive accesses execute as a bounded sequence: at most 32 instructions in
a 128-byte window, including supported register arithmetic, branches and scalar
reads from software memory. A store-exclusive, other supported write or CLREX
ends the sequence. No software monitor survives a
return to native execution; an isolated store-exclusive fails. Unsupported
sequences leave registers and backing data unchanged. A global write generation
may conservatively cause extra exclusive-store failures under contention.
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
simulator and iPad currently
sets `[Engine/Watchdog] TimeoutSeconds = 600` to distinguish slow startup from
its next functional failure. No binary patch or third-party mod is installed.
The INI experiment follows the setting described by the
[watchdog configuration mod's author](https://www.nexusmods.com/cyberpunk2077/mods/16297).
The simulator remains active beyond the previous two-minute timeout with this
setting. The matching iPad run is in progress. Remove that separate file to
restore the default timeout.
