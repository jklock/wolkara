# Cyberpunk 2077

**Status: work in progress. It does not run yet.** This profile is published
early so that the work on it is visible and others can build on it.

What works: the loader handles this client's chained fixups, `__init_offsets`
initializers, thread-local variables and the four libraries it ships in
`Contents/Frameworks` (Bink 2 and GOG Galaxy); every one of its 717,321 fixups
matches `dyld_info`. The iPad reaches all 6,540 initializers and `main`
with the old experimental VM budget, then crashes after opening its first
archive. A controlled simulator run now reproduces this: shortened VM pools
were placed inside ranges already reported to the guest. Preventing that
collision passes the archive stage in the simulator, but the iPad cannot
place the separate ranges and reports out-of-memory during initialization.
See [the investigation](../../docs/CYBERPUNK_VM.md) for the tested results.
No gameplay is validated.

You need your own copy from GOG, installed on a Mac with GOG Galaxy (version
2.3.x, macOS arm64). Nothing from the game is included here.

In `local.env`:

```
GUEST_EXE="/Applications/Cyberpunk 2077/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
TOLKARA_EXPERIMENTAL_ADAPTERS=GameController:MetalFX
```

The build classifies the executable together with the libraries in its
`Contents/Frameworks`, so the compatibility libraries cover all of them. The
two experimental adapters present a Mac with no game controllers (the game's
connect handlers crashed) and MetalFX as unavailable (its initializer crashed
startup), so the game takes its non-MetalFX path. Build, install and set up
your execution mode as described in [docs/BUILDING.md](../../docs/BUILDING.md),
then copy your installation:

```bash
python3 profiles/cyberpunk-2077/install.py
```

The script copies the application bundle and the `archive`, `engine` and `r6`
folders unchanged, and verifies the executable and bundled libraries by hash
before and after. That is about 61 GB, so use a cable and check the iPad's free
space first. Pass `--source` if the game is installed elsewhere, and
`--skip-data` to refresh only the application bundle. The game opens
`archive/mac` while its installer writes `archive/Mac`; the profile's
`caseAliases` links the two.

**Execution mode.** Use Developer service. Local signing does not yet cover an
application's bundled libraries, and startup stops with a message saying so.
The executable and its libraries need about 233 MB of prepared memory, which
took about 3.6 minutes per launch on an iPad Pro M5.

**Memory.** The first three large reservations alone request 112 GiB of
virtual address space. The tested iPad process can reserve about 64 GiB in
large mappings, even with both memory entitlements. This concerns address
space, not physical RAM. `TOLKARA_VM_BUDGET_MB=49152` remains an experimental
diagnostic: it shortens mappings and cannot provide the requested capacity.
It is not a working launch configuration. The placement safeguard now fails
when it cannot keep counted reservations outside earlier reported ranges.
The simulator can place those ranges, but a shortened pool later runs out
while loading the shader cache. `--metal-managed-storage` translates Managed
storage requests but does not address this startup blocker.
