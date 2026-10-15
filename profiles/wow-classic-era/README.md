# World of Warcraft Classic (Classic Era)

Tested with the macOS arm64 Classic Era client 1.15.x on an iPad Pro (M5); on
an iPhone 15 Plus (experimental) it logs in and enters the world. See
[COMPATIBILITY.md](../../COMPATIBILITY.md) for what works.

You need your own installation made by the Battle.net app on a Mac, and your own
account. Nothing from the game is included here.

In `local.env`:

```
GUEST_EXE="/Applications/World of Warcraft/_classic_era_/World of Warcraft Classic.app/Contents/MacOS/World of Warcraft Classic"
```

Build, install and set up your execution mode as described in
[docs/BUILDING.md](../../docs/BUILDING.md), then copy your installation:

```bash
python3 profiles/wow-classic-era/install.py
```

The script copies the client and the `Data` folder unchanged (tens of
gigabytes, so use a cable) and verifies the executable's hash before and after.
It copies only your region and language settings, not account settings, saved
credentials or add-ons. Pass `--source` if the game is installed elsewhere, and
`--skip-data` to refresh the client without copying `Data` again.

**Start the game once on the Mac first.** The client needs the region and
languages it saves the first time Battle.net starts it (`portal`, `textLocale`
and `audioLocale` in `_classic_era_/WTF/Config.wtf`). A copy that never started on the
Mac has none, and on the device the game then asks for a region in a window the
AppKit adapter cannot show yet, so it quits within a second. Before you copy:
in Battle.net choose the game and your region, click Play, wait for the
character list, and quit the game. The script stops with these steps when the
settings are missing (unless the device already has them). It sets only these
three keys in the device's own `Config.wtf`, so graphics settings made on the
device stay. To change region or language later, start the game once on the
Mac again and run the script with `--skip-data` (in Tolkara Management:
Library, then **Copy Again**). Tolkara Management checks this on its Game step.

Open Tolkara, choose an execution mode if it asks, tap World of Warcraft Classic
in the library (it appears once the files are copied), and log in inside the
game as usual.

**Execution mode.** The execution modes are described in the
[README](../../README.md#three-ways-to-run-code); choose one. This client has been
played with Developer service, and with Local signing it logs in and plays
(2026-09-27) with no debugger, helper or tunnel. This client unpacks its
own code at launch, so its page container must be built from a capture of its
final code pages, which Tolkara cannot produce yet.

Start with modest graphics settings; quality 8 at 50% render scale held 120 FPS
on the M5. Voice chat does not work.

**Account risk.** Tolkara is not supported by Blizzard. Blizzard has
historically tolerated Wine and Proton players, and Tolkara works the same way,
but nothing guarantees that for your account. With Local signing, Tolkara also
keeps a derived copy of the game's unpacked code on your iPad, signed under your
own developer identity. That modifies nothing Blizzard ships, but whether it is
acceptable is still for Blizzard's licence terms to decide. The risk of a
suspension or ban is yours alone. Consider testing with a free Starter account
first.
