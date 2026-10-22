# From zero to playing: the complete setup walkthrough

This is the exhaustive, checkpointed route from a Mac with nothing installed to World of
Warcraft running on your iPhone or iPad through WolkaraForever. Every step says what to run,
what you should see, and what to do if you do not.

If you only want the short version, [GETTING_STARTED.md](GETTING_STARTED.md) is the condensed
route. This page assumes you have never built the project before.

> **Time and size.** Expect 45-90 minutes of setup before the game's first download, and a
> first download in the tens of gigabytes (the tested Forever install is about 70 GB). The
> download happens on the device while the app is open.

---

## The one-screen checklist

Print this. You are done when every box is ticked.

- [ ] Apple silicon Mac (M1 or later), macOS up to date.
- [ ] Xcode installed and its platform components downloaded; `xcodebuild -version` works.
- [ ] `xcodegen` and `python3` installed; `xcodegen --version` and `python3 --version` work.
- [ ] Paid Apple Developer Program membership; your team ID in hand.
- [ ] iPhone/iPad with enough free space, cable, unlocked, Developer Mode on, Mac trusted.
- [ ] Repository cloned; `local.env` filled in; `DEVELOPMENT_TEAM`, `TOLKARA_BUNDLE_ID`,
      `TOLKARA_KEYCHAIN_GROUP`, `DEVICE`, `NATIVE_GUEST_SHIMS=GENERIC` set.
- [ ] `wolkaraforever/tools/check_layers.sh` passes.
- [ ] `wolkaraforever/tools/install.sh` finishes at step 5/5 (home).
- [ ] Device shows **WolkaraForever**; launching it reaches the WoW home screen.
- [ ] Enrollment printed **Verified enrollment imported**.
- [ ] An edition is installed, verified, and **Ready to play**.
- [ ] **Play** reaches memory preparation, then the game's login screen.

---

## Step 1 - What you are building

WolkaraForever is a layer on top of the Tolkara engine. The engine is vendored unchanged
under `platform/`; everything this fork adds lives in `wolkaraforever/` and is applied at build
time as patches and file overlays. You build an app whose display name is **WolkaraForever**
(the Xcode scheme and product are still called **Tolkara**), sign it with your own Apple
developer identity, install it on your own device, and download the game directly on the
device. Nothing is streamed from the Mac.

Why the split matters is covered in [MAINTAINING.md](MAINTAINING.md). You do not need it to
finish setup.

## Step 2 - Prerequisites, in detail

### Hardware and accounts

| Need | Why | How to check |
| --- | --- | --- |
| Apple silicon Mac | The engine and its tooling target arm64 macOS; the simulator and device builds assume it. | Apple menu -> About This Mac shows an "Apple M..." chip. |
| iPhone or iPad | The app runs on your device. The best-recorded result is an iPhone 16 Pro Max on iOS 27; an iPad Pro (M5) on iPadOS 27 is the development device. | Settings -> General -> About. |
| Paid Apple Developer membership | The app and its tunnel need the Network Extension, increased-memory-limit and extended-address-space capabilities, which free Personal Team signing cannot provide. | developer.apple.com -> Account -> Membership. |
| A WoW account with access to the edition | The app downloads the client but does not provide an account. | Your Blizzard account. |
| Enough free device storage | The tested Forever install is about 70 GB before updates. | Settings -> General -> iPhone/iPad Storage. |

### Software, installed exactly like this

