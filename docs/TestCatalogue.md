# Test catalogue

The acceptance suite for hearth-engine, a Swift + Metal 2D renderer, and for its first consumer, IdleVillage
(a cozy isometric idle game whose art comes from a Blender-based "village kit"). Written before the engine, so the
engine is built against it. Draft of 2026-11-25. Every test names the need it serves: an asset contract, a game
requirement, or a failure another engine had (`research/engine-pitfalls.md`).

Decisions this catalogue depends on are in `Decisions.md` (D1 compositing space, D6 asset format, ...). Tests that
pin an open decision say so.

## Suites

| Prefix | Suite | Where | Runs |
|---|---|---|---|
| **E** | Engine | this repo, `swift test` | every commit on an Apple-silicon Mac; GPU tests skip when no Metal device exists (hosted CI) and run on a self-hosted Mac |
| **D** | Device | this repo, benchmark app, XCTest `measure` | per engine release, on the test devices (D2) |
| **B** | Build | this repo and the game's CI | every commit |
| **K** | Kit | IdleVillage, `scripts/village_kit` (art track) | `make asset-selftest` / `make asset-test` |
| **C** | Consumer | IdleVillage, unit tests (`scripts/agent-test.sh`) | every commit once `Game/` is unparked |
| **U** | Consumer UI | IdleVillage, UITests and player journeys | every commit once `Game/` is unparked |

Kinds: **P** pure (no GPU), **G** golden image (offscreen render compared to a reference), **M** measured on
device, **S** static check (lint, plist, manifest).

## Golden-image method

- Render offscreen into a fixed-size texture with fixed time, seeds and format; blit to a shared buffer; compare.
- **Dither frozen** in golden mode (off, or a seeded static pattern); dither has its own tests (E-QUAL-7, -8).
- **References:** kit references first (the kit renders the expected result: `sprite.png`, per-frame
  `layercheck/` renders, Blender oracle scenes), so the engine is judged against Blender, not against itself.
  Engine references (grade, particles, fog) are reviewed by eye, committed with a reason, and kept **per GPU
  family** (Apple does not guarantee numerical consistency across devices).
- **Two tiers:** analytic and same-config tests: per-channel |Δ| ≤ 2/255 on ≥ 99.9% of pixels and ≤ 8/255 on all
  (exact where the test is analytic). Art-level and cross-config tests: NVIDIA FLIP mean and a 99th-percentile cap.
  Save the FLIP map as an artifact on failure.
- **Calibration:** run each scene 20 times on one device; set thresholds at about 3x the observed noise.
- Small feature-isolated scenes (one subsystem each) plus one full "postcard" scene as a smoke test.
- The kit's own layers-gate tolerance (24 levels on ≤ 0.5% of covered pixels) is the ceiling for composite tests,
  not the target.

## Conformance corpus

Exported by the kit (`make asset-corpus`, K-CORPUS-1), versioned by `KIT_VERSION`, vendored here pinned. One asset
per feature so a failure names the feature:

