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

### The app shipped the wrong notices, and nothing reached them

This was written down as "the app ships no `LICENSE`/`NOTICE.md`". That was wrong, and the
way it was wrong is the point. The app shipped two documents: upstream's. Patch `0010` asked
the target for resources called `LICENSE` and `NOTICE.md`, and the prepared tree already has
files by those names - upstream Tolkara's - so those were the two that landed in the bundle.
The About page listed them under this app's introduction, which credits the wrong people,
and this repository's own `NOTICE.md` - the one carrying the TACTSharp and CascLib MIT
terms, both of which say they must accompany the software, and CascLib and TACTSharp are
adapted into `launcher/WoW/`, which is in the app - never reached the bundle at all. A
missing licence file is a gap; a file that says the wrong thing under your own name is
worse, and the note described the harmless version of what was happening.

So it is four documents now, not two. The layer overlays this repository's `LICENSE` and
`NOTICE.md` into the prepared tree as `Wolkara-LICENSE` and `Wolkara-NOTICE.md`, because
upstream's have to stay put and both sets have to travel: the app is a fork and it ships
upstream's code, so it owes upstream's notice and its own. By script, as ever - two entries
in `overlay_map.sh`, so `prepare.sh` puts them there and the gate checks the map still
matches the layer. One list in `WolkaraLog.h` names all four, the About page reads that list
and says whose each one is in front of it, and a document that is missing says so on the page
instead of being skipped in silence, which is how this stayed invisible for a day.

The check that would have caught it is not a fixture. A fixture supplies the files, so it can
only show that the page composes them; it passed the whole time. `device_matrix.sh` now reads
the installed app's own log line - `notices: 4 of 4 in the bundle (...)`, written at launch
from `NSBundle.mainBundle` - back off the iPad and fails if a build is missing one, or if
this app's documents are not the ones that are there. The build that was installed is the
subject, not a stand-in for it.

Two smaller things came out of the same reading. The fixture had been copying the files in,
with a comment explaining that the app's target did not carry them - true of the app as it
was, and the reason to fix the app rather than the fixture; the fixture now mirrors the
app's real layout, which is what makes its assertions mean anything. And the audit's list of
required coverage names a config *write* failure, which had never been exercised: the suite
now puts a directory where the temporary file goes, so the atomic write fails for real, and
checks that the previous file survives, that the log names it, and that the next write
lands once the way is clear. That is one of the paths where a bad answer loses the user's
settings, and it was one of the few left with no test.

## 2026-10-16, last: working through the stability audit

`STABILITY_AUDIT_2026-10-16.md` was reviewed in full and every finding was either fixed or answered.
The audit is right about the shape of the problem, and most of its P1s were in the controller/voice
path that was built the day before it.

### The rule that came out of it

**Nothing acts on an input the user did not choose, and nothing about a controller changes before
they ask.** That is now structural rather than a set of checks:

- `AKVoiceSettings.enabled` is NO until the user turns it on, and there is no default trigger and no
  fallback. `-triggerForDevice:` returns nil unless the feature is on *and* that device has a mapping,
  so the router has nothing to match and no code path can fire by accident.
- The inspector's inventory is read-only. It used to clear the Share gesture reservation at startup
  for every pad that declared one; that is a change to how the controller behaves before the user has
  asked for anything. The reservation is released now only for the exact mapped element, and given
  back when the mapping is cleared, voice is switched off, or the pad disconnects.
- A screen-capture change is never an input. A screenshot is offered as `system.screenshot` and does
  nothing unless mapped.

### Element names are keys, so they are ids now

`wolkara/Input/InputElement.h` gives every input a canonical id - `controller.button.share`,
`keyboard.key.36`, `dpad.left.thumbstick.up.left`, `system.screenshot` - and display text is derived
from it. Three separate faults came from using display text as the key: the system's screenshot signal
was `Share` while the pad's button is `Button Share`, so a mapping made by pressing one could never
match the other; d-pad and touchpad events carried their coordinates in the name, so they were a
different string every time and nothing learned from a press could match the next; and a name in a
user's defaults cannot be renamed later without discarding their mapping. A name an older build wrote
is migrated once, on read.