```bash
# Xcode: install from the App Store, open it once, and let it download its components.
xcodebuild -version            # should print an Xcode version

# XcodeGen and Python 3:
brew install xcodegen
xcodegen --version
python3 --version

# Xcode command-line tools, if not already selected:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

If `brew` is missing, install Homebrew from <https://brew.sh> first.

**Checkpoint:** all four version commands print a version without an error.

## Step 3 - Get the code

```bash
git clone https://github.com/fJavierLasso/wolkaraforever.git
cd wolkaraforever
```

The engine (`platform/`) is already vendored in the clone; you do not download Tolkara
separately.

**Checkpoint:** `wolkaraforever/tools/install.sh` does not need the upstream remote, so you
can go straight to building. The layer gate (`wolkaraforever/tools/check_layers.sh`) is a
developer check and is **optional** for setup: it compares `platform/` to your local
`upstream/main` ref, and a fresh clone has no such ref. If you run it and it says the gate has
no `upstream/main` ref, that is expected and not a blocker. To use the gate anyway, add the
remote (`git remote add upstream https://github.com/tolkara/tolkara.git && git fetch upstream`)
- and if it then says `platform/ differs`, that only means upstream has newer commits than the
vendored copy; see [MAINTAINING.md](MAINTAINING.md#updating-tolkara-the-engine).

## Step 4 - Create `local.env`

`local.env` is ignored by git and is the single place your personal settings live. Never
commit it.

```bash
cp local.env.example local.env
```

Open `local.env` and fill in these values:

| Variable | What to put | Where to find it |
| --- | --- | --- |
| `DEVELOPMENT_TEAM` | Your 10-character Apple team ID. | developer.apple.com -> Membership details, or Xcode -> Settings -> Accounts. |
| `TOLKARA_BUNDLE_ID` | An identifier unique to you, e.g. `local.wolkaraforever.yourname`. | You choose it. Apple registers a bundle ID to one team, so the example will not work. The tunnel extension derives `<your id>.authorization` automatically. |
| `TOLKARA_KEYCHAIN_GROUP` | The Keychain group for enrollment, e.g. `local.wolkaraforever.yourname.authorization`. | You choose it. Changing it later requires enrolling again. |
| `DEVICE` | Your device's UDID. | `xcrun devicectl list devices` with the device connected and unlocked. |
| `TOLKARA_MODE` | Leave as `developer-service`. | The integrated build uses Developer service. |
| `NATIVE_GUEST_SHIMS` | `GENERIC` for the WoW appliance. | Builds for no particular Mac executable; the game is chosen on the device. |
| `GUEST_EXE` | Leave empty. | Not needed with `NATIVE_GUEST_SHIMS=GENERIC`. |

Optional: `SIMULATOR` (for simulator-only test runs) and `TOLKARA_DISPLAY_NAME` (defaults to
`WolkaraForever`).

**Checkpoint:** `wolkaraforever/tools/env.sh` sources your file without error. A quick way to
confirm the values are read:

```bash
bash -c '. wolkaraforever/tools/env.sh; echo "team=$DEVELOPMENT_TEAM bundle=$TOLKARA_BUNDLE_ID device=$DEVICE"'
```

Do not share or commit the output beyond your own machine.

## Step 5 - Prepare the device

1. Connect the device by cable, unlock it, and tap **Trust** when asked.
2. Open Xcode once with the device connected (Window -> Devices and Simulators) so the device
   offers Developer Mode.
3. On the device: **Settings -> Privacy & Security -> Developer Mode -> on**. The device
   restarts; confirm the prompt after it boots.
4. Confirm the device is visible:

   ```bash
   xcrun devicectl list devices
   ```

   Copy its identifier into `DEVICE` in `local.env` if you have not already.

**Checkpoint:** `xcrun devicectl list devices` lists your device, and Developer Mode is on.

## Step 6 - Build, install and enroll in one command

```bash
wolkaraforever/tools/install.sh
```

What it does, in order, and what you should see:

| Step | What happens | Good sign |
| --- | --- | --- |
| 0/5 guard | Refuses to install while the game is running. | No refusal, or a clear message that nothing is running. |
| 1/5 prepare | Exports `platform/` to `build/platform`, applies the layer. | `prepare: build/platform ready (platform ...)`. |
| 2/5 build | Builds and signs our code through the platform's installer. | A successful `xcodebuild`, no signing errors. |
| 3/5 enroll | Runs the platform's `enroll.sh` for Developer service. | **Verified enrollment imported**. Approve the pairing prompt on the device. |
| 4/5 verify | Checks the app is really installed. | The bundle identifier listed on the device. |
| 5/5 home | Relaunches the launcher and proves it reached home. | The device shows **WolkaraForever** at its home screen. |

`--build-only` stops after the build and leaves the device alone, so a compile error costs
nothing.

### Prefer Xcode?

```bash
wolkaraforever/tools/generate.sh
open build/platform/Tolkara.xcodeproj
```

Select the **Tolkara** scheme and your device, then Run. Keep **Debug executable** off and
**Run -> Diagnostics -> Metal API Validation** off (the generated shared scheme already does
this). After the first install, enroll once:

```bash
cd build/platform && tools/enroll.sh
```

If Xcode reports a signing error, select both the `Tolkara` and `LocalAuthorizationTunnel`
targets, open Signing & Capabilities, choose your team, and let Xcode repair signing. Put
personal settings in `local.env`, because regenerating the project replaces manual edits.

**Checkpoint:** the device shows **WolkaraForever** and opening it reaches the WoW home screen.
If it does, setup is done; the rest is downloading and playing.

## Step 7 - Install an edition and play

1. On the home screen choose **Forever - Beta** (the edition with recorded gameplay), then your
   region and language.
2. Tap **Install**. Keep the app in the foreground while it downloads; backgrounding cancels
   the current transfer, though verified objects are kept and reused next time.
3. When the download and verification finish, the button becomes **Ready to play**.
4. Tap **Play**. Allow the local VPN-style tunnel if iOS asks - it reaches the device's own
   developer service for memory preparation, and nothing leaves the device.
5. Wait for memory preparation. On the current engine this takes several minutes at each
   launch. Keep the app in the foreground until the game's window appears.
6. Log in with your own account. Touch controls appear without a controller; the upper toolbar
   opens the keyboard, trackpad and settings.

**Checkpoint:** you reach the game's login screen and can log in.

> **A game process gets one session.** When the game closes, WolkaraForever's process ends too;
> reopen the app for another session. The toolbar's **Leave game** does this deliberately after
> a short countdown.

## Step 8 - Confirm it is a healthy install

- Reopen the app: it reaches home without re-enrolling.
- **Settings -> Technical details** shows the app and engine versions and no errors.
- The app's own log is available from Settings (and from `wolkaraforever/tools/device_log.sh`
  on the Mac).
