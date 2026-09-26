# Windows applications: Wine and FEX under Tolkara

> Design and status for running a Windows x86 program on the iPad through
> Tolkara. First target: *Heroes of Might and Magic III: Horn of the Abyss*
> (GOG build, HotA 1.8.1 with the HD mod 5.8, a 32-bit x86 program),
> profile [`heroes3-hota`](../profiles/heroes3-hota). Nothing below is
> validated on a device yet; each section says what is proven and what is not.
>
> **Status, 2026-09-25: blocked below Tolkara.** The runtime builds and runs
> on an Apple silicon Mac, but a native arm64 Darwin process has no address
> space below 4 GB, and Wine's 32-bit side needs it ("The 4 GB floor" below).
> A 32-bit program such as Heroes III cannot run this way on macOS or iPadOS
> until FEX can run 32-bit guests at a translated address; 64-bit programs
> need a smaller Wine change. The rest of the design stands for those.

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
companion (`MemoryWineLoadUnixLibByName`). That tree targets Linux, though:
on macOS its fsync/ntsync, `win32u` OpenGL, `winedmo` and `bcrypt` changes
do not compile, and none of them matter on an iPad. So
[`tools/build_windows_runtime.sh`](../tools/build_windows_runtime.sh) builds
bylaws' `upstream-arm64ec` (upstream Wine plus the same ARM64EC/FEX series,
the tree FEX's own instructions name) and leaves Proton's tree selectable
with `WINE_REPO`/`WINE_BRANCH`.

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

## The 4 GB floor (measured on macOS 27, the kernel iPadOS shares)

A native arm64 Darwin task's address space begins at 4 GB. Measured on this
Mac, 2026-09-25, with two small programs kept in the session notes:

- An arm64 executable linked with `-Wl,-pagezero_size,0x4000` (or `0x1000`,
  which ld rounds up) is killed at exec with `SIGKILL` before its first
  instruction. With the default 4 GB `__PAGEZERO` it runs, and Wine's own
  loader is built that way: configure's `-pagezero_size,0x1000` is silently
  ignored for arm64.
- Inside a running process, the low 4 GB is not a reservation that can be
  given back: `mach_vm_region` reports the first region at `0x100bdc000`;
  after `mach_vm_deallocate(task, 0, 4 GiB)` (which "succeeds"),
  `mach_vm_allocate(VM_FLAGS_FIXED)` at `0x400000` and `0x7ffe0000` return
  `KERN_INVALID_ADDRESS` and `mmap(MAP_FIXED)` at `0x10000000` returns
  `ENOMEM`. The same holds for an x86_64 binary under Rosetta with the default
  page zero; Rosetta's small-`__PAGEZERO` x86_64 processes are the only ones
  that get low memory, which is how Wine has worked on Apple silicon so far.
