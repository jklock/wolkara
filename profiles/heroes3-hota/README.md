# Heroes of Might and Magic III: Horn of the Abyss (Windows, GOG)

**Status: plays on the iPad** (iPad Pro M5, iPadOS 27, Developer service,
2026-09-27): new games on scenario maps, towns, battles, AI turns with up to
eight players, saving and loading, with music, sound, mouse and keyboard.
What is still open is at the end of "On the iPad" in
[docs/WINDOWS.md](../../docs/WINDOWS.md); results are in
[COMPATIBILITY.md](../../COMPATIBILITY.md).

This profile is the first Windows application for Tolkara: a 32-bit x86
program run by an arm64 macOS build of Wine with FEX inside it as the x86
emulator, the same pairing Valve's Proton uses for ARM64 and CodeWeavers'
CrossOver uses on Apple silicon. A native arm64 process on macOS and iPadOS
has no address space below 4 GB, which a 32-bit Windows program needs;
Tolkara's branches of Wine and FEX put the 32-bit address space at a
translated window instead (see "The 4 GB floor" and "The 32-bit window" in
[docs/WINDOWS.md](../../docs/WINDOWS.md)). On the iPad, Wine runs as one
process with its server as a thread, and FEX's translated code lives in a
code pool inside the memory the developer service prepares.

The branches are published as [tolkara/wine](https://github.com/tolkara/wine)
and [tolkara/FEX](https://github.com/tolkara/FEX), branch
`tolkara/darwin-arm64` in each. They are downstream only and are not
submitted to either project (each says why in its `TOLKARA-FORK.md`).

You need your own GOG installer of *Heroes of Might and Magic III: Horn of the
Abyss* (the GOG build bundles HotA and the HD mod; 1.8.1 / HD 5.8 was used
here). Nothing from the game, from Wine or from FEX is included in this
repository.

## 1. Build the runtime

```bash
WINE_REPO=https://github.com/tolkara/wine.git WINE_BRANCH=tolkara/darwin-arm64 FEX_REPO=https://github.com/tolkara/FEX.git FEX_BRANCH=tolkara/darwin-arm64 tools/build_windows_runtime.sh
```

The four variables can also go in `local.env`. Without them the script
builds upstream Wine (bylaws' `upstream-arm64ec`) and FEX, which do not run
a 32-bit program on arm64 Darwin. It builds Wine for arm64 macOS with the
`arm64ec`, `aarch64` and `i386` architectures, builds FEX's two Windows-side
emulator modules (`libarm64ecfex.dll`, `libwow64fex.dll`), and assembles
them into `build/windows-runtime/Wine`. It needs Xcode, the LLVM mingw
toolchain it downloads, and a few Homebrew packages it checks for. Expect an
hour on an M4 Pro. Wine is LGPL and FEX is MIT; they are our runtime, built
by you, not part of the application.

If you built a runtime from other sources before: the script records where
its Wine tree came from (`src/wine.source`), and when the variables name
another source it moves that tree aside, clones again and rebuilds Wine
from scratch. It keeps an existing FEX tree and modules, so delete
`build/windows-runtime/src/FEX`, `libarm64ecfex.dll` and `libwow64fex.dll`
first.

## 2. Stage the game and try it on the Mac

```bash
python3 profiles/heroes3-hota/install.py --installer ~/Downloads/setup_heroes_of_might_and_magic_iii_horn_of_the_abyss_*.exe --stage-only
```

`innoextract` unpacks your installer (no Wine needed), the script creates a
Wine prefix with the arm64 runtime, registers FEX as the emulator for x86 and
x86-64 code in that prefix, and copies the game into `drive_c/GOG Games/`.
Every `.exe` and `.dll` is hashed before and after: the game is never modified.
Pass `--source` instead of `--installer` to use a folder you already installed.
The script also sets the HD mod to its GDI renderer and turns off its update
check at start, and sets Wine's keyboard so that Option is Alt and Command
does nothing (Control stays Control).

The script prints the command that starts the game on the Mac; run it before
going near an iPad. The HD mod's launcher is not used (it starts the game as a
second process, which Tolkara cannot do); the game executable `h3hota HD.exe`
is started directly, so configure HD mod settings once through the launcher
on the Mac if you want to change them.

## 3. Copy to the iPad and play

```bash
python3 profiles/heroes3-hota/install.py --installer ...
```

Without `--stage-only` the script also copies the runtime to
`Documents/Heroes 3 HotA/Wine` and the prefix (game included) to
`Documents/Heroes 3 HotA/prefix`, about 1.5 GB. The launcher lists the game
once both are present. Tap it and keep Tolkara in the foreground while it
prepares memory (about 33 seconds); the game then opens full screen at the
HotA main menu. The runtime log is `Documents/native-guest.log`.

Play with a trackpad or mouse and a keyboard. A double click is not
recognised yet: select a town and press Enter to open it.

**Execution mode.** Developer service only. Local signing signs an
application's code before launch, but this game's code only exists once FEX
has translated it, while the game runs, and on the iPad only memory the
developer service has prepared can run such code (M1 in
[docs/WINDOWS.md](../../docs/WINDOWS.md)). External JIT would provide such
memory as well but has not been tried.

**Do not launch with `--case-insensitive-files`.** Wine already ignores case
in file names. With the option, the runtime answers that `GAMES` exists when
the folder is `games`, so Wine creates saves as `GAMES/AUTOSAVE.GM1`, which
does not exist, and the game reports that it could not save. Started from its
icon, or without the option, the game saves normally.

**Policy.** The game's own files, including the HD mod and HotA libraries the
GOG build ships, are copied unchanged and hash-verified. Wine and FEX are
compatibility layers in the sense of the [README](../../README.md#policy);
nothing here reads or changes the game's memory beyond running it.
