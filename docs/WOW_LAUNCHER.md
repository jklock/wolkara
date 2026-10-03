# Experimental WoW launcher

Branch: `feature/wow-launcher`, based on `feature/iphone-support` at
`05035ccbbf33565ab36abdb1d5e43a6b53cc816b`. This is an early, working prototype,
not a complete replacement for Battle.net. The existing runtime and execution
modes are unchanged. No game files, signing identities or accounts are bundled.

## Available now

The app opens directly into a native WoW home screen with edition selection,
automatic updates and one primary action. General tools and execution modes
remain under Settings. English and Spanish follow the device language. The
“Tolkara / In development” heading has been removed.

- Remembers Forever Beta, Classic Era, Classic, Retail or Retail Beta, region
  and language. Forever currently maps to `wow_classic_beta`; a listed edition
  is not a claim of runtime compatibility.
- Checks at opening, foregrounding and before Play. An outdated installed copy
  **starts updating automatically**. A missing edition offers Install; an
  unverifiable installation offers Repair. Interrupted explicit installations
  are remembered and resumed, including after reopening the process.
- Shows preparation, existing-data verification, downloading, file installation
  and activation progress. Play stays disabled until the current published build
  and its original executable pass verification. A failed check never counts as
  up to date. No game starts automatically unless the user requested Play.
- Keeps settings and addons. The updater writes into a private APFS clone and
  switches the whole installation in one filesystem operation only after all
  required content is present and verified. An interrupted update leaves the
  active installation in place.
- Downloads while the app is open. Backgrounding cancels the current transfer;
  verified objects are checkpointed and reused next time. The same applies to
  returning after a network failure. This is not an iOS background-download
  service. Keep the app open while updating.
- Developer service still prepares executable memory at each launch. Updating
  files does not remove or cache that separate runtime operation.

Play checks `.build.info` and the selected executable on ordinary launches.
Full CASC verification runs during updates/repair, not every time Play is tapped.
The advanced library still has its original manual launch path, outside the
WoW home screen's mandatory-update gate.

## Update implementation

`Manifest.m` reads text metadata, BLTE, install and encoding manifests with
bounds, decompression limits and content checksums. `CASC.m` adds download
manifests, CDN archive indexes and local v7 CASC index/container storage. It
selects standard macOS ARM64 content for the region/language, excluding optional
HighRes/Alternate/feature packs. Encrypted assets are retained as opaque original
bytes; encrypted loose-file extraction is rejected. No content keys, login
credentials or game code are supplied by Tolkara.

`Client.m` uses Blizzard's public HTTPS services, bounded responses and verified
Range requests. It reuses a connection pool and groups adjacent archive objects
into requests of up to 16 MiB (larger individual objects remain bounded at
256 MiB). Every selected object is checked before being passed to storage.
Metadata caches are content-addressed and reverified. Protocol sources and
licences from TACTSharp, CascLib and lookup3 are recorded in `NOTICE.md`;
no .NET runtime is embedded.

`Updater.m`:

1. Locks the updater and records a snapshot keyed by product, build and locale
   under `.tolkara-updates` beside `World of Warcraft`. APFS clones share old
   blocks without permitting writes to alter the old installation. Symlinks
   outside the installation and unsupported files fail the update.
2. Verifies existing content and computes missing objects. It checks space for
   missing objects, loose files and a 1 GiB margin; filesystem write errors also
   stop activation. Bootstrap manifests and the root manifest are included.
3. Appends new encoded objects to new CASC segments and checkpoints local indexes
   every 64 MiB and on a handled interruption. The latest two index generations
   are retained. A forced process kill may lose the current uncheckpointed batch;
   it cannot activate a partial installation. Resume rechecks stored content.
4. Installs original loose files with exact size/content hashes. It never
   patches or re-signs the game's executable. Existing WTF and Interface folders
   are refreshed from the old root immediately before activation, preserving
   edits made while paused. Only when Config.wtf is absent, initial portal and
   locale settings are created to avoid the unsupported region picker.