| Entry | Exercises |
|---|---|
| windmill | `spin` part, shadowless part |
| sawmill | `frames` part (8-cell sheet), review-only smoke, glow |
| woodlot | three `sway` parts with phases, back-to-front parts |
| bakery | additive glow, smoke review layer |
| farmyard | crop canvas, base + glow only |
| grass + plots/* | tile canvas, diamond, 3x3 repeat, four overlays |
| chicken | critter sheets, five rows, mirrored right-facing rows, three animations |
| goods_wood/logs, goods/bread | icon canvas at 24, 32, 48 pt |
| silo t1, t2 | tier variants |
| oracle scenes | Blender renders of small composed layouts at device pixel size (E-COL-5, E-QUAL-1) |

---

## E. Engine suite

### E-HAR: harness and determinism

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-HAR-1 | Render headless into an offscreen texture of any size; no view, no display link | G | A 1x1 red quad reads back exactly where placed |
| E-HAR-2 | Time is an input: every animated value is a function of an injected time; no clock reads in engine code | P+S | Two renders at one time are byte-identical; a lint fails on `Date()`, `CACurrentMediaTime`, `mach_absolute_time` outside the display-link adapter |
| E-HAR-3 | Same inputs, same pixels on one GPU | G | 100 renders of the postcard scene hash identically |
| E-HAR-4 | Typed errors, never a crash: missing texture, malformed asset header, unsupported format, nil device | P | Each throws its error; a fallback is drawn only when the caller asks |
| E-HAR-5 | GPU tests skip cleanly without a Metal device | P | On a nil device the GPU suite reports skipped, not failed |

### E-TEX: textures and loading

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-TEX-1 | Load our container (D6) honouring its premultiplied and colour-space flags; never through `UIImage`/`CGImage` | P+G | A flagged test texture renders as specified; a lint forbids image-framework loaders in the engine |
| E-TEX-2 | Use the shipped mips; never `generateMipmaps` on art | P+S | Loaded mip count equals the file's; lint |
| E-TEX-3 | Atlas or array textures with named sub-rects; no bleed at any mip | G | Neighbours in saturated contrasting colours: foreign contribution ≤ 1/255 at every zoom and offset of E-TILE-2 |
| E-TEX-4 | Optional per-cell crop rect and offset in sheets | G | A trimmed sheet renders identically to the full-canvas one (the sawmill wheel's 8 cells are 16 MiB decoded untrimmed) |
| E-TEX-8 | Preload a named set with progress reporting and completion | P | Progress is monotonic 0→1; completion fires once; after it no upload happens for that set (IdleVillage preload gate "Tending the village") |
| E-TEX-5 | Load and upload off the main thread; never block a frame on an upload; a non-resident texture draws nothing or the caller's placeholder | P | A frame requested during a pending load returns on time and draws without it |
| E-TEX-6 | Upload through a staging buffer and blit (keeps lossless compression); fence before first use | P+G | Readback of every mip of ASTC and RGBA8 textures, odd sizes included, equals the source (ASTC private-storage upload bug on A15/M5) |
| E-TEX-7 | Texture usage flags allow lossless compression: no `.unknown`, `.shaderWrite`, `.pixelFormatView` unless allow-listed | S | Descriptor audit over every created texture |

### E-ALPHA: alpha correctness

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-ALPHA-1 | No halos: premultiplied filtering | G | White-on-transparent and red-on-transparent sprites at 0.5 px offset and 0.37x, 1.7x scale over mid-grey: no edge pixel darker than the background by > 1/255; red edges stay hue-red |
| E-ALPHA-2 | No double premultiplication | G | A 0→1 alpha ramp over grey 0.5 equals the analytic "over" to ±1/255 |
| E-ALPHA-3 | Halo-free mips | G | White building on black and black on white at mips 1-3: no pixel in a 3 px ring outside the silhouette deviates from the background beyond the reference composite + 2/255 |

### E-COL: colour pipeline (pins D1)

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-COL-1 | Blending happens in the decided space | G | 50% white over black reads encode(0.5) = 188/255 (linear, D1-A) or 128/255 (display space, D1-B), ±1 |
| E-COL-2 | The pipeline is colour-neutral with an identity grade | G | An sRGB swatch chart through the full pipeline: ΔE2000 < 1 against the source |
| E-COL-3 | Layer configuration is explicit and frozen | S | Snapshot of `pixelFormat`, `colorspace`, EDR flag, `framebufferOnly`, `maximumDrawableCount`; any change fails |
| E-COL-4 | No EDR, no implicit wide colour in v1 (D11) | S | EDR off; output tagged sRGB |
| E-COL-5 | **Blender oracle:** the engine matches Blender's own composite | G | Oracle scenes (two buildings, three tiles, one glow) at device pixel size: FLIP mean ≤ 0.02, p99 ≤ 0.15 (proposed). Settles D1 |
| E-COL-6 | Gamut sanity on a P3 device | G | sRGB red reads as sRGB red in P3 (about 0.9175, 0.2003, 0.1386), not P3 red |

### E-BLEND: layers and blending

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-BLEND-1 | A sprite is a stack of layers drawn in declared order | G | Swapping two layers changes the output; declared order matches the kit reference |
| E-BLEND-2 | One premultiplied blend state (`one`, `oneMinusSourceAlpha`); glow outputs (light, 0) | P+G | Glow over a known background equals background + light (±1/255 after encode); permuting glow order changes nothing (bit-exact in float16) |
| E-BLEND-3 | Layer intensity 0..1 (glow fade, working states) | G | 0 = layer absent; 1 = E-BLEND-2; 0.5 = linear half |
| E-BLEND-4 | `review_only` layers are never drawn | G | Sawmill with and without its smoke entry renders identically |
| E-BLEND-5 | Per-instance tint and alpha | G | Identity tint is identity; alpha 0 draws nothing |
| E-BLEND-6 | Named slots inside a sprite's layer stack: a caller inserts extra layers (tier trims) between two declared layers | G | A trim inserted between two layers draws above the lower and below the upper; removing it restores the original bytes (IdleVillage #46) |
| E-BLEND-7 | Per-instance fill modes: flat-colour silhouette (rgb replaced, alpha kept) and desaturate/dim | G | Silhouette keeps the exact alpha of the sprite; desaturate 1.0 equals the luminance reference; 0 is identity (IdleVillage #400) |

### E-XF: transforms and part motion

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-XF-1 | Pivot convention: canvas px from top-left, y down (kit `layers.json`) | G | A part turned 90 degrees lands where the kit's rotated reference puts it |
| E-XF-2 | `spin`: angle = speed x t, counter-clockwise on screen; speed from data or caller | P | Exact against the formula |
| E-XF-3 | `sway`: `amplitude_deg * sin(2π(t/period_s + phase))` (also covers "rock" parts such as the brewery lid, IdleVillage #538) | P | Exact to 1e-6 against the kit's formula for the woodlot's three parts |
| E-XF-4 | `frames`: column `floor(frames * ((t/period_s) mod 1))`, never rotated | P+G | Sawmill column sequence over one second; each column matches its `layercheck` render |
| E-XF-5 | Missing `motion` means `spin` | P | A manifest without the field parses as spin |
| E-XF-6 | Mirroring about the anchor (critter rows), light flips with it | G | Mirrored `left` lands at the `right` placement, anchor fixed |
| E-XF-7 | Runtime amplitude scaling (gust x1.5, Reduce Motion) keeps period and phase | P | Zero crossings unchanged |
| E-XF-8 | Rotation keeps the silhouette | G | A square stays square at 0, 30, 45, 90 degrees |

### E-QUAL: image quality

| Id | Requirement | Kind | Pass (proposed thresholds) |
|---|---|---|---|
| E-QUAL-1 | Pre-sized sprites drawn 1:1 match Blender at that size | G | Each corpus building at 240 px vs Blender rendered at 240 px: FLIP mean ≤ 0.03, SSIM ≥ 0.97 |
| E-QUAL-2 | Zoomed-out sprites (mips) stay sharp and halo-free | G | At zoom 0.5-1.0 vs an offline Lanczos reference: FLIP mean ≤ 0.03 |
| E-QUAL-3 | No shimmer on moving or rotating parts | G | Rotate 0.5 degrees per frame and translate 0.1 px per frame for 60 frames; motion-compensated temporal luminance std p95 ≤ 1.5/255 |
| E-QUAL-4 | Rotation edges have no angle-dependent aliasing | G | A part at 0-90 degrees in 1-degree steps vs Blender rotated renders over mid-tone: FLIP mean ≤ 0.03 per angle; per-angle max within 0.01 of the 0-degree value |
| E-QUAL-5 | Crisp at rest: camera snaps to device pixels when settled | G | After settling from a random fractional pan, a 1:1 building equals its integer-offset render (≤ 1/255) |
| E-QUAL-6 | Smooth sub-pixel pans | G+P | Pan 0.1 pt per frame for 120 frames: FLIP vs a resampled reference ≤ 0.02 per frame; a tracked feature's screen position is monotonic, step variance < 0.05 px² |
| E-QUAL-7 | No banding with dither on | M | Dark 0→0.1 gradient and fog over the night grade, captured on device: no run of identical pixels longer than 12 px; the same capture with dither off must fail (sensitivity check) |
| E-QUAL-8 | Dither is neutral | G | Mean of a dithered 64x64 flat patch within 0.25 LSB of the undithered value; pure black stays 0 |
| E-QUAL-9 | LUT accuracy | G | 33³ LUT in-engine vs the analytic grade evaluated per pixel on the CPU over a sampled ramp: max ΔE2000 ≤ 1.0, mean ≤ 0.3 |

### E-BATCH: batching and draw order

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-BATCH-1 | Draw-call budget: one instanced draw per atlas and blend group | P | 500 sprites, one atlas, one blend: exactly 1 draw; the postcard scene ≤ 8 draws; CI fails on growth |
| E-BATCH-2 | State changes per frame are counted and budgeted | P | Frame stats report draws, instances, texture binds, pipeline binds; budget per scene |
| E-BATCH-3 | Order inside a batch is submission order | G | 1,000 overlapping quads draw in order |

### E-SORT: depth order

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-SORT-1 | A total order key (layer, depth, stable id, sub-part); any float depth honoured | P | The consumer's depth function (C-MAP-3) is reproduced exactly |
| E-SORT-2 | Equal depths never flicker | P+G | 1,000 shuffles of a scene with deliberate ties: identical draw list and framebuffer hash |
| E-SORT-3 | Grid footprints sort correctly | P | Random non-overlapping footprints 1x1..3x3 on a 20x20 grid, 10k seeds: for every pair whose screen boxes overlap, draw order matches a brute-force "in front" check; 0 inversions. Golden images for named cases (2x2 with 1x1 on both diagonals, tall tower beside a wide shed) |
| E-SORT-4 | Walkers crossing footprints change order once per crossing | P | A walker crossing every edge of a 2x2 in 0.01-tile steps: order flips exactly once per crossing |
| E-SORT-5 | Additive layers respect depth | G | A front building hides a rear building's glow |

### E-RIG: compound and sliced sprites

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-RIG-1 | Layered character rig: up to 16 sheet layers drawn back to front, sharing one animation frame and facing row | G | All layers show the same column and row at every sampled time; a rig of N layers equals the reference composite (IdleVillage `NPCRig`, #62, #81) |
| E-RIG-2 | Per-layer alpha and per-layer sheet swap mid-animation, keeping the shared frame | P+G | Swapping one layer's sheet (mouth emotion, #63) changes only that layer and keeps the frame index; reverting after a delay restores the bytes |
| E-RIG-3 | Mirroring and facing apply to the whole rig | G | Mirrored rig equals the mirrored reference composite |
| E-RIG-4 | One asset contributes slices at different depths (front and back fence edges) so other sprites draw between them | P+G | An animal inside the fenced yard draws above the back slice and below the front slice (IdleVillage #81) |

### E-TILE: ground

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-TILE-1 | Diamonds on the (48, 28)-pt lattice cover the plane exactly once | G | The 3x3 repeat matches the kit's `contact.png` |
| E-TILE-2 | No seams at any zoom or offset (D7) | G | 32x32 opaque grey diamonds over a magenta clear, zoom 0.5-3.0 in 0.013 steps, offsets in 0.1 px steps: zero pixels with magenta > 1/255 inside the map outline |
| E-TILE-3 | No bleed between tiles | G | Distinct flat-colour tiles: no pixel takes a neighbour's colour |
| E-TILE-4 | Per-tile overlays and per-tile dim/desaturate | G | Each plot-state overlay matches the kit review; dim is an instance parameter |
| E-TILE-5 | Long crossfade between tile textures (ground maturity) | G | Crossfade at 0, 0.5, 1 matches references |

### E-CAM: camera

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-CAM-1 | Camera = scale + translation, with an exact inverse | P | screen → world → screen round-trips to 1e-4 pt |
| E-CAM-2 | Matches the consumer's camera composition | P | Engine matrices for 20 sampled states equal the consumer's formulas (C-HIT-1) |
| E-CAM-3 | Points vs pixels at @2x and @3x, any drawable size | G | The same scene at @2x and @3x is one picture at two resolutions |
| E-CAM-4 | Screen-space layers ignore the camera (tint, vignette) | G | Zoom 2.0 leaves them unchanged |
| E-CAM-6 | World-to-view projection for host overlays (thought bubbles, coin floaters, "+N" text) for the frame being presented, not the previous one | P+M | The projected point of a sprite anchor equals its drawn position in the same presented frame; during a pan an overlay pinned to a sprite stays within 0.5 pt of it (U-OVERLAY-2) |
| E-CAM-5 | One snapping rule for camera and sprites (snap nothing while moving, snap to device pixels at rest) | P | A sprite moving with the camera has zero screen-space motion; static sprites share the camera's phase |

### E-POST: post-processing

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-POST-1 | Keyframed 3D-LUT grade (4-6 keys), monotonic interpolation | P+G | Noon key = identity; dusk and night match references; no overshoot between keys |
| E-POST-2 | Grade composes with a weather factor | G | Night + rain equals night x wet factor reference |
| E-POST-3 | Fog thickening with iso depth | G | Density monotonic in depth; off = identity |
| E-POST-4 | Static paper grain and warm vignette; no blur, bloom or animated grain | G | Identity when off; grain identical across frames |
| E-POST-6 | Drifting soft cloud-shadow layer (world-space alpha texture scrolling over the map) | G | Shadow position is a function of injected time; off = identity (IdleVillage #38) |
| E-POST-5 | Grade, encode and dither in the same render pass as the scene | P | One render pass per frame (E-PASS-2) |

### E-PART: particles

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-PART-1 | Seeded, deterministic from injected time | P | Same seed and time give the same particle list |
| E-PART-2 | Emitters in a sprite's local canvas coordinates move and mirror with it | G | A chimney emitter stays on the chimney at any pan and zoom |
| E-PART-3 | Birth rate is live; 0 stops births, living particles finish | P | Count reaches 0 after the max lifetime |
| E-PART-4 | One-shots remove themselves | P | Emitter gone after its duration; no growth over 1,000 bursts |
| E-PART-5 | Hard caps per emitter and per scene | P | Never above the cap (rain about 60) |
| E-PART-6 | After a long gap an emitter shows its steady state, never a replay | P | t jumps 3 days: cost O(steady state); count ≤ cap |

### E-ANIM: tweens (replacing SKAction)

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-ANIM-1 | Tweens on transform, alpha, tint, intensity: move, scale, fade, crossfade, sequence, group, repeat, delay, custom curve | P | Values at sampled times equal the curve; sequences sum exactly |
| E-ANIM-2 | Driven by absolute time; a late first draw shows the right state | P | Starting late gives the end state, no replay; progress never > 1 |
| E-ANIM-3 | Cancel and replace without a jump | P | Cancel keeps the current value |
| E-ANIM-4 | Exact loop periods, deterministic phases (the game's 1.5 s rhythm base, windmill 9 s) | P | Loop length exact to 1e-9; phase from a seed or coordinate |
| E-ANIM-5 | No tween leaks | P | 1,000 entities with looping tweens created and destroyed: live-tween count back to 0; weak refs nil |
| E-ANIM-6 | Even frame holds | P | Over 10 loops at 60 and 120 Hz, refreshes per animation frame differ by ≤ 1 |
| E-ANIM-7 | Reduce Motion: per-effect calm variants (smaller sway, shorter squash, drift off), not a global stop | P | Each effect reports its calm parameters; part motion keeps running |
| E-ANIM-8 | Presentation time of each animation's first visible frame, for sound (+40 ms) and haptics (+80 ms) | P | Reported per tween from `presentedTime` |

### E-TIME: clocks and time precision

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-TIME-1 | Phases from absolute `Double` time wrapped on the CPU (`fmod` by loop period); GPU time uniform is `float`, never `half` | P+S | Frame-index sequences at t0 = 0 and t0 = 30 days are identical over 10 s at 120 Hz; the GPU time value at day 30 is bit-identical to day 0 at the same phase; lint forbids `half` time |
| E-TIME-2 | Animation samples at `targetTimestamp`; dt from successive targets, clamped | P | A fake display link that skips callbacks and switches 120 → 60 mid-run: progress equals wall time within 1 frame |
| E-TIME-3 | No accumulated-dt drift | P | After 10^6 random dt steps the frame index equals the closed form |
| E-TIME-4 | A 3-day clock jump while live | P | First frame after the jump ≤ 2x normal CPU time; particles ≤ cap; no tween progress > 1 |

### E-CAP: capture

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-CAP-1 | Capture at native resolution, including grade, weather and particles at that time | G | Equals the on-screen frame at scale |
| E-CAP-2 | Capture larger than the drawable | G | 2x drawable size without seams |
| E-CAP-3 | Capture never changes live state or timing | P | Live frames before and after identical |

### E-RATE: frame-rate policy (D3)

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-RATE-1 | Policy table: (interacting, animating, low power, thermal) → rate range or paused | P | Static → paused; ambience max 30 (preferred 20); interacting 60 (120 on ProMotion if enabled); Low Power Mode max 30; `.serious` max 30; `.critical` max 15 with ambience off |
| E-RATE-2 | Render on demand: nothing visibly changing → zero frames | P | N ticks without change or ambience: 0 frames requested |
| E-RATE-3 | The engine reports the fastest rate its content needs, so the host can keep overlays from forcing 60 | P | Reported rate equals the policy result |
| E-RATE-4 | Detect the real delivered rate and pace evenly at it | P | Rate from `targetTimestamp − timestamp` under a fake link at 120, 60, 40, 30 |

### E-PSO: pipelines

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-PSO-1 | No pipeline created after warm-up | P | A counter stays 0 across a scripted tour of every feature (each blend, particles, grade on/off, every sheet) |
| E-PSO-2 | The pipeline key set equals the precompiled set | P | Unit test lists keys |
| E-PSO-3 | All pipelines created asynchronously at init, off the main thread | P+M | Total ≤ 50 ms on the floor device; nothing on the main thread |

### E-PASS: render pass configuration

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-PASS-1 | Load/store and storage: drawable clear (or don't-care) + store; every other attachment memoryless with don't-care; `framebufferOnly = true` | S | Descriptor audit |
| E-PASS-2 | One render pass per frame (scene, grade, encode, dither via programmable blending) | P | Pass count per frame = 1 |
| E-PASS-3 | Ground drawn opaque with blending off; blended content after | P | Draw list audit |

### E-MEM: memory

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-MEM-1 | Texture memory accounted from `allocatedSize` and bounded by a budget | P | Registry total equals the sum; loads beyond budget evict least-recently-used |
| E-MEM-2 | No leaks across load/unload | P+M | 20 load/unload/reload cycles: `phys_footprint` within 2% of cycle 1; live textures back to baseline |
| E-MEM-3 | Memory warning: purge regenerable caches, keep rendering | P+M | Footprint drops; the next frame renders (placeholders allowed) |

### E-LIFE: lifecycle

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-LIFE-1 | No encode while inactive or in background; `waitUntilScheduled` on the last buffer | P | State machine rejects encode when inactive; 0 commits after deactivate |
| E-LIFE-2 | Command-buffer errors (`notPermitted`, `accessRevoked`) are logged, never trap | P | Injected error completions: no crash |
| E-LIFE-3 | The engine never changes the host's pause state | P | Background and return keep the host's pause flag and frame counter |
| E-LIFE-4 | Drawable size follows layout, never per frame; no stale or stretched frame | G+M | After each size change `drawableSize = bounds x scale` (±1 px); a marker sprite at its expected pixel; `nextDrawable` after a resize < 20 ms |

### E-DBG: debug drawing

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-DBG-1 | Debug primitives (lines, outlined diamonds, ellipses, filled rects) in world space on the top band, compiled out of release builds | G+S | Primitives land on the expected pixels; release build contains no debug pipeline (IdleVillage hitbox overlay, `Hitboxes.md`) |

### E-VAL and E-API

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| E-VAL-1 | Metal API and shader validation clean | P+G | The GPU suite also runs with `MTL_DEBUG_LAYER=1` and `MTL_SHADER_VALIDATION=1`: zero messages |
| E-API-1 | Swift 6 strict concurrency, warnings as errors, no dependencies | S | Package settings; `Package.swift` has no dependencies |
| E-API-2 | The render thread reads only an immutable `Sendable` frame description | P | Mutating the source mid-frame has no effect on the frame |
| E-API-3 | Apple5 feature floor: no Metal 4, no HDR ASTC, max texture 16384 | P+G | A capability probe; the corpus renders with every optional feature forced off |
| E-PLIST-1 | Host integration check: a ProMotion iPhone host declares `CADisableMinimumFrameDurationOnPhone` when it wants above 60 Hz | S | The engine logs a warning at startup when 120 Hz is requested without the key |

---

## D. Device suite

Run on the test devices (D2). Budgets are proposals (D10), set for the floor device so ProMotion devices have
headroom.

| Id | Scene / action | Measure | Pass (proposed) |
|---|---|---|---|
| D-PACE-1 | Trivial scene (one rotating sprite) and the postcard scene, 30 s each, idle and with a synthetic drag | `targetTimestamp` intervals, `presentedTime`, GPU start/end | ≥ 99% of intervals within ±1 ms of target; distribution unchanged by touch. Re-run on every iOS beta (SpriteKit's iOS 26 40-fps regression) |
| D-PACE-2 | Same, with a touch stream and with an animating SwiftUI sheet over the view | as D-PACE-1 | p99 interval ≤ 1.1x the idle baseline |
| D-PACE-3 | Low Power Mode, "Limit Frame Rate", thermal states via Device Conditions | delivered rate | Detected rate matches policy; pacing even at it (no 60/30 alternation) |
| D-GPU-1 | Postcard scene and IdleVillage's IV-553 scenes 1 and 2 | CPU encode and GPU time per frame | iPad (9th gen): CPU ≤ 2 ms, GPU ≤ 4 ms; regression ≤ 10% per release |
| D-GPU-2 | Postcard scene | overdraw (fragments per stored pixel), compression-ratio counter | overdraw mean ≤ 2.5, p99 ≤ 6; compression ratio > 1.0 |
| D-WORST-1 | Worst case: full 7x7 village, every glow, rain (60), leaves, three critters, three emitters, zoom 2.0 | dropped frames over 60 s | none at 60 Hz on the floor device |
| D-IDLE-1 | Idle village 10-30 min (only slow ambience) | command buffers per second, average CPU, energy log | ≤ declared idle rate; CPU < 3%; Energy Impact "Low"; frames ≈ policy rate x time (±10%) |
| D-SOAK-1 | Postcard scene at default rate for 20 min; then inject `.serious` | thermal state, GPU ms, intervals | stays nominal/fair; step-down within 1 s of the injected state |
| D-SOAK-2 | 1 h with random taps, pans and simulated returns | footprint, validation | memory flat after warm-up; zero validation errors |
| D-MEM-1 | Full corpus loaded, then a memory warning | `phys_footprint`, texture bytes | textures ≤ 64 MB resident; under 50% of `os_proc_available_memory()` at launch; drops after the warning |
| D-HITCH-1 | Stream 20 new atlases during a 60 s pan; tier flip; new building | frame time | no frame over 1.5x target |
| D-LAUNCH-1 | Cold launch to first scene frame | time | ≤ 400 ms after the host view appears; no pipeline or texture work on the main thread |
| D-PROD-1 | Production (in the consumer) | MetricKit `MetalFrameRateMetric` per named layer and `StateReporting` state, `GPUTimeMetric` | idle-state fps ≤ 30; GPU time per foreground hour regresses ≤ 20% |

## B. Build suite

| Id | Requirement | Kind | Pass |
|---|---|---|---|
| B-METALLIB-1 | Shaders precompiled to `.metallib`; no shader source compiled at runtime | S | Bundle audit |
| B-SIZE-1 | App size tracked | S | Asset payload growth > 5% per change fails without a reason |

---

## K. Kit suite (IdleVillage `scripts/village_kit`, art track)

What the engine needs from the asset pipeline. Several are kit changes that wait on D1 and D6.

| Id | Requirement | Pass |
|---|---|---|
| K-CORPUS-1 | `make asset-corpus` exports the corpus with manifests, shipped textures, references and oracle scenes, stamped with `KIT_VERSION` | Re-export at one version is byte-identical |
| K-SCHEMA-1 | One JSON Schema for `layers.json`, `tile.json`, `sheet.json`; the kit validates its outputs and C-MAN-1 validates the same schema | A field added on one side only fails a test |
| K-LINT-1 | Container textures are premultiplied (rgb ≤ a per texel) with correct flags | Lint over every output |
| K-LINT-2 | Looping sheets: first and last frames not identical unless marked | Lint |
| K-SIZE-1 | Pre-sized @2x and @3x outputs and offline mips (linear, premultiplied, Lanczos/Mitchell, clamped) (D6) | E-QUAL-1/-2 pass on the corpus |
| K-TILE-1 | Ground tiles at native resolution, painted 1-2 px past the diamond (D6, D7) | E-TILE-2 passes |
| K-ASTC-1 | ASTC 4x4 gate: decoded vs source over noon, dusk, night backgrounds: FLIP mean ≤ 0.01, p99.9 ≤ 0.1, PSNR ≥ 45 dB, alpha change ≤ 4/255 near the silhouette; otherwise uncompressed, logged | A synthetic sky gradient fixture must route to uncompressed |
| K-ANCHOR-1 | Emitter anchors exported (point in canvas px, kind, state) | Smoke today exists only as a review-only layer |
| K-SPEED-1 | Spin speed in the data (the game's rhythm registry: windmill 9 s per turn) | Today it is left to the install ticket |
| K-VIEW-1 | (If D1-A) sprites rendered with Standard view, no look; the look exported as the LUT's base key | Oracle scenes match E-COL-5 |
| K-STATES-1 | Working states (idle / working layer sets and intensities) exported | Required by E-BLEND-3 consumers |

## C. Consumer suite (IdleVillage adapter, unit)

Consumer tests follow the game's rules: Swift Testing, renderer suites `@MainActor` at suite level and in their own
files, state built with the fixed test clock and calendar (`scripts/check-test-clock.sh`), run through
`scripts/agent-test.sh` (IdleVillage `docs/conventions/Conventions.md`, `UITesting.md`). A rule is a unit test; a UI
concern is a UITest.

| Id | Requirement | Pass |
|---|---|---|
| C-MAN-1 | Parse every manifest in full against K-SCHEMA-1; reject out-of-range values as the kit does (sway amplitude 0-15, frames 2-16, folds 1-64) | Every corpus manifest parses; each invalid fixture throws its named error |
| C-COMP-1 | Every corpus asset at rest matches its reference (needs D8) | Per the golden method |
| C-PLACE-1 | Canvas placement: building 80 pt, anchor (0.5, 0.3), ground line 0.30; crop about 92 pt, 0.29; critter anchor (64, 96) at 15 pt; tile 96 pt | Each canvas's ground contact lands on the tile centre |
| C-PLACE-2 | Old 60 pt placeholders and new 80 pt kit sprites coexist during the transition | A mixed village renders both |
| C-PLACE-3 | Goods icons are SwiftUI images in the dashboard (asset catalog), not engine sprites; stockpile props in the scene come from the kit's building-canvas parts | The installed icon at 24, 32, 48 pt matches the kit's icon review rows |
| C-MAP-1 | All 49 plots of the derived map, overlay by plot state, nothing stored in the renderer | Frame description lists exactly the expected plots |
| C-MAP-2 | Reconcile by id each frame: idempotent, zero steady-state allocation | Two reconciles of one state change nothing |
| C-MAP-3 | One depth function shared by drawing and hit testing (bands ground 0, prop 10, building 20, actor 25, fx 40, overlay 10,000; depth (x+y)·100) | Same function object used by both |
| C-MAP-4 | Events drive one-shots, deferred until the target exists | Plays once on spawn |
| C-MAP-5 | Rendering never mutates `GameState` | Encoded state identical before and after a frame |
| C-MAP-6 | A return shows the current state, never a replay | After a 2-day `tick(now:)` the first frame equals a fresh render |
| C-MAP-7 | Day-night grade from the game's day cycle (7,200 s release, 720 s quick playtest); lamplighting staggered over about 10 min at dusk | Grade keys at each band; never all lamps at once |
| C-HIT-1 | Camera and hit geometry unchanged (zoom 1.0-2.0, pinch about the centroid, pan clamp, 6 pt tap slop, 0.2 s recenter) | Existing `CameraStateTests` and hit tests pass against the engine camera |
| C-HIT-2 | Hit test agrees with what is drawn | An id buffer of the postcard scene and 1,000 random taps: hit result equals the id at that pixel |
| C-HIT-3 | Photo mode's unbounded camera restored exactly on exit | State equal |
| C-PRE-1 | Preload before the first frame; tier textures preloaded | No upload in the first 10 s or on a tier flip |
| C-PHOTO-1 | Capture saved through a fakeable writer at native resolution | The fake receives one image |
| C-SWAP-1 | Placeholder → kit sprite swap touches one mapping | The rest renders unchanged |
| C-ARCH-1 | `State/` never imports the engine or Metal; the pacing harness still builds from `State/` alone; the Sim Lab target has no renderer | `scripts/check-state-isolation.sh`, `scripts/check-pacing-build.sh` and the Lab build pass |
| C-ARCH-2 | Working-state looks follow utilization: glow intensity, emitter birth rate and part speed are functions of the building's utilization, never stored in the scene | Sampled utilizations map to the expected parameters (IdleVillage #535-#538) |
| C-ARCH-3 | Tier changes: idempotent apply, about 600 ms crossfade, one-shot sparkle, no duplicate layers | Applying a tier twice changes nothing; crossfade and sparkle timings match (IdleVillage #46) |

## U. Consumer UI suite (IdleVillage UITests and journeys)

| Id | Requirement | Pass |
|---|---|---|
| U-OVERLAY-1 | Engine view under the dashboard; SwiftUI overlays (recenter, return band, photo chrome) above it | Identifiers present and hittable |
| U-JOURNEY-1 | No wall-clock render loop under `-UITestMode`; player journeys unchanged | `scripts/player-journeys.sh` output identical before and after unparking |
| U-ALIGN-1 | Alignment playground hosts the runtime renderer | Each adopter aligns through `apply(layout:)` |
| U-RESIZE-1 | Rotation, Split View 1/3-1/2-2/3, Stage Manager steps | Drawable equals bounds x scale; marker sprite in place |
| U-BG-1 | Background and foreground 50 times, including mid-frame | Zero command-buffer errors, no crash, first frame after return correct |
| U-OVERLAY-2 | A SwiftUI overlay pinned to a building stays on it during a pan and a pinch | Within 0.5 pt in every captured frame (E-CAM-6) |
| U-A11Y-1 | The scene is one accessibility container with its identifier; Reduce Motion switches effects to their calm variants; overlays use Dynamic Type | Identifier present; with Reduce Motion on, sway amplitude and drift match E-ANIM-7 |
| U-ASSEMBLY-1 | The Character Assembly view keeps working on the engine | It renders a rig and swaps a layer (IdleVillage #63) |

## Traceability to research

Pitfall → test: SpriteKit pacing regression → D-PACE-1/-2; first-use compile stutter → E-PSO-1..3, B-METALLIB-1;
texture upload hitches and the ASTC blit bug → E-TEX-5/-6, D-HITCH-1; alpha fringes → E-ALPHA-*; tile seams →
E-TILE-2/-3, K-TILE-1; sub-pixel jitter → E-CAM-5, E-QUAL-5/-6; equal-key flicker → E-SORT-2; batching →
E-BATCH-*; overdraw → E-PASS-3, D-GPU-2; gamma blending → E-COL-1/-5; HDR surprises → E-COL-3/-4; frame pacing →
E-TIME-2, E-RATE-4, D-PACE-*; thermal → E-RATE-1, D-SOAK-1; idle battery → E-RATE-2, D-IDLE-1; background GPU →
E-LIFE-1/-2, U-BG-1; jetsam → E-MEM-*, D-MEM-1; resize → E-LIFE-4, U-RESIZE-1; iso sorting → E-SORT-3/-4;
hit/draw mismatch → C-HIT-2; time precision → E-TIME-1/-3; long-absence replay → E-TIME-4, E-PART-6, C-MAP-6;
tween leaks → E-ANIM-5; overlay lag → E-CAM-6, U-OVERLAY-2; loop seams → E-ANIM-6, K-LINT-2; app size → B-SIZE-1.
