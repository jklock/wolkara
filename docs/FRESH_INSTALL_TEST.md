# Fresh-install acceptance test

Record the Wolkara commit, Xcode version, device/OS and game version with each
result. Do not record account names, passwords, pairing records or device IDs.
A synthetic test or existing configured installation is not a clean-device pass.

## Isolate the test

Use a new checkout of the published source. Do not copy `build/`, `local.env`,
Xcode user settings, game files, caches, addons or authorization from an older
checkout/app. Create your own configuration using [Getting started](GETTING_STARTED.md).

For a second installation on the same phone, use **both** a different
`TOLKARA_BUNDLE_ID` and a different `TOLKARA_KEYCHAIN_GROUP`. Set
`TOLKARA_DISPLAY_NAME="Wolkara Test"` to distinguish its icon. This preserves
the existing installation and prevents shared Keychain authorization from hiding
a first-run setup problem. Enroll the new installation separately.

A second full installation needs space for another game copy (roughly 70 GB for
the tested Forever build), plus update headroom. Check iPhone Storage first.
Never clear the existing app's container to simulate a fresh install. Reusing
an empty Documents folder alone does not reset preferences or Keychain state.

## Test sequence

1. **Build/install:** follow only the public guide, including signing and USB
   enrollment. Record any undocumented manual intervention as a failure to fix.
2. **Empty home:** launch the distinct test app. Forever must offer Install,
   with no inherited installation, addons or user preferences.
3. **Download:** choose edition/region/language and Install. Confirm that progress
   is visible and the client comes from the CDN without a Mac game-file copy.
4. **Resume:** after some content has downloaded, close the test app and reopen.
   It must resume and preserve verified downloads. Also test a brief network loss.
5. **Complete:** confirm Ready to play and the expected installed client version;
   record elapsed time and final free storage. No partial install may be playable.
6. **First play:** allow the local tunnel, finish memory preparation, log in and
   enter the world manually. Check keyboard replacement, trackpad scrolling,
   touch controls, a physical controller and graphics settings.
7. **Cold launch:** close/reopen, then reboot and launch with the Mac disconnected.
   Record connected Wi-Fi and cellular-only tests separately.
8. **Next patch:** when a real update becomes available, let it install, confirm
   the new client version, preserved settings/addons and gameplay afterwards.
   A fresh download does not substitute for this test.

Use a second tester with their own signing identity after this local test passes.
That catches assumptions our already-configured Mac/phone cannot expose.

## Report

| Check | Result / evidence |
| --- | --- |
| Commit, Xcode, device/OS, game build | Pending |
| Clean build and independent enrollment | Pending |
| Empty home and full on-device download | Pending |
| Interrupted download / network recovery | Pending |
| Version verified and first world entry | Pending |
| Keyboard, touch, controller | Pending |
| Reopen / reboot, Mac disconnected | Pending |
| Cellular-only startup | Pending; existing unresolved report |
| Subsequent real patch, settings preserved | Pending |
| Another tester's signing/device | Pending |

Only mark a row passed after observing it. These results are separate from the
existing gameplay reports in [COMPATIBILITY.md](../COMPATIBILITY.md).
