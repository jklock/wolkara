# World of Warcraft Classic (Classic Era)

Tested with the macOS arm64 Classic Era client 1.15.x on an iPad Pro (M5). See
[COMPATIBILITY.md](../../COMPATIBILITY.md) for what works.

You need your own installation made by the Battle.net app on a Mac, and your own
account. Nothing from the game is included here.

In `local.env`:

```
GUEST_EXE=/Applications/World of Warcraft/_classic_era_/World of Warcraft Classic.app/Contents/MacOS/World of Warcraft Classic
TOLKARA_PROFILE=profiles/wow-classic-era/profile.json
```

Build, install and enrol as described in
[docs/BUILDING.md](../../docs/BUILDING.md), then copy your installation:

```bash
python3 profiles/wow-classic-era/install.py
```

The script copies the client and the `Data` folder unchanged (tens of
gigabytes, so use a cable) and verifies the executable's hash before and after.
It copies only your region and language settings, not account settings, saved
credentials or add-ons. Pass `--source` if the game is installed elsewhere, and
`--skip-data` to refresh the client without copying `Data` again.

Open Tolkara, press Play, and log in inside the game as usual.

Start with modest graphics settings; quality 8 at 50% render scale held 120 FPS
on the M5. Voice chat does not work.

**Account risk.** Tolkara is not supported by Blizzard. Blizzard has
historically tolerated Wine and Proton players, and Tolkara works the same way,
but nothing guarantees that for your account. The risk of a suspension or ban is
yours alone. Consider testing with a free Starter account first.
