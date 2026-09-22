# Building and installing Tolkara

Tolkara is not distributed as a built app. You build it, you sign it with your
own Apple developer identity, and it runs on your own iPad. This page takes you
from a fresh clone to a running application.

## What you need

- A Mac with a recent Xcode, plus `xcodegen` and Python 3
  (`brew install xcodegen`).
- An Apple developer account. A paid membership is strongly recommended: the
  app needs the Network Extension (packet tunnel), increased memory limit and
  extended virtual addressing capabilities, which free personal teams cannot
  sign, and free provisioning profiles expire after seven days.
- An Apple-silicon iPad. Development and testing so far used an iPad Pro (M5)
  on iPadOS 27.
- A macOS arm64 application that you own, installed on the Mac.

## 1. Enable Developer Mode on the iPad

1. Connect the iPad to the Mac by cable, unlock it and tap **Trust**.
2. Open Xcode once with the iPad connected (Window > Devices and Simulators) so
   that the iPad offers the option.
3. On the iPad: Settings > Privacy & Security > **Developer Mode** > on. The
   iPad restarts; confirm the prompt after it boots.

Tolkara depends on Developer Mode: iPadOS runs development-signed apps only in
Developer Mode, and the Developer service execution mode uses the developer
service that exists only there.

## 2. Configure your own signing

Nothing about your identity is stored in the repository. Copy the template and
fill it in; `local.env` is ignored by git.

```bash
cp local.env.example local.env
```

- `DEVELOPMENT_TEAM`: your 10-character team ID (developer.apple.com >
  Membership details, or Xcode > Settings > Accounts).
- `TOLKARA_BUNDLE_ID`: any identifier unique to you, for example
  `local.tolkara.yourname`. Apple registers a bundle ID to a single team, so the
  default will not work for you. The tunnel extension automatically uses
  `<your id>.authorization`.
- `DEVICE`: your iPad's UDID:

```bash
xcrun devicectl list devices
```

- `GUEST_EXE`: the executable inside the macOS app you own, for example
  `/Applications/Example.app/Contents/MacOS/Example`. To run several apps,
  list all their executables separated by `:` (like `PATH`); the compatibility
  libraries are built for all of them.
- `TOLKARA_PROFILE` (optional): your own profile, if it is not in
  [`profiles/`](../profiles). Every profile there is included automatically.
- `TOLKARA_MODE` (optional): `developer-service` or `local-signing`, see step 4.
  Without it the app asks on first launch.

Xcode signs automatically (`CODE_SIGN_STYLE: Automatic`). The first build
registers the bundle IDs and the iPad with your team and creates the profiles.
If it reports a signing error, open `Tolkara.xcodeproj` once in Xcode, select
the `Tolkara` and `LocalAuthorizationTunnel` targets, and let Xcode repair
signing under Signing & Capabilities.

## 3. Build and install

```bash
tools/install.sh
```

This generates the Xcode project, inspects which macOS frameworks and symbols
your executable imports, builds and signs **only Tolkara's own code** (the app,
its tunnel extension and the translation libraries), and installs the app. Your
executable is read for analysis; it is not copied into the app, modified or
signed. (Local signing signs a separate page container derived from it; see
step 4.)

On first launch iPadOS may ask you to trust your developer certificate:
Settings > General > VPN & Device Management.

## 4. Set up your execution mode

