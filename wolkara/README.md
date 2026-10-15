# The Wolkara layer

Wolkara is a layer above tolkara. The platform is vendored at `platform/` and stays
byte-identical to `upstream/main`; everything we add or change lives here, in
`wolkara/`, and reaches the build in exactly two ways: as a **patch** against a
platform file, or as an **overlay** of one of our files.

## What is where

| Path | Contents |
| --- | --- |
| `patches/` | Our changes to platform files, each small, brand-free and an upstream candidate. Every one carries why it exists and its upstream status. |
| `overlay.map` | Which of our files takes which path in the prepared tree, and whether it replaces a platform file or adds a new one. Regenerate with `tools/overlay_map.sh`. |
| `tools/` | `prepare.sh`, `check_layers.sh`, `overlay_map.sh`, and the scripts that build, install, run and test - each prepares the tree and then runs the platform's own script against it. |
| `Shell/` | The app's own shell: entry point, library home, execution-mode glue, branding plist, icon art, the assets catalog, its test. |
| `WoW/` | The launcher for WoW Forever: Client, CASC, Updater, Installation, Manifest, UpdateLock, WoWViewController, the add-on manager, their tests and their tools. |
| `Touch/` | On-screen controls: the toolbar, trackpad and gamepad, layout and haptics, the drafts and dictation path, and the adapter's fonts. |
| `Bridge/` | What the patched platform files and the public APIs call into: the background pacing install, the local-service retry engine, and the source of the pending AppKit patch. |

## How the layer reaches the build

`wolkara/tools/prepare.sh` builds `build/platform` and does three things in order:

1. exports `platform/` exactly as pinned;
2. applies `patches/` - a patch that no longer applies stops the run;
3. overlays our files: a `replace` entry must find its platform file, and an `add`
   entry must not collide with one upstream now has. Either mismatch stops the run.

So an upstream ingest cannot silently drop our file or overwrite one of theirs: it
either applies, or it fails loudly and names the path to look at.

The platform's own `project.yml`, shim builder and test scripts then build our app
without knowing the layer exists - which is why we own no fork of them. The app's
project is the platform's project, and our files are simply in the tree.

## Module boundaries

- A module owns its own files and its own tests. `WoW/` must not include `Touch/`
  headers, and `Touch/` must not include `WoW/` headers.
- A shared need goes through `Bridge/`, which is also where a platform file that our
  patches call into belongs.
- `check_layers.sh` fails on cross-module reach-in, on a platform tree that drifted,
  on a patch that does not apply, and on an overlay that no longer matches.
- Nothing here may mention Wolkara *inside* `platform/`: the platform stays brand-free,
  which is what keeps our patches acceptable upstream.

## Building, running, testing

```sh
wolkara/tools/prepare.sh              # platform/ -> build/platform, patched and overlaid
wolkara/tools/check_layers.sh         # the gate
wolkara/tools/generate.sh             # the app's Xcode project in build/platform
wolkara/tools/install.sh              # build, sign and install on the configured iPad
wolkara/tools/run.sh sim              # the loader diagnostics in the simulator
wolkara/tools/package_ipa.sh          # the unsigned generic .ipa for External JIT
wolkara/tools/test_emulation.sh       # the platform suite, then the layer's suites
wolkara/tools/test_translation_sim.sh # the UIKit-backed adapters' tests in the simulator
```

Settings come from the repository root's ignored `local.env` (`wolkara/tools/env.sh`);
none of them are committed. The bundle ID is deliberately unchanged, so an install
replaces the app in place and the device keeps its data.

## Open items

- `Bridge/AppKit.m` is our version of the platform's AppKit adapter and is **not**
  overlaid: it is the source of a pending patch. What is left in it is what genuinely
  needs the adapter itself - swallowing Control+Option+D in `postKeys:down:` to open the
  draft keyboard, and the occlusion notifications a guest window gets when the app is
  switched away. Everything else now lives here: the Touch module stands on its own
  behind the install hook the platform's own `AppKit.m` already provides, so the toolbar,
  the gamepad and the settings sheet work with their file untouched.
- That hook has one thing worth knowing: the platform's adapter implements six of our
  ten delegate methods, so the four we added are `@optional` and guarded. Dictation's
  Replace is one of them and needs our adapter back before it does anything.
- The two touch fixtures still block headless unless run with `--self-test`.