5. Rechecks the published version and unchanged source metadata, then uses an
   atomic directory swap to activate metadata, executable and data together.
   Its own replaced snapshot is removed after success. Other editions and
   existing unreferenced data are retained; data compaction is not implemented.

`Installation.m` checks the installed product and original executable.
`WoWViewController.m` serializes update jobs, discards stale UI/launch callbacks
when the screen or edition changes, and registers newly installed executables
with the existing library. Its normal flow needs no running Battle.net on a Mac
for downloading patches. It does not automate login or gameplay.

## Remaining validation and limits

- The new updater has **not yet updated the physical iPhone**. Real-data tests
  use isolated APFS clones on the Mac, with the same native updater sources.
  Those tests prove file installation and integrity, not WoW accepting a newly
  constructed CASC store on iOS. Physical update, interruption and subsequent
  gameplay need manual validation.
- Fresh installation is implemented and tested with synthetic data, but a full
  fresh real-game download has not been validated. Other listed editions have
  metadata checks, not complete update/runtime coverage.
- Existing game language preferences are preserved; changing the download
  language is not a WoW settings editor. Download only a language matching the
  installation until switching languages is tested. Optional packs are not
  part of this standard-content updater.
- Transfers stop on protocol/storage errors and offer Retry. Oversized objects,
  unsupported local-index layouts and encrypted loose files fail explicitly.
  New upstream formats may require code changes. Obsolete data/abandoned build
  snapshots are not globally compacted automatically.
- Preparation time is unchanged. Local signing and the required final-page
  capture/signing workflow remain a separate investigation. A container for an
  old executable must never be reused for an updated one.

## AltStore PAL feasibility

The intended public distribution channel is **AltStore PAL**, not Classic.
There is currently **no demonstrated PAL-compatible native execution path** for
this launcher. The home screen and downloader do not solve that.