Tolkara runs the application's code in one of two ways; the README's
[Two ways to run code](../README.md#two-ways-to-run-code) compares them. Choose
one. The app asks on first launch unless `TOLKARA_MODE` preselected a mode, and
**Execution mode…** in the app changes it later. You only need to set up the
mode you use.

### Developer service: enrol local authorization (once)

```bash
tools/enroll.sh
```

With the iPad connected and unlocked, this creates a pairing identity for the
Tolkara app over the Mac's existing trusted USB session and stores it in the
app's device-only Keychain. Approve the prompt on the iPad. The temporary file
is deleted from the Mac afterwards.

The first time you start an app, iPadOS asks permission to add a VPN
configuration. This is Tolkara's own on-device packet tunnel. It routes one
private address to the iPad's own developer service and carries no other
traffic; nothing leaves the device. How it works is documented in
[LOCAL_AUTHORIZATION.md](LOCAL_AUTHORIZATION.md).

After enrolment the Mac is no longer needed: launches, relaunches and reboots
work on the iPad alone. You need to repeat steps 3 and 4 only when your
provisioning profile expires or you change the bundle ID or Keychain group.

> `tools/enroll.sh` packages the procedure used during development into one
> command. If it fails, the individual steps are readable in the script and
> each prints its own diagnosis.

### Local signing: build the page container

With `TOLKARA_MODE=local-signing` in `local.env`, `tools/install.sh` does this
after installing. By hand:

```bash
python3 tools/build_signed_container.py
```

It reads `GUEST_EXE`, `TOLKARA_CAPTURE`, `DEVELOPMENT_TEAM` and `SIGN_IDENTITY`
from the environment or `local.env`, puts the executable's `__TEXT` pages into
`build/signed-image/page-container.dylib`, signs it with your Apple Development identity and verifies the signature. The
first signature asks macOS whether the signing tool may use your signing key:
choose **Always Allow**. The approval belongs to that build of the tool, so it
is asked again after the tool is rebuilt. Signing on the iPad itself is not
implemented yet.

Copy the container into the Tolkara app's Documents as
`LocalSigning/page-container.dylib` (in the Files app: On My iPad > Tolkara >
LocalSigning). `tools/install.sh` with `TOLKARA_MODE=local-signing` copies it
for you.

With several apps, each needs its own container, named after the SHA-256 of
its executable file: `LocalSigning/<sha256>.dylib` (`shasum -a 256` prints it;
an app's details in the library show it too). `tools/install.sh` builds and
copies one per `GUEST_EXE` entry; give `TOLKARA_CAPTURE` one entry per
executable, in the same order, separated by `:` (empty for the on-disk code,
`skip` for none). An app without its own container uses `page-container.dylib`
if present, and the runtime refuses it unless it belongs to that executable.

Without `--capture`, the container holds the executable's code as it is on
disk. That is right only for applications that do not rewrite their own code at
launch. For one that does, such as the tested World of Warcraft client, the
container must be built from a capture of the final code pages
(`--capture FILE`, or `TOLKARA_CAPTURE` in `local.env`), and Tolkara cannot
produce that capture yet. A container that does not match the executable, or
what its own startup code produces, stops the launch before any more
application code runs; the app may close, and `Documents/native-guest.log` says
why (`[signed-image] FATAL …` or a rejection). Rebuild the container whenever
the application is updated.

## 5. Copy your application's files

The application's files live in the Tolkara app's Documents folder on the iPad,
visible in the Files app under On My iPad > Tolkara. A profile says where the
launcher expects them. For the tested profile:

```bash
python3 profiles/wow-classic-era/install.py
```

An app whose profile is in `profiles/` appears in Tolkara's library by itself
once its files are there. For anything else, copy the application's folder with
Finder or the Files app, then tap **+** in Tolkara and choose its executable (or
its `.app`). Tolkara remembers it; you do not pick it again. Optionally write a
profile: see [profiles/README.md](../profiles/README.md).

## 6. Run

Open Tolkara on the iPad, choose the execution mode if it asks, and tap the
app in the library. With Developer service, keep Tolkara in the foreground
while it prepares memory (currently about 80 seconds). One app can start per
session: to start another, close Tolkara in the app switcher and open it again.
Runtime output goes to `Documents/native-guest.log`; the Diagnostics menu
(stethoscope) shows it and the other logs, and holds the development checks.

## Developing without a device

```bash
tools/test_emulation.sh
```

```bash
tools/run.sh sim
```

The first runs the sanitizer regression suite on the Mac. The second builds the
`TolkaraDiagnostics` scheme and runs the loader diagnostics in the simulator
against a synthetic test application from [`testguest/`](../testguest). To try
Local signing in the simulator:

```bash
TOLKARA_MODE=local-signing tools/run.sh sim
```

It builds an ad-hoc signed page container for the test application (or for
`GUEST_EXE` if `local.env` sets it) and runs its first initializer through
Local signing.
Simulator builds need no signing team. A simulator pass says nothing about
Metal behaviour or native execution on a real iPad.

To build the full app for the simulator by hand:

```bash
tools/generate.sh && xcodebuild -project Tolkara.xcodeproj -scheme Tolkara -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/integrated-sim ARCHS=arm64 build
```

## Things that will bite you

- Never attach a debugger (Xcode, lldb) to the app once application code is
  running. Tolkara deliberately runs with the debugger detached.
- Deleting the app from the iPad deletes the application files you copied, the
  enrolment and the page container. Installing over it keeps them.
- Do not commit `local.env`, provisioning profiles, pairing records, page
  containers, captures or anything from `build/` or `logs/`.