Mappings are keyed by `AKControllerIdentity` (vendor *and* category) rather than the vendor name, so
two pads from one vendor stop sharing one mapping, and a mapping written under the old key is adopted
the first time that controller is seen.

### Dictation delivers once, and gives the audio back

The old `stopAndSend` copied the transcript, ended the audio and tore everything down immediately, so
the recogniser's last words could arrive after the text - and after Return - had already gone to the
game. There is now a state machine (`idle`/`authorizing`/`listening`/`finalizing`), the audio ends
first, the recogniser is asked for its final result, and delivery happens exactly once, when that
result arrives or when the wait times out. The audio session's category, mode, options and active
state are snapshotted and put back on every path, including denial, cancellation and error. On-device
recognition is required rather than hoped for: a device that cannot do it is refused with a message.

The recogniser and the audio session are behind two protocols, because they are the two things a test
cannot run and the delivery rules are exactly what needs testing.

The game's text target is registered by the adapter that creates it (a notification from
`TouchControls`, wired in `main.m`) instead of dictation searching every window in every scene for the
private selector.

### The suite, and what it found

`wolkara/tools/test_voice.sh` runs `wolkara/Voice/tests/test_voice_app.m` as a small app in the
simulator: 113 checks over canonical ids, migration, mapping storage, the learning lifecycle,
screenshot isolation, the dictation state machine and a malformed-config corpus. It found three real
defects while being written:

- A config `int` of `1` was refused as "not a boolean" by my own validator, which would have silently
  dropped a valid mode from the user's file.
- A controller **connecting** cancelled an armed mapping, which makes mapping impossible on hardware
  that connects a moment after launch - the simulator has such a pad, which is how it was seen.
- A mapping is stored against the device the signal is attributed to, which for a system signal is the
  connected pad rather than `system`; the first version of the test assumed otherwise and the log said
  so plainly.

`wolkara/tools/tests/test_pilot.sh` (11 checks) covers the pilot's fail-closed rule and its session
directory; `wolkara/tools/tests/test_after_install.sh` (11 checks) covers the execution-mode branching
with a stub `enroll.sh` and a stub `xcrun`.

### Tooling that had to change with it

- `install.sh` no longer enrolls unconditionally. `wolkara/tools/after_install.sh` decides by mode:
  enroll for Developer service, check the page containers for Local signing, and do nothing at all for
  External JIT or an unset mode. Enrolling is developer-service work and was being done to devices
  using neither of the other two modes.
- `pilot.sh` keeps its work files in one `mktemp -d` directory per run. They were fixed names under
  `/tmp`, so a second pilot compared against the first one's baseline and could call a crash "no new
  crash report". It also fails closed: if `devicectl` cannot be asked, `state` says the device could
  not be inspected, `stop`/`install` refuse, and `wait` keeps waiting rather than concluding anything.
- `wolkara/tools/validate.sh` produces the evidence the audit asked for: one file per commit under
  `development/validation/`, naming the commit, whether the tree was clean, every command, its exit
  status and what it printed. It refuses to run on a dirty worktree unless told to, and `prepare.sh`
  now prints the dirty files when it builds uncommitted layer code over a committed platform half.

### Answered rather than fixed

- **Trailing whitespace in our patches.** There is none. The lines that look like it are the unified
  diff format's blank context lines, which are a single space by definition; "cleaning" them would
  corrupt the patches. Checked with `grep -nE '^\+.*[^ ] +$'` over every patch: nothing.
- **"Any button" is not collision-free.** It is not, and it cannot be without owning the input: the
  router observes, so a button the game also uses still does what the game does with it. The launcher
  now says so where the button is chosen, and `INPUT_TRIGGERS.md` says so in its own section. What is
  no longer claimed is that a long press or a chord is free.

## 2026-10-16, end: the remediation review, and what it found in the remediation

The audit was updated with a review of the remediation itself (`1dec7d6`, `fe03af0`), and it
found five more P1s - all of them in my own work, and all of them real.

