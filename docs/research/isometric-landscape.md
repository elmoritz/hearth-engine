# The isometric landscape: what other engines do, and what this engine needs

Research of 2026-11-25. Question: what would make the engine carry any isometric or tile-based game, not only a
7x7 village, and how can it be seen, driven and verified while it is built. The outcomes are decisions D12-D22 in
`../Decisions.md`; this file holds the evidence and the options that were weighed.
Legend: unmarked = read on the source; **[UV]** = unverified (search snippet, one report, recollection or
inference); **[probe]** = measured locally on 2026-11-25 (Xcode 27.1, Swift 6.4, macOS 27.2.1, M1 Pro, iOS 27.0
simulator runtime), not documented by Apple. A `?` in the matrix means the same as [UV].

## 1. Tile and isometric support in general engines

Y = yes, P = partial, N = no, - = not applicable.

| Feature | Godot 4.7 | Unity 6.6 | Tiled (format) | SpriteKit | Bevy (ecs_tilemap) | Phaser 3.50+/4 |
|---|---|---|---|---|---|---|
| Diamond isometric | Y | Y | Y | Y | Y | Y |
| Staggered isometric | Y | N? | Y | N? | Y | Y |
| Hexagonal | Y | Y | Y | Y | Y | Y |
| Elevation inside one map | P | Y (Z as Y) | N | N | N? | N? |
| Tiles sort against sprites | Y | P (Individual mode) | - | N | ? | N? |
| Autotile / terrain sets | Y (3 modes) | Y (Rule Tiles) | Y (Wang) | Y | N? | N? |
| Animated tiles | Y | Y | Y | Y | Y (GPU) | P |
| Per-tile custom data | Y | P? | Y | Y (`userData`) | Y | Y? |
| Scene / object tiles | Y | Y | Y | N | Y | P? |
| Chunked or infinite maps | P (16-tile quadrants) | P (Chunk mode) | Y | N? | Y | N? |
| 2D lights and normal maps | Y | Y | - | Y | ? | P? |

