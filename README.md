# Wolkara

**World of Warcraft on iPhone and iPad, built on [Tolkara](https://github.com/tolkara/tolkara).**

Wolkara is an independent, experimental fork focused on the WoW experience:
choose an edition, download its macOS client on the device, keep it updated,
and play with touch controls or a physical controller. The game runs locally
through Tolkara's compatibility layer; it is not streamed from a Mac.

Tolkara's runtime and macOS API translation are the foundation of this project.
Wolkara adds the WoW launcher, downloader/updater and mobile input interface.
The upstream history, MIT license and [third-party notices](NOTICE.md) are retained.
This project is not affiliated with or endorsed by Blizzard Entertainment.

## Try it with Xcode

**Start here: [Build and run Wolkara](docs/GETTING_STARTED.md).**

The current route needs a Mac with Xcode, XcodeGen and Python 3, your own Apple
developer signing with the required capabilities, Developer Mode on the device,
and one-time USB authorization. Use the **Tolkara** scheme: the app is displayed
as **Wolkara**, while the internal target name is retained for compatibility.

You do not need to install WoW or Battle.net on the Mac to build the generic
launcher. You need your own eligible game account/access to log in. Game files
are downloaded from Blizzard's CDN; no game code or assets are included here.

This is a source release for people comfortable with Xcode. There is no tested
public Wolkara IPA, App Store/TestFlight release or AltStore PAL install path.
A successful build alone does not prove that a signing profile permits startup.

## Features

- A single WoW home screen with edition, region and language selection.
- On-device installation and automatic update checks; required updates finish
  before Play becomes available.
- Resumable downloads, checksum verification and reuse of verified unchanged
  game data. Updates preserve settings and addons.
- An iOS keyboard with dictation and an editable draft that replaces the focused
  game field, plus a touch trackpad with two-finger scrolling.
- Physical controller support and an on-screen controller when none is connected.
- Movable touch controls, opacity and size settings, an alignment grid and haptics.

## What has been tested

The developer reports **60 FPS at graphics quality 4 on an iPhone 16 Pro Max**
playing WoW Forever (Classic beta). This is a gameplay report, not a benchmark
or a promise for every scene/device. Render scale was not specified in this
latest report; the earlier quality-2 session used 50% render scale.

Forever login, gameplay and the touch controls have been tested on that phone.
Classic Era reached its cinematic and login screen. A Mac-disconnected launch,
including after reboot, has also been reported with the existing authorization.
The edition selector includes other WoW clients; their presence is not a
compatibility claim. See [COMPATIBILITY.md](COMPATIBILITY.md) for dated results.

The updater has synthetic regression coverage, isolated Mac-copy tests and a
recorded device patch installations. Xcode logs also confirm that the latest
metadata-recovery fix completed an on-device update. A complete first download
into an empty iPhone installation still needs end-to-end validation. Follow the [fresh-install checklist](docs/FRESH_INSTALL_TEST.md)
and report the exact commit and client build you tried.

## Current limits

- Setup is still a developer workflow, with personal signing and enrollment.
- Executable-memory preparation still takes several minutes on each launch.
  Keep the app in the foreground during this step.
- Cellular-only startup has an unresolved report; a disconnected Mac does not
  establish that every mobile-network condition works.
- Other devices, editions and signing methods need testing. Voice chat's
  separate helper process is not supported.
- Keyboard/input and update recovery are actively being improved. If something
  fails, include the exact message from Settings → Technical details and a
  redacted log, never account or pairing information.

## Development

```bash
tools/test_emulation.sh
```

Focused updater tests: `tools/test_wow_launcher.sh`. UIKit fixtures:
`tools/test_wow_launcher_ui.sh` (set `SIMULATOR` to an available simulator).
Read [CONTRIBUTING.md](CONTRIBUTING.md) before contributing.

- [Launcher and updater](docs/WOW_LAUNCHER.md)
- [Touch input](docs/TOUCH_INPUT.md)
- [Touch controller](docs/TOUCH_CONTROLLER_PROPOSAL.md)
- [Engine architecture](docs/ARCHITECTURE.md)
- [Advanced Tolkara build and execution modes](docs/BUILDING.md)
- [Distribution research and unverified routes](docs/WOLKARA_DISTRIBUTION.md)

The shared engine, adapters and non-WoW test fixtures remain in this fork to
preserve upstream compatibility and regression coverage. Public Wolkara builds
use the WoW home; alternative loaders/modes are development tools.

## What Tolkara does to the application

So that you can judge this yourself rather than take our word for it:

- The original executable is imported as a file, verified by SHA-256, and mapped
  into memory. It is never edited, re-signed, or included in the app bundle. The
  loader applies the same rebases and binds dyld would; those are runtime state
  in memory, not changes to the file. With Local signing, a copy of its final
  code pages is signed with your identity in a separate page container that
  stays on your Mac and your iPad.
- The loader answers a short, fixed list of calls itself instead of passing them
  to iPadOS, because they concern how the image was loaded: `mmap`, `mprotect`,
  `munmap`, `memcpy`, `memmove`, `memset`, `__clear_cache` (for the separate
  read-write and executable views of code memory), `pthread_jit_write_protect_np`, `dladdr`,
  `dlsym`, `_NSGetExecutablePath`, `CFBundleGetMainBundle`, `_tlv_bootstrap`,
  `dyld_stub_binder`, `__ulock_wait` and `sigaction` (the last only when you
  opt into crash logging). The list is in
  [`runtime/NativeGuest.m`](runtime/NativeGuest.m).
- Everything else the application imports resolves to the real iPadOS framework,
  to a translation library in [`translation/`](translation), or to a library the
  application carries in its own bundle. An import that nothing provides
  becomes a stub that logs and returns zero: generated at build time for the
  executable of a build made for it, and made at launch in a generic build (made
  for no particular application) and for the libraries an application carries.
  In a build made for one application, an import of its executable that nothing
  provides at launch stops the launch instead.
- Nothing in Tolkara exists to hide the environment from the application. It does
  not conceal debuggers, processes, the device model or the operating system.
  With Developer service, the debugger used to prepare memory detaches before
  the first application instruction runs, and nothing attaches afterwards.
  With External JIT, Tolkara asks the enabler's debugger to detach and does not
  start the application while any debugger is attached. Local signing uses no
  debugger.

## Policy

Wolkara builds on Tolkara as a compatibility layer. This fork will not accept:

- reading or changing an application's memory for any purpose other than
  loading it, including "trainers", overlays, bots or input automation;
- workarounds for anti-cheat, licence or integrity checks;
- redistribution of third-party application code, assets or operating-system
  components in this repository or its releases. The updater obtains game
  content directly from the vendor for the user's installation.

## Online games

Wolkara is not approved or supported by Blizzard. Successful execution does not
establish publisher approval or guarantee the safety of an online account.
The project provides no anti-cheat, license or integrity-check workarounds.

## Legal

Wolkara and the upstream Tolkara code are released under the [MIT License](LICENSE).
No game files or Apple operating-system components are included. Third-party
adaptations and reference material are credited in [NOTICE.md](NOTICE.md).

Wolkara is an independent project and is not affiliated with, sponsored by or
endorsed by Apple Inc. or Blizzard Entertainment, Inc. macOS, iPadOS, iPad,
Metal and Xcode are trademarks of Apple Inc. World of Warcraft and Blizzard are
trademarks of Blizzard Entertainment, Inc. Other names are the property of their
owners and are used only to describe compatibility.

You are responsible for having the right to use any application you run with
Wolkara, and for complying with its licence.

Wolkara: [source and issues](https://github.com/fJavierLasso/wolkara).
Upstream engine: [Tolkara](https://github.com/tolkara/tolkara) · [tolkara.org](https://tolkara.org).