**A rejected config file could recurse until the stack ran out.** `rejectFileBecause:` copied
the previous good copy over the primary and called `importFromFile` again. With a malformed
primary beside a backup that was readable JSON but not a config file, that went round and
round: both files sit in the user-editable Documents boundary. The copy is now validated
against the same schema as any other file, applied directly rather than by re-reading, and
attempted at most once per launch. The suite has the corpus case the review asked for.

**A screenshot was still offered as a trigger.** I had made it opt-in, and the review is
right that this is not enough: nothing in the notification says whether a pad or a thumb on
the screen produced it, so mapping it only moves the guess to the user. The signal is now
recorded in the log and reported to nobody; a stored mapping that points at one is refused,
and one written by an earlier build is dropped with a line explaining it.

**A timeout typed a partial transcript.** The deadline delivered whatever had been
recognised so far, which contradicts the product's promise and can send half a sentence to
the game's chat. It now delivers nothing and tells the user.

**The audio session's active state was still changed.** `AVAudioSession` has no public way
to ask whether it was active before we arrived, so exact restoration cannot be claimed. What
is there now is a policy, named as one in the header and in `docs/VOICE.md`: category, mode
and options are put back and the session is left active, because this is a foreground game
host. Interruptions are handled - a call or anything else taking the audio ends the session
instead of leaving the microphone open behind it.

**The validation record combined a failed install with a passing log.** `fe03af0`'s manifest
shows `pilot.sh cycle` failing and then a log step passing, and that log was written by an
older build. A failed install now leaves the dependent log step `NOT RUN`, and the log step
carries its own binding: `pilot.sh` counts the app's launch lines before launching and again
afterwards, and says whether the log holds a launch from this run or an earlier one.

Two P2s as well. Identical controllers share a mapping because GameController exposes no
per-device identity - that was claimed as per-controller persistence and is now documented
as per-model, with a log line when two pads of one model are connected. And the config write
removed the primary before moving the temporary over the gap, so an interruption there left
no config at all; it is an atomic replacement now, with the previous file kept as the copy
the recovery path reads.

Already fixed by the time the review was written: the concurrency boundary, which the review
lists as P2. Every input report is delivered on the main queue - GameController does not
promise a thread - and the router asserts it.

## 2026-10-16, last: running the platform's own suites, and the device matrix

The audit's exit criteria are not satisfied by our own tests passing. It asks for the
*platform's* suites, and for the physical-iPad matrix to pass repeatedly. Running them found
three more real defects in the layer, none of which our own tests could have seen.

**The overlay had quietly lost ten methods of the touch-controls view.** The platform's
simulator suite failed on `-[AKTouchControlsView isSecureTextEntry]: unrecognized selector`.
The overlay replaces that file wholesale, and the replacement had been written from memory:
it kept the drawing and the tracking that were being worked on and dropped whatever the
platform had that had not come up. `isSecureTextEntry` and the text traits
(`autocapitalizationType`, `autocorrectionType`, `spellCheckingType`, `smartQuotesType`,
`smartDashesType`, `smartInsertDeleteType`, `keyboardType`, `returnKeyType`) are back, and so
is `pointInside:withEvent:`, which is the one that hurt the most in use: without it the
overlay swallowed taps in the gaps between its buttons, so the toolbar looked dead in the
places a thumb lands. This is what "the platform's suite" is for. Our fixture never asked,
because it only ever tapped inside the buttons.

**The platform test asserted the platform's default for on-screen controls.** The layer
turns the on-screen controls on for every device, which is a deliberate product decision, and
the platform's own test checks it is off by default. That is a genuine divergence, so it is a
patch (`0014`) that rewrites the expectation and adds the assertion that matters -
`!plainHost.multipleTouchEnabled`, since multi-touch follows the trackpad.

**A duplicate add-on import deleted the installed one.** Found by writing the coverage the
audit asked for rather than by any failure in use: the import tracked every folder it
touched, including ones that already existed, and its cleanup removed them on the way out.
Importing the same add-on twice lost the first copy. It now tracks only the folders it
created, and the suite imports twice on purpose.