- Optional, on the Mac: `wolkaraforever/tools/device_matrix.sh` runs the Mac-drivable device
  checks.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `check_layers.sh` says "no upstream/main ref" | The upstream remote or ref is missing from the clone. | `git remote add upstream https://github.com/tolkara/tolkara.git && git fetch upstream`. |
| `check_layers.sh` reports `platform/ differs from upstream/main` | You fetched upstream but did not vendor it, or `platform/` was edited by hand. | Vendor it: see [MAINTAINING.md](MAINTAINING.md#updating-tolkara-the-engine). Never edit `platform/`. |
| Xcode signing error on `Tolkara` or `LocalAuthorizationTunnel` | Team/capability not set for one target. | Select both targets -> Signing & Capabilities -> your team; let Xcode repair. |
| `install.sh` cannot see the device | Cable, lock state, trust, or Developer Mode. | Unlock, reconnect, tap Trust, confirm Developer Mode, re-run. |
| Enrollment does not print "Verified enrollment imported" | Device locked or connection dropped during pairing. | Keep it unlocked and connected, re-run `cd build/platform && tools/enroll.sh`. |
| Play stays disabled | An update or verification is in progress, or the build is not verified. | Keep the foreground; wait. **Settings -> Verify and repair game files** forces a full check. |
| Memory preparation seems stuck | It genuinely pauses the host while the service prepares memory. | Keep the foreground and wait minutes; if it fails, reopen. Do not delete the app. |
| First launch asks for a VPN configuration | That is the app's own packet tunnel. | Allow it; it routes one private address and carries no other traffic. |
| Wrong region or language in the client | The client's region picker is unsupported. | Set portal/locale as described in [IPHONE.md](IPHONE.md#region-and-language-before-the-first-launch). |
| Local signing rejects the container after a game update | The container is bound to the executable's pages, which changed. | Rebuild the container (see [MAINTAINING.md](MAINTAINING.md#updating-the-game)). |
| Something fails and you are tempted to delete the app | Deleting removes the game files, the enrollment and any page container. | Read the Technical details and the log first. Do not delete the app or its data as a first step. |

## Security and housekeeping

- `local.env`, pairing records, provisioning profiles, page containers and captures stay on
  your machine; none belong in a commit or a log.
- Keep `TOLKARA_BUNDLE_ID` and `TOLKARA_KEYCHAIN_GROUP` stable: that is what makes an update
  replace the app in place and keep its data.
- The app does not read or change the game's memory beyond loading it, and it does not hide
  the environment from the game.

## Where to go next

- [USING_WOLKARAFOREVER.md](USING_WOLKARAFOREVER.md) - the in-app guide (add-ons, voice, controls).
- [MAINTAINING.md](MAINTAINING.md) - how the layers fit and how to update the engine, the app and the game.
- [FRESH_INSTALL_TEST.md](FRESH_INSTALL_TEST.md) - the clean-device acceptance checklist.
