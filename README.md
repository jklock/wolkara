# Tolkara

Tolkara runs **unmodified** arm64 macOS applications on an iPad. It loads the
original executable as data, executes its instructions natively on the iPad's
Apple silicon, and translates the macOS API calls it makes (AppKit, Metal,
CoreAudio, Carbon, Security, …) into their iPadOS equivalents.

It follows the model of [Wine](https://www.winehq.org) and Valve's
[Proton](https://github.com/ValveSoftware/Proton): the program is not ported or
patched, and its executable is never modified or re-signed. Only the
operating-system calls underneath it are translated. The application's own code,
logic, assets and network protocol are left exactly as the vendor shipped them.

Tolkara is a do-it-yourself developer project. You build it with your own Apple
developer account, sign it yourself, and bring your own legally obtained copy of
the macOS application. Nothing here is distributed through the App Store, and
the repository contains no third-party application code or assets.

## Status

Tested on an iPad Pro (M5) with iPadOS 27. The first application validated end
to end, with Developer service, is World of Warcraft Classic (Classic Era macOS
client): login, world entry, movement, combat, quests, audio and intro
cinematics work, at up to 120 FPS on reduced resolution. See
[COMPATIBILITY.md](COMPATIBILITY.md) for details and known problems. Other
applications will need more API coverage; reports and patches are welcome.

Notable limits today: with Developer service, preparing executable memory takes
roughly 80 seconds per launch, and switching apps during startup can interrupt
it. With Local signing, an earlier build reached the application's original
`main` on a device; the current build has not been re-run there yet, and login
and gameplay are not validated. Helper processes that an app launches separately
(for example a voice-chat helper) are not supported.

## Two ways to run code

iPadOS executes only code whose pages are covered by a valid code signature,
with one exception for development: memory that the device's developer service
has prepared. Tolkara supports both routes. Each user chooses one: the app asks
on first launch, and **Execution mode…** in the app changes it later.

| | Developer service | Local signing |
| --- | --- | --- |
| What it does | Tolkara's bundled packet-tunnel extension reaches the iPad's own developer service, which prepares executable memory and detaches before any application code runs. Tolkara then copies the original code in. | The application's final code pages are put into a small library, a *page container*, signed with your own developer identity. iPadOS validates it when Tolkara loads it, and Tolkara maps those validated pages into place. |
| What it requires | Developer Mode, a one-time enrolment from a Mac (`tools/enroll.sh`), and permission for Tolkara's own VPN-style tunnel. About 80 seconds of preparation per launch. | Developer Mode and your developer identity. For now the container is built and signed on a Mac (`tools/build_signed_container.py`) and copied to the iPad. For an application that rewrites its own code at launch, this needs a capture of its final code pages, which Tolkara cannot produce yet. |
| What it does with the application's code | Runs the original code unchanged. Nothing of the application is ever signed. | Leaves the executable unchanged, but keeps a derived copy of its final code pages on your iPad (and in your build folder), signed under your identity. Tolkara refuses to start if the container does not match the executable or what the application's own startup code produces. |

Choose one. [COMPATIBILITY.md](COMPATIBILITY.md) says which mode each result
was obtained with.

## How it works

| Module | Role |
| --- | --- |
| [`runtime/`](runtime) | Mach-O loader: maps the original image, applies dyld rebases and binds, sets up TLS and Objective-C metadata, and enters the original initializers and `main`. For Local signing it validates the page container against the executable and maps its signed pages (`SignedImage`). Also a software MMU and a small interpreter used for testing. |
| [`translation/`](translation) | The macOS API layer: AppKit on UIKit, Metal device/shader-library adaptation, CoreAudio/AudioToolbox, Carbon keyboard, CoreGraphics displays, Security. One library per macOS framework; anything not hand-written gets a generated logging stub. |
| [`authorization/`](authorization) | Developer service. iPadOS only lets a development-signed app run code it did not sign after a debugger has prepared that memory. This module does that on the iPad itself: a bundled packet-tunnel extension reaches the device's own developer service, prepares the memory, and detaches before any application code runs. No Mac is needed after the one-time enrollment. |
| [`launcher/`](launcher) | The UIKit app: import, the execution-mode choice, diagnostics, and the Play button. |
| [`profiles/`](profiles) | Small data files that describe a tested application: its name and where its files live. No code. |

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the protocol notes
in [docs/LOCAL_AUTHORIZATION.md](docs/LOCAL_AUTHORIZATION.md).

## Getting started

You need a Mac with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
Python 3, an Apple developer account, and an iPad with Developer Mode enabled.
The full walkthrough, including signing and Developer Mode, is in
**[docs/BUILDING.md](docs/BUILDING.md)**. In short:

```bash
cp local.env.example local.env
```

Fill in your team ID, a bundle ID unique to you, your iPad's UDID and the path
of the macOS executable, and optionally `TOLKARA_MODE` (`developer-service` or
`local-signing`; without it the app asks). Then:

```bash
tools/install.sh
```

With Developer service, enrol once:

```bash
tools/enroll.sh
```

With `TOLKARA_MODE=local-signing`, `tools/install.sh` also builds, signs and
copies the page container. Copy your application's files to the iPad (for the
WoW Classic profile,
[`profiles/wow-classic-era/install.py`](profiles/wow-classic-era)), open Tolkara
on the iPad and press Play.

To check a change without a device:

```bash
tools/test_emulation.sh
```

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
  `munmap`, `memcpy`, `memmove`, `memset` (for the separate read-write and
  executable views of code memory), `pthread_jit_write_protect_np`, `dladdr`,
  `dlsym`, `_NSGetExecutablePath`, `CFBundleGetMainBundle`, `_tlv_bootstrap`,
  `dyld_stub_binder`, `__ulock_wait` and `sigaction` (the last only when you
  opt into crash logging). The list is in
  [`runtime/NativeGuest.m`](runtime/NativeGuest.m).
- Everything else the application imports resolves to the real iPadOS framework
  or to a translation library in [`translation/`](translation).
- Nothing in Tolkara exists to hide the environment from the application. It does
  not conceal debuggers, processes, the device model or the operating system.
  With Developer service, the debugger used to prepare memory detaches before
  the first application instruction runs, and nothing attaches afterwards.
  Local signing uses no debugger.

## Policy

Tolkara is a compatibility layer and nothing else. The project will not accept:

- reading or changing an application's memory for any purpose other than
  loading it, including "trainers", overlays, bots or input automation;
- workarounds for anti-cheat, licence or integrity checks;
- bundled or downloadable copies of any third-party application, asset or
  operating-system component.

## Online games and account risk

Read this before you use Tolkara with an online game.

Tolkara is not supported, endorsed or approved by the publisher of any
application you run with it. Running a game client on an operating system it was
not released for may be against that game's terms of service.

Blizzard has for many years tolerated players who run its games on Linux
through Wine and Proton, and does not ban them for doing so. Tolkara is built
the same way and for the same purpose. That history is not a promise. Automated
detection can misfire, as it occasionally has for Wine users, and a publisher can
change its position at any time without notice.

With Local signing, a signed copy of the application's unpacked code is kept on
your iPad. That changes nothing the publisher ships, but whether it is
acceptable is for the publisher's terms to say, not us.

**If you use Tolkara with an online account, the risk of a suspension or ban is
real and it is entirely yours.** The authors and contributors accept no
responsibility for lost accounts, characters, purchases or subscriptions. If
that risk is not acceptable to you, do not use Tolkara with that account.

## Legal

Tolkara is released under the [MIT License](LICENSE). It contains no code from
Apple, Blizzard or any other third party; see [NOTICE.md](NOTICE.md) for the
references used while writing it.

Tolkara is an independent project and is not affiliated with, sponsored by or
endorsed by Apple Inc. or Blizzard Entertainment, Inc. macOS, iPadOS, iPad,
Metal and Xcode are trademarks of Apple Inc. World of Warcraft and Blizzard are
trademarks of Blizzard Entertainment, Inc. Other names are the property of their
owners and are used only to describe compatibility.

You are responsible for having the right to use any application you run with
Tolkara, and for complying with its licence.

Project home: [tolkara.org](https://tolkara.org). Contact: vk@tolkara.org.