**One platform failure is not ours, and proving that took a pristine worktree.**
`tests.test_sign_guest_local` compares our ad-hoc signature to this macOS's `codesign`
byte for byte, and fails - identically, with identical sizes - in a checkout of the platform
at the same commit with no layer applied at all. It is on the known-failures list with that
evidence next to it. The list is a document, which is how its one real entry came to be
commented out: the parser matched nothing and the platform's own failure read as ours. It
strips the comment mark now, and the manifest names the entry rather than counting it.

**The matrix was reading the client's own work as our failure.** `device_matrix.sh` reported
ten failures, then one, then none, with no code change between - which is the worst kind of
result, because it means the outcome depended on the device's mood rather than on the layer.
Two causes, both in the tooling:

- `pilot.sh` refuses to stop or install while the client is writing to its own store, which is
  correct and is the guard from the 2026-10-15 note below. The client was staging a 135 MB
  update of its own, so the guard fired, `stop_app` exited 2, and the matrix - which treated
  any non-zero exit as a failure and `exit 1`ed - aborted a step and reported it as broken
  behaviour. The guard's own message says "try again when it stops", so the matrix now does
  that, up to five minutes, and prints how long it waited. It is a wait, not a retry of
  something that failed.
- Step 3 asserted a fixed `WoWRegion=us` while step 2 left `eu` behind, so a second run saw
  "no choice was changed" and failed the log check. Both now flip to the opposite of whatever
  is on the device, and the push is verified by fetching the file back and comparing it.

The lesson worth keeping: a check whose answer depends on what a previous run left on the
device is not a check, and a guard that exists to protect the user's data must be waited out
rather than overridden. `--force` was available the whole time and would have turned every
one of these into a pass while quietly writing over a half-finished update.

**A button that had stopped doing what it says, and no step that asked.** The touch-controls
fixture asserts that Replace replaces the whole game field and that an empty draft clears it.
It had been failing, at one assertion, for a day - and nothing ran it: not `validate.sh`, not
the emulation suite, not the translation suite. A green validation record meant nothing about
this file, which is the same shape of gap as the notices: the evidence was being read from
somewhere that could not have known.

The assertion had no message, so the first thing was to make it say which of its three
conditions moved. It said:

    TOUCH_UI_INSERT_MISMATCH: guest text=Previous synthetic value insert.enabled=0 replacements=0

Zero guest operations, the field untouched, and the button had gone from enabled to disabled -
so the tap had been handled, and had done nothing to the game. The handler was in our patch
`0009`:

    // Nothing else: no select-all, no delete, no clipboard, no Return. A synthetic
    // Command+A followed by a delete was the only thing the guest received differently on
    // the dictation then Replace that ended with the app quitting, so it is gone.

Select-all-then-delete had been removed as a suspected cause of the app quitting after
"dictation then Replace". The real cause had already been diagnosed with its exception
message: `-[AKKeyboardTextView insertDictationResult:]`, a selector `UITextView` does not
implement, sent to `super` the instant a dictation landed - the note above, same day. Replace
was blamed because it came next. With that fixed, removing select-all bought nothing and cost
the contract: the button stayed enabled for an empty draft, its hint still said "Replaces the
whole selected game field. An empty draft clears it.", `docs/TOUCH_INPUT.md` still specified
the Command+A/Backspace/keys sequence, and `touchReplaceText:` typed at the caret instead. So
Replace inserted text where the user expected the field to be replaced, or cleared - in a game
chat box, which is the worst place to be quietly wrong about whether old text is still there.

Restored, to the sequence the documentation specifies, with the reasoning written down where
the next person will read it. `test_touch_controls_ui.sh --self-test` passes again:
"whole-field replacement, empty clearing, duplicate suppression, draft editing, dictation,
cancellation and fixed toolbar". Both touch fixtures are now steps in `validate.sh`, because
a fixture that nothing runs is a fixture that lies.

**And then the same question found two more.** "Which suites does nothing run?" is worth
asking of every suite once, so: `test_emulation.sh` ends with a loop over
`wolkara/tools/test_*.sh`, and that loop had never executed in any recorded run. The platform
suite exits 1 on its one known failure - deliberately listed as the platform's - and `set -e`
stopped our script on that status, before the loop. The records say so once you look: the
"platform emulation suite" step contains the platform's eighty tests and its known failure,
and not one layer-suite banner. The `VOICE PASS` I had been reading in that step belongs to
the voice step, four rows above it.

