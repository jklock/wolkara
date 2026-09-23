# World of Warcraft Forever (Classic beta)

The macOS arm64 Classic beta client (1.60.1) from `_classic_beta_`. See
[COMPATIBILITY.md](../../COMPATIBILITY.md) for what works.

You need your own installation made by the Battle.net app on a Mac, and your own
account. Nothing from the game is included here.

In `local.env`:

```
GUEST_EXE="/Applications/World of Warcraft/_classic_beta_/World of Warcraft Beta.app/Contents/MacOS/World of Warcraft"
```

Build, install and set up your execution mode as described in
[docs/BUILDING.md](../../docs/BUILDING.md), then copy your installation:

```bash
python3 profiles/wow-forever/install.py
```

The script copies the client and the `Data` folder unchanged (tens of
gigabytes, so use a cable) and verifies the executable's hash before and after.
It copies only your region and language settings, not account settings, saved
credentials or add-ons. Pass `--source` if the game is installed elsewhere, and
`--skip-data` to refresh the client without copying `Data` again.

Open Tolkara, choose an execution mode if it asks, tap World of Warcraft Forever
in the library (it appears once the files are copied), and log in inside the
game as usual.

**Execution mode.** Both modes are described in the
[README](../../README.md#two-ways-to-run-code); choose one. This client has not
yet been run on a device with either mode. Like the Era client, it is expected
to unpack its own code at launch, so its Local signing page container would
have to be built from a capture of its final code pages (see
`tools/capture_final_text.sh`).

Start with modest graphics settings.

**Account risk.** Tolkara is not supported by Blizzard. Blizzard has
historically tolerated Wine and Proton players, and Tolkara works the same way,
but nothing guarantees that for your account. With Local signing, Tolkara also
keeps a derived copy of the game's unpacked code on your iPad, signed under your
own developer identity. That modifies nothing Blizzard ships, but whether it is
acceptable is still for Blizzard's licence terms to decide. The risk of a
suspension or ban is yours alone. Consider testing with a free Starter account
first.
