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

**D4. Metal API level (follows from D2).** The device floor has no Metal 4 (needs Apple7), so the engine uses the
Metal 3-era API and Apple5 features only, behind a small GPU protocol so a Metal 4 path can come later.

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
