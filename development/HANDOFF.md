# Handoff: what is left, and how to finish it

A prompt for whoever picks this up next. Everything before the line marked "remaining
work" is context you should not have to rediscover; everything after it is a list of jobs
with the evidence each one needs.

## What this repository is

`platform/` is upstream tolkara, vendored byte-identical to `upstream/main` (pinned
`00a8501`) and **never edited by hand**. `wolkara/` is our layer above it: 14 patches in
`wolkara/patches/` and 91 overlay entries in `wolkara/overlay.map`,
applied to a copy of the platform by `wolkara/tools/prepare.sh` into `build/platform/`.
Anything Wolkara needs from the platform is done **by script** — a patch or an overlay
entry — so it is reproducible. `wolkara/tools/check_layers.sh` is the gate and must pass
before and after any layer change.

Read `AGENTS.md` (repository rules), `development/NOTES.md` (hard-won lessons, in date
order, newest last) and `development/README.md` (current counts and the command that
checks each one). The stability audit and its dispositions are in
`development/STABILITY_AUDIT_2026-10-16.md` and `development/AUDIT.md`.

## How to verify anything

```
wolkara/tools/check_layers.sh        # the gate: 11 checks
wolkara/tools/test_voice.sh          # 238 checks: input, voice, config, page layout
wolkara/tools/tests/test_pilot.sh    # 25 checks: pilot fails closed, one session per run
wolkara/tools/tests/test_after_install.sh
wolkara/tools/test_wow_launcher_ui.sh
wolkara/tools/test_touch_controls_ui.sh --self-test
wolkara/tools/test_touch_gamepad_ui.sh --self-test
wolkara/tools/test_wow_launcher.sh
wolkara/tools/test_local_service_retry.sh
wolkara/tools/validate.sh --full --device   # all of the above, the platform's suites,
                                            # the install, and the device matrix
```

`validate.sh` **refuses a dirty worktree** and writes `development/validation/<sha>.md`
with every command it ran, the commit, and whether the tree was clean. Do not hand-edit
those files. A run that fails still produces a record; keep it and say so.

The device is an iPad Pro 12.9" M1 (iPad13,9), iPadOS 27.0.1, bundle id
`local.wolkara.johnklock`, set in the ignored `local.env`. The app is
`wolkara/tools/install.sh`; the device matrix is `wolkara/tools/device_matrix.sh`
(20 checks, all passing as of `ff4d091`). **Never put a device identifier, signing team or
pairing record in a commit** — `validate.sh` scrubs them from its output for the same
reason.

## What "done" meant for the last pass, and what it found

The standing instruction was: do not stop to report, finish and test. Several things were
described as "needs a person" or "not started" and turned out not to be. Do not write into
the docs that something needs a person until you have tried to automate it — two of the
three entries on the deferred list were closed by a script and a test in one sitting.

The pattern worth carrying forward, in decreasing order of how much it has caught:

1. **A suite that nothing runs is a suite that lies.** Ask, of every
   `wolkara/tools/test_*.sh`: which step runs this? Four answered "none" once, and one of
   them had been failing at an assertion for a day while every recorded validation said
   PASS. Every layer suite now has its own row in `validate.sh`; keep it that way and
   never rely on a wrapper's loop.
2. **Ask the artefact, not the note.** The note said the app shipped no licence notices; it
   shipped upstream's, under our name, and the one that matters never reached the bundle.
   The note said `Replace` worked; it had not replaced anything for a day.
3. **A check whose answer depends on what a previous run left behind is not a check.**
   The matrix read the client's own update as our failure and reported ten failures that
   were not failures.
4. **What cannot be done must be said where the user is looking**, not only in a document:
   the pad-button limitation and the collision warning live on the page that makes the
   mapping, and a fixture asserts they are still there.

## Remaining work

### 1. Finish this pass's evidence (do this first, it may already be done)

`development/HANDOFF.md` was written the same commit as the code it describes. Confirm the
last validation record names the current `HEAD`; if it does not, run
`wolkara/tools/validate.sh --full --device` on a clean tree and commit the record. A record
for an older SHA is not evidence about this one.

### 2. The app icon, from the corrected logo

The logo was corrected in `logo.png` (repository root) and integrated into
`wolkara/Shell/artwork/wolkara-logo.png` and the `WolkaraLogo` imageset. The **app icon**
is a separate asset set, `wolkara/Shell/Assets.xcassets/Wolkara.appiconset/`, and it is
drawn by `wolkara/tools/make_wolkara_icon.py`, which needs Google Chrome. The icon was not
regenerated. Decide with the user whether the icon should follow the logo — they are not
the same picture today — and if so run the tool, look at the result at every size
(`artwork/wolkara/` after the overlay), and install to check it on the iPad home screen.
Note the leftover: `logo.png` is untracked at the repository root; the layer holds the
artwork now, so ask before deleting it.

