# Compatibility

Applications that people have actually run with Tolkara. Add a row through a
pull request; say what you tested, on what hardware, with which execution mode
(Developer service, Local signing or External JIT), and what did not work.

| Application | Version | Device / OS | Execution mode | Works | Known problems | Profile |
| --- | --- | --- | --- | --- | --- | --- |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Developer service | In-game login, world entry, movement, combat, spells, quests, trading, audio, intro cinematics, cursors, clean exit. Up to 120 FPS at graphics quality 8, 50% render scale. Launch without a Mac, including after reboot. | Character-selection top menu is oversized and misplaced. Voice chat unavailable (its separate helper app is not supported). About 80 s of memory preparation per launch. Switching apps during startup may interrupt it. Shader coverage beyond the played areas is unverified. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Local signing | Startup: the client's own unpacked code matched the signed page container byte for byte, and all 12,658 initializers ran into the original `main`, with no debugger, helper or tunnel. Re-validated with the current container checks. | Login and gameplay not yet validated in this mode. Building the page container for this client needs a capture of its final code pages, which the app cannot produce on its own yet. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Forever (Classic beta, macOS arm64 client) | 1.60.1 | iPad Pro M5, iPadOS 27 | Local signing | Startup: the client's own unpacked code matched the signed page container byte for byte, and all 13,280 initializers ran into the original `main`, with no debugger, helper or tunnel. | Login and gameplay not yet validated, in this or any mode. Same capture limitation as Classic Era. | [`wow-forever`](profiles/wow-forever) |
| Cyberpunk 2077 (GOG, macOS arm64) | 2.3.x (buildId 59052989568257053) | iPad Pro M5, iPadOS 27 | Developer service | Experimental software-memory mode completes all 6,540 initializers, main, GOG initialization, archives, scripts and shader caches, creates the game window, and visibly renders the opening cinematic with a Space-to-continue prompt. | Menu content and gameplay unverified. Early presentation samples are about 5 FPS, then settle near 1 FPS in the cinematic, with long pauses. Manual Space presses reach the adapter queue but have not visibly continued the game; routing 4 GiB pools to software passes the earlier Foundation allocation failure and reaches further loading. Loader and call-wrapper unwind support clears the GOG rich-presence abort on the iPad: the call reports its service error and returns, and loading continues. The merged-main run logs a main-menu presence state; visual menu and gameplay validation remain pending. Tests use a 3600-second watchdog timeout and a two-CPU query cap. See [VM investigation](docs/CYBERPUNK_VM.md) and [software-memory experiment](docs/SOFTWARE_MEMORY.md). | [`cyberpunk-2077`](profiles/cyberpunk-2077) |

## Runtime diagnostics

On 2026-09-26, `--sparse-memory-probe` passed on the iPad Pro M5 / iPadOS 27.
Tolkara's own assembly used 112 GiB of software address ranges and completed
18,600 scalar, SIMD, addressing and atomic fault/resume operations, using
96 KiB of backing pages. The subsequent opt-in Cyberpunk run uses full software
reservations and passes the original first-archive crash on the same iPad.
It opens all 32 archives and `final.redscripts`, then reaches an engine watchdog
timeout after over 33 million handled faults. No gameplay result is validated.
The experiment and instruction limitations are in
[Software-memory experiment](docs/SOFTWARE_MEMORY.md).

An entry records what one person observed. It is not a promise that the
application will keep working, and it says nothing about whether its publisher
permits it: read "Online games and account risk" in the [README](README.md).
