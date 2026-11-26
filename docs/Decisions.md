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
version as a test resource. Amended by D21: the vendored export is the art tier only and arrives in engine formats.

### D12-D22: any isometric or tile game, and how the engine is seen and verified

Decided by the owner on 2026-11-25 from `research/isometric-landscape.md`, which holds the options that were
weighed. Each entry lists the catalogue changes it implied; they were made in `TestCatalogue.md` the same day, and
the work is ticketed as #21-#30 (tickets #1-#13 updated to match).

**D12. The engine owns the grid projection.** A `GridProjection` is a pure `Sendable` value: screen vectors for
grid axes i and j, a vector k for one height unit, and the tile outline as a polygon in lattice coordinates. Tile
layers, the default depth key, picking and culling read it. Sprites may be placed in grid coordinates or in raw
world points with a caller-supplied depth, as before; a game that never creates a projection never touches grid
code. v1 covers parallelogram tiles (diamond at any ratio, staggered, orthogonal); hex is not precluded. Why:
without it elevation, box sorting, tile picking and range culling cannot live in the engine, and every consumer
re-solves them. Catalogue: E-TILE-1's fixed (48, 28)-pt lattice becomes a parameter; E-TILE-1/-2 run over at
least three projections (IdleVillage's, a 2:1 diamond, orthogonal); new pure tests for projection round trips; D7's
shared-vertex seam guarantee is restated for any parallelogram.

**D13. Elevation is a third coordinate, with flat-topped terraces.** Positions are (i, j, h): h is continuous for
sprites and an integer level per tile for ground. The depth key, picking and culling account for h; with h = 0
everything is today's behaviour. Tile height is stored per tile so per-corner heights (slopes) can be added later
without changing the coordinate model. Consequences: a higher tile needs cliff-face art, D7's seam guarantee holds
only within a run of equal height, and screen-to-world is ambiguous so picking returns the topmost hit.
Catalogue: elevation cases for sorting, picking and culling padding.

**D14. Box sort, with the scalar key as tie-break.** A sortable may carry a 3D box in grid units (footprint plus
height range). The engine derives "behind" only for pairs whose screen rectangles overlap and orders them
topologically; unrelated pairs fall back to (depth key, stable id); bands stay the outermost key. Layers, glow,
parts and emitters ride with their parent and skip the sort. Sprites without a box keep the plain key. The order
is cached and re-sorted only when something moves; larger scenes need screen-space bucketing. Cycles are detected,
broken deterministically and reported; the art fix is slicing (E-RIG-4). Why: no single depth number satisfies
E-SORT-3 (worked example in the research file, section 4). Per-pixel depth was rejected for v1 because soft edges
and glow still need back-to-front blending. Catalogue: E-SORT-3 extended to boxes with heights; deterministic
cycle handling; a debug view of the sort boxes (E-DBG); a sort-time budget on the floor device (D10).

**D15. Batching across textures: a bound texture set with a per-instance slot index.** Up to K textures are bound
at once and each instance selects its slot, so textures of different size and format (ASTC bases, uncompressed
glow) share a draw. A batch splits only when a frame needs more than K textures. Plain texture slots, not argument
buffers tier 2 (Apple6+). The instance format carries the slot index from day one and reserves one byte for an
array-layer index, so texture arrays can be combined later. K is fixed by measurement on the iPad (9th gen). Why:
with D6 as recommended and E-SORT-5, base and glow alternate in depth order and "one draw per atlas" gives about
two draws per lit building. Catalogue: E-BATCH-1 reworded to "one draw per blend group while the frame uses at
most K textures"; sprites alternating between two textures in depth order give exactly one draw; K+1 textures
give a deterministic split into two.

**D16. Retained tile layers; 256x256 tested, 4096x4096 not precluded.** A tile layer is a resource the consumer
creates and edits by region. The engine keeps it in chunks, rebuilds only dirty chunks, and culls chunks against
the camera, padded for elevation. A frame description refers to a layer by handle and version and pins an
immutable snapshot, so an edit during a frame cannot change it. Loose per-frame tiles and sprites stay allowed.
IdleVillage uses the layer, so the path is exercised by the first consumer. Baked chunk textures are out (memory,
magnified art, elevation, permanent crossfades), except possibly later for far zoom. Target: 256x256 tiles tested,
with a visible-tile budget (proposed: about 4,000 tiles plus overlays at 60 Hz on the iPad (9th gen); confirm
under D10). To keep 4096x4096 possible: chunk-relative coordinates with `Double` camera maths; a chunk-addressed
layer API with sparse storage, so a chunk provider can be added without breaking it; a declared minimum zoom that
enforces the visible-tile budget, so level of detail is an addition. Streaming, level of detail and retained
object layers are not v1. Catalogue: only dirty chunks are rebuilt; snapshot isolation; culling equals a
draw-everything reference; layer memory in E-MEM-1; the retained path and the per-frame path give identical
pixels; pan smoothness at tile (4095, 4095); an empty 4096x4096 layer costs almost no memory.

**D17. Picking is a CPU query on the engine's draw list.** Every drawable carries an opaque consumer id and a hit
shape. Three queries against the frame being presented: everything under a point with a slop radius, front to
back; the tile under a point, scanning for elevation; all ids inside a rectangle. Policy (what is tappable, what
wins, how much slop) stays in the consumer. A GPU id buffer is a test oracle only, never on the frame path. Hit
shapes: declared shapes (rectangle, ellipse, diamond, polygon in sprite space) by default, alpha masks optional
per asset (recommendation; the owner chose the query model and did not object to this default). Why: after D14 the
consumer cannot reproduce the draw order, so C-MAP-3's shared depth function no longer covers boxed sprites.
Catalogue: an engine version of C-HIT-2 (pick result equals the id buffer at 1,000 random points on a synthetic
scene); C-MAP-3 reworded; the consumer keeps its policy tests.

**D18. The Simulator runs a two-pass fallback; the frame description is serialisable.** The Simulator rejects
programmable blending, so D1's single-pass design cannot run there or in iOS Previews, and IdleVillage's test loop
runs in the Simulator. Behind the GPU protocol a second path renders the scene into a stored float texture and
grades, encodes and dithers it in a second pass. Contract: (1) the reference is the single-pass path on a real
Apple GPU (Mac harness and devices); (2) the fallback is proven pixel-equivalent to the reference on the Mac, on
every commit; (3) the Simulator runs the fallback and is only smoke-tested (not blank, validation clean, same draw
list as the Mac for the same description) and is never a source of golden references. The frame description is
serialisable in a stable, versioned format, so a frame built anywhere can be replayed on the Mac. IdleVillage's
golden tests (C-COMP-1) are judged on the Mac path through replay. Two passes everywhere was rejected for its
bandwidth cost on device. Catalogue: E-PASS-2 gains a Simulator carve-out; a single-pass against two-pass
equivalence test; Simulator smoke tests; a serialisation round trip; texture pages at most 8192 px.

**D19. The primary viewing surface is a native macOS viewer in this repo, controllable by agents and tests.**
macOS is a development host only, not a product platform. It needs an AppKit host view and a display-link adapter
for macOS; the package already builds for macOS because of `swift test`. One scene catalogue feeds the tests,
Previews, the viewer and the benchmark app (#13), which doubles as the on-device viewer. Control and verification
go through the harness of D22, not through UI automation of the window.

**D20. Hot reload: assets and scene files in the macOS viewer.** The viewer watches a directory and reloads
changed texture containers and scene files; a debug build in the Simulator can read the same host directory. The
engine gains one operation: replace a resource behind its handle at a frame boundary, keeping the old one until
in-flight frames finish; a failed reload keeps the old resource and reports a typed error. File watching lives in
the viewer, not the engine. Shader reload in debug builds is ticket #20, pushing assets to a device is #19. No
Swift code hot reload. Catalogue: replace during a frame in flight leaves that frame unchanged; no leak across 100
reloads.

**D21. Two-tier conformance corpus; the game's adapter produces scene files.** Synthetic tier: owned by this repo
and generated by code (flat colours, ramps, numbered tiles, boxes of known height, several projections), for every
analytic test and every feature of D12-D17. Art tier: the pinned kit export, used only where Blender must be the
judge (E-COL-5, E-QUAL-1, -2, -4), delivered in engine formats (texture containers, scene files, Blender
references). The engine never reads a kit manifest. Scene files for kit assets are exported by IdleVillage's
adapter as the frame descriptions it builds (D18), not written by the kit, so the real mapping is tested and
nothing is duplicated; the viewer shows kit art by opening those scenes. Amends D5. Catalogue: the corpus section
is rewritten; kit-specific rules (E-XF-5, the woodlot numbers of E-XF-3, kit names in E-BLEND-4 and E-XF-4) move
to the consumer suite or the art tier.

**D22. Agents work through a headless harness, and proof has rules.** A command-line harness on the engine library
renders a scene file at a given time, answers pick queries, reads back pixels and regions, diffs images and runs
catalogue ids. Each run emits: a PNG; a frame report in JSON; an id map (the topmost drawable per pixel); a
receipt. The frame report has an *intended* section (one entry per drawable in draw order: id, texture and
sub-rectangle, screen quad, grid position and height, sort box, band, batch index, tint, animation state, culled
or not; needs no GPU) and an *observed* section derived from the id map and the image (visible pixel count and
bounding box per sprite, fraction hidden and by whom, region colours, difference metrics and the worst regions).
Each sprite's intended quad must agree with its observed bounding box. The report has a published, versioned
schema, deterministic output and a queryable, summarised form. It is not a second source of truth: the catalogue
states per test which evidence it needs, and the PNG stays the only thing a human approves. Rules:
1. Reference images are human-approved only. An agent proposes a candidate with a diff; the owner approves in the
   viewer's review mode, which records the image hash; a commit that changes a reference without that record fails.
2. Skipped is not passed. Every run writes a receipt (commit, GPU, ids run, passed and skipped, image hashes); a
   ticket is done only with a receipt showing zero skips on a real GPU.
3. Every golden test has a negative control: with the feature broken the test must fail.
4. Scenes carry their intent as checkable statements (A in front of B, this region has this colour, at most one
   draw).
A model looking at an image is triage, never a gate. Limits: the device suite needs real devices; cloud agent
sessions have no GPU and can run only pure tests and the intended half of the report. Relates to D8. Catalogue: a
harness suite (report schema and determinism, intended against observed, receipts, negative controls); E-HAR-5
gains the receipt rule; a new evidence kind for report-based tests.

### D24: which games the engine is for

**D24. Scope: tile and isometric games like the first consumer; an RTS is not a goal (owner, 2026-11-26).** v1
serves IdleVillage. The generalisation of D12-D22, "any isometric or tile game", stands: a city builder, a farming
game or a turn-based tactics game are the likely second consumers, and they need the same grid, elevation, sort,
picking and layers. A real-time strategy game is not a goal and is not precluded. Why: there is no RTS consumer,
so its features would be designed against an imagined game and tested only on synthetic scenes; its targets oppose
the idle game's (hundreds of movers and continuous 60 Hz against render on demand, readability against mood); the
renderer is the small part of an RTS (pathfinding, simulation, AI, netcode and controls are outside this engine);
and the work is about a fifth milestone. The evidence is `research/isometric-landscape.md` section 8.
Consequences:
1. No RTS feature enters engine-01 to engine-04. Tickets #14 (team colours), #16 (minimap), #17 (fog of war) and
   #18 (terrain transitions) stay in the inbox as a record until a concrete game needs them.
2. Building placement is shared by city builders and tactics games: #15 (shapes in release builds), #41 (footprint
   outline) and #42 (per-tile colour, highlight layer) are pulled forward when a game needs it, not before.
3. Three protections are cheap now and a format break later, whatever the second game is. Each belongs to the
   ticket that fixes the format: spare room in the instance format for a per-instance colour and a mask slot,
   beyond D15's one reserved byte (#6); a list of tile layers and more than one view in the first scene-file
   version (#21) and in the layer API (#25); the box sort measured with a few hundred movers, not only static
   boxes, so D14's deferred bucketing is known to fit behind the same interface (#24).
A feature added for a second consumer follows E-GRID-6's pattern: a scene that does not use it renders
byte-identically and pays nothing.

## Open

**D1. Where compositing happens (owner).** Recommendation: **linear light**. Sprites rendered with Blender's
Standard view and no look (today the kit bakes "Medium Contrast"); the look moves into the in-game LUT; textures
`_srgb`, premultiplied in linear; an `rgba16Float` scene attachment (memoryless, read in the same pass by the final
grade-encode-dither stage through programmable blending, so still one render pass); `bgr10a2Unorm` or `bgra8Unorm`
drawable tagged sRGB. Why: it matches Blender's own full render on soft edges and glow, which the art is judged
against. The alternative keeps today's kit convention (composite in sRGB display values) and needs no kit change,
but deviates from Blender on partial alpha and glow. The kit's layers gate changes with the choice.
Test that settles it: E-COL-5 (Blender oracle). See `research/image-quality.md` section 0. Whatever is chosen, the
Simulator cannot read the scene attachment in the same pass and runs the two-pass fallback of D18.
Until then (owner, 2026-11-26): HE-2's texture stage follows the recommendation provisionally (`_srgb` pages, straight
alpha multiplied after sampling, so sampled values are premultiplied linear), in one function that E-COL-5 may change.

**D6. Asset delivery format (owner; kit changes in IdleVillage).** Recommendation: pre-sized outputs per scale
(@2x and @3x, re-rendered by Blender where affordable), offline mips (linear, premultiplied, Lanczos/Mitchell,
clamped), ground tiles rendered at native resolution and painted 1-2 px past the diamond, our own container
(KTX2 with premultiplied and colour-space flags), ASTC 4x4 gated by FLIP/PSNR/alpha checks with an uncompressed
fallback for glow, fog and gradients. Replaces today's single 512 px PNG per asset and 1 px/pt tiles.
Container part decided (owner, 2026-11-26): the engine reads a strict KTX2 subset (2D, one face, no supercompression,
RGBA8 and ASTC 4x4, colour-space and premultiplied flags in the DFD, regions in the key/value block), built in HE-2.
Output sizes, offline mips and the ASTC gate stay open with the kit.

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

**D23. Will this repository be public? (owner).** Asked on 2026-11-25, not answered. If yes, the vendored art tier
of D21 needs a licence decision, which is a reason to keep that tier small.
