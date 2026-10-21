# Layer deltas: Wolkara against tolkara

This is the single source of truth for the split of Wolkara into a layer above
tolkara. It records what we changed, what upstream changed, where the two ran over
each other, and the class each path gets in the layer split.

## Pins

| Item | Value |
| --- | --- |
| Our branch | `feature/wolkara-above-tolkara` (fork of the pre-split state, tagged `wolkara-pre-layer`) |
| Merge base with upstream | `05035cc` *Document confirmed iPhone keyboard and trackpad use* |
| Pinned upstream | `00a8501` *Compatibility: WoW Forever water renders on the iPad Pro M5* (`upstream/main`) |
| Our side | 37 commits, 109 files, +9737 / -356 |
| Upstream side | 30 commits, 107 files, +9737 / -580 |

Reproduce these numbers:

```
git rev-parse --short upstream/main
git --no-pager log --oneline --no-merges upstream/main..main | wc -l
git --no-pager log --oneline --no-merges main..upstream/main | wc -l
git --no-pager diff --name-status --no-renames 05035cc..main
git --no-pager diff --name-status --no-renames 05035cc..upstream/main
```

Both sides only add and modify files: neither deletes anything (`D` count is 0 on
both sides), so the split never has to resurrect or retire a path.

## The four quadrants

| Quadrant | Files | What happens in the split |
| --- | --- | --- |
| Contested: both sides modified | 29 (24 modified, 5 added by both) | Decided one by one below - the only real work |
| Ours only: we added | 64 | Move into the layer modules |
| Ours only: we modified a platform file | 16 | Patch, replace, or drop |
| Upstream only | 83 (63 added, 20 modified) | Arrives with the vendored platform, free |

`0e244e1` ("primary commits and updates") is **ours**, not upstream work: 24 files,
the add-on manager plus that session's AppKit and Metal device changes. It is not a
rebase hazard.

## The measured delta set

The quadrants above count *commits* that touched a path, so a path both sides touched
but where the two ended up with the same bytes is counted as contested. Measured on
2026-10-15 by comparing our working tree with the pinned platform:

| Measure | Count |
| --- | --- |
| Paths we share with `platform/` | 455 |
| ...byte-identical to the pin, so deleting our copy loses nothing | 398 |
| ...differ from the pin - the real delta set | **57** |
| ...changed lines across those 57 | ~4034 |
| Paths with no counterpart in `platform/` (layer candidates) | 71 |

By area: `tools/` 8, root files 8, `profiles/` 7, `launcher/` 7, `translation/` 6,
`tests/` 6, `docs/` 5, `authorization/` 5, `runtime/` 4, `.github/` 1. Only the
`translation/`, `runtime/` and `authorization/` groups are platform code, so the part
that needs patches or layer replacements is 15 files.

A whole class of rows in the tables above turned out to need no work at all:
`translation/AKSupport/AKSupport.{h,m}`, `translation/AppKit/AppKit.h`,
`translation/IOKit/{GPUIdentity.h,Registry.m,ldflags}`, `translation/Metal/MetalTrace.m`
and `tests/test_gpu_identity.m` are already byte-identical to the pin.

The 57 paths:

```
.github/workflows/release.yml
.gitignore
AGENTS.md
COMPATIBILITY.md
LICENSE
NOTICE.md
README.md
authorization/App/Integrated-Info.plist
authorization/App/LocalAuthorization.h
authorization/App/LocalAuthorization.m
authorization/Tunnel/LocalPacketProvider.m
authorization/Tunnel/PacketServiceProbe.swift
docs/ARCHITECTURE.md
docs/BUILDING.md
docs/IPHONE.md
docs/TOUCH_INPUT.md
launcher/App/AppLibrary.h
launcher/App/AppLibrary.m
launcher/App/ExecutionMode.h
launcher/App/ExecutionMode.m
launcher/App/LibraryViewController.m
launcher/App/main.m
launcher/Info.plist
local.env.example
profiles/README.md
profiles/wow-classic-era/README.md
profiles/wow-classic-era/install.py
profiles/wow-classic-era/profile.json
profiles/wow-forever/README.md
profiles/wow-forever/install.py
profiles/wow-forever/profile.json
project.yml
runtime/GuestFixups.c
runtime/GuestStubs.m
runtime/NativeGuest.h
runtime/NativeGuest.m
tests/test_app_library.m
tests/test_appkit_views.m
tests/test_execution_mode.m
tests/test_fixups.c
tests/test_profile.py
tests/test_touch_controls_app.m
tools/build_emulated_guest.sh
tools/build_shims.py
tools/check_profile.py
tools/generate.sh
tools/install.sh
tools/package_ipa.sh
tools/test_emulation.sh
tools/test_touch_controls_ui.sh
translation/AppKit/AppKit.m
translation/AppKit/TouchControls.h
translation/AppKit/TouchControls.m
translation/AppKit/ldflags
translation/CoreAudio/Hardware.m
translation/Metal/Devices.m
```

