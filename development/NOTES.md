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

## Never install while the game is running (2026-10-15)

The hardest lesson of this project so far, learned by breaking a working install.

An install (`wolkara/tools/install.sh`) was run at 11:30 while the game was live on the iPad.
Replacing the app underneath a running client left its CASC index update slot occupied. The
next launch then aborted with

    BC_ASSERT(targetUpdateSlot.hash == 0)

and that aborted commit left an index generation the client would not accept, so every launch
afterwards failed with

    BC_ASSERT(!m_exists)

- the client's own logs show the run: `---- Startup ----` at 11:32:25, `---- Shutdown ----` at
11:33:08, and an `Errors/` file at 11:33:09 naming `targetUpdateSlot.hash == 0`;
- the newest index generations in the store carry that same 11:33 timestamp;
- and then ten more installs were run, each replacing the app and re-staging the installation
over the half-committed store, which kept the damage in place.

Recovery was the game's own rebuild-and-verify, not anything in this repository.

`wolkara/tools/install.sh` now has a guard as its first step: it refuses to install unless the
game is gone, and `--replace-running` stops it cleanly (SIGTERM, then waits for the process to
exit so the client can close its store) before anything is replaced. The detection uses
`grep -E`, not `sed` - BSD `sed` has no `\|` alternation and a pattern that silently matches
nothing would report "nothing running" for a live game, which is the one case that matters.

Rules that follow from it:

1. Never run an install while a game session is live - not to save time, not to test quickly.
2. Judge a launch by whether a NEW file appears in
   `Documents/World of Warcraft/_classic_beta_/Errors/`. A growing guest log is not success; on
   this day two launches were reported as working that had in fact asserted and exited.
3. When the launcher says "rebuild and verify", that is the repair for exactly this fault.
## 2026-10-15, later: the dictation crash, and what the enrolment step leaves behind

Dictation finished and the app died instantly. The guest log named it exactly:

    [ak] dictation result: 1 phrases, 14 characters
    [native] Objective-C exception NSInvalidArgumentException:
             -[AKKeyboardTextView insertDictationResult:]: unrecognized selector sent to instance

`insertDictationResult:` belongs to `UITextInput`, and `UITextView` does not implement it. Our
`AKKeyboardTextView` took the result and forwarded the same selector to `super`, which is a send to a
method that does not exist: fatal every time, the instant a dictation lands. Upstream carries no
dictation code at all - this file replaces the platform's `TouchControls.m` - so the defect was ours
alone. The two placeholder callbacks forwarded to `super` in the same way and had never yet been
called, so they were the next crash waiting; they are now guarded. All three insert the text
themselves instead.

Rule that follows: a `[super ...]` send is safe only for a method the superclass is known to
implement. `UITextView` implements the core text-input selectors and none of the dictation family.

Install step 3 runs the platform's `tools/enroll.sh`, which launches the app into its two import modes
and leaves it there showing the result. On a re-install with a valid pin that screen reads "Enrollment
import rejected; no existing trust pin was replaced." - the success path, but it reads like a failure,
and the app is left running, so the next launch is refused as "already running". Stop that process and
launch the game: the enrolment is fine.

## 2026-10-16: the launcher page, the config file, and a toolchain that looks before it steps

The main page is now four labelled groups - Game edition, Add-ons, Voice manager - with the layer's
mark where the wordmark used to be, and **Open Add-on Directory** opens Files at the same
`Interface/AddOns` folder the Addon Manager installs into, via `UIDocumentPickerViewController` with
`directoryURL` (there is no supported `shareddocuments://` route, and we are not using one).
`LSSupportsOpeningDocumentsInPlace` was added beside the `UIFileSharingEnabled` the app already had,
which is what makes `Documents` a Files location. The user's choices are mirrored to
`Documents/wolkara-config.json` (`wolkara/Shell/WolkaraConfig.*`), so an update does not mean
re-entering them; the CurseForge key stays in the keychain and is deliberately not in that file.

