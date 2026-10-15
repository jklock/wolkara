# Operational notes

Hard-won knowledge about running and debugging this stack that is easy to lose. Keep
entries short and concrete; move anything that becomes documentation proper into
`docs/`.

## WoW launch failures on device

Symptom: the game shows its own "World of Warcraft" bubble and exits, and the launcher
session ends - it looks like a crash.

The cause seen twice was a **truncated newest index generation** in
`<install>/Data/data/`, for example `0f0000004e.idx` at 40 bytes. `Tact.log` says
"Corruption detected" and "Truncated updated section in KMT file", then "Failed to bind
mapping table N" (N is the bucket), then "failed to bind Container index ... 9
(NeedsRepair)". The client writes that 40-byte skeleton itself during an index commit
(its own report shows `BC_ASSERT(targetUpdateSlot.hash == 0)`) and then refuses to fall
back to older generations.

Fixes that work: make the newest generation per bucket valid again, either by
overwriting the truncated file with valid content or by removing it so the previous
generation wins. Restoring the whole generation set from a known-good Mac copy also
works.

Not the cause: `index.lock.0` and `shmem` were both present during successful launches
(CASC's `checkpoint:` already deletes `shmem`).

Implemented in `6e7fcb5`: `TKWoWCASCRepairIndexGenerations` in `launcher/WoW/CASC.{h,m}`,
called from `runNativeGame:` in `launcher/App/main.m` before the guest runs. It rewrites
a bucket's newest generation from the newest generation that validates *and has rows* (a
bare 40-byte header passes the store's validity check but cannot be bound), and removes
`<bucket>tempfile.idx`. The validator `LocalIndexEntries` is shared by the store's open
path and the repair. Note that `CASC.m`'s checkpoint prunes old `.idx` generations down
to the latest two, which removes the rollback material the repair depends on - keep more.

Startup timing: the memory arena takes about 80 s, then all 13,302 initializers, then
main. The guest log is `Documents/native-guest.log`; the game's own logs stay empty
until the client flushes.

## Keeping a running guest alive in the background

iOS suspends an app that switches away; if it then burns CPU it is killed with a crash
report named `cpu_resource` (`bug_type 202`) after roughly 2.5 minutes. To the user this
looks like "I come back and I'm on Wolkara's start screen".

The fix has two parts and both are needed:

1. `UIBackgroundModes: [audio]` in `launcher/Info.plist` keeps the process running.
   `translation/CoreAudio/Hardware.m` already sets the playback category and activates
   the session, and nothing deactivates it.
2. `translation/Metal/BackgroundPacing.m` caps the guest to about 5 frames per second
   while `UIApplication.applicationState != Active`, by sleeping in
   `CAMetalLayer.nextDrawable` (the guest paces on the drawable). Without this the CPU
   watchdog still kills it.

Verified on Dadpad: switch away with `devicectl device process launch
com.apple.Preferences`, stay away for more than 6 minutes, no 202 report, then relaunch
the app (`devicectl ... launch <bundleid>`, no `--terminate-existing`) - the same
session is there, `arena result` count is still 1, and the game is where it was.

The guest is also told about occlusion now (`NSWindowDidChangeOcclusionStateNotification`
on activate and resign, in `translation/AppKit/AppKit.m`), as a Mac window being covered
would be.

## Voice: Apple dictation into a guest text field

The draft panel is a real `UITextView`: the iOS keyboard's microphone dictates into it,
Replace writes the field, Return sends. Trigger it from inside the game with
Control+Option+D (swallowed before the guest, in `AppKit.m`'s `postKeys:`) or start with
`--touch-keyboard-open`.

A hardware keyboard (the dock) makes iPadOS hide the keyboard's keys:
`UIKeyboardFrameEndUserInfoKey` height is 0 and only our accessory row shows, so the
microphone key is unreachable. We detect and report this (`hardware keyboard attached`,
`software keyboard keys are not on screen`) and hint in the composer label; Command+K
brings the keys, and the microphone, back.

Dictation takes focus: a resign with a pending dictation placeholder keeps the draft and
keeps accepting input, and the keyboard is taken back when the session ends.

## Tooling and device gotchas

- `git apply` inside a directory that belongs to a larger repository resolves the
  patch's paths against the **repository root**, so a patch written relative to a
  vendored tree is skipped silently and still exits 0. Use
  `git apply -p1 --directory=<tree>` from the repository root, and verify with
  `git apply -p1 --check --reverse --directory=<tree>`. A `mktemp -d` scratch directory is
  outside the repository, so `git -C` works there.
- `devicectl device process launch <bundleID> <args...>`: the bundle ID has to come
  first; anything before it is swallowed.
- The device file service (`dtfileserviced`) is flaky: listings and copies intermittently
  fail with CoreDevice error 3 or 7000. Retry.
- `xcrun devicectl` needs the device UDID; `local.env` carries it as `DEVICE`.
- The simulator set on this Mac is iOS 27.0 only, and there is no "iPhone 17 Pro" - see
  `AUDIT.md` for which scripts default to it.