Reproduce this set:

```sh
comm -12 <(git ls-files | grep -v '^platform/' | sort) \
         <(git ls-files platform/ | sed 's|^platform/||' | sort) > /tmp/shared.txt
while read -r f; do
    [ "$(git hash-object "$f")" = "$(git rev-parse "HEAD:platform/$f")" ] || echo "$f"
done < /tmp/shared.txt
```

## Progress: seven patches, six paths that need nothing (2026-10-15)

Every delta was worked through by merging our changes onto the pin (base = `05035cc`,
ours = `HEAD`, theirs = `HEAD:platform`), never by diffing our file against the pin:
our copies predate upstream's newer edits to the same files, so a plain diff would
have reverted those edits instead of expressing our change.

Seven patches now carry the platform-side changes, and the platform suite in the
prepared tree is green: 59 PASS plus the one accepted codesign failure, with the
generic builds linking.

| Patch | Paths | Why |
| --- | --- | --- |
| 0001 | `tests/test_bc_textures.m` | BC7's reserved mode has no defined decode, so it cannot be compared; `off` now really measures instead of printing PASS |
| 0002 | `translation/Metal/BCTextures.m` | log the host's BC capability once per run |
| 0003 | `runtime/GuestFixups.c`, `tests/test_fixups.c` | a rebase program may end exactly at `rebase_size` with no DONE opcode |
| 0004 | `runtime/GuestStubs.m` | write down why an existing class wins, and the NSFont trap that follows |
| 0005 | `translation/CoreAudio/Hardware.m` | keep the audio session alive across an app switch |
| 0006 | `authorization/App/LocalAuthorization.{h,m}` | retry the local service when its first connection fails |
| 0007 | `authorization/Tunnel/LocalPacketProvider.m`, `PacketServiceProbe.swift` | retire a failed probe, keeping the old tuple reserved |

Six paths in the list above need no work, because our copy is already upstream's:

| Path | Why nothing is needed |
| --- | --- |
| `runtime/NativeGuest.h`, `runtime/NativeGuest.m` | upstream already carries our changes |
| `tests/test_app_library.m`, `tests/test_profile.py` | the same |
| `translation/Metal/Devices.m` | our copy only *removed* upstream's BC fallback install; taking upstream's restores it, and the layer installs the background pacing itself |
| `translation/AppKit/ldflags` | the AKFont alias is a build setting of whatever compiles the adapter: the platform's generic builds have no AKFont, and aliasing it there breaks their link (measured: two link errors) |

Of what is left, ten paths are carried by the patches above, three are the Phase 3
files, and the rest are our own content - root documents, profiles, tools, the
launcher shell and our tests - which moves into the layer or stays at the root.

Deliberately left for Phase 3: `translation/AppKit/AppKit.m` and
`translation/AppKit/TouchControls.{h,m}`. Our AppKit delta is 21 hunks and about 200
lines mixing NSView emulation (autoresizing masks, subview ordering, `setHidden:`),
the touch host wiring, dictation Replace, pointer handling and diagnostics - while
upstream has since rewritten its own touch controls and installs them through an API
our class already provides (`+enabled`, `trackpadEnabled`, `cancelTouches`,
`processTouches:withEvent:`, `AKTouchControlsDelegate`). The patch has to be derived
against the layer's TouchControls API, which Phase 3 creates; deriving it first would
mean writing it twice.

