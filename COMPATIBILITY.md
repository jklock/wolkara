# Compatibility

Applications that people have actually run with Tolkara. Add a row through a
pull request; say what you tested, on what hardware, with which execution mode
(Developer service or Local signing), and what did not work.

| Application | Version | Device / OS | Execution mode | Works | Known problems | Profile |
| --- | --- | --- | --- | --- | --- | --- |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Developer service | In-game login, world entry, movement, combat, spells, quests, trading, audio, intro cinematics, cursors, clean exit. Up to 120 FPS at graphics quality 8, 50% render scale. Launch without a Mac, including after reboot. | Character-selection top menu is oversized and misplaced. Voice chat unavailable (its separate helper app is not supported). About 80 s of memory preparation per launch. Switching apps during startup may interrupt it. Shader coverage beyond the played areas is unverified. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Local signing | Startup: the client's own unpacked code matched the signed page container byte for byte, and all 12,658 initializers ran into the original `main`, with no debugger, helper or tunnel. Re-validated with the current container checks. | Login and gameplay not yet validated in this mode. Building the page container for this client needs a capture of its final code pages, which the app cannot produce on its own yet. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Forever (Classic beta, macOS arm64 client) | 1.60.1 | iPad Pro M5, iPadOS 27 | Local signing | Startup: the client's own unpacked code matched the signed page container byte for byte, and all 13,280 initializers ran into the original `main`, with no debugger, helper or tunnel. | Login and gameplay not yet validated, in this or any mode. Same capture limitation as Classic Era. | [`wow-forever`](profiles/wow-forever) |

An entry records what one person observed. It is not a promise that the
application will keep working, and it says nothing about whether its publisher
permits it: read "Online games and account risk" in the [README](README.md).
