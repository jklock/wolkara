# Pre-split baseline

> **Historical record.** This page describes the pre-split state and is kept as evidence.
> It is not current guidance - see [the documentation index](README.md) for the live
> documents. A bare `tools/<script>` below is a pre-split path; the layer's scripts are
> in `wolkaraforever/tools/`, the platform's in `platform/tools/`.

Recorded on the pre-split state: branch `feature/wolkaraforever-above-tolkara`, tagged
`wolkaraforever-pre-layer`, pinned upstream `00a8501`. The layer split must reproduce
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
| `tools/test_emulation.sh` on the pristine `platform/` | **aborts** (SIGABRT) at the first `tests/test_bc_textures` run - which is what patch 0001 fixes |
| `tools/test_emulation.sh` on the prepared tree (patches 0001-0007 applied) | 59 PASS and the one accepted codesign failure below; the generic builds link; all three BC runs PASS |

The abort is upstream's native-GPU assertion (`tests/test_bc_textures.m:87`,
`assert(worst <= allowed)` in `referenceDecoding`): BC1, BC2, BC3 and BC6 match the
CPU decode exactly, BC4/BC5 sit inside the documented half-step, and **BC7 differs
by 255.0 steps** on this Mac's GPU.

**Diagnosed in Phase 2** (see `docs/GPU_SUPPORT.md` for the measurements): the
difference is not a decode error on either side. `randomBlocks` deliberately forces
one BC7 block in nine into the format's *reserved* mode (a zero first byte), whose
decoded value the BC7 specification leaves undefined - and the test then requires
the CPU decoder and the GPU to agree on it. On this M1 the GPU answers alpha 1.0 for
such a block and the CPU decoder answers alpha 0.0, which is exactly the 255.0 step
difference. All **eight defined BC7 modes decode bit-exactly** against Apple's
hardware here (0.000 steps, through both `texture.read()` and a nearest sampler, in
shared and default storage), so the fallback decoder is correct.

Our fix is `wolkaraforever/patches/0001-bc7-reserved-mode-not-comparable.patch`: generate
only the eight defined modes for the cross-check (the reserved mode's robustness is
still covered by `tests/test_bc_decode.c`), and make `TOLKARA_BC_FALLBACK=off`
actually run the comparison instead of printing PASS without measuring anything.
With the patches applied all three runs PASS, so the platform BC test joins the gate
as a required pass rather than an accepted abort. `wolkaraforever/patches/0002` logs the
host's BC capability once per run so every device reports it.

Both patches are upstream candidates (Phase 7).

## The gate for every later phase

1. `tools/test_wow_launcher.sh` and `tools/test_translation_sim.sh`: exit 0.
2. `tools/test_emulation.sh`: same 62 PASS and the same single accepted failure (the
   codesign byte-for-byte comparison). It must not gain or lose any other failure.
3. Platform suite, run against the **prepared tree** (`build/platform`, our patches
   applied): `tools/test_translation_sim.sh` exit 0, and all three
   `tests/test_bc_textures` runs PASS. Inside the pristine `platform/` the native
   comparison still aborts on BC7's reserved mode, which is why patch 0001 exists;
   the prepared tree is the tree we build and test.
4. Device checks above, repeated on the installed app with the same bundle id.
5. `wolkaraforever/tools/check_layers.sh` (new): platform pristine, patches apply,
   source coverage complete, no cross-module reach-in.