Two of the layer's suites were therefore run by nothing at all: `test_wow_launcher.sh` (CASC
verification, repair, checkpoint/resume, malformed records) and `test_local_service_retry.sh`,
which is the only test of a patch we carry. Both pass when run by hand; nobody had asked.

Two bugs behind one line: the platform suite's status was the gate for running ours, and the
loop's glob included the script itself, so the first iteration would have re-prepared the tree
and run the platform's suite again, for ever. The `set -e` bug had been hiding that - the loop
could not run, so the recursion could not happen. Fixing one without the other would have
turned a silent gap into a hang. Now the platform's status is carried rather than obeyed, a
*layer* suite failing still fails the run, the loop skips itself, and every suite the layer
owns has its own row in `validate.sh`, so coverage never again depends on a wrapper's loop
being reached. Fifteen rows, from eleven at the start of this work.

### Still open, and known

- Voice has no test for the *pages* beyond the fixture's screenshots; the rules are covered, the
  layout is not.
- Input arbitration, which is what "collision-free" would require, is not started.

Closed since this list was written: the notices the app carries. They were not missing, they
were the wrong ones - upstream's, under our name - and it is four documents now, checked
against the installed app. See "The app shipped the wrong notices" above.

Closed the other way, and worth reading as an example: the audit's "any button is neither
collision-free nor complete" finding offered two ways out - real input arbitration, or a
product limited to explicitly mapped inputs *with a collision warning*. The warning came
first, and then the ownership, because the first version of this note said ownership was "a
large change" and that was not true. It is about sixty lines.

**Keep the game from seeing it**, on the voice page, does what "collision-free" means for the
inputs where it can be done. With it on, a keyboard key the user has mapped for dictation is
never posted to the guest - press or release, so the game is not left holding a key down -
and the trigger still fires, because the router learns what was pressed from the adapter's own
observation rather than from the guest's event queue. One physical press, seen once, forwarded
nowhere.

Two things had to be right for it to be honest rather than merely present:

- **What cannot be taken is named where the switch is.** A *controller* button cannot be:
  iPadOS reports a pad's buttons as gamepad elements, the guest receives them as key events,
  and there is no API connecting the two - so a pad mapping cannot be matched where a key
  would be swallowed, and choosing a button the game does not use stays the answer for a pad.
  A system signal never could be taken; there is nothing to swallow, and the layer releases
  the system gesture instead.
- **It had to fit the boundary, not go around it.** The adapter is compiled into a signed
  dylib that the app never links against, which is why the toolbar is already asked for by
  notification. The first attempt had `main.m` assign a function pointer that the adapter
  defines, and it failed to link - `_AKTouchKeyIsTakenForVoice` undefined - which is the
  boundary saying so. The shell now *publishes* the set of usages the user has taken and the
  adapter swallows those keys; the notification name is a string on the app's side for the
  same reason the existing one is.

Tested where each half can be: the decision in the voice fixture (184 checks, up from 173),
and the swallowing end to end in the touch fixture, which fakes a `UIKey`/`UIPress` - they
cannot be constructed - drives the adapter's own key path, and watches what the guest's view
receives. The fixture also proves the honest negatives: a key the user has not taken still
arrives, publishing an empty set gives the key straight back, and with nothing published at
all every key goes through, which is what a build that never fills this in does.

Remaining on this list, unchanged: the voice page *layout* is asserted behaviourally rather
than looked at, and the other patterns the trigger model can store are still not offered by
the page.



## 2026-10-17 — finishing the handoff

The user chose the corrected-logo icon, Hold/Toggle only, and the controller collision
warning. The root logo stays tracked. `development/ICON.md` records the committed icon
source and reproducible generator; all device-size previews were visually reviewed.