## Contested at commit level: 29 paths and their class

These are the paths *commits* on both sides touched. Being touched by both is not the
same as differing now - see "The measured delta set" below for what actually differs.

| Path | Class | Why |
| --- | --- | --- |
| `project.yml` | layer | Wolkara gets its own `wolkara/project.yml`; the platform's stays upstream and untouched |
| `launcher/App/main.m` | replace | The layer supplies the Wolkara app shell; the platform's entry point stays for platform builds |
| `launcher/App/ExecutionMode.h`, `ExecutionMode.m` | replace | Our shell owns mode glue and branding; upstream's version serves platform builds |
| `launcher/Info.plist` | layer | Our branded plist, with `UIBackgroundModes: [audio]` and the microphone usage string; the platform's stays under `platform/` |
| `translation/AppKit/AppKit.m` | patch | Touch-controls install, the Control+Option+D trigger in `postKeys:down:`, occlusion reporting in `ak_becameActive:`/`ak_resignedActive:`. **Re-derived in Phase 3** - see "Progress: seven patches" above for why, and for what upstream's rewritten version already gives us |
| `translation/AppKit/AppKit.h` | platform-owned | Measured 2026-10-15: our copy is byte-identical to the pin, so there is nothing to patch |
| `translation/AppKit/TouchControls.h`, `TouchControls.m` | replace | The layer's own touch/keyboard/dictation module is compiled instead of the platform's |
| `translation/AKSupport/AKSupport.h`, `AKSupport.m` | platform-owned | Measured 2026-10-15: byte-identical to the pin, so there is nothing to patch |
| `translation/Metal/Devices.m` | patch | One call that installs the background frame pacing |
| `translation/IOKit/GPUIdentity.h`, `translation/IOKit/Registry.m`, `translation/IOKit/ldflags` | platform-owned | Measured 2026-10-15: our copies already equal upstream's, so dropping ours is a no-op |
| `translation/Metal/MetalTrace.m` | platform-owned | Measured 2026-10-15: already identical to upstream's |
| `tests/test_gpu_identity.m` | platform-owned | Measured 2026-10-15: already identical to upstream's |
| `tests/test_appkit_views.m`, `tests/test_touch_controls_app.m` | platform-owned + new layer tests | Upstream's assert the platform's two-button layout; the layer ships its own fixtures for its toolbar, drafts and dictation |
| `tests/test_execution_mode.m` | platform-owned + new layer test | Mode machinery is platform; the layer tests its own glue |
| `tools/test_emulation.sh` | patch | Add the layer's suites to the run |
| `README.md`, `COMPATIBILITY.md`, `NOTICE.md`, `docs/BUILDING.md`, `docs/IPHONE.md`, `docs/TOUCH_INPUT.md`, `profiles/wow-forever/README.md`, `local.env.example`, `.github/workflows/release.yml` | layer | Root-level documents, profiles, settings contract and CI belong to the repository we own; upstream's live untouched under `platform/` and are merged in by hand when their content matters |

## Ours only: 16 platform files we modified (upstream never touched)

| Path | Class | Why |
| --- | --- | --- |
| `translation/CoreAudio/Hardware.m` | patch | `keepSession`/`observeSession`: the audio session that keeps a backgrounded guest alive |
| `runtime/GuestFixups.c`, `runtime/GuestStubs.m` | patch | Our 15-line runtime delta |
| `authorization/App/Integrated-Info.plist` | layer | The layer compiles against its own branded plist |
| `authorization/App/LocalAuthorization.h`, `LocalAuthorization.m`, `authorization/Tunnel/LocalPacketProvider.m`, `authorization/Tunnel/PacketServiceProbe.swift` | patch | LocalServiceRetry wiring - a good upstream contribution candidate |
| `launcher/Info.plist` | layer | Branded plist with `UIBackgroundModes: [audio]` and the microphone string |
| `tools/generate.sh`, `tools/install.sh`, `tools/package_ipa.sh`, `tools/test_touch_controls_ui.sh` | layer | The layer's own wrapper scripts under `wolkara/tools/` |
| `translation/AppKit/ldflags` | layer | The AKFont alias is a build setting for the target that compiles the adapter, not a platform change: the platform's own generic builds carry no AKFont and fail to link if it is aliased there |
| `LICENSE`, `NOTICE.md` | layer | Our licence and notice, and only from 2026-10-16: they reach the app as `Wolkara-LICENSE` and `Wolkara-NOTICE.md`, because the prepared tree already has upstream's files under the bare names and both sets have to ship. The app had been showing upstream's documents under our attribution. |
| `tests/test_fixups.c` | patch | Follows the runtime delta |