Others: LDtk has no isometric support (square grids only, https://itch.io/post/3370677). Defold has none
(https://forum.defold.com/t/how-can-2d-isometric-artstyles-be-used-in-defold/80942). libGDX calls its isometric
renderer experimental and notes that isometric is costly on mobile because every tile needs blending
(https://libgdx.com/wiki/graphics/2d/tile-maps). MonoGame.Extended 6 reads Tiled maps in all four orientations
(https://www.monogameextended.net/docs/features/tilemaps/). Cocos Creator reads TMX only
(https://docs.cocos.com/creator/3.8/manual/en/editor/components/tiledmap.html).

Sources: Godot https://docs.godotengine.org/en/stable/classes/class_tileset.html,
https://docs.godotengine.org/en/stable/classes/class_tilemaplayer.html,
https://docs.godotengine.org/en/stable/tutorials/2d/using_tilesets.html. Unity
https://docs.unity.com/en-us/engine/6000.6/manual/unity2d/tilemaps/isometric-tilemap/tilemap-renderer-isometric-modes,
https://docs.unity3d.com/Packages/com.unity.2d.tilemap.extras@1.8/index.html. Tiled
https://doc.mapeditor.org/en/stable/reference/tmx-map-format/, https://doc.mapeditor.org/en/stable/manual/terrain/.
SpriteKit https://developer.apple.com/documentation/spritekit/sktilemapnode ("A tile map does not expose its tiles
as nodes, and therefore you cannot assign individual tiles with a different zPosition"). Bevy
https://github.com/StarArawn/bevy_ecs_tilemap. Phaser https://docs.phaser.io/api-documentation/namespace/tilemaps-orientation.

## 2. Purpose-built isometric renderers

**OpenTTD** (https://github.com/OpenTTD/OpenTTD/blob/master/src/viewport.cpp):
- Three sprite classes: ground tiles drawn first and unsorted; "parent" sprites with a 3D world bounding box,
  sorted; "child" sprites attached at a screen offset to a parent, never sorted.
- The sorter only reorders pairs whose boxes overlap
  (https://docs.openttd.org/source/d4/d7d/viewport__sprite__sorter__sse4_8cpp_source.html).
- Scrolling blits existing pixels and redraws only the exposed strips; tile changes mark dirty blocks.
- Six discrete zoom levels with art authored per level, not scaled
  (https://github.com/OpenTTD/OpenTTD/blob/master/src/zoom_type.h). Maximum map 4096x4096
  (https://github.com/OpenTTD/OpenTTD/blob/master/src/map_type.h).

**OpenRCT2** (https://github.com/OpenRCT2/OpenRCT2/blob/develop/src/openrct2/paint/Paint.cpp):
- 32 x/y units per tile, 8 z units per height step
  (https://github.com/OpenRCT2/OpenRCT2/blob/develop/src/openrct2/world/Location.hpp).
- Four camera rotations are first-class: each has its own sort comparison.
- Paint structs are bucketed into diagonal quadrants and box-compared only against their own and the next
  quadrant, which bounds the quadratic sort. A debug wireframe shows the sort boxes.
- Each paint struct records what it represents, so picking reuses the paint list.
- View flags are renderer features: hide or make see-through by category, cut-away, underground view
  (https://github.com/OpenRCT2/OpenRCT2/blob/develop/src/openrct2/interface/ViewportFlags.h).

**Age of Empires II** (https://simonsan.github.io/openage-webdocs/sphinx/doc/media/blendomatic.html): no transition
art. Each terrain has a priority; a higher-priority neighbour is drawn over the base tile through a shared alpha
mask picked from the 8-neighbourhood.

**Factorio:** batching keyed by texture plus render state; sprites outside atlases gave "thousands of draw calls
instead of just hundreds", fixed with one virtual atlas (https://factorio.com/blog/post/fff-251,
https://factorio.com/blog/post/fff-264). Terrain transitions moved to shared greyscale masks over a world-anchored
material texture (https://factorio.com/blog/post/fff-214).

**Pre-rendered art with depth:** Pillars of Eternity renders final, depth, normal and albedo passes per background
for per-pixel occlusion and dynamic lights (https://eternity.obsidian.net/news/update--79-graphics-and-rendering-).
Disco Elysium projects painted tiles onto a simple 3D block-in
(https://discoelysium.com/devblog/2016/08/18/tiling-of-the-world).

## 3. What users of Godot and Unity report as missing

- **Elevation.** Godot has no height model; the workaround is one tile layer per level with a shifted sort origin
  (https://forum.godotengine.org/t/unable-to-properly-y-sort-entities-in-a-multi-leveled-isometric-tilemap/93061),
  and performance drops as layers stack
  (https://forum.godotengine.org/t/performance-issues-with-lots-of-tilemaplayers-for-large-3d-stacked-worlds/116503).
- **Multi-tile sorting.** Godot #71257: objects larger than one cell sort wrongly from a single origin; the
  maintainer called it "not really a fix" without X-sorting (https://github.com/godotengine/godot/issues/71257).
  Unity's Z-as-Y sorting mis-sorts tall and multi-cell sprites
  (https://discussions.unity.com/t/isometric-tilemap-sorting-issues/714645).
- **Picking with height.** Godot has no API
  (https://forum.godotengine.org/t/solved-how-to-find-tile-under-cursor-in-a-multilevel-2d-isometric-terrain/7893);
  Unity's `WorldToCell` ignores elevation
  (https://discussions.unity.com/t/clicking-on-tiles-with-an-isometric-z-as-y-tilemap/739199).
- **Batching.** Godot's Y-sort disables quadrant batching; Unity's Chunk mode needs a single atlas and cannot
  interleave other renderers.
- Camera rotation, bridges and half-height walls: no engine support found in either [UV].

## 4. Why one depth number cannot sort footprints

A 1x3 wall A covers x 0..1, y 0..3. A 1x1 hut B covers x 1..2, y 0..1. B stands in front of the wall and overlaps
it on screen, so A must draw first. Keyed by front corner (max x + max y): A = 4, B = 3, B draws first, wrong.
Keyed by back corner: right here, wrong for the mirrored hut behind the wall's far end. Keyed by centre: a tie.
Correct ordering needs a pairwise "behind" relation between boxes, applied only to pairs whose screen rectangles
overlap, and a topological order over it (https://shaunlebron.github.io/IsometricBlocks). With differing heights
three boxes can form a cycle; engines treat that as a content error fixed by slicing the sprite.

## 5. Techniques

- **Terrain transitions:** priority plus shared masks (section 2); dual grid, where the visual grid is offset half
  a cell and each visual tile is chosen by its four corners
  (https://excaliburjs.com/blog/Dual%20Tilemap%20Autotiling%20Technique); Wang corner, edge and blob sets (Tiled).
- **Fog of war:** one texel per tile in a small texture, filtered, drawn as one quad
  (https://wildfiregames.com/forum/topic/14325-fog-rendering). Explored and visible as two channels [UV].
- **Outlines:** a distance field generated from alpha at bake time gives width-adjustable outlines
  (https://www.redblobgames.com/x/2404-distance-field-effects/).
- **Shadows without double darkening:** draw all shadows opaque into one layer, composite once with a single
  alpha.
- **See-through for occluded units:** occluders write depth or stencil; units are redrawn as a flat silhouette
  with an inverted test. A stencil alone cannot tell in front from behind.
- **Picking with elevation:** walk candidate tiles front to back; or reuse the draw list (OpenRCT2).
- **Culling a diamond map:** inverse-project the screen rectangle, padded for tall sprites and maximum elevation,
  to a tile range.
- **Batching across atlases:** a per-instance texture index into a texture array or an array of textures
  (https://jorenjoestar.github.io/post/modern_sprite_batch). Apple5 limits per the capability table of
  2026-10-23 (https://developer.apple.com/metal/capabilities/): 96 texture table entries per function, 16
  samplers, 2048 array layers, arrays of textures (read) since Apple3, argument buffers tier 1 only (tier 2 from
  Apple6).

## 6. Running the engine: Simulator, Previews, SwiftPM, macOS

- **The iOS Simulator cannot run the single-pass design of D1.** Apple documents the Simulator device as "similar
  to an Apple family 2 GPU", says programmable blending is unsupported and "Don't use Simulator to design your ...
  rendering engine" (https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator).
  [probe] A pipeline with a `[[color(0)]]` input fails with "reading from a rendertarget is not supported"; the
  device reports `apple1`, `apple2`, `common1` only.
- **Other Simulator limits.** [probe] Maximum 2D texture 8192; no counter sets (no GPU timing); ASTC LDR and
  staging-buffer blits work; `bgr10a2Unorm` and `rgba16Float` drawables work. Documented: no writes to sRGB
  textures, constant buffers at most 64 KB with 256-byte offset alignment.
- **iOS Previews run in the Simulator** and inherit all of the above; macOS Previews run natively
  (https://developer.apple.com/documentation/xcode/interacting-with-previews-in-the-canvas). That Metal behaves
  the same inside a preview is an inference [UV].
- **Apple-silicon macOS runs the full design.** [probe] The M1 Pro reports `apple1`-`apple7` and `metal3`; a
  memoryless `rgba16Float` attachment read through `[[color(0)]]` in one pass returns correct pixels.
  `CAMetalDisplayLink` exists on macOS 14+. Mac Catalyst and "Designed for iPad" were not tested [UV].
- **SwiftPM compiles `.metal`** with Swift 6.4, where Swift Build is the default back end [probe]. The Metal
  Toolchain is a separate Xcode component since Xcode 26 (`xcodebuild -downloadComponent metalToolchain`); on the
  owner's Mac it was not installed on 2026-11-25, so a package with a `.metal` file fails to build there until it
  is. CI needs it too.
- **Consumer side.** IdleVillage's `scripts/agent-test.sh`, player journeys and UITests all run on the iOS
  Simulator, so whatever the engine does there is what the consumer's test loop sees.

## 7. Hot reload

- **Assets:** `DispatchSource` file-system sources or `NSFilePresenter` on macOS. Simulator apps can read host
  paths (https://developer.apple.com/forums/thread/736983). Devices: `devicectl device copy to --domain-type
  appDataContainer` (https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line)
  or a network push.
- **Shaders:** `makeLibrary(source:options:)` has no include search path
  (https://developer.apple.com/documentation/metal/mtldevice/makelibrary(source:options:)). [probe] About 42 ms
  cold for a small source on macOS, about 3.1 s cold in the Simulator. Compile options must mirror the offline
  build.
- **Code:** InjectionNext is maintained for Xcode 27 (https://github.com/johnno1962/InjectionNext); it needs
  `-Xlinker -interposable` and can only change function bodies. Apple offers nothing beyond Previews.
- **Other engines:** Defold pushes resources to a running device build and keeps Lua state
  (https://defold.com/manuals/hot-reload/); Bevy reloads assets through a file watcher; Godot syncs scene and
  script changes to a running game; Flutter keeps state but does not re-run initialisers
  (https://docs.flutter.dev/tools/hot-reload). Common failures: state whose layout changed, initialisers not
  re-run, GPU resources swapped mid-frame, handles that lose identity on reload.

## 8. Could it carry an RTS (Command & Conquer, Warcraft II, StarCraft class)?

For rendering, yes. Square-cell games map to an orthogonal basis; Tiberian Sun and Red Alert 2 to a diamond basis
with elevation. Pathfinding, simulation, lockstep networking, AI and audio are outside this engine by design.

| Need | Where it is handled |
|---|---|
| Maps of 64 to 256 tiles a side | D16 |
| Cliffs and ramps | D13, D14 |
| Box selection and unit picking | D17 |
| Many facings, turrets | existing sheets, parts and rigs (E-XF, E-RIG) |
| Team colours | ticket #14 |
| Selection rings, health bars, drag rectangle in release builds | ticket #15 |
| Minimap | ticket #16 |
| Fog of war and shroud | ticket #17 |
| Terrain transitions | ticket #18 |
| Building-placement grid: one outline around a footprint of any shape | ticket #41 |
| Placement cells coloured valid or blocked, following the pointer | ticket #42 |

### 8.1 Building placement (added 2026-11-26)

The StarCraft-style grid under a building ghost. Per-cell boxes need nothing new: a bordered cell texture as a
per-tile overlay (E-TILE-4) on a retained layer (D16), with the tile under the pointer from the pick query (D17),
cells lifted with their level (D13) and the ghost drawn with instance tint, alpha or the silhouette fill
(E-BLEND-5, E-BLEND-7). Any footprint shape works because the overlay is per-cell data. Three gaps: no stroked
shape in release builds (E-DBG-1 is compiled out), so a border scales with the camera; no single perimeter around
a multi-tile footprint without a 16-case edge set chosen by the consumer; no per-tile colour, so each state is its
own overlay texture, and a highlight on the ground layer dirties ground chunks on every pointer move.

### 8.2 What an RTS changes, beyond the tickets above (added 2026-11-26)

Own reasoning from the Decisions and the catalogue, not measured. Ordered by how expensive each is to retrofit.

1. **Sort cost.** D14 caches the order and re-sorts only what moved (E-SORT-9). In an idle village almost nothing
   moves; in an RTS everything does, so the screen-space bucketing D14 defers becomes the normal path.
2. **Instance format.** D15 fixes it from day one with one reserved byte. Team colour needs a colour and a mask
   slot per instance, placement cells a per-tile colour. Widening the format later touches every pipeline and
   every golden image.
3. **Frame description.** More than one tile layer per frame (placement highlights, fog of war) and more than one
   view of a scene (minimap). Scene files are versioned (D18), but a first version with a list of layers is cheaper.
4. **Ramps.** D13 gives flat terraces with cliff faces and defers per-corner heights. RTS maps need walkable ramps.
5. **Frame rate and power.** Idle wants render on demand and low rates (D3); an RTS is continuous 60 Hz with
   full-screen motion. The policy carries both; the budgets (D10) were framed around the idle case.
6. **Texture memory.** 8 or 16 facings times several animations multiply sheet area. Mirroring halves it; the
   64 MB resident target (D-MEM-1) and K textures per batch (D15) are the first limits hit.
7. **Zoom range.** The visible-tile budget (E-LAYER-7) sets the minimum zoom. RTS players zoom further out than a
   village view, which is where the deferred level of detail comes in.
8. **Readability against mood.** Glow, soft light, the colour grade and scene fog carry the cozy look; an RTS needs
   units readable at a glance, so effects need a ceiling or a per-band exemption, and glow per unit multiplies
   overdraw on the fill-rate floor device.

Outside the engine either way: a fixed-step simulation with interpolation (it fits an immutable frame description
plus injected time), pathfinding, selection policy and touch controls.

### 8.3 Closer second consumers: city builder, turn-based tactics (added 2026-11-26)

Both sit next to IdleVillage and use what D12-D22 already provide. A city builder needs building placement (8.1),
larger maps (D16), terrain transitions (#18) and many static buildings, which suits the cached sort. A tactics game
needs tile highlights for movement and attack range (#42), a selection marker and bars (#15) and elevation that
matters to the rules (D13), with few movers at a time. Neither needs the unit counts, continuous simulation or
zoom range of points 1, 5 and 7. D24 records the scope that follows.

## 9. Deferred, with no ticket yet

Each needs a seam, not an implementation: four-way camera rotation (the kit renders four views; D12 makes it four
bases); a single-alpha shadow layer; see-through, cut-away and hide-by-category view flags; optional depth and
normal bake passes from Blender; outlines from a baked distance field; a Tiled TMJ importer as a separate target
(a free map editor); in-world text at scale (SwiftUI overlays stop scaling at hundreds of labels); discrete zoom
levels with per-level art; animated tiles and flip flags; input beyond touch (pointer hover, trackpad and scroll
zoom, keyboard), which the macOS viewer forces early; several cameras on one scene; projected accessibility frames
for tappable sprites.

## Not verified

Whether "Designed for iPad" and Mac Catalyst support framebuffer fetch; whether the Simulator's 64 KB
constant-buffer limit forces instance data into per-instance vertex attributes; that the A12Z does not report the
`metal3` family (so capability checks must probe features, never family names); the Apple3 "arrays of textures"
entry (taken from the survey of the capability table, not re-read); Metal library loading from `Bundle.module`
inside Xcode 27 previews; the memory estimate for baked ground chunks (tens of megabytes per screenful at @2x, own
arithmetic); typical RTS map sizes (recollection). Sources not opened: Unity's Tilemap Renderer reference (404),
Factorio FFF-199, the Sims Z-sprite design document, anything for SimCity 2000/3000.
