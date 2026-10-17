# Validation: 6cdcd1c

- Commit: `6cdcd1cfd3d746e2feeb18cc94ff86e98e0016b3` (branch `controller`)
- Recorded: 2026-10-17 00:52:19Z
- Working tree: clean
- Host: macOS 26.7.1 (arm64)
- Xcode: Xcode 27.0
- Device: an iPad, 27.0.1

## Results

| Step | Result |
| --- | --- |
| layer gate (check_layers.sh) | PASS |
| install does the right thing per execution mode | PASS |
| pilot.sh fails closed and keeps its own session | PASS |
| launcher pages (simulator fixture) | PASS |
| input, voice and config rules (simulator fixture) | PASS |
| on-screen controls and the game text field (simulator fixture) | PASS |
| the on-screen gamepad (simulator fixture) | PASS |
| the app builds for the device | PASS |
| platform emulation suite | PASS (1 known platform failure(s)) |
| translation adapters (simulator) | PASS |
| install and launch on the iPad | PASS |
| the app's own log, from the launch above | PASS |
| the device matrix, so far as a script can go | PASS |

## What each step printed

### layer gate (check_layers.sh) - PASS

```
PASS platform/ is byte-identical to upstream/main (00a8501, 1e8d13f1fe089fa32cd84a6b46fe3692e288aeac)
PASS no Wolkara strings under platform/
PASS 14 patch(es) apply cleanly
PASS every layer file is carried by the overlay
PASS every overlayed file exists in the layer
PASS wolkara/overlay.map is what wolkara/tools/overlay_map.sh generates
PASS prepare.sh accepts the overlay against the pinned platform
PASS every replacement is a change of ours
PASS no cross-module reach-in from WoW into Touch
PASS no cross-module reach-in from Touch into WoW
PASS the root carries no platform path
check_layers: OK
```

### install does the right thing per execution mode - PASS

```
AFTER-INSTALL PASS: 11 checks
```

### pilot.sh fails closed and keeps its own session - PASS

```
PILOT PASS: 25 checks
```

### launcher pages (simulator fixture) - PASS

```
19:53:13.888 [wow] a check was asked for
19:53:13.891 [wow] checking wow_classic_beta eu/enUS install=1 launch=0
2026-10-16 19:53:13.922 WoWFixture[53703:15615102] [wow-update] Phase: snapshot
2026-10-16 19:53:13.922 WoWFixture[53703:15615102] [wow-update] Phase: download
2026-10-16 19:53:13.924 WoWFixture[53703:15615102] [wow-update] Phase: complete
2026-10-16 19:53:13.929 WoWFixture[53703:15615102] [wow-update] Verification bytes read=0 reused=0
19:53:13.931 [wow] checked: state=3 error=none
19:53:14.193 [wow] a check was asked for
19:53:14.196 [wow] checking wow_classic_beta eu/enUS install=0 launch=0
19:53:14.228 [wow] checked: state=0 error=Synthetic offline response
19:53:14.497 [wow] a check was asked for
19:53:14.500 [wow] checking wow_classic_beta eu/enUS install=0 launch=0
19:53:14.530 [wow] checked: state=3 error=none
19:53:14.805 [wow] checking wow_classic_beta eu/enUS install=0 launch=1
19:53:15.512 [wow] a check was asked for
19:53:15.513 [wow] checking wow_classic_beta eu/enUS install=0 launch=0
19:53:15.545 [wow] checked: state=3 error=none
2026-10-16 19:53:15.815 WoWFixture[53703:15615062] DESCENDER_METRICS: frame={{0, 0}, {538, 27.5}} text={{0, 0}, {140.5, 27.5}} lineHeight=27.4473 ascender=21.8994 descender=-5.54785
19:53:17.172 [wow] checking wow_classic_beta eu/enUS install=0 launch=1
19:53:17.204 [wow] checked: state=3 error=none
19:53:17.484 [wow] a check was asked for
19:53:17.485 [ui] home: back in front
WoW UIKit PASS: automatic check/update, offline retry, edition race, background cancellation, verified launch, inline preparation/failure/session end, no duplicate launches and bundled licenses.
org.tolkara.tests.wow-launcher: 53703
screenshots: /Users/klock/Library/Developer/CoreSimulator/Devices/1CBC92F4-0C09-4A4D-983B-E08608D5AF8F/data/Containers/Data/Application/E9264CA3-D89C-47DF-8367-9F6A02C4C49F/Documents
```

