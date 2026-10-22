# WolkaraForever documentation

This folder holds the fork's own documentation. The vendored upstream engine keeps
its own, unchanged, under `platform/docs/`; anything in this folder describes
WolkaraForever - the WoW launcher, the mobile input layer and the layer split - or the
fork's view of the engine.

New here? Read the repository [README](../README.md), then
[From zero to playing](FROM_ZERO.md) for the complete setup walkthrough (or the
[condensed route](GETTING_STARTED.md)), then the
[in-app guide](USING_WOLKARAFOREVER.md).

## Using the app

| Document | What it covers |
| --- | --- |
| [README](../README.md) | The single front page: requirements, build, enroll, install, play, update, troubleshoot. |
| [FROM_ZERO.md](FROM_ZERO.md) | The complete, checkpointed walkthrough from a bare Mac to playing, with troubleshooting. |
| [GETTING_STARTED.md](GETTING_STARTED.md) | The condensed route: clone, `local.env`, Xcode run, one-time enroll, install an edition. |
| [USING_WOLKARAFOREVER.md](USING_WOLKARAFOREVER.md) | The in-app guide: home, add-ons, Performance & UI, voice, settings, recovery. |
| [FRESH_INSTALL_TEST.md](FRESH_INSTALL_TEST.md) | Clean-device acceptance checklist for a first full download. |
| [WOW_LAUNCHER.md](WOW_LAUNCHER.md) | Launcher and updater: editions, download, verification, resume, updates. |
| [TOUCH_INPUT.md](TOUCH_INPUT.md) | On-screen toolbar, keyboard, trackpad, draft and dictation. |
| [TOUCH_CONTROLLER_PROPOSAL.md](TOUCH_CONTROLLER_PROPOSAL.md) | The on-screen controller: layout, customization, HUD. |
| [CONTROLLER_INPUT.md](CONTROLLER_INPUT.md) | Physical controller support and the inspector. |
| [INPUT_TRIGGERS.md](INPUT_TRIGGERS.md) | Trigger modes, key mapping and ownership. |
| [VOICE.md](VOICE.md) | Voice dictation: modes, auto-submit, verification, crash history. |
| [IPHONE.md](IPHONE.md) | The experimental iPhone path and mobile-data notes. |
| [COMPATIBILITY.md](../COMPATIBILITY.md) | Dated device results; what was measured, and where. |

## Developing

| Document | What it covers |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The loader, the translation layer and the three execution modes. |
| [BUILDING.md](BUILDING.md) | Advanced engine build and execution modes; development runs on the iPad. |
| [MAINTAINING.md](MAINTAINING.md) | How the layers fit; how to update Tolkara, the app and the game safely. |
| [TESTING.md](TESTING.md) | The suites, the device matrix, the self-tests and how evidence is recorded. |
| [TOOLING.md](TOOLING.md) | Every script in `wolkaraforever/tools/`, its arguments and environment. |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | Ground rules and workflow. |
| [../SECURITY.md](../SECURITY.md) | Reporting a vulnerability and what is in scope. |
| [../NOTICE.md](../NOTICE.md) | Licences and third-party notices. |
| [WOLKARAFOREVER_DISTRIBUTION.md](WOLKARAFOREVER_DISTRIBUTION.md) | Distribution channels and the rollout recommendation. |
| [GPU_SUPPORT.md](GPU_SUPPORT.md) | BC texture support and the Metal path. |
| [LOCAL_AUTHORIZATION.md](LOCAL_AUTHORIZATION.md) | The developer-service protocol, with its engineering history. |
| [ADDON_MANAGER_PLAN.md](ADDON_MANAGER_PLAN.md) | How the add-on manager works and where its code lives. |

## Historical records

These describe a past state. They are kept because they are evidence; do not treat them
as current guidance. Each begins with a banner naming what it was true of.

| Document | What it records |
| --- | --- |
| [LAYER_BASELINE.md](LAYER_BASELINE.md) | The measurements taken before the layer split. |
| [LAYER_DELTAS.md](LAYER_DELTAS.md) | The authoritative delta set of the layer split. |
| [../PERFORMANCE_UI_PLAN.md](../PERFORMANCE_UI_PLAN.md) | The plan for the boxed home page and Forever UI, since shipped. |
| [../development/validation/](../development/validation/) | Per-commit validation records written by `validate.sh`. |

## The layer split, in one paragraph

The engine is vendored at `platform/`, byte-identical to `upstream/main`, and is never
edited by hand. Everything the fork adds or changes lives in `wolkaraforever/` and
reaches the build in exactly two ways: as a **patch** against a platform file
(`wolkaraforever/patches/`) or as an **overlay** of one of our files
(`wolkaraforever/overlay.map`). `wolkaraforever/tools/prepare.sh` exports `platform/` to
`build/platform/`, applies the patches, then copies the overlay into place.
`wolkaraforever/tools/check_layers.sh` is the gate that keeps the split honest. The
layer's own README, at [`wolkaraforever/README.md`](../wolkaraforever/README.md), is the
short version of this.
