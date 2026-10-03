# Experimental WoW launcher

Branch: `feature/wow-launcher`, based on `feature/iphone-support` at
`05035ccbbf33565ab36abdb1d5e43a6b53cc816b`. This is an early, working prototype,
not a complete replacement for Battle.net. The existing runtime and execution
modes are unchanged. No game files, signing identities or accounts are bundled.

## Available now

The **WoW** button in Tolkara's library opens a native edition selector:
Forever Beta, Classic Era, Classic, Retail and Retail Beta. It remembers the
selected product, region and download language. Forever currently corresponds
to `wow_classic_beta`; this channel is not assumed to be a permanent product ID.

- Checks the selected channel on opening the screen and returning to it.
- Queries Blizzard's public HTTPS version/CDN services without Battle.net or
  an account. A failed check is an error, never interpreted as “up to date”.
- Downloads the build configuration and installation manifest, verifies their
  content hashes, decodes BLTE, and filters macOS/ARM64/region/language tags.
- Can download the original WoW executable into **temporary staging storage**.
  It uses the encoding manifest to resolve content hashes and verifies the
  original bytes. This does not install an executable or make a game playable.
- **Play imported copy** checks the latest metadata again, requires the
  imported copy's `.build.info` to match the product, active build, CDN config
  and version, and hashes its original executable against the manifest before
  passing it to Tolkara's existing launch path. Missing metadata, a patch,
  a failed request or an executable mismatch blocks this launch.

The imported installation must already exist in Tolkara's library, with the
usual `World of Warcraft/_<edition>_/…` layout and `.build.info` in its parent.
This check does not audit every CASC data block. Other entries in Tolkara's
original library retain their existing behaviour: this is an opt-in prototype,
not a global update gate. Edition visibility does not establish runtime support.

Only English (`enUS`) and Spanish (`esES`) are exposed in the prototype UI.
Download preferences do not edit `WTF/Config.wtf`, the portal, account data,
addons or existing game files. Errors and cancellation leave the installation
alone. Temporary, verified metadata may remain cached after cancellation.

## Implementation

`launcher/WoW/Manifest.m` reads the text metadata, BLTE, install and encoding
formats. It bounds lengths and decompression, checks encoded/chunk/content
hashes, rejects unsafe paths and unsupported encrypted extraction, and does
not inspect application code. `Client.m` provides bounded HTTPS transfers with
timeouts, cancellation, no credentials/cookies, no redirects and no HTTP
fallback. A changed published build invalidates an extraction plan. Encoding
metadata is cached by content hash and reverified before reuse.

`WoWViewController.m` is the UIKit interface. A generation counter prevents
late responses for a previously selected edition from updating the current
screen. Background transfers do not run UIKit or start a guest. The public
protocol source reference is [TACTSharp](https://github.com/wowdev/TACTSharp);
its adapted format readers and MIT licence are acknowledged in `NOTICE.md`.
The app uses Foundation and system zlib, with no embedded .NET runtime.

## What is not implemented

1. **Complete installations and patching.** The install manifest describes
   loose client files, not the tens of gigabytes of game data. Download-manifest
   selection, CDN archive/range lookup, local CASC index/container construction,
   resumable downloads, storage budgeting and atomic installation switching
   are still required. A successful manifest or executable download never sets
   an installation to complete. Some files may require archive lookup;
   the tested Info.plist request returned HTTP 403 and is reported as a failure.
   Archive lookup is not implemented yet, so its availability through an archive
   was not established by this test.
2. **Automatic mandatory updates.** The new Play action blocks outdated copies,
   but cannot yet repair them. No old files are removed. Existing Mac-to-iPhone
   copying remains necessary to update a playable installation.
3. **Removing per-launch memory preparation.** Developer service still prepares
   a fresh executable arena for each process. Caching downloads cannot eliminate
   this. Local signing remains the candidate route for reusing prepared code.
4. **Self-contained Local signing on iPhone.** The existing local signer compiles
   for iOS ARM64, but that is not a device signing test. Tolkara still needs a
   supported way to produce final code pages during loading, securely provision
   the user's signing identity, construct/sign its own private page container,
   and verify that iOS accepts it. The executable must remain unchanged. No keys
   were exported, no debugger attached, and no game memory captured in this work.

The next implementation milestone is archive-backed extraction and a complete
CASC installation in an isolated staging directory. Updates should be keyed by
product and build hashes, preserve WTF/Interface, resume verified content, and
switch the active installation only after every required file is verified.
Executable preparation must be a separate recorded stage, invalidated when the
executable or signing requirements change. It must never reuse an incompatible
container or silently fall back to a partially installed build.

## Validation — 2026-10-03

All real CDN requests below were run on the Mac using the **same native client
code** compiled into the iOS app. They do not establish downloads on a physical
iPhone or gameplay with the downloaded copy.

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

- Focused manifest and client tests: **PASS**, `-Wall -Wextra -Werror`, ASan and
  UBSan. Synthetic fixtures cover truncation, bounds, decompression limits,
  checksums, unsafe paths, multi-chunk decoding, tag filtering, cache corruption,
  missing/changed/ambiguous build metadata, protocol failures and HTTPS-only
  selection. No third-party application data is in the tests.
- UIKit fixture: **PASS** on iPhone 17 Pro / iOS 26.5 Simulator. Synthetic
  responses exercise rapid edition changes, plan display and blocked launch
  with no installation. The landscape layout was visually inspected.
- Full integrated Tolkara build for generic iOS ARM64: **BUILD SUCCEEDED**.
  This was an unsigned compile check, with public system roots disabled for this
  test output. It was **not installed on the user's phone**; a private build for
  gameplay still needs the usual signing and system-root settings.
- Full `tools/test_emulation.sh`: **FAIL**, at the previously documented
  `tests.test_sign_guest_local.AdhocTests.test_matches_codesign_byte_for_byte`
  comparison (`sgl-fixture.dylib` differs from `codesign -s -`). This same failure
  was already reproduced on the original base during the iPhone PR review.
  It is not caused or fixed by the launcher changes. Later suite steps do not run
  after that failure. The focused launcher tests pass independently.

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
