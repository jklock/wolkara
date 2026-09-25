# Windows applications: Wine and FEX under Tolkara

> Design and status for running a Windows x86 program on the iPad through
> Tolkara. First target: *Heroes of Might and Magic III: Horn of the Abyss*
> (GOG build, HotA 1.8.1 with the HD mod 5.8, a 32-bit x86 program),
> profile [`heroes3-hota`](../profiles/heroes3-hota). Nothing below is
> validated on a device yet; each section says what is proven and what is not.

## The stack

Tolkara runs unmodified arm64 macOS executables. Wine is one: on macOS it is a
native arm64 program that maps Windows PE images and implements the Windows
API on top of the macOS one. Since Wine 10, a Wine built with the `arm64ec`
architecture runs x86-64 Windows code through an emulator module it loads into
the Windows process, and with `i386` and its WoW64 layer it runs 32-bit x86
code the same way. FEX provides those modules: `libarm64ecfex.dll` (x86-64)
and `libwow64fex.dll` (x86). They are PE files that depend only on `ntdll`,
so they work wherever Wine works. This is exactly the pairing Valve ships as
Proton for ARM64 (Steam Frame; Proton 11 with FEX-2604+, Wine 11 with full
WoW64), and the one CodeWeavers shipped in CrossOver's ARM64 preview for
Apple silicon in July 2026 after "making a custom version of FEX compatible
with macOS". Proton's contribution here is its Wine tree: it carries bylaws'
ARM64EC patch series and the loader that lets FEX bring a native `.so`
companion (`MemoryWineLoadUnixLibByName`), and it is what
[`tools/build_windows_runtime.sh`](../tools/build_windows_runtime.sh) builds
for macOS.

```
  Heroes III (x86 Windows program, unchanged)
        │ Windows API, x86 instructions
  Wine PE side (arm64ec/i386 DLLs)  ──►  FEX libwow64fex.dll: x86 → arm64 JIT
        │ Wine's Unix ABI
  Wine Unix side (arm64 macOS: ntdll.so, win32u.so, winemac.drv.so, …)
        │ macOS API: libSystem, AppKit, CoreAudio, Vulkan (MoltenVK), …
  Tolkara runtime + translation (macOS → iPadOS)      ◄── this repository
        │
  iPadOS
```

Every layer above Tolkara exists and is maintained elsewhere. What this
repository has to add is the part Tolkara does not do today for *any* app:
Wine is not a single self-contained program the way a game is.

## What Wine needs from its host, and what Tolkara has