Real ZIP coverage did not need a person or an external add-on. The fixture builds the
same pinned ZIPFoundation and the production Swift extractor, then drives the real
Objective-C import bridge and store. It caught discarded CRC results: corrupt bytes
were accepted. CRC mismatches now fail and clean up; an existing destination is refused
rather than risking removal of caller data. An outer import cleanup also covers errors
before acquiring the store lock. The suite checks 49 assertions plus the import lifecycle.

CurseForge transport can be faked without faking the client's parser. Nineteen checks
caught unchecked response and file-entry shapes. Live credentials and service availability
are still a distinct verification boundary.

The known signer failure also stopped the platform suite before container, fixup, TLS,
keyboard, drawing, crypto and cloud tests. Patch 0015 retains that failure but runs the
rest. Validation requires the completion marker and exit 1 to classify it as known;
six classifier cases reject incomplete runs, mixed failures and crashes. Layer suites
have their own rows, so validation runs the platform emulation script directly instead
of repeating all layer suites through its wrapper.

Retired double/long/chord mappings fail closed and must be remapped. Hold and Toggle
keep their stored values. Mode selection wins over stale imported patterns, and repeated
pressed samples cannot toggle twice. The final focused voice run passed 244 checks.

The current candidate's full/device results belong in the generated record under
`development/validation/`. Microphone speech, physical controller delivery and live game
chat still require observations on that installed candidate; passing fakes is not proof.

## 2026-10-17 - the second pass: what reading found, and what the device now proves

The handoff was picked up again and the audit's reading-level findings were worked rather
than assumed. Each of these was a real defect, and each has a fixture that would fail if it
came back:

- **The extractor believed the archive.** The limits were checked against the sizes a ZIP
declares in its own header, and the compressed stream is read to its end - so one entry
declaring ten bytes and inflating to seventy megabytes passed every check. The bytes that
actually come out are counted now, per entry and in total, and measured *before* anything is
written. The fixture rewrites a central directory's uncompressed size to build exactly that
archive; the suite refuses it, for that reason, and asserts nothing was written.
- **A failed removal could lose a package.** The folders were moved aside and the ownership
record written afterwards, so a failed write left the folders gone while the manifest still
claimed them. The record is written first now: a failed write moves nothing, and a failed
move leaves an ordinary folder the user still has. Asserted by making the add-on directory
unwritable and checking the package is still present and still listed.
- **Removal kept one copy per removal** in a directory nothing reads - storage that grew for
ever and could never be used. One copy per package is kept now, and a copy that fails
part-way is cleaned up (its destination is recorded before the copy, not after).
- **The two halves of "Keep the game from seeing it" disagreed.** The router fires on an
element by exact match, family or "any"; ownership compared strings exactly, so a mapping
stored as `keyboard.key.` fired the trigger and still let every key it covers through to the
game. Both ask one rule now, `+[AKTrigger element:covers:]`. The "any" sentinel is refused
as a stored value, which its own header always said it should be.
- **`-[AKInputRouter shouldTakeKeyWithUsage:]` was dead code** that described itself as the
place the adapter asks - a call that cannot exist, because the adapter is compiled into a
dylib this app never links. Deleted, and the header now names the mechanism that is real.

Two things the device can prove that nothing proved before: that the app is **still running**
after being put away (the pilot printed that line and no check read it - a build that lost
`UIBackgroundModes` would have left the app gone with every check still passing), and what its
audio session is left set to. The shell logs `audio=<category>/<mode>/<active> mic=<0|1>` on
both transitions, and the matrix requires `mic=0` on both sides. The microphone is also closed
*by the shell* before the shell says it has been: the old line claimed a close that had not
happened yet, on a path - resigning active without entering the background - where it never
happened at all.

What that leaves is a real voice: someone speaking, so the recogniser produces words. Every
other path that can end a session - a timeout, an interruption, going to the background - is
covered, and the state the session is left in is now read back off the iPad.

Proof: `test_addon_archive.sh` 58 checks (from 49), `test_voice.sh` 252 (from 244), the
device matrix at 21 checks, and the record under `development/validation/`. The 21 is one more
than before and the record says so; the count in this note is the one the script printed, not
the one this paragraph was written with.
