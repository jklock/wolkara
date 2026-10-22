# Mac setup, device variables, and pushing the game

This page covers the three scripted pieces of a WolkaraForever setup that are easy to get
wrong by hand:

1. installing the Mac prerequisites safely;
2. reading the variables for an attached iPad over **USB or the network**;
3. pushing a game that is already on your Mac into the app, so the iPad does not download it.

The scripts are heavily commented and safe by default. Two of them (`install_prerequisites.sh`
and `device_variables.sh`) only change things when told to; the third wraps the existing copy
installer. The whole flow is tested end to end on iPad Pro M5 (iPadOS 27).

```mermaid
flowchart LR
    A["install_prerequisites.sh"] --> B["local.env + install.sh"]
    B --> C["device_variables.sh --write"]
    C --> D["push_game.sh --source ..."]
    D --> E["Play - no device download"]
```

## Things only you can do

The scripts cannot do these, and do not try:

- install **Xcode** from the App Store, open it once, and accept its licence
  (`sudo xcodebuild -license accept`);
- join the **Apple Developer Program** (paid) and know your team ID;
- on the iPad, turn on **Developer Mode** (Settings > Privacy & Security), unlock it, tap
  **Trust** for this Mac, and pair it over the network in Xcode if you want cable-free use;
- have your own WoW account.

`install_prerequisites.sh` lists exactly which of these are still missing.

## 1. Install the Mac prerequisites

```bash
wolkaraforever/tools/install_prerequisites.sh          # check, then install what is safe
wolkaraforever/tools/install_prerequisites.sh --check  # report only, change nothing
```

It checks, in order: macOS and architecture, full Xcode and its licence, `devicectl`, the iOS
SDK, Homebrew, `xcodegen`, `git` **with subtree**, Python 3.9+, `local.env`, and free disk
space. It installs only the small Homebrew formulae (`xcodegen`, `git`, and `python` only if
the system one is too old).

It will **not**:

- use `sudo`, accept a licence, or install Xcode (App Store);
- install Homebrew unless you pass `--install-homebrew`;
- join the Apple Developer Program, enable Developer Mode, or trust the Mac on the iPad.

Nothing is changed when everything is present, so it is safe to re-run. It exits non-zero if a
required piece is still missing.

## 2. Read the iPad's variables (USB or network)

```bash
wolkaraforever/tools/device_variables.sh                # show the device and the variables
wolkaraforever/tools/device_variables.sh --write        # also set DEVICE in local.env
wolkaraforever/tools/device_variables.sh --export       # eval-able shell assignments
wolkaraforever/tools/device_variables.sh --json         # machine-readable
```

It asks CoreDevice (`xcrun devicectl list devices --json-output`) for the device list and keeps
physical iPads. For the chosen device it prints:

| Variable | Meaning |
| --- | --- |
| `DEVICE` | The UDID the tools pass to `devicectl` (the value `local.env` needs). |
| `DEVICE_NAME` | The name shown in Xcode and on the device. |
| `DEVICE_MODEL` | Marketing model, e.g. "iPad Pro (12.9-inch) (5th generation)". |
| `DEVICE_OS` | The iPadOS version. |
| `DEVICE_CONNECTION` | `USB` (wired), `Network` (paired), or `Simulator`. |
| `TOLKARA_BUNDLE_ID` | Read from `local.env`; the app the copy targets. |

**USB or network.** CoreDevice lists a cable-connected iPad and a network-paired one the same
way; the script reports which link it is using. A paired device that is asleep may appear as not
connected - wake it or use the cable. Pair over the network in Xcode > Window > Devices and
Simulators.

**Several devices.** The script picks the only connected physical iPad. If more than one is
connected it stops and lists them; choose one with `--device "Dadpad"` (name, UDID or
CoreDevice identifier).

**`--write`** changes only the `DEVICE=` line in the ignored `local.env`, creating the file if it
does not exist. It refuses to replace a different existing `DEVICE` unless you pass `--force`.
Device identifiers stay on your Mac; do not paste this output into a commit or a log.

The iPad must be unlocked and trusted, with Developer Mode on, or CoreDevice will not offer it.

## 3. Push the game from the Mac (skip the download)

