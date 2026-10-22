# Game data migration: local.wolkara.johnklock → local.wolkaraforever.johnklock

> **Historical record.** A one-off on-device migration record; it is not current
> guidance. See [docs/README.md](../../docs/README.md) for the live documents.

- Date: 2026-10-22
- Device: Dadpad, iPad Pro 12.9-inch (5th generation), iPadOS 27
- Source container: `local.wolkara.johnklock` (the pre-rename bundle that held the game)
- Destination container: `local.wolkaraforever.johnklock`
- Game tree: `Documents/World of Warcraft`, 2,894 regular files, 330 directories, 71.76 GB

## Method — on the iPad only

The two apps have separate sandboxes, so the transfer went through a shared app
group container on the same data volume. That makes each step a rename, not a
copy: the tree never leaves the iPad, no second 72 GB is needed, and no Mac
copy exists. A temporary app-group entitlement and two one-off self-test modes
were used for the move and were removed again afterwards.

1. Both apps were stopped; no update was writing.
2. `--selftest=migrate-out` in the old app moved `Documents/World of Warcraft`,
   `apps.json` and the launcher configuration into the group. PASS 10/10,
   "2894 files moved on-device into the app group".
3. The same build was installed over the new bundle (its own empty container
   kept), and `--selftest=migrate-in` moved the tree into it. PASS 11/11,
   "2894 files moved on-device into this app". The handoff folder was removed
   and its absence checked.
4. The old app was uninstalled, deleting its now-empty container.
5. The temporary entitlement, patch and self-test modes were removed, and the
   clean build was installed over the new app. The data stayed.

## Results

| Check | Result |
| --- | --- |
| migrate-out (old app) | PASS 10/10, 2,894 files |
| migrate-in (new app) | PASS 11/11, 2,894 files |
| destination file count and bytes | 2,894 files, 71.76 GB (before the self-test's backup) |
| destination home page | `Ready to play`, client 1.60.1 (70450) |
| Forever UI self-test on the destination | PASS 18/18 |
| old app | uninstalled; only `local.wolkaraforever.johnklock` remains |
| CurseForge key in the destination | stored (60 chars, core shape); authenticated search PASS, 50 projects |
| Mac copies | none; the aborted 50 GB partial and `build/migrate` were deleted |

The destination now has 2,895 files in the tree because the Forever UI self-test
made its own backup ZIP in `WTF/Backups`; that is a product file, not a
migration leftover.

The clean build carries 18 patches (no app-group entitlement) and the temporary
migration modes are not part of it.

## Enrollment after the move

The first launch from the new bundle failed with *"Local launch could not
prepare … service returned … execution permission"*. The cause was not the game
data: uninstalling the old app deleted its container (including the
`TKEnrolledDeviceIdentifier` default), and the new app had been built for a
different Keychain access group. The pairing record itself lives in the Keychain
(`PairingKeychain`, service `local.tolkara.pairing.enrollment.v1`) and survives
app deletion.

Fix, without re-enrolling:

- The new app is built and installed with
  `TOLKARA_KEYCHAIN_GROUP=local.wolkara.johnklock.authorization`, the group the
  surviving item belongs to. `local.env` now records that choice, with a
  comment, because it cannot be recreated without the USB pairing session.
- The `TKEnrolledDeviceIdentifier` default was restored once from the device
  identifier; the one-off self-test used for that was removed from the build.

Verified after the final clean install:

- Play reaches memory preparation and the client's login screen
  (1.60.1 (70450)).
- `--selftest=curseforge` PASS 3/3: the stored key (60 characters, core shape)
  is accepted by the authenticated search (50 projects). The key had to be
  stored again because the group changed.

An earlier reading blamed the iPad's Wi-Fi transport for the enrollment
handshake `EOFError`. That was wrong: the bridge only sees USB devices, but the
enrollment itself was not needed — the old record was still present.