### Three defects, all found by looking rather than by reasoning

1. **The overlay was not regenerable.** `wolkara/tools/overlay_map.sh` had sections for Shell, WoW,
   Touch and Bridge only. Running it produced a map *missing* Controller, Voice and Input - 64 entries
   instead of 78 - so a regeneration would have quietly stopped `prepare.sh` copying three whole
   modules. The committed map had been hand-extended to cover them. The generator now has all
   sections, and `check_layers.sh` compares the committed map against what the generator produces, so
   a hand-edited map cannot pass again. That check also used to truncate its layer listing with
   `head -50`, hiding any orphan past the fiftieth file.
2. **A constraint across view hierarchies aborts the app at launch.** `-markView` activated
   `imageView.heightAnchor <= self.view.heightAnchor` while the image view was still unattached:
   UIKit raises *no common ancestor*, `NSLayoutConstraint` throws, and the process aborts. Found in a
   **system crash report**, not in the client's own `Errors/` folder - the app died before it wrote
   anything of its own, which is why `Documents/Errors/` looked clean and a `pilot.sh` launch read as
   successful. The cap is now switched on in `-viewDidLayoutSubviews`, when both ends have an
   ancestor. Rule: a constraint that spans a subview and the controller's view cannot be activated
   from the code that *creates* the subview.
3. **`cycle` could never reach its own launch.** `install.sh` ends by enrolling, and enrolling starts
   the app into its import mode; `launch` then refused because something was already running. The
   pilot now stops what the install left behind, gracefully, before launching.

### The toolchain, and the facts it is built on

- `wolkara/tools/pilot.sh`: `state`, `stop`, `install`, `launch`, `game`, `wait`, `view`, `crash`,
  `cycle`. It never passes `--terminate-existing`; it asks with SIGTERM, waits, and refuses to
  escalate to SIGKILL unless asked in so many words; it judges a launch by a **new** error file *or* a
  **new crash report** compared against a recorded baseline; and it does not call a stale guest-log
  line success - the log outlives app restarts, so yesterday's `PASS` would otherwise read as today's.
- `wolkara/tools/install.sh --build-only`: builds through the platform's own script with
  `xcrun devicectl` made a no-op, so a compile error costs nothing. `--replace-running` no longer
  escalates to SIGKILL by itself; that is `--force-kill`.
- `devicectl` facts, each measured the hard way: `info files` has `--json-output` and its table wraps
  dates mid-value, so never parse the table; `copy from` takes `--username` only for `info files`, not
  for `copy`; a directory given to `--source` copies *nothing at all* and reports success, which reads
  exactly like "no error file"; and crash reports live in the `systemCrashLogs` domain, not in the
  app's container.

## 2026-10-16, later: one palette, popups, one check per launch, and a log that survives

Four things were wrong from the user's seat: the voice screens did not look like the add-on screen
they sit beside, they were pages you navigated *away* to, closing a page made the launcher re-read
every manifest, and there was no way to find out why anything had broken.

### The log, first, because it found the rest

`wolkara/Shell/WolkaraLog.{h,m}` appends to `Documents/wolkara.log` (capped at a megabyte, one
rotation) from the first line of `main`, mirrors every line to `stderr` so a console run reads as it
always did, and writes uncaught exceptions - name, reason, user info and 40 stack frames - plus a
marker line for SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP. The signal handlers write a literal with
`write(2)` and re-raise, so the system crash report is still produced; they add a line rather than
replacing anything.

Why it was needed: the host's lines went to `stderr`, which exists only when a console is attached,
and the platform only redirects `stderr` into `native-guest.log` once a guest starts. Everything the
launcher said while opening, and everything it said while dying, was gone before anyone looked. An
hour went into finding an Auto Layout exception that the log now hands over in one line.

`wolkara/tools/pilot.sh log [lines] [pattern]` fetches and prints it, and `view` shows the tail. The
input layer (`ControllerInspector`, `InputRouter`, `ControllerWindow`) and dictation now write to both
channels, which is what made the next finding visible.