If the game is already installed on your Mac, copy it to the app instead of downloading it on
the iPad:

```bash
wolkaraforever/tools/push_game.sh --source "/Applications/World of Warcraft"
wolkaraforever/tools/push_game.sh --source "/Volumes/Storage/World of Warcraft"
wolkaraforever/tools/push_game.sh --source "/Volumes/Storage/World of Warcraft" --skip-data
```

The link is reported: with a cable attached CoreDevice uses USB; otherwise the copy
runs over the paired network, which works but is much slower for tens of gigabytes.

`--source` accepts the game on any folder or volume (it is the folder containing
`_classic_beta_`). The tested install is about 63 GB, so allow roughly 70 GB free on the
iPad. `preflight.sh --source <folder>` checks it, and reports iPad free space when the
iPad is connected by USB; a network-only iPad exposes its capacity but not free space, so
then check Settings > General > iPad Storage.

A copy is retried up to three times (`--retries N`); each retry reuses files already
verified, so it resumes rather than restarts.

`push_game.sh` is a thin wrapper around the supported installer,
`profiles/wow-forever/install.py` in the prepared tree (`build/platform/`). It:

1. loads `local.env` (so `DEVICE` and `TOLKARA_BUNDLE_ID` are what `install.sh` uses);
2. prepares `build/platform` if it is missing (`--prepare` forces a fresh prepare);
3. runs the installer from `build/platform`, copying into the app's Documents.

Options (passed through to `install.py`):

| Option | Effect |
| --- | --- |
| `--source <folder>` | The Mac game folder (default `/Applications/World of Warcraft`). |
| `--skip-data` | Copy the client bundle only, not the large `Data` folder. |
| `--device <UDID>` | Override `DEVICE` for this run. |

What the copy does, and does not do:

- It copies the client bundle and resources, and `Data` unless `--skip-data`, into
  `Documents/World of Warcraft` in the app's container. `devicectl` skips unchanged files on
  later runs, so a second push is fast.
- It copies only the settings keys the launcher manages; it does **not** copy account
  credentials, and it never modifies your Mac installation.
- The app must already be installed (`wolkaraforever/tools/install.sh`). The push copies into
  its container; it does not install the app.
- The copy is one-way. Nothing on the iPad is deleted.
- The app still verifies what it has and may still check for a newer game patch; the push
  matches the version you have on the Mac.

Expect a large transfer (tens of gigabytes with `Data`). USB is much faster than network for
this; `device_variables.sh` reports which link is in use.

### Add-ons

Close WolkaraForever first, then merge the Mac's add-ons without deleting anything on the
iPad:

```bash
cd build/platform && profiles/wow-forever/sync_addons.sh --source "/Volumes/Storage/World of Warcraft"
```

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `device_variables` finds no iPad | Not connected/trusted, Developer Mode off, or not paired on the network. | Connect by cable, unlock, tap Trust; or pair in Xcode > Devices; enable Developer Mode. |
| `several iPads are available` | More than one connected device is visible. | Re-run with `--device "Name"` or `--device <UDID>`. |
| `local.env already has a different DEVICE` | `--write` refuses to switch devices silently. | Use the intended device, or pass `--force`. |
| `DEVICE is not set` from `push_game` | `local.env` has no `DEVICE`. | `wolkaraforever/tools/device_variables.sh --write`. |
| `original Classic beta executable not found` | `--source` is not a WoW Forever (Classic beta) install. | Point `--source` at the folder containing `_classic_beta_/World of Warcraft Beta.app`. |
| `install_prerequisites` says full Xcode is missing | Only Command Line Tools are selected. | Install Xcode from the App Store, open it once, then `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. |
| `git-subtree is not available` | `git` is Apple's, without subtree. | `brew install git` and put Homebrew's bin first in `PATH`. |

## Safety

- `install_prerequisites.sh` never uses `sudo` and never installs Xcode or Homebrew silently.
- `device_variables.sh` changes nothing except the `DEVICE=` line in the ignored `local.env`.
- `push_game.sh` copies from the Mac to the iPad only; it never deletes device files and never
  writes to the Mac game folder.
- Never commit `local.env`, device identifiers, pairing records, containers or captures.
