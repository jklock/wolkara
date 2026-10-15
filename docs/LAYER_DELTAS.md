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

## Contested: 29 paths and their class

| Path | Class | Why |
| --- | --- | --- |
| `project.yml` | layer | Wolkara gets its own `wolkara/project.yml`; the platform's stays upstream and untouched |
| `launcher/App/main.m` | replace | The layer supplies the Wolkara app shell; the platform's entry point stays for platform builds |
| `launcher/App/ExecutionMode.h`, `ExecutionMode.m` | replace | Our shell owns mode glue and branding; upstream's version serves platform builds |
| `launcher/Info.plist` | layer | Wait: this one is ours-only, listed here for contrast - our branded plist lives in the layer |
| `translation/AppKit/AppKit.m` | patch | Touch-controls install, the Control+Option+D trigger in `postKeys:down:`, occlusion reporting in `ak_becameActive:`/`ak_resignedActive:` |
| `translation/AppKit/AppKit.h` | patch | Delegate and notification declarations the layer needs |
| `translation/AppKit/TouchControls.h`, `TouchControls.m` | replace | The layer's own touch/keyboard/dictation module is compiled instead of the platform's |
| `translation/AKSupport/AKSupport.h`, `AKSupport.m` | patch | Our additions; verify the diff is small, otherwise move behind a layer file |
| `translation/Metal/Devices.m` | patch | One call that installs the background frame pacing |
| `translation/IOKit/GPUIdentity.h`, `translation/IOKit/Registry.m`, `translation/IOKit/ldflags` | platform-owned | Both sides added these independently; upstream's `f54662e`/`920b4da` are the maintained versions - drop ours |
| `translation/Metal/MetalTrace.m` | platform-owned | Same: take upstream's version |
| `tests/test_gpu_identity.m` | platform-owned | Upstream's test matches upstream's implementation |
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
| `translation/AppKit/ldflags` | patch | Re-export additions the layer's files need |
| `LICENSE` | layer | Our notice; the platform's stays under `platform/` |
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
(`runtime/NativeGuest.h`, `NativeGuest.m`); the MegaBonk profile and the
`profiles/*` fixes; the pointer/touch fixes in `translation/AppKit/AppKit.m` and
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
