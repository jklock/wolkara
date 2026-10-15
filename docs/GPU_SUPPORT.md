# GPU support across the M series

The layer must work on every Apple-silicon device we ship on - M1 through M5 and
later - on both iPadOS and macOS, at whatever OS version each device runs. Nothing
we write may assume a particular GPU generation.

## How we support a GPU: capabilities, never names

The adapter never branches on a device name, a GPU family or an OS version to decide
what a GPU can do. It asks the device:

| Question | Asked through | Where |
| --- | --- | --- |
| Can this GPU sample BC (DXT/BPTC) textures? | `-[MTLDevice supportsBCTextureCompression]` | `translation/Metal/BCTextures.m`, `deviceSamplesBC()` |
| Feature set the caller is testing for | `-[MTLDevice supportsFeatureSet:]` | the Metal adapter's device wrappers |
| Anything else capability-shaped | the matching `MTLDevice`/`MTLTexture` query | as above |

The BC decision is exactly this shape: `TOLKARA_BC_FALLBACK` unset or `auto` engages
the CPU decoder **only** when the device says it cannot sample BC; `on` forces it (for
testing on a device that can); `off` never engages it. A new M-series GPU therefore
needs no code change - it either samples BC natively or the fallback engages.

Device identity is separate from capability. The Metal adapter deliberately reports a
Mac-like GPU to the guest (macOS applications upload BC textures unconditionally), so
the guest is *told* BC is available. What the **host** can really do still governs
whether uploads are decoded on the CPU: the guest-visible answer comes from our
wrapper, the host's answer from Apple's driver.

### Do not read support from a simulator profile

A simulator device called e.g. "iPad Pro 13-inch (M5)" is a *profile*: its Metal
implementation is the Mac's, and its name says nothing about the hardware we ship on.
Support is decided by the measurements below, on real devices.

## Measurements

Recorded 2026-09 on the branch's two hosts:

| Host | `supportsBCTextureCompression` | Evidence |
| --- | --- | --- |
| Mac, Apple M1, macOS 26.7.1 / Xcode 27.0 | YES | probe: `device = Apple M1`, `supportsBC = 1`, unified memory, max buffer 9534832640 |
| iPad, Apple M1, iPadOS 27.0.1 | YES | the fallback never engaged in any recorded session (`Metal BC fallback on: ... cannot sample BC textures` is absent from every log) |

### BC decode accuracy against Apple's M1 hardware

`tests/test_bc_textures.m` compares the CPU decoder with the same GPU that decodes
the texture natively: 256 random blocks per format, largest difference in 8-bit
steps (relative for BC6H). With the layer's patch 0001 applied:

| Format | Largest difference | Note |
| --- | --- | --- |
| BC1, BC2, BC3 | 0.000 | exact |
| BC4, BC4s, BC5, BC5s | 0.500 | expected: the GPU keeps these unrounded, 8-bit storage is within half a step |
| BC6Hs, BC6Hu | 0.000 (relative) | exact |
| BC7 | 0.000 | exact, all eight defined modes |

### The BC7 reserved mode

BC7's mode is encoded by the position of the first set bit of the block's first byte.
A zero first byte selects the **reserved** mode, whose decoded value the specification
leaves undefined. Measured on the M1:

- all eight *defined* modes decode bit-exactly on the GPU, through `texture.read()`
  and through a nearest sampler, in both shared and default storage; the CPU decoder
  matches every one of them (0.000 steps);
- a reserved-mode block is *not* agreed on: the GPU returns alpha 1.0, the CPU decoder
  returns alpha 0.0. That is 255.0 steps, and it is undefined behaviour on both sides,
  not a bug in either.

`randomBlocks` used to force one block in nine into the reserved mode and then require
the two to agree, which is why the test aborted on this OS/driver. Patch 0001
(`wolkara/patches/0001-bc7-reserved-mode-not-comparable.patch`) generates only the
eight defined modes for that comparison; `tests/test_bc_decode.c` still covers that a
reserved block is handled without crashing. With the patch the three runs (auto, off,
forced on) all PASS, and `TOLKARA_BC_FALLBACK=off` now really compares instead of
printing PASS without measuring.

Patch 0002 adds one line to the same decision so every run records the host's answer:
`Metal BC: <device> samples BC textures natively, nothing installed`. That line is the
per-device evidence we want from each M-series device we support.

## Verification on a new M-series device

1. Install and launch; the log must contain exactly one `Metal BC:` line naming the
   device, either `samples BC textures natively, nothing installed` or `Metal BC
   fallback on: ... cannot sample BC textures`.
2. If the device does *not* sample BC, the fallback engages automatically and BC
   uploads are decoded on the CPU - nothing to change, but record the line as the
   device's evidence.
3. In-game checks (the texture-heavy screens of the profile in use) for banding,
   wrong colours or blocky artefacts; BC7-class textures are the sensitive case.

A device that reports BC support but decodes it incorrectly would affect only the
guest's own textures, never the executable we import; `TOLKARA_BC_FALLBACK=on` forces
the CPU path as a workaround without touching code.

## Status

Patches 0001 and 0002 are upstream candidates (Phase 7). Nothing here is
Wolkara-specific: both are corrections to the platform's own BC work, and the log line
is diagnostics the platform wants for itself.
