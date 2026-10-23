World of Warcraft on an iPad: the client, your UI, your add-ons and your voice, in one app. The engine underneath is [Tolkara](https://github.com/tolkara/tolkara); this repository is the WoW-focused layer on top of it, and this is its first release.

![The WolkaraForever home screen](https://raw.githubusercontent.com/jklock/wolkaraforever/v1.0.0/docs/screenshots/launcher-home.jpg)

## At a glance

| | |
|---|---|
| **Client editions** | Forever Beta, Classic Era, Classic, Retail, Retail Beta |
| **Downloads** | Europe, Americas, Korea, Taiwan · English and Spanish |
| **Device** | iPad on iPadOS 17 or later; tested on iPad Pro M5 / iPadOS 27 |
| **Execution modes** | Developer service · Local signing · External JIT — chosen in the app, changeable later |
| **Add-ons** | Installed list, archive import, and a CurseForge browser with sorting, filtering and columns |
| **Voice** | Map any controller button or key to dictation, on-device recognition, transcript typed into the game's focused field |
| **Controls** | Touch trackpad, on-screen gamepad with an editor, physical controllers, and a toolbar over the game |
| **Licence** | MIT, upstream credits retained in [NOTICE.md](https://github.com/jklock/wolkaraforever/blob/v1.0.0/NOTICE.md) |

## The home page

One screen, four managers: **Game Edition**, **Add-On Manager**, **Voice & Input Manager**, **Performance & UI Manager**. Choose the client edition, the download region and the language, then press Play. Every row uses the same text size, so a switch is never smaller than the button beside it; hierarchy comes from weight and colour. Rows that would change something are grey while they cannot be used, and gold when they can.

The page always says where it is:

- **Starting** — the client is being prepared; anything that would change it is disabled.
- **Running** — the game's own window is up.
- **Game closed** — the game quit. A launch can only run one game session, so the page says so and offers **Close WolkaraForever**, which is the only way to play again.

## Installing and updating

Updates check themselves, resume where they stopped, verify what they download, and skip files that have not changed. A required update finishes before Play becomes available, and your settings and add-ons survive it. When something is damaged, **Verify and repair game files** revalidates the local client, including a truncated index the client left behind, and never writes a generation the client did not author.

You choose how the game runs, and the choice is stored in the app:

| Mode | What it does |
|---|---|
| **Developer service** | The iPad's own developer service prepares memory and detaches before any game code runs. Nothing is signed. |
| **Local signing** | Signs only a page container derived locally from the game's final code pages, with your own developer identity. |
| **External JIT** | A sideloading tool prepares memory at launch; the runtime asks it to detach and refuses guest entry while any debugger is attached. |

## Add-ons

![The add-on manager](https://raw.githubusercontent.com/jklock/wolkaraforever/v1.0.0/docs/screenshots/addon-manager.jpg)

**Installed** lists what is on this device with search and refresh; select one to **Disable**, **Restore**, **Pin this version**, **Unpin updates** or **Remove managed package**. WolkaraForever keeps a manifest of what it installed and removes only what it created — your own folders are left alone. Import a single archive from Files, or open the add-on folder directly.

**Browse CurseForge** works the way the site does, because it is the site's own API:

- Artwork, name and current file, total downloads, popularity rank, last update, category, game version and author for every project.
- **Sort** by Featured, Popularity, Last Updated, Name, Author, Total Downloads or Release Date — tap the field in use to reverse it.
- **Filters** narrow the list to one game version or one category, and clear again.
- **Columns** chooses which of the six fields are shown, remembers the choice, and never hides the name.
- The count above the list follows both sorting and filtering; it read 6,615 projects when this release was cut.

## Your UI, kept safe

The last box on the home page holds Forever's file operations and two switches:

- **Backup WoW UI Configuration** writes a verified zip of `WTF` and `Interface` into `WTF/Backups`, and names it.
- **Reset to Default Graphical Settings** asks first, backs up first, and removes *only* graphics and display settings from `Config.wtf`. Accounts, locale, audio, input, gamepad configuration, bindings, SavedVariables and unknown lines are kept byte for byte.
- **Restore WoW UI Configuration** opens Files at your backups; a snapshot of the current state is taken first, so a restore can itself be undone and older backups are kept.
- **Gamepad UI** and **Performance Overlay** — the overlay shows frame rate, frame time, thermal state, battery and memory in the game, applies immediately, and can be moved. The in-game controller settings carry the same switch.

## Playing on a screen with no mouse

A toolbar sits over the game: cursor, keyboard, gamepad, settings and **Leave game**. The touch trackpad scrolls with two fingers and drags when you hold and slide; the on-screen pad has rings around both sticks, a layout editor, size and opacity, a grid and haptics.

**There is a keyboard of our own**, for the times iPadOS reports a software keyboard with no keys on screen — which is what this iPad did, leaving the login field impossible to type into. It supplies qwerty, a numbers and symbols page, shift, backspace, space, return, `@` and `.`, plus a microphone key so dictation is one tap away rather than hidden on a keyboard that is not there. Typing goes into the field the game has focused, and the draft box lets you write a line first and replace that field with it.

## Controllers and voice

![Key and button configuration](https://raw.githubusercontent.com/jklock/wolkaraforever/v1.0.0/docs/screenshots/voice-configuration.jpg)

Any button on any controller, extra buttons included, with an inspector that reports what a pad actually sends. Map a button to dictation and choose how it behaves:

- **Hold to talk**, or **Press to start and stop** for a control whose release iPadOS never delivers.
- **Send it straight away** to submit after the transcript, or leave it off to review first.
- **Add a space after the text** instead of ending the message.
- **Words to expect** teaches the recognizer the names, places and terms you use.
- **Keep the game from seeing it** swallows a mapped key before the guest sees it.

Recognition runs on the iPad; a device that cannot do it is refused rather than quietly sent to a server. **Test Voice** checks a mapping before you open the game, and **Permissions** takes you straight to this app's page in Settings.

![Test Voice](https://raw.githubusercontent.com/jklock/wolkaraforever/v1.0.0/docs/screenshots/test-voice.jpg)

## Getting out

Some screens have no quit of their own — the login screen is one. **Leave game** closes WolkaraForever through a short countdown page that says what to do next, and the page now has a **Close WolkaraForever** button as well, in case the countdown does not run. Quitting from the game's own menu returns you to the home page saying the game closed, with the same close action. Switching apps does not stop the game: iPadOS is told this is an audio app, so a running client keeps running.

![](https://raw.githubusercontent.com/jklock/wolkaraforever/v1.0.0/docs/screenshots/launcher-settings.jpg)

## What is verified, and how

Everything below was run on this release's commit; the record is committed in `development/validation/`.

| Check | Result |
|---|---|
| Project suites (`validate.sh --full`) | 16 of 16 pass |
| Platform emulation suite | passes, with 1 known upstream failure counted as known |
| Device matrix on the iPad | 23 of 23 checks pass |
| App self-test `input` | 28 of 28 — mapper, both modes, stored forms, published key set |
| App self-test `voice` | 9 of 9 — on-device recognizer, session recorded and handed back, real microphone peak −27 dBFS |
| App self-test `forever-ui` | 17 of 17 — real backup, graphics reset, restore, gamepad write, each undone |
| App self-test `curseforge` | 6 of 6 — stored key, live search, artwork, author and category, a file for 1.60.1 |
| App self-test `dictation-target` | 2 of 2 — with the guest running |
| Simulator fixtures | launcher pages, input and voice rules, touch controls, gamepad, translation adapters |

What that does **not** claim: nobody has spoken a sentence into this build for this release, no physical controller was pressed, the Windows/Wine path and the updater were not run, and Local signing and External JIT were not exercised. Those are listed as deferred in the matrix output and in [COMPATIBILITY.md](https://github.com/jklock/wolkaraforever/blob/v1.0.0/COMPATIBILITY.md) rather than presented as passed.

## Installing it

You build it. That is the supported path, and it is what the documentation covers step by step:

- [From zero to playing](https://github.com/jklock/wolkaraforever/blob/v1.0.0/docs/FROM_ZERO.md) — prerequisites, signing, first run, end to end.
- [Build and run](https://github.com/jklock/wolkaraforever/blob/v1.0.0/docs/GETTING_STARTED.md) — the short version.
- [Using WolkaraForever](https://github.com/jklock/wolkaraforever/blob/v1.0.0/docs/USING_WOLKARAFOREVER.md) — the in-app guide, with screenshots.
- [Maintaining](https://github.com/jklock/wolkaraforever/blob/v1.0.0/docs/MAINTAINING.md) — updating the app and the vendored engine.

You need an Apple silicon Mac, Xcode, XcodeGen, Python 3, your own signing identity, and the game files you already own. Nothing here downloads or ships Blizzard's code or assets.

For External JIT there is also an unsigned `.ipa`: start the **Experimental IPA (manual)** workflow with this release's tag. It contains only our runtime and adapters — no application code, no assets, no signing material.

## Known limits

- One game session per launch: quit the game and you reopen the app to play again. The page tells you so and gives you the button.
- The updater and the in-game path touch the client's own store, so they stay a by-hand check.
- Voice needs this app's Microphone and Speech Recognition permissions; **Permissions** opens the page that grants them.
- The original executable is never modified or re-signed. It is imported as hash-verified data, exactly as Blizzard shipped it.

## Credit, and the rules this project keeps

Tolkara's runtime and translation layer are by Vasilii Kharitonov and the Tolkara contributors, and the vendored copy is kept byte-identical to `upstream/main`; everything this fork adds lives above it and is described in [docs/ARCHITECTURE.md](https://github.com/jklock/wolkaraforever/blob/v1.0.0/docs/ARCHITECTURE.md). The app ships the notices it is obliged to ship, under the right names.

It does not automate the game, read its memory beyond loading and verifying the image, patch its binaries, or work around its integrity checks. Playing it is yours to do; automating it is not what this is for.