### input, voice and config rules (simulator fixture) - PASS

```
19:53:34.244 [voice] dictation: authorizing -> listening
19:53:34.244 [voice] dictation: listening (on-device=1)
19:53:34.350 [voice] dictation: listening -> idle
19:53:34.550 [voice] AKVoiceEnabled set
19:53:34.551 [voice] test screen armed on Not set
19:53:34.978 [config] wolkara-config.json was not used: it is not readable: The data couldn’t be read because it isn’t in the correct format.
19:53:34.980 [config] recovered 1 choice(s) from the previous copy
19:53:34.982 [config] wolkara-config.json was not used: it is not readable: The data couldn’t be read because it isn’t in the correct format.
19:53:34.982 [config] the previous copy has already been tried once this launch
19:53:34.984 [config] 1 setting(s) were refused: AKVoiceMode (out of range)
19:53:34.984 [config] restored 1 choice(s) from wolkara-config.json
19:53:35.002 [config] could not write wolkara-config.json.writing (You don’t have permission to save the file “wolkara-config.json.writing” in the folder “Documents”.)
19:53:35.004 [config] restored 0 choice(s) from wolkara-config.json
19:53:35.007 [config] wolkara-config.json was not used: it is 3145728 bytes, and a config file is not
19:53:35.008 [config] the previous copy has already been tried once this launch
19:53:35.009 [config] wolkara-config.json was not used: it is not readable: The data couldn’t be read because it isn’t in the correct format.
19:53:35.009 [config] the previous copy has already been tried once this launch
19:53:35.010 [config] wolkara-config.json was not used: it is not readable: The data couldn’t be read because it isn’t in the correct format.
19:53:35.010 [config] the previous copy has already been tried once this launch
19:53:35.011 [config] restored 0 choice(s) from wolkara-config.json
19:53:35.013 [test] a write failure is being provoked now
19:53:35.015 [config] could not write wolkara-config.json.writing (The file “wolkara-config.json.writing” doesn’t exist.)
19:53:35.021 [config] restored 0 choice(s) from wolkara-config.json
VOICE PASS: 173 checks
VOICE PASS: 173 checks
```

### on-screen controls and the game text field (simulator fixture) - PASS

```
[ak] keyboard dequeued type=11 age_ms=10.5 pending=16
[ak] keyboard dequeued type=10 age_ms=10.5 pending=15
[ak] keyboard dequeued type=11 age_ms=10.5 pending=14
[ak] keyboard dequeued type=10 age_ms=10.5 pending=13
[ak] keyboard dequeued type=11 age_ms=10.5 pending=12
[ak] keyboard dequeued type=10 age_ms=10.5 pending=11
[ak] keyboard dequeued type=11 age_ms=10.5 pending=10
[ak] keyboard dequeued type=10 age_ms=10.6 pending=9
[ak] keyboard dequeued type=11 age_ms=10.6 pending=8
[ak] dictation placeholder inserted=1 pending=1 accepting=1
[ak] dictation placeholder removed willInsertResult=1 pending=0
[ak] dictation recognition failed (markedText=1, placeholders=0)
[ak] system keyboard hidden draftFirstResponder=0
[ak] system keyboard shown draftFirstResponder=0 markedText=1 height=44
[ak] system keyboard hidden draftFirstResponder=0
[ak] system keyboard hidden draftFirstResponder=0
[ak] input suspended (draftFirstResponder=1)
[ak] input suspended (draftFirstResponder=1)
[ak] input suspended (draftFirstResponder=1)
2026-10-16 19:53:55.701 TouchControlsFixture[54688:15618582] CoreText note: Client requested name ".SFCompact", it will get TimesNewRomanPSMT rather than the intended font. All system UI font access should be through proper APIs such as CTFontCreateUIFontForLanguage() or +[UIFont systemFontOfSize:].
[ak] system keyboard shown draftFirstResponder=0 markedText=0 height=44
[ak] system keyboard hidden draftFirstResponder=0
[ak] system keyboard hidden draftFirstResponder=0
2026-10-16 19:53:56.761 TouchControlsFixture[54688:15618582] TOUCH_UI_SELF_TEST_PASS: whole-field replacement, empty clearing, duplicate suppression, draft editing, dictation, cancellation and fixed toolbar
org.tolkara.tests.touch-controls: 54688
```

