# Cyberpunk 2077

**Status: work in progress. It does not run yet.** This profile is published
early so that the work on it is visible and others can build on it.

What works: the loader handles this client's chained fixups, `__init_offsets`
initializers, thread-local variables and the four libraries it ships in
`Contents/Frameworks` (Bink 2 and GOG Galaxy); every one of its 717,321 fixups
matches `dyld_info`. With a development build that also carried local
diagnostics which are not part of this repository, an iPad Pro M5 ran all
6,540 initializers and the original `main`, opened the game's window and
locked the pointer. The latest such run ended in a crash after about 13
minutes. Nobody has watched the picture or played. Expect a build from this
repository to stop earlier, in the Metal setup, where one of the game's
dictionaries holds an invalid key; that is being investigated. The simulator
stops in the renderer, because its Metal cannot create heap buffers.

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

**Memory.** The Mac version asks for 16 GB of unified memory and reserves about
118 GB of virtual address space for its pools; iPadOS grants an app about
64 GB, charged when it is reserved. Start it as a development run with
`TOLKARA_VM_BUDGET_MB=49152` in the launch environment (experimental; see
"Development runs on the iPad" in [docs/BUILDING.md](../../docs/BUILDING.md)),
so that large reservations are downsized to fit and every pool exists. A pool
that fills up then faults instead of growing. Start with the lowest texture
quality, and expect the system to end the app if it goes over its memory
limit. `--metal-managed-storage` (experimental) translates the Managed storage
the Mac renderer asks for.
