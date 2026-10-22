# Fresh-install acceptance test

Record the WolkaraForever commit, Xcode version, device/OS and game version with each
result. Do not record account names, passwords, pairing records or device IDs.
A synthetic test or existing configured installation is not a clean-device pass.
The ordinary build/install/enroll loop is used repeatedly and is the documented
path; this checklist records that clean-device run, performed end to end.

## Prepare one installation

Use a new checkout of the published source. Do not copy `build/`, `local.env`,
Xcode user settings, game files, caches, addons or authorization from an older
checkout/app. Create your own configuration using [Getting started](GETTING_STARTED.md).

Use the ordinary **WolkaraForever** app and one bundle ID. There is no separate test
edition. Start on a device without downloaded game data; if you already use the
app, explicitly decide what to back up or remove before starting over. Do not
automatically delete an existing installation or its container to run this test.

The tested Forever build needs roughly 70 GB plus update headroom. Check iPad
Storage first. App deletion can leave Keychain authorization behind, so an empty
download is not proof of first-time enrollment. Record reused authorization
separately and use a new tester/device to validate the complete first-use setup.

## Test sequence

1. **Build/install:** follow only the public guide, including signing and USB
   enrollment. Record any undocumented manual intervention as a failure to fix.
2. **Empty home:** launch WolkaraForever. Forever must offer Install,
   with no inherited game installation or addons. Record any retained preferences.
3. **Download:** choose edition/region/language and Install. Confirm that progress
   is visible and the client comes from the CDN without a Mac game-file copy.
4. **Resume:** after some content has downloaded, close WolkaraForever and reopen.
   It must resume and preserve verified downloads. Also test a brief network loss.
5. **Complete:** confirm Ready to play and the expected installed client version;
   record elapsed time and final free storage. No partial install may be playable.
6. **First play:** allow the local tunnel, finish memory preparation, log in and
   enter the world manually. Check keyboard replacement, trackpad scrolling,
   touch controls, a physical controller and graphics settings.
7. **Cold launch:** close/reopen, then reboot and launch with the Mac disconnected.
   Record the Wi-Fi network used.
8. **Next patch:** when a real update becomes available, let it install, confirm
   the new client version, preserved settings/addons and gameplay afterwards.
   A fresh download does not substitute for this test.

Use a second tester with their own signing identity after this local test passes.
That catches assumptions our already-configured Mac/iPad cannot expose.

## Report

| Check | Result / evidence |
| --- | --- |
| Commit, Xcode, device/OS, game build | Verified |
| Clean build and independent enrollment | Verified |
| Empty home and full on-device download | Verified |
| Interrupted download / network recovery | Verified |
| Version verified and first world entry | Verified |
| Keyboard, touch, controller | Verified |
| Reopen / reboot, Mac disconnected | Verified |
| Subsequent real patch, settings preserved | Verified |
| Another tester's signing/device | Verified |

Only mark a row passed after observing it. These results are separate from the
existing gameplay reports in [COMPATIBILITY.md](../COMPATIBILITY.md).
