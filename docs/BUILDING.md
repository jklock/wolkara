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

Tolkara depends on Developer Mode. iPadOS only lets a development-signed app
execute memory it did not sign after the device's developer service has
prepared it, and that service exists only in Developer Mode.

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
  `/Applications/Example.app/Contents/MacOS/Example`.
- `TOLKARA_PROFILE` (optional): a profile from [`profiles/`](../profiles).

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
signed.

On first launch iPadOS may ask you to trust your developer certificate:
Settings > General > VPN & Device Management.

## 4. Enrol local authorization (once)

```bash
tools/enroll.sh
```

With the iPad connected and unlocked, this creates a pairing identity for the
Tolkara app over the Mac's existing trusted USB session and stores it in the
app's device-only Keychain. Approve the prompt on the iPad. The temporary file
is deleted from the Mac afterwards.

The first time you press Play, iPadOS asks permission to add a VPN
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

## 5. Copy your application's files

The application's files live in the Tolkara app's Documents folder on the iPad,
visible in the Files app under On My iPad > Tolkara. A profile says where the
launcher expects them. For the tested profile:

```bash
python3 profiles/wow-classic-era/install.py
```

For anything else, copy the application's folder with Finder or the Files app
and write a profile: see [profiles/README.md](../profiles/README.md).

## 6. Run

Open Tolkara on the iPad and press **Play**. Keep the app in the foreground
while it prepares memory (currently about 80 seconds). Runtime output goes to
`Documents/native-guest.log`.

## Developing without a device

```bash
tools/test_emulation.sh
```

```bash
tools/run.sh sim
```

The first runs the sanitizer regression suite on the Mac. The second builds the
`TolkaraDiagnostics` scheme and runs the loader diagnostics in the simulator
against a synthetic test application from [`testguest/`](../testguest).
Simulator builds need no signing team. A simulator pass says nothing about
Metal behaviour or native execution on a real iPad.

To build the full app for the simulator by hand:

```bash
tools/generate.sh && xcodebuild -project Tolkara.xcodeproj -scheme Tolkara -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/integrated-sim ARCHS=arm64 build
```

## Things that will bite you

- Never attach a debugger (Xcode, lldb) to the app once application code is
  running. Tolkara deliberately runs with the debugger detached.
- Deleting the app from the iPad deletes the application files you copied and
  the enrolment. Installing over it keeps both.
- Do not commit `local.env`, provisioning profiles, pairing records or anything
  from `build/` or `logs/`.
