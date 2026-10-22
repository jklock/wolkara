# Build and run WolkaraForever

This guide is for the WolkaraForever fork and its integrated Developer service build.
It builds our generic runtime, then downloads the selected WoW client directly
on the iPad. WoW and Battle.net do not need to be installed on your Mac.

> This is the condensed route. For the exhaustive, checkpointed walkthrough - with
> prerequisites, what each step should print, and troubleshooting - see
> [From zero to playing](FROM_ZERO.md).

## Requirements

- An Apple silicon Mac, Xcode with support for your iPad's iPadOS version,
  XcodeGen and Python 3. Install Xcode's requested platform components first.
- Your own Apple developer signing. The integrated app and its tunnel need
  Network Extension, increased-memory-limit and extended-address-space
  capabilities. Use a paid developer membership for this workflow; free
  Personal Team signing is not a validated alternative for this build.
- A connected, unlocked device with Developer Mode enabled and the Mac trusted.
  The recorded testing is on an iPad Pro M5 running iPadOS 27.
- Enough free device storage for the edition and its updates. The tested
  Forever installation is roughly 70 GB; the required size changes by build.
- Your own game account and access to the selected edition/beta.

Or run `wolkaraforever/tools/install_prerequisites.sh` to check and install the Mac pieces.

## 1. Clone and configure

```bash
git clone https://github.com/fJavierLasso/wolkaraforever.git
cd wolkaraforever
brew install xcodegen
cp local.env.example local.env
```

The clone already contains the most current Tolkara engine in `platform/`; you do not
clone Tolkara separately. To move to a newer Tolkara later, see
[MAINTAINING](MAINTAINING.md#updating-tolkara-the-engine).

With the iPad connected, `wolkaraforever/tools/device_variables.sh --write` fills `DEVICE`
for you (USB or paired network). `wolkaraforever/tools/preflight.sh` then checks the Mac,
device and app before you build.

Edit the ignored `local.env` with your own values:

```bash
DEVELOPMENT_TEAM=YOUR_TEAM_ID
TOLKARA_BUNDLE_ID=local.wolkaraforever.yourname
TOLKARA_KEYCHAIN_GROUP=local.wolkaraforever.yourname.authorization
DEVICE=YOUR_DEVICE_UDID
TOLKARA_MODE=developer-service
NATIVE_GUEST_SHIMS=GENERIC
GUEST_EXE=
```

Find the team in Xcode → Settings → Accounts and the device identifier with
`xcrun devicectl list devices`. Keep those values local; do not commit them.
Use identifiers unique to your team. The extension's identifier is derived from
the app identifier automatically. Leave experimental adapters and captures unset.

## 2. Open Xcode and Run

```bash
wolkaraforever/tools/generate.sh
open build/platform/Tolkara.xcodeproj
```

Select the **Tolkara** scheme and your physical iPad destination, then
press **Run**. The app installed on the device is called **WolkaraForever**. Do not run
`LocalAuthorizationTunnel` or `StorageProbe` as the application.

Automatic signing must succeed for both `Tolkara` and `LocalAuthorizationTunnel`.
If Xcode needs account/capability setup, fix Signing & Capabilities for both
before retrying. Keep **Debug executable** and **Metal API Validation** off;
the generated shared scheme already does this. Store persistent personal
settings in `local.env`, because regeneration replaces manual project edits.

If the device requests developer trust, use Settings → General → VPN & Device
Management. Enable Developer Mode under Privacy & Security if needed.

## 3. Authorize this installation once

After the app is installed, keep the device unlocked and connected. From the
same checkout, run:

```bash
build/platform/tools/enroll.sh
```

Approve the system pairing prompt on the device. The command must finish with
**Verified enrollment imported**. It stores this installation's authorization
in the device-only Keychain. Do not share pairing records or authorization files.
Changing the bundle ID or Keychain group requires enrolling again.

Reopen WolkaraForever normally afterwards. When first launching the game, allow its
local VPN-style tunnel if iPadOS asks. It is used to reach the device's developer
service for memory preparation, not to stream the game from the Mac.

## Optional: push the game from the Mac

If the game is already on your Mac, copy it instead of downloading it on the device:

```bash
wolkaraforever/tools/push_game.sh --source "/Applications/World of Warcraft"
wolkaraforever/tools/push_game.sh --source "/Volumes/Storage/World of Warcraft"
```

`--source` is the folder containing `_classic_beta_`, on any volume.
See [DEVICE_WORKFLOW.md](DEVICE_WORKFLOW.md).

## 4. Install an edition and play

Choose **Forever · Beta** for the edition with recorded gameplay, then your
region/language and **Install**. Keep WolkaraForever in the foreground while downloading.
It checks for updates when opened and before launch, and installs required
updates before enabling Play. If interrupted, reopen and retry to resume.

After **Ready to play**, press **Play** and allow memory preparation to finish.
Log in manually using your eligible account. Touch controls appear without a
physical controller; the upper toolbar opens the keyboard, trackpad and settings.

Installing is the documented path and is done repeatedly. If a step does fail,
record Settings → Technical details and a redacted log; do not delete the app or
its data as an initial troubleshooting step. See [fresh-install testing](FRESH_INSTALL_TEST.md).

## Updating WolkaraForever itself

Close the game, pull the source changes, regenerate the project and Run again
with the same bundle ID, team and Keychain group. This replaces the app while
keeping its game data. Game updates happen inside WolkaraForever; source/app updates
still require rebuilding. Signing and authorization requirements remain separate.

Keep your existing bundle ID and Keychain group when updating, so the install
replaces the app in place. Saved touch layouts, verified-download receipts, the
settings file and the app log are stored under WolkaraForever's own names; a build
that predates them starts from defaults, so set your layout and options once.

The existing setup has launched without the Mac and after reboot. Network access
(Wi-Fi is fine) is required to download and update. Build success or a simulator
pass is not proof of game execution on another device or signing setup.