### 3. Input ownership for a controller button

`AKVoiceSettings.takeButtonFromGame` ("Keep the game from seeing it") means a **keyboard**
key the user has mapped for dictation is never posted to the guest — press or release —
while the trigger still fires. It works for keys because the observation and the forwarding
name the same input (`keyboard.key.<usage>`).

It cannot be done for a **pad** button today, and the page says so: iPadOS reports a pad's
buttons as gamepad elements (`controller.button.*`) while the guest receives them as key
events, and no public API connects the two. Closing this means either

- finding a verified map from a `GCController` button to the HID usage the guest sees, and
  only if it can be *measured* — do not invent a table; or
- deciding, with the user, that the pad case stays a warning.

`wolkara/Input/InputRouter.m` (`shouldTakeKeyWithUsage:`), `wolkara/Voice/VoiceSettings.m`
(`ownsElement:`, `ownedKeyUsages`) and the adapter's swallow point in patch `0009`
(`postKeys:`) are where the mechanism lives. The boundary matters: the adapter is compiled
into a **signed dylib the app never links**, so the shell publishes the owned usages by
notification (`AKTouchOwnedKeyUsagesDidChange`) and the adapter swallows them. A link-time
symbol between the two does not work — that was measured.

### 4. The other trigger patterns

The trigger model stores and validates five patterns (`press`, `double`, `long`, `chord`,
`push-to-talk`) and the router implements and tests all of them, but the page offers two
modes and no double/long/chord choice. Either offer them (a product decision: the mode
currently owns the pattern, and `applyModeToStoredMappings` rewrites it — read
`VoiceSettings.h` before changing that) or remove the unreachable code. Do not leave the
model's five patterns looking like five options; `docs/VOICE.md` currently says so in
words, which is the honest minimum but not a decision.

### 5. What genuinely needs a person, and how to make it need one less

- **Audio before/after dictation with a real recogniser.** The policy is implemented and
  tested with fakes, and the session is now closed on every path that can end it (timeout,
  interruption, backgrounding). Proving it with a real microphone means someone speaks.
  Consider whether `AVAudioSession` state can be read back on the device instead.
- **A controller button pressed by hand** to complete a mapping. There is no input
  injection on this setup. If one is ever found, `pilot.sh` is where it belongs.
- **A live game session** (CASC repair, in-game chat). This touches the client's own store
  and is deliberately not automated; `COMPATIBILITY.md` records what was done by hand and
  when.
- **A real add-on import** through the Swift/ZIPFoundation extractor. The fixture stands in
  for it; the archive path itself has only been exercised by that stand-in.

### 6. Documentation debt

- `docs/TOUCH_INPUT.md` and `docs/WOW_LAUNCHER.md` contain dated validation records that
  name pre-split `tools/` paths. Both now say so where the records begin; the rest of the
  prose has not been audited for the same thing.
- `development/AUDIT.md`'s "Still open" list is the authoritative list of what was left
  unanswered. Re-read it against the code before declaring anything done.
- Voice page layout is asserted structurally (on screen, sized, not overlapping, every
  switch named and labelled). Whether it *looks* right still needs eyes: the launcher
  fixture writes screenshots to the simulator container, printed at the end of its run.

## Rules that are easy to break by accident

- Never edit `platform/`. A change there is a patch, regenerated mechanically: export the
  platform, apply the patches before it, `git apply` the one you are changing, edit the
  file, then diff that tree against the pre-patch state in a scratch git repo and splice
  the result under the patch's prose header. Hand-editing a hunk header produces a patch
  that applies by luck.
- Adding a layer file takes two steps or the gate fails: `git add` it, then run
  `wolkara/tools/overlay_map.sh` to regenerate the map.
- `build/platform` is generated and is regenerated by every tool. Never edit it directly,
  and never trust a build product that is older than the last `prepare.sh` — the device
  build lands in `build/platform/build/device/Build/Products/Debug-iphoneos/Tolkara.app`,
  and a stale copy in `build/device/` will answer questions about the wrong build.
- The app has its own log, `Documents/wolkara.log`, from the first line of `main`. Read it
  with `pilot.sh log [lines] [pattern]`. `stderr` is not enough — it exists only with a
  console attached.
- `pilot.sh` refuses to stop or install while the client is writing to its own store. That
  guard is correct: wait for it, do not pass `--force` to get around it.