### The Share button was being pressed by nothing

`ControllerInspector` treated `UIScreenCapturedDidChangeNotification` as "Share held", on the reasoning
that iPadOS spends the pad's Share hold on screen recording. That is only true when the pad started
the recording, and the notification cannot say who did. With the iPad being captured from a Mac - the
normal state while working on it - `isCaptured` is already 1, the change fires about a tenth of a
second after every launch, and the launcher **started dictating by itself**: six times in one log,
nobody touching anything. Measured, fixed, and confirmed by counting: zero starts after the fix.

The capture change is now recorded in the inspector's history and the log and reported to nobody. The
screenshot notification stays a Share press: it is a discrete gesture the user made, it is how the pad's
Share button is reachable at all, and the tooling's own screenshots do not fire it (checked).

Rule that follows: a fact about the system is not a button press. `recordLine:` exists for the first,
`reportLine:element:value:pressed:` for the second.

### One palette, and pages that come up over the launcher

`wolkara/Shell/WolkaraTheme.{h,m}` is the one place the ink, the gold, the panel and the card are
written down, with the Add-on Manager's values because that is the screen the rest is expected to
match. The voice screens were built out of `UIColor.systemBackgroundColor` and `labelColor`; they are
now cards on the same navy with the same gold, the same uppercase headings and the same gold Done
button.

The add-on manager, the voice settings and the voice test are now **presented** - each inside its own
navigation controller at `UIModalPresentationPageSheet` - instead of pushed. `WKDismissPage` closes one
either way, and it sends the dismissal to the *presented* navigation controller rather than reading the
presenter back: measured in the fixture, `presentingViewController` came back nil for the voice page,
the call fell through to a pop that the root cannot do, and the sheet simply stayed open.

The add-on table's background was `clearColor`, which is fine when a pushed page covers the window and
wrong in a sheet, where it exposes the presentation container: as a popup it had a white body under a
navy navigation bar. It draws `WKInk()` itself now.

### The check runs once per launch

`-viewDidAppear:` called `-refresh` on *every* appearance, so closing a popup sent the launcher back to
the network for a full manifest check and the home page sat busy again - every time, for a page the
user had only looked at. `-foreground:` did the same on every return to the app. Both are now gated by
`_checkedThisLaunch`; the refresh button, Try again and a changed edition still ask on purpose, and
those are the only way to get a second check.

Trade-off, stated plainly: an app left open for hours will no longer notice a new update until it is
relaunched. If that matters, a time-based recheck is the change to make - not a per-appearance one.

### The launcher UI fixture had been failing to link

`test_wow_launcher_ui.sh` compiles the prepared sources directly, and it listed neither the voice pages
the launcher opens nor, later, the theme and the log. It had been failing at the link since the voice
pages were added. It now compiles them, and it captures `addons-popup.png`, `voice-settings.png` and
`voice-test.png` so the pages can be looked at rather than assumed. Three things it taught us:

- A sheet cannot be measured or dismissed while it is still arriving. The fixture used to hit-test and
  close ~0.4 s after presenting, and the result looked exactly like a page that cannot be closed.
- The search field *is* hit-testable in the popup (`UISearchBarTextField`), so the presentation change
  did not break the thing that check was written for.
- It bundled `LICENSE`/`NOTICE.md` from `build/platform`, i.e. upstream's, while asserting our
  attribution. It bundles the repository's now.

### Open: the app does not ship its notices

Nothing in `platform/project.yml` refers to `LICENSE` or `NOTICE.md`, and they sit outside every source
path the app target lists, so the packaged app's About page shows the introduction and no licenses. The
fixture checks the About page's *composition* - it reads whatever the bundle holds - so a green fixture
is not evidence that the app carries them. Fixing it means getting the two files into the app's
resources without hand-editing `platform/`: a patch or an overlay entry, which is a decision rather
than a chore.