### the on-screen gamepad (simulator fixture) - PASS

```
apply: applied 0001-bc7-reserved-mode-not-comparable.patch
apply: applied 0002-log-native-bc-capability.patch
apply: applied 0003-runtime-rebase-without-done.patch
apply: applied 0004-appkit-nsfont-stub-trap.patch
apply: applied 0005-coreaudio-keep-session.patch
apply: applied 0006-authorization-local-service-retry.patch
apply: applied 0007-authorization-tunnel-service-probe.patch
apply: applied 0008-akfont-alias.patch
apply: applied 0009-appkit-hooks.patch
apply: applied 0010-project-layer-needs.patch
apply: applied 0011-resolve-packages.patch
apply: applied 0012-guest-input-trace.patch
apply: applied 0013-host-key-boundary.patch
apply: applied 0014-touch-controls-default.patch
apply: /Volumes/Storage/Projects/Wolkara/build/platform now carries the layer (14 patch(es), 91 file(s) overlaid)
prepare: build/platform ready (platform 00a8501)
build/touch-gamepad-fixture/TouchGamepad.app: replacing existing signature
2026-10-16 19:54:06.748 TouchGamepadFixture[55146:15619955] [TouchGamepad] Connection failed: Fixture (1)
TOUCH_HAPTICS_PASS: independent stick edges, held/jitter suppression, inward rearm, cancellation and disabled feedback.
TOUCH_GAMEPAD_LIFECYCLE_PASS: physical priority, own/snapshot filtering, keyboard/focus cancellation, late replies, failure, retry and teardown.
org.tolkara.tests.touch-gamepad: 55146
```

### the app builds for the device - PASS

```
apply: applied 0001-bc7-reserved-mode-not-comparable.patch
apply: applied 0002-log-native-bc-capability.patch
apply: applied 0003-runtime-rebase-without-done.patch
apply: applied 0004-appkit-nsfont-stub-trap.patch
apply: applied 0005-coreaudio-keep-session.patch
apply: applied 0006-authorization-local-service-retry.patch
apply: applied 0007-authorization-tunnel-service-probe.patch
apply: applied 0008-akfont-alias.patch
apply: applied 0009-appkit-hooks.patch
apply: applied 0010-project-layer-needs.patch
apply: applied 0011-resolve-packages.patch
apply: applied 0012-guest-input-trace.patch
apply: applied 0013-host-key-boundary.patch
apply: applied 0014-touch-controls-default.patch
apply: /Volumes/Storage/Projects/Wolkara/build/platform now carries the layer (14 patch(es), 91 file(s) overlaid)
prepare: build/platform ready (platform 00a8501)

== 2/2 build (the platform's own script)
   build only: not touching the device (xcrun devicectl device install …)
Installed with Developer service. Next: tools/enroll.sh (once), then copy your apps' files (see profiles/).
A mode already chosen in the app is kept; change it there with Execution mode…

== 2/2 done: built, and the device was left alone
   install it       wolkara/tools/pilot.sh install
   the log          build/platform/logs/install-*.log
```

