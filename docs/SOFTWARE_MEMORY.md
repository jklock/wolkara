# Software-memory experiment

The `--sparse-memory-probe` diagnostic runs Tolkara's own assembly fixtures.
It does not enable software memory for imported applications. Normal game
launches still use the existing native memory path.

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
loads and stores, pairs, LDAR/STLR, single-register CAS, and the nine scalar
LSE read-modify-write operations. Unsupported instructions are rejected.
Although the backing API has a software exclusive monitor for interpreter
tests, native LDXR/STXR instructions are deliberately unsupported: a partial
emulator cannot observe a native CLREX between faults and would risk preserving
an invalid monitor.
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

An imported application would also require syscall and framework pointer
bridges, more instruction coverage, an explicit backing-capacity policy and
thread-safe signal integration. Those are not implemented by this diagnostic.
There is no Cyberpunk gameplay result from this experiment.