| Wine needs | Tolkara today | Work item |
| --- | --- | --- |
| A command line and environment for the runtime (`wine "h3hota HD.exe"`, `WINEPREFIX`) | Profiles named only an executable and a folder | **W1, done on this branch.** Profiles may name a `runtime`, `arguments` and `environment` ([profiles/README.md](../profiles/README.md)); the launcher sets the variables and passes `argv`. |
| Executable memory it allocates itself: PE images mapped from files (`NtMapViewOfSection`), and FEX's code buffers, written and executed continuously | One arena, prepared once before any application code runs; `mmap(PROT_EXEC)` outside it goes to the host and is not executable; `pthread_jit_write_protect_np` is a no-op. Developer service arenas go up to 512 MiB at about 1.1 MB/s of preparation on an iPad Pro M5 (233 MB in 3.6 min); `nc_create_managed` accepts up to `NC_MAX_ARENA` (1 GiB) or what memory allows (`nc_launch_limit`). A third mode, External JIT (`runtime/DebuggerArena.c`, TolkaraDiagnostics only, untested on a device), has a sideloading tool's debugger allocate the region on request before detaching. | **W2, measured (M1 below): only prepared memory executes.** So the arena must be over-provisioned at startup with a JIT pool, and `guest_mmap`/`guest_mprotect` serve `PROT_EXEC` requests from it: an RW alias for writes (as `NativeCodeMemory` already does) and the RX view for execution; the PE side's `PAGE_EXECUTE_READWRITE` becomes that pair. Wine's PE images plus FEX's code cache must fit a budget of a few hundred MiB, prepared at the rate above; a file-backed PE mapping is copied in rather than mapped. External JIT may suit the pool if a device confirms it. `--jit-probe` overlaps the execution probe of `runtime/HostDiagnostics.c` (`hd_collect(..., probe_execution, ...)`); fold it in there rather than keep two. |
| Loading its own Unix libraries at run time: `wine` dlopens `ntdll.so`, which dlopens `win32u.so`, `winemac.drv.so`, `ws2_32.so`, … (about forty arm64 Mach-O dylibs) | `runtime/GuestLink.c` loads the libraries an application carries at startup (up to 64, from its bundle or the executable's folder), resolves imports as dyld does, initializes them in dependency order, and answers the application's own `dlopen`/`dlsym`/`dlclose` for those *placed* images by any name dyld takes; a host `dlopen` of anything inside the application folder is refused (`gl_inside`) rather than handed to iOS dyld | **W3.** Build on GuestLink: place a library that was *not* loaded at startup when `dlopen` first names it, into arena space reserved for it (W2), with its fixups, initializers and registration as for a carried one; let the root be the runtime folder rather than the `.app`; follow dlopen chains (`ntdll.so` → `win32u.so` → …). Check each of Wine's dylibs first with `guest_probe <file> --library --validate-fixups` and `--carried-libraries`. |
| More than one process: `wineserver` (the process that owns handles, objects and synchronization) plus one Unix process per Windows process; `wineboot` starts `services.exe`, `plugplay.exe`, `explorer.exe` | None: iPadOS cannot spawn processes; `posix_spawn`, `system` and `popen` are logged and pass through to fail | **W4, single-process Wine.** `wineserver` becomes a thread in the same process (it already talks to clients over a Unix socket in the prefix and, on macOS, reads client memory through Mach task ports and suspends client threads through Mach thread ports, which work in-process). The Windows side is limited to one process: the prefix is created on the Mac (`wineboot` already run, `services.exe` never started), `CreateProcess` is refused, and the game executable is started directly instead of through the HD mod's launcher. Wine's `fork`/`exec` sites (`server.c` start_server, `process.c` spawn, `loader.c` exec_wineloader) are reached through the loader-owned function table in `runtime/NativeGuest.m` (README, "What Tolkara does to the application"); adding `fork`, `execv` and `posix_spawn` to that table has to be documented there. |
| AppKit for windows, events, cursors and screens (`winemac.drv`) | AppKit on UIKit for what WoW and Cyberpunk use, including `NSWindow` geometry, `NSScreen` coverage and opt-in local event monitors; a generic build (`NATIVE_GUEST_SHIMS=GENERIC`) stubs at run time what nothing provides | **W5.** Classify `winemac.drv.so` and the other Unix libraries with `tools/classify.py` (`--bundled` takes carried libraries); the driver subclasses `NSApplication`, uses `NSWindow`/`NSView`, `CGDisplay*`, `CGWarpMouseCursorPosition`, and `NSOpenGLContext` for GL. Fill the gaps in `translation/AppKit`; GL is not available (see W6). |
| A GPU path: HotA/HD mod render through DirectDraw or Direct3D 9 | Metal passes through | **W6.** Wine's `wined3d` needs OpenGL or Vulkan; iPadOS has neither natively. Vulkan through MoltenVK (which supports iOS) is the route: `winevulkan` → `libMoltenVK.dylib` built for iOS and bundled in the runtime as a translation library → Metal. DXVK's `d3d9` (built for arm64ec) on top of that is the combination CrossOver and Whisky use for Direct3D 9 on Macs. |
| Audio through CoreAudio (`winecoreaudio.drv`) | CoreAudio/AudioToolbox on AVFAudio for the calls WoW makes | **W7.** Classify and fill, like W5. |
| 4 KiB page semantics for x86 code on a 16 KiB kernel | n/a (the arena is 16 KiB aligned) | **W8, upstream.** FEX's Linux mode requires a 4 KiB host kernel (Asahi runs it in a 4 KiB microVM); on Windows/ARM64EC Wine mediates memory, and CrossOver's Mac preview shows it can be made to work on 16 KiB pages, but those FEX changes are not published yet (CodeWeavers' source page carries 26.3; the ARM64 work is due with CrossOver 27 in early 2027). Until then this is the least certain layer: watch upstream FEX (FEX-2609 as of September 2026), `bylaws/FEX` (`arm64ec`, `asahi` branches) and `bylaws/wine` (`upstream-arm64ec`). |
| Memory-model emulation | n/a | Apple silicon has no user-selectable TSO outside Rosetta; FEX falls back to explicit ordering, at a cost. Heroes III is a 1999 program; this should not matter. |

Also upstream, not in Tolkara: Wine's own `virtual.c` has no `MAP_JIT` handling
on macOS at all, so a RWX request from the PE side (`PAGE_EXECUTE_READWRITE`,
which FEX uses for its code buffers) needs the same RW/RX treatment as W2
inside Wine's Unix side, or a small patch to Wine. CrossOver's tree has this;
upstream Wine 11 does not.

## Milestones

Ordered so that each layer is proven before the next depends on it.

- **M0 — the runtime runs the game natively on the Mac.** No Rosetta, no
  Tolkara: `tools/build_windows_runtime.sh`, then
  `profiles/heroes3-hota/install.py --installer … --stage-only` and the command
  it prints. This validates Wine's arm64ec build on macOS, FEX's modules and
  the prefix. Everything in W8 shows up here first.
- **M1 — the device JIT measurement.** Launch the installed, enrolled app
  once with `xcrun devicectl device process launch --device "$DEVICE"
  "$TOLKARA_BUNDLE_ID" --local-game-startup --jit-probe` (any library app will
  do: the probe runs after the arena is prepared and the helper has detached,
  and skips guest entry) and record the `[jit-probe]` lines from
  `Documents/native-guest.log` here. This decides the shape of W2.

  **Result, 2026-09-25, iPad Pro M5, iPadOS 27, Developer service, this
  branch at 1b4d23a.** After the helper prepared an 87,425,024-byte arena in
  81.5 s and detached: `MAP_JIT` allocation denied (`EPERM`); an anonymous
  page the process mapped, wrote and `mprotect`ed to RX was executed and
  the kernel ended the process with `SIGBUS`, `KERN_PROTECTION_FAILURE` at
  that page (`Tolkara-2026-09-25-185053.ips`). The process's code-signing
  flags at that point were `0x32000305`: `CS_DEBUGGED` set, `CS_HARD` and
  `CS_KILL` still in force. The RWX stage was never reached. Conclusion:
  only memory the developer service prepared can execute; a JIT has to live
  in a pool reserved inside the prepared arena (W2 above). The same
  measurement under External JIT is still to be made.
- **M2 — `wine --version` under Tolkara.** Wine's loader reaches its Unix side
  (W3 and the first half of W2).
- **M3 — `wineserver` in-process and a Wine-shipped program on screen**
  (`notepad.exe` or `winecfg`, both Wine's own; W4, W5).
- **M4 — Heroes III main menu.** W6, W7, and the game's own DLLs under FEX.
- **M5 — a game played through**, recorded in
  [COMPATIBILITY.md](../COMPATIBILITY.md).

## Working rules specific to this stack

- The game's files are copied unchanged and hash-verified by the install
  script (every `.exe`, `.dll` and `.asi`). The HD mod and HotA libraries are
  part of the game as GOG ships it and are treated the same way.
- Wine and FEX are our runtime: built from source by the user, signed under
  the user's identity like the rest of Tolkara's libraries, and never
  committed. Their licences (LGPL 2.1+, MIT) are compatible with that.
- The single-process model (W4) is a Tolkara constraint, not a policy: when
  iPadOS offers a way to run helpers, `wineserver` can go back to being one.
- A native alternative exists for this particular game: VCMI, an open-source
  reimplementation of the Heroes III engine with an iPadOS build. It cannot
  run HotA's own code, which is why this profile runs the real program.
