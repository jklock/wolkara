# Pre-split baseline

Recorded on the pre-split state: branch `feature/wolkara-above-tolkara`, tagged
`wolkara-pre-layer`, pinned upstream `00a8501`. The layer split must reproduce
every result below exactly, including the one accepted failure.

## Environment

| Item | Value |
| --- | --- |
| macOS | 26.7.1 |
| Xcode | 27.0 (27A266a) |
| Simulator | `iPad Pro 13-inch (M5)` present |

## Suites

| Command | Result |
| --- | --- |
| `tools/test_wow_launcher.sh` | exit 0; 5 PASS (manifest, client, installation, updater, verification) |
| `tools/test_translation_sim.sh` | exit 0; 3 PASS (online displays, audio property API, AppKit views including the touch controls and the guest font class) |
| `tools/test_emulation.sh` | exit 1; 62 PASS lines, and one Python failure (below) |

### The one accepted failure

`tests/test_sign_guest_local.py::AdhocTests::test_matches_codesign_byte_for_byte`
fails: the signer's output for `sgl-fixture.dylib` differs byte for byte from
`codesign -s -` (test_sign_guest_local.py:898).

It is pre-existing and not ours:

- the file is **not** in our change set (our 109 changed files do not include it);
- its last change is upstream's `4e63855` *Local signing: harden the signed-image
  backend and signer after review*;
- the docs already disagree about it - `docs/WOW_LAUNCHER.md` carries both a FAIL
  ("signing-test failure") and a later PASS ("no longer reproduces") claim, and
  `docs/TOUCH_INPUT.md` still carries the FAIL version. That contradiction is a
  Phase 6 item.

Most likely it depends on this machine's `codesign` (Xcode 27.0). Phase 6 either
records it as environment-dependent or fixes the signer; either way the split must
not change it.

## Device checks (pre-split, verified in this session)

| Check | Evidence |
| --- | --- |
| WoW reaches the login screen | screenshot; `constants: arena result=1`, 13302 initializers, `entering original main` |
| Truncated CASC index generation is repaired | `[host] CASC index 0b0000004e.idx was truncated; rewrote it from 0b0000004d.idx` then a clean `Tact.log` bind |
| Dictation trigger opens the draft keyboard | `[ak] draft keyboard requested from the guest`, `system keyboard shown draftFirstResponder=1` |
| Hardware keyboard diagnosis | `[ak] hardware keyboard attached`, `software keyboard keys are not on screen (height 0 ...)` and the draft label hint |
| Background survival | switch to Messages and back: pacing logged both ways, no CPU report, one `arena result`, session interactive; plus a six-minute soak in the background |

## The gate for every later phase

1. `tools/test_wow_launcher.sh` and `tools/test_translation_sim.sh`: exit 0.
2. `tools/test_emulation.sh`: same 62 PASS and the same single accepted failure.
3. Device checks above, repeated on the installed app with the same bundle id.
4. `wolkara/tools/check_layers.sh` (new): platform pristine, patches apply,
   source coverage complete, no cross-module reach-in.
