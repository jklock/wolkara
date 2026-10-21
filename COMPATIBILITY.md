# Compatibility

Applications that people have actually run with Tolkara. Add a row through a
pull request; say what you tested, on what hardware, with which execution mode
(Developer service, Local signing or External JIT), and what did not work.

| Application | Version | Device / OS | Execution mode | Works | Known problems | Profile |
| --- | --- | --- | --- | --- | --- | --- |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Developer service | In-game login, world entry, movement, combat, spells, quests, trading, audio, intro cinematics, cursors, clean exit. Up to 120 FPS at graphics quality 8, 50% render scale. Launch without a Mac, including after reboot. | Character-selection top menu is oversized and misplaced. Voice chat unavailable (its separate helper app is not supported). Memory preparation at each launch (about 80 s before the 2026-09-27 speed-up; not re-measured since). Switching apps during startup may interrupt it. Shader coverage beyond the played areas is unverified. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.9 (70003) | iPhone 16 Pro Max, iOS 27.0 | Developer service | User-confirmed startup, opening cinematic, login screen and mouse use with AssistiveTouch; runtime log records graphics window and audio. | Experimental. Region/language configuration required to avoid unsupported RegionPicker. AssistiveTouch required for the tested mouse setup. Account login, world entry, gameplay and controller input unverified. See [iPhone validation](#iphone-validation-2026-10-01). | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Classic (Classic Era, macOS arm64 client) | 1.15.x | iPad Pro M5, iPadOS 27 | Local signing | Login and gameplay (2026-09-27), with no debugger, helper or tunnel and no memory preparation. At startup the client's own unpacked code matched the signed page container byte for byte, and all 12,658 initializers ran into the original `main`. | Building the page container for this client needs a capture of its final code pages, which the app cannot produce on its own yet. | [`wow-classic-era`](profiles/wow-classic-era) |
| World of Warcraft Forever (Classic beta, macOS arm64 client) | 1.60.1 | iPad Pro M5, iPadOS 27 | Local signing | Login and gameplay (2026-09-27), with no debugger, helper or tunnel and no memory preparation. At startup the client's own unpacked code matched the signed page container byte for byte, and all 13,280 initializers ran into the original `main`. | Developer service not yet validated on this iPad. Same capture limitation as Classic Era. | [`wow-forever`](profiles/wow-forever) |
| World of Warcraft Forever (Classic beta, macOS arm64 client) | 1.60.1 (70170) | iPhone 16 Pro Max, iOS 27.0 | Developer service | User-confirmed login, world entry and about two hours of gameplay without reported problems (2026-10-02). Reported 60 FPS at 50% render scale and graphics quality 2. Controller support enabled using middle mouse click; controller menu navigation works. | Initial tests used a Bluetooth keyboard and AssistiveTouch; physical left mouse click did not activate the tested menu controls, while wheel-button click worked. The new [iOS keyboard and touch trackpad](docs/TOUCH_INPUT.md) were subsequently confirmed working by the user on this iPhone (2026-10-02). See [iPhone validation](#iphone-validation-2026-10-01). | [`wow-forever`](profiles/wow-forever) |

## Voice dictation into the game (2026-10-21)

On Dadpad (iPad Pro 12.9-inch, 5th generation, iPadOS 27), Developer service, with an Xbox
Bluetooth pad mapped to Options as Hold to talk: the **Test Voice** page on the home screen
delivered a transcript, and two further utterances were typed into the running game at its
login screen - 21 characters each, Return sent by auto-submit, 43 key events dequeued by the
guest, the audio session handed back to the game, no crash report, and the app still running.
The app's own `dictation-target` self-test reported PASS 2/2. Not covered: microphone audio
was not verified sample by sample, no other controller was tried, and the in-game test used
the login screen rather than the game's chat box.

## Latest Wolkara gameplay report (2026-10-07)

The developer reports **60 FPS at graphics quality 4 on an iPhone 16 Pro Max**
in WoW Forever. Render scale, exact client build and a repeatable benchmark were
not supplied for this latest report; do not infer them from the older quality-2
session below. This confirms reported gameplay performance, not the fresh-download
flow or the latest update-recovery fix. Those require separate device tests.

## iPhone validation (2026-10-01)

The [WoW launcher branch](docs/WOW_LAUNCHER.md) was compiled for iOS on 2026-10-03.
The user tested the themed home screen on this iPhone and requested automatic
installation of detected patches. This revision implements native CDN updates,
verified data reuse, resumable staging and atomic activation. Synthetic tests
and isolated Mac-copy transactions pass: Forever 1.60.1.70205 selected
1,215,567 standard macOS objects (67,079,188,425 encoded bytes), fetched
248,252,461 missing asset bytes and verified all 143 loose files. The Mac source
installation was unchanged. The user subsequently completed the patch download
on the physical iPhone. Readback confirmed version 1.60.1.70205 and an executable
identical to the Mac original (SHA-256). Startup stopped before guest entry:
the loader incorrectly required a DONE marker after the complete rebase stream.
This revision accepts a stream ending at its declared length, retains operand
and target bounds checks, and validates all 241,069 rebases and 3,549 binds of
the readback executable without running it. **Device startup and gameplay after
this fix still need manual confirmation.** Fresh installation is covered only by synthetic
fixtures. AltStore PAL execution remains unproven. These launcher checks do not
extend the gameplay results recorded below.

The 2026-10-07 updater optimization persists verification receipts so ordinary
patches can reuse unchanged CASC segments without rereading all their payload.
The first update without receipts still checks existing content; Settings →
**Verify and repair game files** always forces a complete check. Synthetic
patch/resume/corruption tests, the simulator repair flow and the signed device
build pass. A 16 MiB synthetic warm planning pass reads zero payload bytes;
speed on the physical iPhone's full installation remains unmeasured. The first
device trial reported repeated **CASC data changed during the update** while
resuming 70235 → 70245. A follow-up revalidates only a changed segment's trusted
objects before allowing metadata-only recovery; checksum failures still block
activation. Synthetic metadata-change/resume and 64 MiB checkpoint tests pass;
a subsequent physical retry reached `activate` and `complete` in Xcode after
rechecking `data.075`. The logged counters were 67,488,524,145 bytes read and
44,033,527 reused during that adoption/resume pass. This is an observed update
completion, not a warm-patch speed measurement or a post-update gameplay test.
See [persistent verification](docs/WOW_LAUNCHER.md#persistent-verification-2026-10-07).

On 2026-10-06, the follow-up adds an [automatic touch controller](docs/TOUCH_CONTROLLER_PROPOSAL.md)
with a custom UIKit layout, and fixes clipped descenders in the home status.
Real GameController input and connection lifecycle are covered by synthetic
simulator fixtures. This touch-controller revision has **not yet been tested
in WoW on the physical iPhone** and does not extend the gameplay report below.

The subsequent Wolkara revision adds saved control opacity, separate rear/front
sizes, draggable groups/buttons and reset. Its original UIKit fixture verifies
preferences, bounds, all button/axis events and input suppression during editing;
the settings and editor were also inspected in the simulator. The app now has
its own name/icon and selects the build's startup route without a public picker.
The signed arm64 iOS build and strict signature check pass. The user subsequently
reported native keyboard/slider stalls while WoW and the controller continued
working; beginning the Control Center gesture released the UI. A follow-up fixes
UIKit starvation reproduced with a busy synthetic desktop-event queue and
publishes pending native UI changes after event processing. Regression tests,
manual simulator typing/slider drags and the signed device build pass. The
[UI-pump correction](docs/TOUCH_INPUT.md#native-ui-stalls-while-the-guest-continues-2026-10-06)
did **not** resolve the full device symptom: on 2026-10-07 the user reported
queued keyboard taps released by Control Center / Notification Center. The new
[visible draft editor and tracking-mode follow-up](docs/TOUCH_INPUT.md#visible-draft-and-tracking-mode-follow-up-2026-10-07)
remove per-key native document resets and service UIKit tracking work while the
keyboard/settings are open. Synthetic checks pass; resolution of the device
stall and frame-rate impact remain unverified. The toolbar now stays top center
regardless of keyboard/controller state, with a further optical pointer offset.
The draft's **Replace** action now selects all and replaces the focused field
instead of appending; an empty draft clears it. Reading the field's prior text
is still unsupported. Synthetic replacement/clearing and key-order tests pass;
WoW's handling of Select All on the iPhone needs user validation.

On 2026-10-07, the user reported a first-launch failure after installing from
Xcode, followed by a successful launch from the icon. The failed device log
records completed memory preparation and confirmed helper detachment, followed
by an `isLowPower` Objective-C exception on the native iOS Metal device during
initialization. Xcode's launch record enabled `MTL_DEBUG_LAYER=1`; the shared
scheme now disables Metal API Validation to match an ordinary icon launch.
A synthetic Metal-property probe passes in the simulator with validation both
on and off, so it does not reproduce the device failure. The user subsequently
reported that it now works after this correction (2026-10-07).

The subsequent haptics change adds optional phone feedback for controller and
toolbar buttons, plus one cue per stick-edge crossing with independent radial
hysteresis. Synthetic tests check pulse requests and unchanged controller input;
the physical feel and strength still need testing on the iPhone.

Results updated on 2026-10-02 with the Forever gameplay report below.

Experimental support was tested on an iPhone 16 Pro Max / iOS 27.0 with
Developer service. The generic arm64 build installed successfully. Trusted USB
enrollment and the local authenticated tunnel/capability probe passed. The user
confirmed a cold launch after reboot with the iPhone disconnected from the Mac.
On 2026-10-04 the first reported launch using cellular data, with Wi-Fi enabled
but unassociated, failed before preparation: the local route was running but
the TCP connection to the on-device developer service failed. Disconnected-Mac
launches do not establish cellular-only startup support. The branch now keeps
the local route alive and retries initial connection failures for up to two
minutes, with instructions to temporarily disable mobile data and restore it
after preparation. Synthetic recovery tests and compilation are separate from
physical evidence: **this recovery sequence is not yet validated on the iPhone**.
See [the iPhone guide](docs/IPHONE.md) for a reproducible setup.

The user confirmed that both Classic Era and Forever start and work through
the screens described below. Both required AssistiveTouch for the tested mouse
setup. These are manual device observations; the extent of input and gameplay
validation is recorded separately for each client.

### World of Warcraft Classic Era 1.15.9 (build 70003)

Memory preparation took 53–55 seconds for 87,425,024 bytes, all 12,658
initializers returned, and the original main ran. The user reached the opening
cinematic and login screen. The runtime log records a game window, loaded
Metal libraries and audio playback. The user confirmed mouse use with
AssistiveTouch enabled. Successful account login, world entry,
gameplay and performance have not been validated.

Initial launches stopped in `RegionPicker.nib`: its window, controls and
bindings are unsupported by the AppKit adapter. The source installation had
no `WTF/Config.wtf` to copy. Setting only `portal` did not resolve the failure;
setting `portal`, `textLocale` and `audioLocale` together to match the chosen
region and installed languages allowed startup to proceed. See the
[configuration workaround](profiles/wow-classic-era/README.md#region-and-language-before-the-first-launch).
No game executable was modified.

Controller input remains unverified. With `GamePadEnable=1`, a GameSir G8+
using its Switch profile did not control the login screen. A reported crash
in that attempt was a clean guest exit in the captured log: main returned 0,
startup returned PASS, and the host ended its session normally. No related
system crash report was available. The action that triggered the exit is
unknown. The build did not include the experimental controller-hiding adapter.
ConsolePort 3.2.7 installation was subsequently verified (interface 11509),
but addon loading inside a character and physical input were not validated.
These results do not establish gamepad support at login.

### World of Warcraft Forever 1.60.1 (build 70170)

On 2026-10-02 the user confirmed successful login, world entry and about two
hours of gameplay without problems on an iPhone 16 Pro Max / iOS 27.0, using
Developer service. The reported frame rate was 60 FPS at 50% render scale and
graphics quality 2. This is a manual report from the tested session, not a
benchmark across all areas or activities.

The initial setup used a Bluetooth keyboard and AssistiveTouch. The keyboard
was needed to enter account details. With AssistiveTouch
enabled, clicking the mouse wheel (middle button, not scrolling) selected the
controls used to enable controller support; left mouse click did not. The
controller could then navigate the menus. The separate
[touch-input implementation](docs/TOUCH_INPUT.md) now provides an iOS keyboard
and trackpad with two-finger scrolling. Its synthetic and simulator checks
pass, and on 2026-10-02 the user confirmed the new controls working correctly
in Forever on the same iPhone 16 Pro Max / iOS 27.0. Other-device input testing
remains pending. The two-hour gameplay/performance report above predates
these controls.

The working setup uses the beta's own `portal "test"` setting and the default
`TOLKARA_SYSTEM_ROOTS=YES` for the private build. Earlier attempts rejected
login with `BLZ51900003`. Matching the portal alone did not resolve it; the
initial build also lacked `CompatibilityRootCertificates.plist`. Login and
gameplay were confirmed after rebuilding with that public certificate
resource. The existing certificate-adapter tests passed with ASan/UBSan on
the Mac using all 158 packaged candidates.

Build 70170 was copied over 70124 with current Data files verified by path and
size, and the copied client bundle and metadata verified by SHA-256 readback.
Game files and iPhone settings were preserved during the subsequent Tolkara
app update. The original game executable was not modified.

### Palworld 1.0.8

The first native attempt prepared 351,895,552 bytes of executable memory in
209.602 seconds, then stopped before initializers at legacy rebase operation
1,000,001. The loader now bounds rebase work by the loaded image's pointer
capacity instead of a fixed million. A data-only Mac check of the unchanged
executable and its six carried libraries passed: the executable has 1,598,313
rebases and 14,217 binds.

With that fix installed, the next attempt prepared memory in 210.030 seconds,
completed all 5,741 initializers and entered the original main, then stopped.
The log includes unavailable libraries/stubbed imports and an unimplemented
`NSAppleEventManager` call, and ends with Unreal's crash reporter failing to
spawn (`EPERM`). The reporter failure does not identify the preceding fault.
No out-of-memory error was recorded in that runtime log; peak memory and the
original crash cause remain unknown. No game window or gameplay was validated.

## Runtime diagnostics

### Add-on manager (2026-10-14)

The native add-on manager was signed with the configured development identity
and installed on Dadpad (iPad13,9); the current build launches and stays
running. The installed app contains the ZIPFoundation 0.9.20 archive
validator, device-only CurseForge credential storage, a live CurseForge
browse surface (search, sort, category filter, pagination) and
managed-package controls. This is build/launch proof only: interactive Files
import, an approved personal CurseForge key and WoW's AddOns menu have not yet
been exercised on the device, so no package or game compatibility result is
claimed here.

As of 2026-10-16 the parts of that which a fixture can hold are covered by
`wolkara/WoW/tests/test_wow_launcher_app.m`: TOC parsing, store import (including
importing the same add-on twice, which used to delete the installed copy), a
missing TOC, a file the TOC does not list, pin, disable, remove, and the
credentials contract. The device-side list above is unchanged - a fixture is not
a device, and what it covers is the manager's own logic, not WoW reading the
result.

The game launch itself exposed a runtime gap. The guest's `NSFont` class
reference bound to UIFoundation's private `NSFont`, whose selectors are not
AppKit's, so `+[NSFont messageFontOfSize:]` raised during the login UI and the
process ended with no crash report (the guest log's last lines record the
exception). The AppKit adapter now implements `NSFont` as `AKFont` and aliases
the AppKit symbol names in its `ldflags`, as it already did for `NSColor`; the
shipped shim exports the class and a simulator check drives its class methods.
The rebuilt app was reinstalled and relaunched on Dadpad, and with the container
repaired the client now starts: `Client.log` records `Client Initialize` at
18:23:33 and reaches the login screen (`Switching to screen="AccountLogin"`,
with the intro movie at 18:23:40), then a clean `Glues Shutdown` at 18:40:14 when
the user closed it, with no crash report and no CPU-resource diagnostic for the
session. Logging in and gameplay past the login screen are not yet verified on
the device.

The same afternoon the client refused to start at all, showing its own "World of
Warcraft" alert and then exiting cleanly (the launcher ended the session, so it
looked like a crash). Its `Tact.log` recorded the reason: "Corruption detected in
KMT file. (invalid sorted hash) ... Failed to initialize dynamic container.
Error(11): needs repair". Every `.idx` (KMT) file under `Data/data` had been
rewritten at 15:34 and a `05tempfile.idx` was left behind, so an update had been
interrupted by the app's termination, leaving one half-written index generation
and no earlier generation to fall back on. Restoring the complete index set from
the intact Mac copy (98 files covering all 16 buckets and their earlier
generations) plus one valid newest-generation index per bucket let the client
bind the container, run all 13,302 initializers, enter main, play its intro
cinematic with video and audio, and reach the login screen on Dadpad. The launcher's update path still needs
to be checked for this failure mode: an interrupted index write must leave the
container bootable, and older index generations must be kept (or restored) so the
client can roll back.

The launcher now repairs that state instead of leaving it to a manual copy of the
index set. The client's own interrupted index commit leaves a truncated
generation as a bucket's newest, and TACT then refuses to bind that mapping table,
so the next launch aborts with the client's own alert. Before the guest runs,
`runNativeGame:` rewrites each bucket's newest generation from the newest
generation that validates and carries rows, using the same validity checks the
CASC store applies when it opens, and removes the client's leftover
`<bucket>tempfile.idx` (`TKWoWCASCRepairIndexGenerations`, `launcher/WoW/CASC.m`).
Verified on Dadpad by planting the exact damage and launching three times in a
row: each launch from a planted truncated generation (buckets `0b` and `0c`) logged
the rewrite and reached the client's intro cinematic with no TACT error and no
NeedsRepair, and a fourth relaunch after killing a running session needed no
repair at all.

The Metal adapter no longer references a `BCTextures.m` fallback. That file never
existed in the repository, and clean shim builds failed to link on the dangling
`AKInstallBCTextureFallback` symbol (see
`build/black-screen-triage/upstream-gpu-identity-test.log`) while cached shims
kept the app building, so the add-on commit removed the reference. Whether the
guest needs BC-texture handling behind the Mac-style GPU identity the adapter
reports remains an open compatibility question.

A device report said the Add-on Manager's search field raises no keyboard. The
field does take focus: the fixture now pushes the manager into a window exactly
as the launcher does and confirms the search field is hit-testable and becomes
first responder. A plain text field behaves the same in the headless simulator,
which presents no software keyboard at all, so that probe cannot separate app
from environment. Nothing in the app suppresses text input: the launcher has a
single key window when the manager is open, the AppKit adapter installs no
responder or event swizzles, and the manager is unreachable after a guest
session. An attached hardware keyboard is the remaining explanation, as iPadOS
keeps the on-screen keyboard hidden until the keyboard key or Command-K is
pressed; this is not independently confirmed on the device.

On 2026-09-26, `--sparse-memory-probe` passed on the iPad Pro M5 / iPadOS 27.
Tolkara's own assembly used 112 GiB of software address ranges and completed
18,600 scalar, SIMD, addressing and atomic fault/resume operations, using
96 KiB of backing pages.

An entry records what one person observed. It is not a promise that the
application will keep working, and it says nothing about whether its publisher
permits it: read "Online games and account risk" in the [README](README.md).