[AltStore's PAL distribution documentation](https://faq.altstore.io/developers/distribute-with-altstore-pal)
requires Apple notarization. [Apple's code-signing documentation](https://support.apple.com/guide/security/app-code-signing-process-sec7c917bf14/web)
explains mandatory executable-code validation. Our engineering conclusion is
that installing the wrapper through PAL alone cannot be treated as permission
to execute a separately downloaded Mac client. No notarized build was submitted
or tested, and no PAL distribution or execution entitlement is claimed.

[AltStore's JIT guide](https://faq.altstore.io/altstore-classic/enabling-jit)
does describe a helper, StikDebug, distributed through PAL. Its documented target
apps are sideloaded through **AltStore Classic**, with a pairing setup involving
a Mac or PC. The helper's availability on PAL does not establish that this
wrapper installed through PAL can execute WoW.

Local signing remains a development experiment involving the user's own signed
page container, not a proven solution for marketplace distribution. Its keys or
third-party code must not be bundled into a public app. Replacing native execution
with interpretation would be a different engineering project with unproven WoW
compatibility and performance. “Install from PAL, choose an edition and play,
without setup or preparation” therefore remains an unresolved feasibility goal,
not a deliverable promised by this branch.

## Validation — 2026-10-03

All real CDN operations below were run on the Mac using the **same native
client/updater code** compiled into the iOS app. They do not establish downloads
on a physical iPhone or gameplay with the downloaded copy.

Two isolated Forever 1.60.1.70205 transactions completed. Both verified
1,215,567 selected objects (67,079,188,425 encoded bytes), reused existing valid
content, downloaded 248,252,461 missing asset bytes and verified all 143 loose
files after activation. A deliberately absent Info.plist in each **test clone**
was restored through a verified archive range. The original Mac installation's
metadata and executable remained unchanged. No game was run. The second
transaction exercised batched range downloads and connection reuse. A final
transaction also verified the required root manifest and reused every selected
asset (zero missing asset bytes downloaded).

| Product | Published version observed | Result |
| --- | --- | --- |
| `wow_classic_beta` | 1.60.1.70205 | Verified config, install and encoding manifests; 143 selected install files; downloaded the 149,167,072-byte original executable. Its SHA-256 exactly matched the existing Mac original. Neither was executed or modified. |
| `wow` | 12.1.0.69933 | Verified config and install manifest; 142 selected install files. Runtime not tested. |
| `wow_classic` | 5.5.4.70032 | Verified config and install manifest; 141 selected install files. Runtime not tested. |
| `wow_classic_era` | 1.15.9.70003 | Verified config and install manifest; 141 selected install files. No new runtime test. |
| `wow_beta` | 12.0.1.66220 | Verified config and install manifest; 141 selected install files. Runtime not tested. |

The initial large-file decoder caused excessive temporary allocations. After
changing to one preallocated output buffer and non-copying chunk views, the
cached-encoding executable extraction used **464,437,248 bytes maximum RSS**
on the Mac (about 443 MiB), versus about 27 GB before. This is a Mac process
measurement, not an iPhone memory budget or a guarantee for larger builds.

- Focused manifest, client, installation and updater tests: **PASS**,
  `-Wall -Wextra -Werror`, ASan and UBSan. Synthetic fixtures cover truncation, bounds, decompression limits,
  checksums, unsafe paths, multi-chunk decoding, tag filtering, cache corruption,
  missing/changed/ambiguous build metadata, read-only inspection, changed original
  bytes, protocol failures and HTTPS-only selection. No third-party application
  data is in the tests. Updater fixtures also cover grouped archive downloads,
  corrupt ranges, pause/resume, source preservation, late upstream build changes,
  external symlinks, protected user paths, optional packs and fresh installs.
- UIKit fixture: **PASS** on iPhone 17 Pro / iOS 26.5 Simulator. Synthetic
  responses exercise automatic checks and installation of a detected patch
  without a Play tap, rapid edition changes, missing-install action, initial startup configuration, offline retry,
  pending launch cancellation in the background, verified launch callback and
  session-end blocking. No game code executes. The Spanish landscape layout was
  visually inspected using the fixture, with the Play button visible.
- Full integrated Tolkara build for generic iOS ARM64: **BUILD SUCCEEDED**.
  This was an unsigned compile check, with public system roots disabled for this
  test output. A separate private build with the existing development identity
  and `TOLKARA_SYSTEM_ROOTS=YES` also **BUILD SUCCEEDED**; its strict signature,
  unchanged keychain groups and 158 public root certificates were verified.
  Neither build was installed on the phone during this update.
- Full `tools/test_emulation.sh`: **FAIL**, at the previously documented
  `tests.test_sign_guest_local.AdhocTests.test_matches_codesign_byte_for_byte`
  comparison (`sgl-fixture.dylib` differs from `codesign -s -`). This same failure
  was already reproduced on the original base during the iPhone PR review.
  The launcher changes do not modify that signer. This failure remains unresolved.
  Later suite steps do not run after that failure. The focused launcher tests pass independently.

## Reproduce

From the repository root (Xcode and XcodeGen required):

```sh
bash tools/test_wow_launcher.sh
bash tools/test_wow_launcher_ui.sh
bash tools/test_emulation.sh
tools/generate.sh
xcodebuild -project Tolkara.xcodeproj -scheme Tolkara -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/wow-launcher/DerivedData-iOS \
  CODE_SIGNING_ALLOWED=NO TOLKARA_SYSTEM_ROOTS=NO build

# Public metadata only; does not install anything.
build/wow-launcher/wow_cdn wow_classic_beta eu build/wow-launcher/forever

# Downloads encoding metadata and an original file into ignored build output.
build/wow-launcher/wow_cdn wow_classic_beta eu build/wow-launcher/forever \
  --stage 'World of Warcraft Beta.app/Contents/MacOS/World of Warcraft'

# Compile probe only: does not sign or execute a container on a device.
xcrun --sdk iphoneos clang -target arm64-apple-ios17.0 -fobjc-arc \
  -Wall -Wextra -Werror -c tools/sign_guest_local.m \
  -o build/wow-launcher/sign_guest_local-ios.o
```

Generated plans, metadata and original files must stay in ignored `build/`,
or the app's private cache on a device. Never commit or distribute them.
