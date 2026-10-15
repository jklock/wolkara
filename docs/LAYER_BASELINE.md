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

## The vendored platform on this host

`git subtree add --prefix=platform upstream main --squash` produced a subtree whose
tree hash equals upstream's root tree hash (`1e8d13f1fe089fa32cd84a6b46fe3692e288aeac`),
so `platform/` is byte-identical to upstream `00a8501`: 513 files.

| Platform suite, run inside `platform/` | Result |
| --- | --- |
| `tools/test_translation_sim.sh` | exit 0; 3 PASS |
| `tests/test_bc_textures` with `TOLKARA_BC_FALLBACK=off` | PASS: native BC textures, nothing installed |
| `tests/test_bc_textures` with `TOLKARA_BC_FALLBACK=on` | PASS: guest sees BC formats; replaceRegion, slices, 3D, blit uploads, texture copies, views, heaps handled |
| BC1-BC7 CPU reference decode (inside the same test) | PASS: reference blocks, punch-through, signed, partial blocks, padded rows, mip chains |
| `tools/test_emulation.sh` | **aborts** (SIGABRT) at the first `tests/test_bc_textures` run |

The abort is upstream's new native-GPU assertion (`tests/test_bc_textures.m:87`,
`assert(worst <= allowed)` in `referenceDecoding`): BC1, BC2, BC3 and BC6 match the
CPU decode exactly, BC4/BC5 sit inside the documented half-step, and **BC7 differs
by 255.0 steps** on this Mac's GPU - i.e. the native BC7 path does not decode as
the test expects on macOS 26.7.1 with Xcode 27.0.

This is not ours and not caused by the split:

- `platform/` is byte-identical to upstream, and our pre-split tree never contained
  the BC work at all, so this test ran here for the first time;
- both fallback paths - the ones that matter for the iPads - pass;
- it is host/driver-dependent in the same way as the accepted codesign failure.

Follow-ups (Phase 6 and 7): either teach the test to skip the native comparison
when the GPU reports no BC7 support, or report it upstream as a genuine macOS-beta
finding. Both are contribution candidates.

## The gate for every later phase

1. `tools/test_wow_launcher.sh` and `tools/test_translation_sim.sh`: exit 0.
2. `tools/test_emulation.sh`: same 62 PASS and the same single accepted failure (the
   codesign byte-for-byte comparison). It must not gain or lose any other failure.
3. Platform suite inside `platform/`: `tools/test_translation_sim.sh` exit 0, and the
   BC test's two fallback runs PASS. `tools/test_emulation.sh` there is expected to
   abort at the native BC7 comparison on this Mac, exactly as recorded above.
4. Device checks above, repeated on the installed app with the same bundle id.
5. `wolkara/tools/check_layers.sh` (new): platform pristine, patches apply,
   source coverage complete, no cross-module reach-in.
