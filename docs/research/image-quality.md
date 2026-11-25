# Image quality for pre-rendered, soft-lit 2D art

Research of 2026-11-25. The art: Blender Cycles renders, soft-lit, smooth gradients and soft edges; 512x1024 px
building sprites drawn at 80 pt (240 px at @3x, 160 px at @2x); 96x56 px ground diamonds drawn at 96 pt
(magnified 2-3x); additive glow stored as light-as-alpha; a whole-scene grade by LUT; fog; rain; sprite sheets;
rotating and swaying parts.
Legend: **[UV]** = unverified (general knowledge, or a source that could not be opened). Thresholds marked
"proposed" must be calibrated on our own images.

## 0. The decision that drives the rest: where compositing happens

Cycles computes radiance, pixel-filter antialiasing and alpha coverage in **linear light**; the view transform
(Standard, Filmic, AgX, plus a "look") is applied only when the PNG is written, with straight alpha. So the
composite that matches Blender's own full render is: **linear-light premultiplied "over", then the view
transform**. That is exact for the Standard view without a look, and only approximate for AgX, Filmic or a
contrast look, whose curves are non-linear and also shape alpha edges (Blender
https://projects.blender.org/blender/blender/issues/34966, https://developer.blender.org/T93030,
https://projects.blender.org/blender/blender/issues/99186).

Today the village kit renders with view transform "Standard" **and look "Medium Contrast"**, and its layers gate
composites layers in sRGB display values. Two consistent options exist (see `../Decisions.md` D1):

- **A. Linear pipeline (recommended by the research).** Sprites rendered with Standard and no look; the look moves
  into the in-game LUT. Engine: `_srgb` textures, premultiplied in linear light, an `rgba16Float` linear scene
  buffer, one final pass (fog, LUT grade, encode, dither) into the drawable. The kit's layers gate composites in
  linear too. Matches Blender's full render, glow adds like Blender emission.
- **B. Display-space pipeline (today's kit convention).** Keep the baked look; composite in sRGB display values in
  an 8-bit (or 10-bit) buffer. Matches the kit's current layer check exactly, deviates from Blender's full render on
  partial-alpha edges and on glow.

Arbiter test (**Blender oracle**): build one fixed scene in Blender (two buildings, three tiles, one glow) and
render it composited at device pixel size; render the same layout in the engine offscreen; compare with FLIP
(mean ≤ 0.02, 99th percentile ≤ 0.15, proposed).

## 1. Minification (512 px drawn at 240 px)

512 to 240 is about 2.13x, LOD about 1.1: trilinear blends mip 1 and mip 2, and box-filtered mips look soft there.
Quality is decided by how the mips are made more than by the base level.

1. **Pre-size offline** where zoom is fixed or quantized: 240 px (@3x) and 160 px (@2x) per sprite, ideally
   re-rendered by Blender at that size (the true reference), else Lanczos-3 or Mitchell in linear light on
   premultiplied RGBA, drawn 1:1. Mips then matter only for zoom-out. With continuous pinch zoom, a level-0 size
   whose level 1 is the @3x size (480x960 -> 240) [UV that the art takes the 15/16 resize].
2. **Build mips offline**, not with `generateMipmaps` (unspecified filter, probably box [UV]): per level decode sRGB
   to linear, premultiply, downsample from level 0 (not chained) with Kaiser, Lanczos or Mitchell, clamp RGB to
   [0, α] after Lanczos (negative lobes make invalid premultiplied values, which show as glow fringes), re-encode.
   Filament's mipgen defaults to Lanczos (https://www.mintlify.com/google/filament/tools/mipgen); NVTT offers
   Kaiser and Mitchell (https://docs.rs/nvtt_rs/0.8.0/nvtt_rs/enum.MipmapFilter.html).
3. **Premultiplied mips** remove halos: straight-alpha averaging pulls in the colour of transparent texels
   (https://developer.nvidia.com/content/alpha-blending-pre-or-not-pre,
   https://lisyarus.github.io/blog/posts/exploring-ways-to-mipmap-alpha-tested-textures.html,
   https://www.ludicon.com/castano/blog/?p=1662). If an asset must stay straight, dilate RGB into transparent texels.
4. **Linear vs gamma downsampling:** linear matches what Cycles does at a lower resolution; gamma averaging darkens
   bright detail (window glints, rim light) (https://nicolbolas.github.io/oldtut/Texturing/Tut16%20Mipmaps%20and%20Linearity.html).
5. **Sampler:** linear min, mag and mip. Anisotropy only for non-uniform scale (4 is cheap insurance). A negative
   mip bias (-0.25 to -0.5, via the shader's `bias()`) sharpens static buildings but brings shimmer back on moving
   parts: per material.
6. **Rotating or swaying parts:** trilinear, no negative bias, a transparent border of at least 2 px so the
   silhouette is filtered by the texture, optionally 4-tap rotated-grid supersampling
   (https://bgolus.medium.com/sharper-mipmapping-using-shader-based-supersampling-ed7aadb47bec [UV, 403]). For thin
   fast parts (sails), an offline Blender sprite sheet with motion blur beats any runtime filter.

## 2. Magnification of ground tiles (96x56 drawn at 288x168)

- **Do not magnify pre-rendered art.** Re-render tiles at 288x168 (@3x) and 192x112 (@2x); about 190 KB each.
- If 96x56 stays: Catmull-Rom bicubic (9 taps with bilinear help, clamp to tap min/max)
  (https://gist.github.com/TheRealMJP/c83b8c0f46b63f3a88a5986f4fa982b1). "Sharp bilinear" is a pixel-art look and
  posterizes painterly tiles (https://jorenjoestar.github.io/post/pixel_art_filtering).
- **Seams:** the main risk is the **conflation artifact**: two antialiased alpha edges on a shared diagonal each
  give about 50% coverage, so 1 − 0.5·0.5 = 75% and the background shows as a faint lattice [UV, known from Vello
  and Skia]. Fixes, best first: draw each tile as an **opaque quad clipped by diamond geometry** (exact shared
  vertices, no alpha on internal edges) with texture painted 1-2 px past the diamond; or bake the static ground into
  one texture or chunks; or overlap tiles by 2-4 px in draw order.
- **Atlas bleed:** extrude edge texels at least 1 px (bilinear), 2 px (bicubic or mips), padded to the ASTC block
  (4 px) (https://game-forest.github.io/Citrus/articles/assets/texture_bleeding.html,
  https://webgl2fundamentals.org/webgl/lessons/webgl-qna-how-to-prevent-texture-bleeding-with-a-texture-atlas.html).
  Half-texel UV inset only when extrusion is impossible.
- **Metal half-texel:** pixel and texel centres are at +0.5 (D3D10 convention); a quad on integer pixel bounds with
  UV 0..1 maps 1:1 without inset [UV].

## 3. Blending

- **Everything premultiplied, one blend state:** `src = one`, `dst = oneMinusSourceAlpha` for RGB and alpha.
  Normal sprites output (rgb·a, a). **Glow outputs (light, 0):** with alpha 0 the same state is pure addition, so
  glow batches with sprites and its order among glows does not matter
  (https://www.shawnhargreaves.com/blog/premultiplied-alpha.html,
  https://www.shawnhargreaves.com/blog/premultiplied-alpha-and-image-composition.html,
  https://iquilezles.org/articles/premultipliedalpha).
- **Double premultiplication:** premultiplied offline and again by a loader darkens edges. `MTKTextureLoader` and
  the asset catalog may premultiply or force sRGB (https://developer.apple.com/forums/thread/693058,
  https://developer.apple.com/documentation/metalkit/mtktextureloader/option/srgb). Ship our own container
  (for example KTX2) with header flags (premultiplied, colour space); never load sprites through `UIImage` or
  `CGImage`, which premultiply in gamma space.
- With `_srgb` textures the GPU decodes before filtering [UV], so filtering happens in linear.

## 4. Colour, banding and the grade

- **Gamut:** sRGB-primary renders gain nothing from P3 by themselves. v1 tags output sRGB; a later grade may leave
  sRGB through `extendedSRGB` and `bgr10_xr` (https://developer.apple.com/documentation/metal/mtlpixelformat/bgra10_xr).
  Set `CAMetalLayer.colorspace` explicitly; nil means "not colour-matched"
  (https://developer.apple.com/documentation/quartzcore/cametallayer/colorspace). Note: iPad (9th gen) has no P3.
- **ICC in PNGs:** convert once offline (OCIO, Blender's config) to the engine's canonical space and drop the
  profile; the loader's sRGB flag only chooses an interpretation.
- **EDR for glow:** possible (`wantsExtendedDynamicRangeContent`, float format, extended-linear colourspace,
  https://developer.apple.com/documentation/metal/using-color-spaces-to-display-hdr-content) but headroom varies by
  device and brightness and costs power. Not for v1; tone-map glow softly in the LUT.
- **Drawable format:** `bgr10a2Unorm` (or `bgra8Unorm`) with our own sRGB encode and dither, fed from the
  `rgba16Float` scene buffer (option A of section 0).
- **Banding:** night grades, fog and soft gradients band at 8 bits, worst in the dark. Always dither at the final
  quantization, in the encoded domain: TPDF, 1-2 LSB of the output depth, from a tiled 64x64 or 128x128 blue-noise
  texture; fade near 0 and 1 to keep true black and white; static screen-space noise is calmer than animated
  (https://pixelmager.github.io/linelight/banding,
  https://bartwronski.com/2016/10/30/dithering-part-three-real-world-2d-quantization-dithering/,
  https://developers.meta.com/horizon/blog/tech-note-shader-snippets-for-efficient-2d-dithering/).
- **LUT:** 3D, 33³ (or 32³), rgba16Float, applied to a shaped (sRGB-encoded or log) input, never linear. Hardware
  trilinear first; tetrahedral is about 20-25% more accurate at the same size (SMPTE:
  https://journal.smpte.org/periodicals/SMPTE%20Motion%20Imaging%20Journal/129/2/17/). Noon to dusk to night as a
  lerp of two LUTs, or a LUT baked when the hour changes (one fetch).

## 5. Texture compression

- ASTC 4x4 LDR sRGB, encoded from **premultiplied** data (transparent texels become 0 and compress cleanly), each
  mip encoded separately, `astcenc -thorough` (or `-exhaustive` for release) with alpha-weighted error
  (https://github.com/ARM-software/astc-encoder/blob/main/Docs/FormatOverview.md,
  https://developer.nvidia.com/astc-texture-compression-for-game-assets). 6x6/8x8 only for large low-frequency
  backdrops that pass the gate.
- **Keep uncompressed** (RGBA8 sRGB, or R8 for light-as-alpha glow): glow, fog cards, sky, LUTs; smooth
  low-amplitude gradients are where ASTC endpoint quantization shows.
- Budget memory from `MTLTexture.allocatedSize`, not file size. ASTC LDR works on every iOS 27 device; BC never on
  iPhone.
- **Quality gate** in the asset build, decoded ASTC vs source, per mip, composited over noon, dusk and night
  backgrounds: FLIP mean ≤ 0.01 and 99.9th percentile ≤ 0.1, PSNR ≥ 45 dB on premultiplied RGBA, alpha change at
  most 4/255 within 3 px of the silhouette (proposed). Fail: next preset, then uncompressed, logged. Regression
  fixture: a synthetic sky gradient that must be routed to uncompressed.

## 6. Golden-image testing: how others do it

- **Skia Gold / Chromium:** exact match by default with several approved baselines per hardware/OS config;
  opt-in fuzzy (max differing pixels plus per-pixel delta) or Sobel edge masks; they warn fuzzy matching lets
  regressions through (https://chromium.googlesource.com/chromium/src/+/main/docs/gpu/gpu_pixel_testing_with_gold.md,
  https://pkg.go.dev/go.skia.org/infra/gold-client/go/imgmatching/fuzzy).
- **Flutter Impeller:** goldens through Skia Gold, historically macOS + Metal only; flaky cases excluded, not
  loosened (https://flutter.googlesource.com/mirrors/engine/+show/refs/heads/main/impeller/golden_tests/README.md).
- **Filament:** a renderdiff harness with goldens in a separate repo and an explicit accept flag [UV, page 404].
- **Vello:** NVIDIA FLIP, a mean threshold per test, sanity-checked below 0.1.
- **Blender:** fail threshold 0.016, fail percent 1, per-test and per-platform overrides
  (https://sources.debian.org/src/blender/4.3.2%2Bdfsg-2/tests/python/modules/render_report.py).
- **FLIP:** https://github.com/NVlabs/flip (`pip install flip-evaluator`, or `FLIP.h`); set pixels-per-degree for
  a phone at about 30 cm [UV value]; keep the per-pixel FLIP map as a test artifact.

Methodology adopted in `../TestCatalogue.md`: offscreen fixed-size renders, fixed time and seeds, dither frozen in
golden mode (tested separately), baselines per GPU family, two tiers (exact or near-exact for analytic tests,
FLIP for art-level tests), small feature-isolated scenes plus one full postcard scene, human-approved baselines,
thresholds calibrated at about 3x the noise of 20 repeated runs.

## 7. Pixel snapping vs sub-pixel motion

- Soft high-resolution art: **sub-pixel motion with linear filtering**; snapping is a pixel-art technique and
  judders smooth pans, worse at 120 Hz.
- **Snap at rest:** when the camera settles, ease its final position to a whole device pixel (1/3 pt at @3x) so
  1:1 sprites sample texel centres exactly. Snap static sprite origins to the device-pixel grid in world space so
  all static sprites share the camera's phase. Animated elements stay fractional; no snapping while zoom ≠ 1.
  (https://docs.unity3d.com/Packages/com.unity.2d.pixel-perfect@2.0/manual/index.html,
  https://forum.godotengine.org/t/better-pixel-snap-camera/42603)
- Slow sway (5 degrees or less): runtime rotation of a mipped premultiplied texture is fine.

## Top recommendations

1. Decide the compositing space (D1); the research favours linear light in an `rgba16Float` scene buffer with the
   look moved into the LUT.
2. Ship art at display resolution, pre-sized offline; build mips offline, linear, premultiplied, Lanczos/Mitchell.
3. Draw the ground as opaque, geometry-clipped diamonds or a baked ground layer.
4. One premultiplied blend state; glow as alpha-0 additive.
5. Dither the final quantization with static blue-noise TPDF; 33³ LUT.
6. ASTC 4x4 gated by FLIP/PSNR/alpha checks, uncompressed fallback for gradients and glow.
7. Goldens: offscreen, frozen dither, per GPU family, exact tier plus FLIP tier, Blender as the art oracle.
8. Sub-pixel motion, snapping to device pixels only at rest.