### platform emulation suite - PASS (1 known platform failure(s))

```
known platform failures in this run: 1
----------------------------------------------------------------------
Ran 1 test in 0.000s

OK (skipped=1)
...F.................ss.........................................................
======================================================================
FAIL: test_matches_codesign_byte_for_byte (tests.test_sign_guest_local.AdhocTests.test_matches_codesign_byte_for_byte)
----------------------------------------------------------------------
Traceback (most recent call last):
  File "/Volumes/Storage/Projects/Wolkara/build/platform/tests/test_sign_guest_local.py", line 898, in test_matches_codesign_byte_for_byte
    self.assertEqual(read(out), read(ref), 'differs from codesign -s - for ' + os.path.basename(src))
    ~~~~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
AssertionError: b'\xcf\xfa\xed\xfe\x0c\x00\x00\x01\x00\x00[131953 chars]\x00' != b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01\x00\x00[203878 chars]\x00" : differs from codesign -s - for sgl-fixture.dylib

----------------------------------------------------------------------
Ran 80 tests in 16.866s

FAILED (failures=1, skipped=2)
```

### translation adapters (simulator) - PASS

```
known platform failures in this run: 0
[ak] mouse capture requested=1 raw_devices=0
[ak] mouse capture requested=1 raw_devices=0
[ak] mouse capture requested=1 raw_devices=0
[ak] mouse capture requested=1 raw_devices=0
[ak] mouse capture requested=1 raw_devices=0
[ak] mouse capture requested=0 raw_devices=0
[ak] mouse capture requested=0 raw_devices=0
[ak] mouse capture requested=0 raw_devices=0
[ak] mouse event type=1 point=(10,70)
[ak] mouse event type=2 point=(10,70)
[ak] mouse event type=3 point=(10,70)
[ak] mouse event type=4 point=(10,70)
[ak] mouse event type=25 point=(10,70)
[ak] mouse event type=26 point=(10,70)
[ak] mouse event type=1 point=(10,70)
[ak] mouse event type=2 point=(10,70)
[ak] cursor visibility hidden=1 outside=1 game_hidden=0 no_image=0
display pass, frame rects, panels, tracking areas, layer placement, contents scale, window ordering, Quartz events, window numbers and modifier keys: PASS
```

### install and launch on the iPad - PASS

```
  2026-10-15 20:51:19.286 Tolkara[4422:1134257] [ak] input: Button Menu value=0.00
  2026-10-15 20:51:24.949 Tolkara[4422:1134257] [ak] input: Button Menu pressed=1.00
  2026-10-15 20:51:25.090 Tolkara[4422:1134257] [ak] input: Button Menu value=0.00
  2026-10-15 20:51:26.373 Tolkara[4422:1134257] [ak] input: Button Options pressed=1.00
  2026-10-15 20:51:26.503 Tolkara[4422:1134257] [ak] input: Button Options value=0.00
  2026-10-15 20:51:26.757 Tolkara[4422:1134257] [ak] input: Share (system screenshot)
  2026-10-15 20:51:26.758 Tolkara[4422:1134257] [ak] input: Share (system screenshot)

== the app's own log
  20:02:41.749 [input] inspector: 0 controller(s) connected
  20:02:41.749 [input] inspector: keyboard=Generic Keyboard mouse=CoreDevice touchscreenGesture
  20:02:41.749 [input] inspector: keyboard keys=134 printScreen=PrintScreen
  20:02:41.749 [input] inspector: keyboard key names= | A | Application | B | Backslash | C | CapsLock | CloseBracket | Comma | D | DeleteForward | DeleteOrBackspace | Down
  20:02:41.749 [input] inspector: watching controller, keyboard, screenshot and capture
  20:02:41.774 [ui] home: first appearance, checking the game files
  20:02:41.774 [wow] a check was asked for
  20:02:41.775 [wow] checking wow_classic_beta us/enUS install=0 launch=0
  20:02:41.781 [input] inspector: screen capture changed, captured=1
  20:02:41.781 [input] input: system.capture on
  20:02:41.969 [ui] home: back in front
  20:02:43.101 [wow] checked: state=3 error=none

== state
  app running:    1
  guest log says: PASS (written 83521s ago)
```