- Wine's `wineboot` under the arm64 runtime therefore stops in
  `virtual_alloc_first_teb`: "failed to map the shared user data" at
  `0x7ffe0000` (`WINELOADERNOEXEC=1` to see it; the normal path re-execs and
  the re-exec'd process dies without output). Upstream's `configure.ac` sets
  no preloader and no reservation segments for `aarch64` on Darwin: nobody
  has made this work in public yet.

What it means for the two kinds of Windows program:

- **32-bit x86 (Heroes III, the HD mod, HotA).** Wine's WoW64 layer keeps
  the 32-bit process's address space in the low 4 GB of the 64-bit process,
  and FEX's `libwow64fex.dll` runs the guest with guest addresses equal to
  host addresses (bylaws' Wine series even forces every host allocation out
  of the 32-bit range to keep it free for the guest). With no memory below
  4 GB there is no 32-bit address space to give. Running such a program on
  arm64 Darwin needs a 32-bit guest at a translated base address, which FEX
  does not have; QEMU's user mode has that (`guest_base`) but no Darwin
  host. This is a change in FEX, upstream of everything here.
- **64-bit x86.** The guest's own allocations live above 4 GB anyway. What
  sits below is `KUSER_SHARED_DATA` at `0x7ffe0000`, which Wine maps at that
  address because Windows programs read it there directly. Wine's ARM64EC
  code reaches it through a pointer and could map it anywhere; x86-64 guest
  code that hardcodes the address would have to be caught by FEX. CrossOver's
  ARM64 preview on macOS runs 64-bit programs, so CodeWeavers have done this
  in their unpublished FEX and Wine changes; it is a bounded patch.

On the iPad the floor is the same kernel rule, so nothing Tolkara does can
lift it; the arena Tolkara prepares also lives above 4 GB. Until FEX gains a
translated 32-bit mode, this profile cannot reach M0, and the milestones
below apply to 64-bit Windows programs. The alternatives for this particular
game are in "Working rules".

### The downstream forks

Decided 2026-09-26: Tolkara carries its own branches of Wine and FEX for
arm64 Darwin, in this order: first the 64-bit path (relocate
`KUSER_SHARED_DATA`, which also validates FEX's JIT on 16 KiB pages and
without TSO with a 64-bit program), then the 32-bit window (a translated
base in FEX's 32-bit JIT and a movable WoW64 address range in Wine).

Both projects refuse code written with LLM tools (FEX's `CONTRIBUTING.md`:
"No AI/ML/LLM/etc code contributions."; Wine's Clean Room Guidelines: "Don't
use an LLM tool to generate code."). The changes on Tolkara's branches were
written that way, so they are **downstream only and will not be submitted
upstream**; each fork says so in its `TOLKARA-FORK.md`. They keep each
project's coding style and one-change-per-commit convention so that they
stay reviewable and rebaseable, not to prepare them for upstream. Should
either project publish its own arm64 Darwin work, Tolkara moves to it.

The Wine branch is `tolkara/darwin-arm64` on bylaws' `upstream-arm64ec`;
`tools/build_windows_runtime.sh` builds whatever is checked out in
`build/windows-runtime/src/wine`. Its first commits, and what each fixed:

- `configure`: the arm64 loader keeps the 4 GB page zero. Configure's macOS
  flags asked for a 4 KiB one, the linker obliged for `loader/wine`, and the
  kernel killed every re-exec of it at exec time (the silent `SIGKILL` seen
  at first).
- `ntdll`: the address space starts at 4 GB on arm64 macOS; the
  `KUSER_SHARED_DATA` page and the TEB block fall back to where the host can
  put them; the PE side asks the Unix side for the page's address
  (`unix_get_user_shared_data`) and other modules read it through
  `__wine_get_user_shared_data()` instead of hardcoding `0x7ffe0000`
  (`kernelbase`, `kernel32`, `ntoskrnl.exe`).

Three more Darwin rules surfaced while bringing `wineboot` up, each measured
with a small C program and each now handled on the Wine branch:

- **No W+X memory, ever.** `mmap`/`mach_vm_map` with write and execute
  together fail (`EPERM`) for anonymous and file mappings alike; only
  `MAP_JIT` gives both, and then a thread has *either* write or execute
  access, toggled with `pthread_jit_write_protect_np`, starting
  write-protected. RW→RX `mprotect` is allowed. So Wine maps a PE image RW,
  copies it in, and gives each section its final protection (`ntdll`
  `map_image_view`). A JIT (FEX's code buffers) has to be `MAP_JIT` plus the
  toggle, or write through a separate alias; that is the FEX side of the
  work and the shape Tolkara's in-arena pool takes on the iPad.
- **Protection faults arrive as `SIGBUS`, `si_code 1`,** the same code as
  alignment faults; the ESR in the signal context tells them apart
  (`DFSC 0x21` is alignment). Wine's arm64 `bus_handler` treated every
  `SIGBUS` as `STATUS_DATATYPE_MISALIGNMENT`, so guard-page hits and access
  violations were never handled; it now classifies by ESR.
- **`x18` is not preserved.** It survives a fast syscall but is zeroed by
  any context switch and by every return from a signal handler (the
  handler's `ucontext` still shows it). Windows ARM64 keeps the TEB in
  `x18`, so PE code and Wine's dispatchers cannot rely on it here.
  `TPIDR_EL0` is user-writable but the kernel reuses it (CPU number), and
  `TPIDRRO_EL0` is read-only and points at the thread's pthread TSD array.
  The TEB therefore lives in TSD slot 767 (`0x17f8` from `TPIDRRO_EL0`, above
  the keys `pthread_key_create` hands out from 258): `NtCurrentTeb()` in PE
  code compiled for this host is `mrs`+`ldr` (`-D__WINE_TEB_TSD_OFFSET`),
  the five PE assembly sites that read the PEB through `x18` use the same
  sequence, and both dispatchers reload `x18` from the slot on entry from
  PE code. Native ARM64 Windows *applications* would still break; x86
  programs under FEX never touch `x18`, and FEX's own Windows code gets the
  same `NtCurrentTeb()` treatment in its fork.

A fourth rule closed the last gap for `wineboot`: **Apple's arm64 ABI packs
stack arguments at their natural alignment** (a `ULONG` tenth argument sits
four bytes into the ninth's slot), while the syscall dispatcher copies the
PE caller's arguments as the Windows ABI lays them out, one 8-byte slot
each. Every system call with more than eight arguments (25 of them) got a
wrong tenth argument. On Darwin the syscall table now points at generated
wrappers (`tools/make_darwin_syscalls`, `dlls/ntdll/unix/syscall_darwin.h`)
whose stack parameters are all `ULONG_PTR`.

**State of the Wine branch, 2026-09-26, 13 commits on `upstream-arm64ec`:**
`wineboot -u` creates a complete prefix on this Mac in 73 s (826 files in
`system32`, registry written, `explorer` on the Mac driver, no process left
behind), and Wine's own `notepad.exe`, an ARM64EC program, runs with a
window. That is the native half of M0 without any x86 code involved.
Remaining noise: FreeType, GnuTLS and SDL2 are `dlopen`ed by bare soname and
not found in the bundled runtime (configure should record `@rpath` sonames
and the build script bundle them); no Vulkan (MoltenVK) yet.

A 64-bit Windows test program of our own,
[`testguest/windows/shared_data_probe.c`](../testguest/windows/shared_data_probe.c),
exercises the relocated page through the API and reports what a direct read
of `0x7ffe0000` does. Under FEX (`libarm64ecfex.dll` registered in the
prefix) it currently recurses into a stack overflow: FEX's own Windows code
and its JIT read the TEB through `x18` (five loads in `ARM64EC/Module.S`,
two emitted in `MiscOps.cpp`, and mingw's `NtCurrentTeb()` inline for the
C++), which is null on this host. The FEX branch `tolkara/darwin-arm64`
adds `FEX_TEB_TSD_OFFSET` and reads the TEB from the TSD slot in all three
places; whether the W^X rule bites next (FEX asked for no RWX memory before
the recursion) is the next measurement.

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

  **Result, 2026-09-25, M4 Pro, macOS 27.** The runtime builds (wine-10.13
  arm64: 32 Unix-side libraries, 1052 PE DLLs for arm64ec and i386, FEX's
  `libarm64ecfex.dll` and `libwow64fex.dll` built with llvm-mingw 20260922)
  and `wine --version` runs natively. The installer unpacks with innoextract.
  Prefix creation fails: `wineboot` cannot map `KUSER_SHARED_DATA` at
  `0x7ffe0000`, see "The 4 GB floor". M0 is not reached and cannot be for a
  32-bit program with the current FEX.
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
