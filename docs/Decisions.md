# Decisions

Decided items carry the date and who decided. Open items carry a recommendation. When an item is decided, move it
up and say why; larger ones become an ADR under `docs/adr/` once code exists.

## Decided

**D2. Device floor (owner, 2026-11-25).** The oldest devices are whatever iOS 27 supports: iPhone 11 family and
iPhone SE (2nd gen) (A13, Apple6), and on iPad the A12Z iPad Pros (Apple5) and iPad (9th gen) (A13, 3 GB). Test
devices: iPad (9th gen) as the performance and battery floor, iPhone SE (2nd gen) for the small screen, iPad Pro
12.9" (4th gen) as the feature and fill-rate floor, the newest iPhone Pro for ProMotion. See
`research/device-floor.md`.

**D3. Idle frame pacing (owner, 2026-11-25).** The engine may skip frames whenever the skip is not visible: render
on demand when nothing on screen changes, and lower the rate while only slow ambience moves. Proposed policy in
`research/performance-and-power.md` section 2; tests E-RATE-1..4.

**D4. Metal API level (owner, 2026-11-25: "stay up to date, but if there is no improvement, stick with Metal 3").**
The engine uses the Metal 3-era API and Apple5 features only, behind one small internal GPU protocol so a Metal 4
back end can be added without touching the rest. Why Metal 4 brings no improvement here:
- Its gains are lower CPU encode overhead (command allocators, argument tables, residency sets, explicit barriers)
  and faster, controllable pipeline compilation (`MTL4Compiler`, flexible pipelines). This engine plans 8 or fewer
  draws per frame (E-BATCH-1) with a CPU encode budget of 2 ms or less (D-GPU-1), and fewer than 10 pipelines, all
  built asynchronously at launch within 50 ms (E-PSO-3). There is nothing measurable to win, and in exchange
  resource lifetimes and synchronisation become manual.
- WWDC26's Metal additions (ML and tensors, MetalFX) do not apply to a 2D sprite renderer.
- Metal 4 needs Apple7 (A14/M1). The D2 floor (iPhone 11 family, SE 2nd gen, iPad 9th gen, A12Z iPad Pros) cannot
  run it, so adopting it means dropping those devices or maintaining two back ends and two GPU test surfaces.
- The Metal 3 API is not deprecated; Apple designed Metal 4 to coexist with it.

Staying current: OS features that are not Metal 4-only (for example iOS 27's `MetalFrameRateMetric` and
`StateReporting`) are adopted as they come. Revisit Metal 4 when (a) every supported device is Apple7 or later
(the iOS release that drops the A13 and A12Z), or (b) device measurement shows CPU encode or pipeline compilation
is a real cost.

**D5. Repos (owner, 2026-11-25).** The engine lives in this repo (`hearth-engine`), game-agnostic. IdleVillage
keeps the adapter (manifests to engine calls, `GameState` to frame description, hit testing, SwiftUI bridge) and
the village kit's corpus export (`make asset-corpus`, owner yes 2026-11-25). The engine vendors a pinned corpus
version as a test resource.

## Open

**D1. Where compositing happens (owner).** Recommendation: **linear light**. Sprites rendered with Blender's
Standard view and no look (today the kit bakes "Medium Contrast"); the look moves into the in-game LUT; textures
`_srgb`, premultiplied in linear; an `rgba16Float` scene attachment (memoryless, read in the same pass by the final
grade-encode-dither stage through programmable blending, so still one render pass); `bgr10a2Unorm` or `bgra8Unorm`
drawable tagged sRGB. Why: it matches Blender's own full render on soft edges and glow, which the art is judged
against. The alternative keeps today's kit convention (composite in sRGB display values) and needs no kit change,
but deviates from Blender on partial alpha and glow. The kit's layers gate changes with the choice.
Test that settles it: E-COL-5 (Blender oracle). See `research/image-quality.md` section 0.

**D6. Asset delivery format (owner; kit changes in IdleVillage).** Recommendation: pre-sized outputs per scale
(@2x and @3x, re-rendered by Blender where affordable), offline mips (linear, premultiplied, Lanczos/Mitchell,
clamped), ground tiles rendered at native resolution and painted 1-2 px past the diamond, our own container
(KTX2 with premultiplied and colour-space flags), ASTC 4x4 gated by FLIP/PSNR/alpha checks with an uncompressed
fallback for glow, fog and gradients. Replaces today's single 512 px PNG per asset and 1 px/pt tiles.

**D7. Ground drawing.** Recommendation: opaque quads clipped by diamond geometry with shared integer-derived
vertices (no alpha on internal edges); a baked ground layer per chunk as the fallback if overdraw or seams fail.

**D8. Golden-image convention in IdleVillage.** The game repo has no snapshot tests today. Before its first
consumer golden test (C-COMP-1) it needs a Conventions entry or ADR: offscreen render, frozen dither, references per
GPU family, two tolerance tiers, human-approved baselines.

**D9. Display link.** Recommendation: `CAMetalLayer` + `CAMetalDisplayLink` (Apple's recommended pacing path) with a
`CADisplayLink` fallback behind a switch, because Unity saw `CAMetalDisplayLink` hang on older iOS after a
command-buffer timeout.

**D10. Budgets.** Proposed numbers in `TestCatalogue.md` *Device suite*; confirm them once the first benchmark
scene runs on the iPad (9th gen).

**D11. Wide colour and EDR.** Recommendation: not in v1. Output tagged sRGB; revisit P3 or EDR for glow later
(the iPad (9th gen) has no P3 at all).