### the app's own log, from the launch above - PASS

```
  20:02:41.641 [input] inspector: watching controller, keyboard, screenshot and capture
  20:02:41.641 [input] input: router watching every source
  20:02:41.641 [host] execution mode=developer-service source=saved
  20:02:41.661 [ui] home: the launcher is up (mode=developer-service source=saved)
  20:02:41.721 [input] window: offered a key command for Print Screen (input=0x46)
  20:02:41.748 [input] inspector: GCKeyboardDidConnectNotification
  20:02:41.748 [input] inspector: 0 controller(s) connected
  20:02:41.748 [input] inspector: keyboard=Generic Keyboard mouse=none
  20:02:41.749 [input] inspector: keyboard keys=134 printScreen=PrintScreen
  20:02:41.749 [input] inspector: keyboard key names= | A | Application | B | Backslash | C | CapsLock | CloseBracket | Comma | D | DeleteForward | DeleteOrBackspace | DownArrow | E | Eight | End | Equa
  20:02:41.749 [input] inspector: watching controller, keyboard, screenshot and capture
  20:02:41.749 [input] inspector: GCMouseDidConnectNotification
  20:02:41.749 [input] inspector: 0 controller(s) connected
  20:02:41.749 [input] inspector: keyboard=Generic Keyboard mouse=CoreDevice touchscreenGesture
  20:02:41.749 [input] inspector: keyboard keys=134 printScreen=PrintScreen
  20:02:41.749 [input] inspector: keyboard key names= | A | Application | B | Backslash | C | CapsLock | CloseBracket | Comma | D | DeleteForward | DeleteOrBackspace | DownArrow | E | Eight | End | Equa
  20:02:41.749 [input] inspector: watching controller, keyboard, screenshot and capture
  20:02:41.774 [ui] home: first appearance, checking the game files
  20:02:41.774 [wow] a check was asked for
  20:02:41.775 [wow] checking wow_classic_beta us/enUS install=0 launch=0
  20:02:41.781 [input] inspector: screen capture changed, captured=1
  20:02:41.781 [input] input: system.capture on
  20:02:41.969 [ui] home: back in front
  20:02:43.101 [wow] checked: state=3 error=none
  this log holds the launch from this run (111 before it, 112 now)
```

### the device matrix, so far as a script can go - PASS

```

== 5. it ships the licences it is obliged to ship
  ok   the installed app carries all four notices (its own log says so)
  notices: 4 of 4 in the bundle (Wolkara-LICENSE, Wolkara-NOTICE.md, LICENSE, NOTICE.md)
  ok   ours under our own names, not mixed in with upstream's

== 6. nothing crashed and the client did not assert
  ok   no new crash report for any launch above
  ok   no new game error file for any launch above

== deferred, and why

  background/foreground      needs a person tapping Home or locking the iPad; nothing on
                             this Mac can do it, and a simulator is not the same thing.
  audio before/after         needs someone to speak into the iPad, so the microphone is
                             really opened and the session really handed back.
  a controller button        mapping is arm-then-press: it needs a hand on a pad. What is
                             checked without one is that nothing fires while nothing is
                             mapped, and that no system signal can be mapped at all.
  the game itself            a live session touches the client's own store; the CASC and
                             in-game checks stay in COMPATIBILITY.md and are done by hand.
  a real add-on import       the extractor is the Swift/ZIPFoundation path the fixture
                             stands in for; it is exercised by importing an archive here.

DEVICE MATRIX PASS: 18 checks
```

## Read this as

Every step that ran passed, on the commit named above.

A step marked NOT RUN is not evidence. Anything the audit asked for that is not
listed as PASS here has not been shown for this commit.
