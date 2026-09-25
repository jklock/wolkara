# Heroes of Might and Magic III: Horn of the Abyss (Windows, GOG)

**Status: blocked below Tolkara, on the Mac already.** This profile describes
the first Windows application for Tolkara: a 32-bit x86 program run by an
arm64 macOS build of Wine with FEX inside it as the x86 emulator, the same
pairing Valve's Proton uses for ARM64 and CodeWeavers' CrossOver uses on Apple
silicon. The runtime builds and starts natively on an Apple silicon Mac, but a
native arm64 process on macOS and iPadOS has no address space below 4 GB, and
a 32-bit Windows program needs exactly that; see "The 4 GB floor" in
[docs/WINDOWS.md](../../docs/WINDOWS.md). Until FEX can run a 32-bit guest at
a translated address, this game cannot reach the first milestone. The steps
below still build and stage everything, so the state is reproducible and the
runtime is ready for 64-bit Windows programs once Wine's shared-data mapping
is relocated.

You need your own GOG installer of *Heroes of Might and Magic III: Horn of the
Abyss* (the GOG build bundles HotA and the HD mod; 1.8.1 / HD 5.8 was used
here). Nothing from the game, from Wine or from FEX is included in this
repository.

## 1. Build the runtime

```bash
tools/build_windows_runtime.sh
```

This fetches Wine (bylaws' `upstream-arm64ec`: upstream Wine with the
ARM64EC/FEX series Proton carries; Proton's own Linux-targeted tree can be
named with `WINE_REPO`/`WINE_BRANCH` but does not compile on macOS) and FEX,
builds Wine for arm64 macOS with the `arm64ec`, `aarch64` and `i386`
architectures, builds FEX's two Windows-side emulator modules
(`libarm64ecfex.dll`, `libwow64fex.dll`), and assembles them into
`build/windows-runtime/Wine`. It needs Xcode, the LLVM mingw toolchain it
downloads, and a few Homebrew packages it checks for. Expect an hour on an
M4 Pro. Wine is LGPL and FEX is MIT; they are our runtime, built by you, not
part of the application.

## 2. Stage the game and try it on the Mac

```bash
python3 profiles/heroes3-hota/install.py --installer ~/Downloads/setup_heroes_of_might_and_magic_iii_horn_of_the_abyss_*.exe --stage-only
```

`innoextract` unpacks your installer (no Wine needed), the script creates a
Wine prefix with the arm64 runtime, registers FEX as the emulator for x86 and
x86-64 code in that prefix, and copies the game into `drive_c/GOG Games/`.
Every `.exe` and `.dll` is hashed before and after: the game is never modified.
Pass `--source` instead of `--installer` to use a folder you already installed.
The script prints the command that starts the game on the Mac; run it before
going near an iPad. The HD mod's launcher is not used (it starts the game as a
second process, which Tolkara cannot do); the game executable `h3hota HD.exe`
is started directly, so configure HD mod settings once through the launcher
on the Mac if you want to change them.

## 3. Copy to the iPad

```bash
python3 profiles/heroes3-hota/install.py --installer ... 
```

Without `--stage-only` the script also copies the runtime to
`Documents/Heroes 3 HotA/Wine` and the prefix (game included) to
`Documents/Heroes 3 HotA/prefix`, about 1.5 GB. The launcher lists the game
once both are present. Today a start stops early in the runtime log
(`Documents/native-guest.log`); [docs/WINDOWS.md](../../docs/WINDOWS.md) says
which item each message corresponds to.

**Execution mode.** Developer service only: an x86 emulator generates code
while it runs, which Local signing cannot cover. Whether the process may make
its own memory executable after the helper detaches is the first device
question. With the app installed and enrolled, launch it once with

```bash
xcrun devicectl device process launch --device "$DEVICE" "$TOLKARA_BUNDLE_ID" --local-game-startup --jit-probe
```

and read the `[jit-probe]` lines in `Documents/native-guest.log` (the process
may be ended by the kernel on the last stage; the log is flushed before it).

**Policy.** The game's own files, including the HD mod and HotA libraries the
GOG build ships, are copied unchanged and hash-verified. Wine and FEX are
compatibility layers in the sense of the [README](../../README.md#policy);
nothing here reads or changes the game's memory beyond running it.