## Ours only: 64 additions, by module

| Module | Files |
| --- | --- |
| `wolkara/WoW` (launcher, updates, add-ons) | 17 files under `launcher/WoW/`, plus `tools/wow_cdn.m`, `profiles/wow-forever/sync_addons.sh`, `tests/test_wow_{client,installation,manifest,update,verification}.m`, `tests/wow_installation_fixture.h`, `tests/test_wow_launcher_app.m`, `tools/test_wow_launcher.sh`, `tools/test_wow_launcher_ui.sh`, `docs/WOW_LAUNCHER.md`, `docs/ADDON_MANAGER_PLAN.md` |
| `wolkara/Touch` | `translation/AppKit/{Fonts.h,Fonts.m,TouchGamepad*,TouchGamepadLayout*,TouchHaptics*}`, `translation/Metal/BackgroundPacing.m`, `tests/test_touch_gamepad_app.m`, `tools/test_touch_gamepad_ui.sh`, `docs/TOUCH_CONTROLLER_PROPOSAL.md`, `docs/TOUCH_INPUT.md` |
| `wolkara/Shell` | `launcher/Assets.xcassets/Wolkara.appiconset/*`, `artwork/wolkara/*`, `tools/make_wolkara_icon.py`, `docs/{GETTING_STARTED,WOLKARA_DISTRIBUTION,FRESH_INSTALL_TEST}.md` |
| `wolkara/Bridge` | `authorization/App/LocalServiceRetry.{h,m}`, `tests/test_local_service_retry.m`, `tools/test_local_service_retry.sh`, `tests/test_packet_service_retry.swift` |

## Upstream only: arrives with the pinned platform

83 paths, notably: all 34 `management/` files (the Mac setup app) plus
`docs/MANAGEMENT.md`; `launcher/Cloud/*` (Steam Cloud) with `tests/test_steam_cloud.m`;
the BC texture fallback (`translation/Metal/{BCDecode.c,BCDecode.h,BCTextures.m}`,
`tests/bc_gpu_reference.h`, `tests/test_bc_decode.c`, `tests/test_bc_textures.m`);
the build work (`tools/{embed_vulkan_runtime,shim_stubs}.py`, adapter dependency
resolution in `tools/build_shims.py`, `tests/test_shim_dependencies.py`,
`tests/test_shim_stubs.py`); runtime write-flush and exit-observer logging
(`runtime/NativeGuest.h`, `NativeGuest.m`); the `profiles/*` fixes; the
pointer/touch fixes in `translation/AppKit/AppKit.m` and
`AppKit.h` - which is exactly why those two files are patches for us.

## Patch budget

Patches are the contribution pipeline, so they stay small and brand-free:

| Patch | Files touched |
| --- | --- |
| Touch, keyboard and dictation hooks | `translation/AppKit/AppKit.{h,m}`, `translation/AKSupport/AKSupport.{h,m}`, `translation/AppKit/ldflags` |
| Background survival | `translation/CoreAudio/Hardware.m`, `translation/Metal/Devices.m` |
| Runtime delta | `runtime/GuestFixups.c`, `runtime/GuestStubs.m`, `tests/test_fixups.c` |
| Local service retry | `authorization/App/LocalAuthorization.{h,m}`, `authorization/Tunnel/{LocalPacketProvider.m,PacketServiceProbe.swift}` |
| Test entry point | `tools/test_emulation.sh` |

Hard rule: if the set grows past five files or about 150 lines in any one patch,
move the behaviour behind a layer-owned file or land the change upstream first.
