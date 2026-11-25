# What went wrong in other engines

Research of 2026-11-25: documented incidents from SpriteKit, Unity, Godot, Flutter/Impeller, Cocos, Defold,
Bevy, Phaser, LÖVE, SDL and others, each with its root cause, how robust engines avoid it, and the test that
would catch it. The tests are folded into `../TestCatalogue.md` (ids in brackets).
Legend: **[UV]** = unverified (search snippet, one report, or inference). Some SpriteKit sources are Stack
Overflow mirrors.

## 1. SpriteKit

**1.1 Frame rate stuck near 40 fps on iOS 26** (FB20287404, FB21914640, FB22038921). A minimal scene drops to
about 40 fps on iPhone 11 Pro, 13 and 16e on iOS 26.0/26.1 but holds 60 on iOS 18. Fixed in 26.2 beta 3,
regressed in 26.2.1/26.3, still present in 26.4; FB22038921 still open in Oct 2026 (DTS asked for a retest on
iOS 27.2 beta 3). Dragging a finger restores 60 fps, which points to OS frame scheduling or CPU power state.
Unity's `CADisplayLink` path showed the same drop; its `CAMetalDisplayLink` path hung on older iOS after a
command-buffer timeout, so Unity turned it off by default.
Sources: https://developer.apple.com/forums/thread/800952, https://developer.apple.com/forums/thread/815783,
https://developer.apple.com/forums/thread/816719,
https://issuetracker.unity3d.com/product/unity/issues/guid/UUM-125778,
https://issuetracker.unity.com/issues/21514/game-freezes-after-command-buffer-timeout-error-disable-cametaldisplaylink-by-default.
Avoid: own the display link and the present; measure on every OS beta; keep a fallback link path.
Test [D-PACE-1]: frame-interval harness, trivial and village scenes, idle and with a synthetic drag.

**1.2 Touch and SwiftUI overlays cost frames.** Touching an iOS 26.3.1 SpriteKit scene drops fps even with
empty handlers (https://developer.apple.com/forums/thread/821590). A SwiftUI glass `Menu` over a `SpriteView`
drops frames, FB20808104 (https://developer.apple.com/forums/thread/804973). Unity: frame drops on touch on
ProMotion devices (https://issuetracker.unity3d.com/issues/ios-framerate-drops-when-screen-is-touched-on-promotion-devices).
Avoid: hit-test on our own geometry; keep SwiftUI chrome light over the Metal layer.
Test [D-PACE-2]: pacing under a touch stream and under an animating SwiftUI sheet.

**1.3 First-use shader compile hitch.** `SKShader` compiles on first render, not on creation
(https://developer.apple.com/forums/thread/690915). See 2.1.

**1.4 Opaque texture cache, atlas memory, leaks.** `SKTextureAtlas.preload` leaked and doubled memory
(https://developer.apple.com/forums/thread/65482); `SKTileMap` leaks with `SKTexture(rect:)`
(https://developer.apple.com/forums/thread/769734, https://developer.apple.com/forums/thread/93295).
Avoid: texture lifetime owned by the app through an explicit registry.
Test [E-MEM-2]: load/unload/reload 20 times; footprint within 2% of cycle 1, live textures back to baseline.

**1.5 Batching broken by atlas source.** Asset-catalog atlases did not batch; runtime atlases did
(FB9763803, https://developer.apple.com/forums/thread/694641). Test [E-BATCH-1]: draw-call budget per scene.

**1.6 `SKEffectNode` / CIFilter cost.** Filters run every frame without `shouldRasterize`; full-screen blur
too heavy (https://developer.apple.com/documentation/spritekit/skeffectnode/shouldrasterize,
https://developer.apple.com/forums/thread/714230). Avoid: bake effects; one fixed post pass. Test [D-GPU-1].

**1.7 `SKView` pauses itself.** It sets `isPaused` on resign-active and restores it, unpausing games that had
paused (https://developer.apple.com/documentation/spritekit/skview/ispaused,
https://developer.apple.com/forums/thread/692527). Avoid: one pause state owned by the app.
Test [E-LIFE-3]: pause, background, foreground; still paused, frame counter unchanged.

**1.8 Straight alpha out of a shader** gives fringes; SKShader output must be premultiplied
(https://developer.apple.com/documentation/spritekit/blending-a-sprite-with-different-interpretations-of-alpha). See 2.3.

**1.9 Retain cycles in action closures** keep scenes alive (https://developer.apple.com/forums/thread/701295). See 4.3.

**1.10 Tile-map cracks at non-integer zoom** (https://mfessenden.github.io/SKTiled/1.3/troubleshooting.html). See 2.4.

## 2. Cross-engine 2D pitfalls on iOS and Metal

**2.1 Pipeline compile stutter.** Flutter/Skia shader jank since 2015; SkSL warm-up did not work on Metal
(https://github.com/flutter/flutter/issues/61450); Impeller fixed it by compiling a fixed shader set at build
time (https://flutter.googlesource.com/mirrors/engine/+/61616ace5fa8ff8a74c370c84f1eebfb9779b3cb/impeller/docs/faq.md),
yet still janks on some heavy shaders (https://github.com/flutter/flutter/issues/148496). Godot compiled
pipelines on first view until 4.4; its 2D canvas pipelines are still not precompiled
(https://docs.godotengine.org/en/stable/tutorials/performance/pipeline_compilations.html); a 5 s first-launch
freeze on iOS 26 [UV, one report] (https://developer.apple.com/forums/thread/824902) and an App Review
rejection as unresponsive (https://forum.godotengine.org/t/ios-app-rejected-unresponsive-on-launch/130784).
Unity URP `GetCachedPipeline` spikes
(https://discussions.unity.com/t/gpuprogrammetal-getcachedpipeline-frame-time-issue-on-ios-urp/1539777).
Root cause: a pipeline needs the full state, known only at first draw. Avoid: a small closed pipeline set, all
built at launch asynchronously, `.metallib` precompiled, never a pipeline created in the frame loop.
Tests [E-PSO-1..3].

**2.2 Texture upload hitches and upload bugs.** Upload happens just before first use; three.js and PlayCanvas
pre-draw off-screen (https://discourse.threejs.org/t/how-to-improve-texture-first-render-performance/10436).
ASTC uploads to private storage through a blit mis-addressed a mip tail on A15 and M5
(https://developer.apple.com/forums/thread/845139). Cocos crashed switching large maps
(https://forum.cocos.org/t/topic/172363). Avoid: decode off the main thread, upload on a separate queue,
fence before first use, never block a frame on an upload. Tests [E-TEX-5, E-TEX-6, D-HITCH-1].

**2.3 Alpha fringes.** Filtering straight alpha averages in the colour of transparent texels (dark halos);
premultiplying twice darkens edges (https://www.realtimerendering.com/blog/?p=4075,
https://www.adriancourreges.com/blog/2017/05/09/beware-of-transparent-pixels,
https://iquilezles.org/articles/premultipliedalpha, https://www.love2d.org/wiki/BlendAlphaMode).
Avoid: premultiply once at import, recorded in the asset header; one blend function.
Tests [E-ALPHA-1..3].

**2.4 Tile seams, cracks and atlas bleed at fractional zoom.** Godot seams at zoom 1.0 that vanish at 0.99
(https://godotengine.org/qa/105272/lines-seams-bug-on-tilemap); Unity tearing even with pixel snap, fixed by 8 px
padding (https://discussions.unity.com/t/tilemap-has-tearing-between-tiles-even-with-pixel-snap/679199); Phaser
gaps fixed by extrusion (https://phaser.discourse.group/t/tilemap-gaps-when-camera-moves/1162); Godot thin lines
between high-fidelity isometric tiles that no filter fixes
(https://forum.godotengine.org/t/thin-lines-between-2d-isometric-tiles-nearest-fixes-pixel-art-but-no-filter-works-for-high-fidelity-tiles/119606).
Root causes: filtering reads neighbours; shared edges not bit-identical (T-junctions); mips average across
borders; and, for soft-edged diamonds, the conflation artifact (two 50% edges give 75% coverage, see
image-quality.md 2). Avoid: opaque, geometry-clipped ground; shared vertices from integer grid coordinates through
one transform; extrusion. Tests [E-TILE-1..3].

**2.5 Sub-pixel jitter.** Godot Camera2D rounds after smoothing so edges crawl
(https://github.com/godotengine/godot-proposals/issues/6389); isometric jitter while the player moves
(https://forum.godotengine.org/t/help-with-2d-isometric-pixel-art-tilemap-jitter-when-player-moves/109938).
Root cause: some layers snapped, others not. Avoid: snap nothing while moving (soft art), snap to device
pixels only at rest, one rule for camera and sprites. Tests [E-CAM-5, E-QUAL-6].

**2.6 Flicker from equal sort keys.** Unity sprites with equal order swap randomly
(https://discussions.unity.com/t/sprite-changes-sort-order-randomly-issue/818913); Bevy draws equal layers in
arbitrary order (https://docs.rs/crate/extol_sprite_layer/latest); Phaser isometric flicker
(https://www.html5gamedevs.com/topic/10120-depth-issue-with-isometric-plugin/). Avoid: a total order key
(layer, depth, stable id, sub-part). Test [E-SORT-2].

**2.7 Batching broken by state changes.** Unity MaterialPropertyBlocks break SRP batching
(https://discussions.unity.com/t/srp-batcher-spriterenderer/918871); Flame on Impeller issues many separate
`drawImageRect` calls. Avoid: per-instance data in an instance buffer, few atlases. Test [E-BATCH-1..2].

**2.8 Overdraw on tile-based GPUs.** Hidden-surface removal only helps opaque fragments; every blended layer is
shaded (https://developer.apple.com/documentation/metal/tailor-your-apps-for-apple-gpus-and-tile-based-deferred-rendering,
https://developer.apple.com/videos/play/wwdc2020/10632). Avoid: opaque ground pass with blending off, tight sprite
meshes, one in-pass grade. Test [D-GPU-2].

**2.9 Gamma-incorrect blending.** Unity: switching to linear changes how gamma-authored alpha looks
(https://docs.unity3d.com/2020.3/Documentation/Manual/LinearRendering-LinearOrGammaWorkflow.html); a Metal `_srgb`
drawable needs a matching layer colorspace (https://developer.apple.com/forums/thread/724223). Visible effect:
glow "hot" in gamma, softer in linear; the engine stops matching the art tool. Avoid: decide once (an ADR), set
`CAMetalLayer.colorspace` explicitly, keep the LUT in the same space. Tests [E-COL-1..3].

**2.10 HDR/EDR/P3 surprises.** EDR needs an extended-linear colourspace, a float format and the flag together
(https://developer.apple.com/documentation/metal/using-color-spaces-to-display-hdr-content). Avoid: stay SDR.
Test [E-COL-4].

**2.11 Frame pacing and judder.** WWDC21 10147 (https://developer.apple.com/videos/play/wwdc2021/10147): sample
animation at `targetTimestamp`; fixed 8 ms steps run slow when callbacks are skipped; plain `present` hitches,
`present(afterMinimumDuration:)` paces. 120 Hz on iPhone needs `CADisableMinimumFrameDurationOnPhone`
(https://www.developer.apple.com/forums/thread/792011). A missed vsync makes iOS raise CPU clocks then drop them,
so frame time oscillates [UV]. Avoid: one clock (`targetTimestamp`), dt from successive targets, a rate that
divides the refresh. Tests [E-TIME-2, D-PACE-1, E-PLIST-1].

**2.12 Thermal throttling.** Games drop to 30 fps at "serious"; Unity added a thermal fps setting
(https://developer.apple.com/forums/thread/696078,
https://docs.unity3d.com/6000.5/Documentation/ScriptReference/PlayerSettings-adjustIOSFPSUsingThermalState.html).
No Apple curve for when it happens [UV]. Tests [E-RATE-1, D-SOAK-1].

**2.13 Battery drain when idle.** Apple's energy guide: avoid extraneous graphics
(https://developer-mdn.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/AvoidExtraneousGraphicsAndAnimations.html);
Godot's low-processor mode still ran at 60 on Android
(https://forum.godotengine.org/t/how-to-use-low-processor-in-android/5298); Defold users ask how to pause
rendering (https://forum.defold.com/t/any-way-to-pause-game-rendering-to-reduce-cpu-usage-when-idle/64112).
Avoid: render on demand plus an "animating" count. Tests [E-RATE-2, D-IDLE-1].

**2.14 GPU work encoded in the background.** Command buffers committed after backgrounding fail
(`notPermitted`); iOS 26.2 aborts with `accessRevoked` and whisper.cpp crashed its host
(https://github.com/ggml-org/whisper.cpp/issues/3531); SDL fixed crashes by stopping its loop
(https://discourse.libsdl.org/t/ios-app-sent-to-background-gets-exc-bad-access/21575); Apple:
https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background.
Tests [E-LIFE-1..2].

**2.15 Memory warnings and jetsam.** Per-app limits change between OS releases: an 8 GB iPad went from about
6 GB to about 3 GB in iPadOS 26.4 (https://developer.apple.com/forums/thread/826325) [UV]; Unity under-reports
ASTC memory
(https://issuetracker.unity3d.com/issues/higher-than-expected-memory-for-certain-block-sizes-is-used-when-using-astc-textures-on-ios-devices).
Avoid: compressed textures, a texture budget in code, purgeable caches, measure `phys_footprint` and
`allocatedSize`. Tests [E-MEM-1..3, D-MEM-1].

**2.16 App size.** No postmortem found [UV]; mechanism: duplicate @2x/@3x PNGs, unstripped shader sources.
Test [B-SIZE-1].

**2.17 Low Power Mode, Limit Frame Rate, Adaptive Power** can each cap the rate; iOS 26 Adaptive Power has no
public detection API [UV]. Test [D-PACE-3]: detect the real rate and pace evenly at it.

**2.18 Drawable size during resize.** The drawable lags the view during live resize
(https://developer.apple.com/documentation/metal/managing-your-metal-app-window-in-ipados,
https://thume.ca/2019/06/19/glitchless-metal-window-resizing/); `nextDrawable` blocked about 1 s after a size
change (https://www.developer.apple.com/forums/thread/773229); Unity launch screen partly transparent in iPad
split view; Unity fps drop after rotation (https://issuetracker.unity.com/issues/19924/iphone-13-pro-framerate-drops-after-rotating-the-device).
Tests [E-LIFE-4, U-RESIZE-1].

## 3. Isometric

**3.1 Depth sorting of tall or multi-tile objects.** Godot multi-tile y-sort wrong because the sort origin is the
tile centre (Godot #71257 via https://forum.godotengine.org/t/godot-4-tilemap-sorting-larger-objects/3915);
Unity isometric chunks sorted wrongly; point sorting "fails spectacularly", segment sorting plus topological
sort works (https://gist.github.com/CharlieHess/ae59e5d268176391375d5014e4e3db8c,
https://shaunlebron.github.io/IsometricBlocks). Avoid: for grid-snapped footprints sort by the footprint's
front corner with a deterministic tie-break; topological sort only for free walkers. Test [E-SORT-3].

**3.2 Walkers crossing footprints** flip order back and forth. Avoid: depth from the continuous foot point,
hysteresis tie-break. Test [E-SORT-4].

**3.3 Hit-testing that disagrees with draw order** [UV, inference]: tapping a tower's top hits the tile behind.
Avoid: hit-test from the same sorted list. Test [C-HIT-2]: an id buffer agrees with the hit test at 1,000
random points.

## 4. Time and animation

**4.1 Float time precision and dt drift.** Unreal shader time visibly degrades after about 1 hour
(https://issues.unrealengine.com/issue/UE-373131); Unity half-precision time stutters after minutes
(https://issuetracker.unity3d.com/issues/half-point-precision-causes-stutter-in-shader); cocos2d mediump time
degrades after about 10k frames; Defold variable dt ran the game twice as fast
(https://forum.defold.com/t/variable-dt-causes-game-to-run-twice-as-fast-def-3146-solved/15827). Avoid: phase from
absolute `Double` time wrapped with `fmod` on the CPU, `float` (never `half`) for time in shaders.
Tests [E-TIME-1, E-TIME-3].

**4.2 Long-absence catch-up.** "Fix Your Timestep" spiral of death (https://gafferongames.com/post/fix_your_timestep/);
idle games compute offline progress in closed form (https://blog.kongregate.com/quest-for-progress-the-math-of-idle-games).
Renderer side: an emitter spawns rate x hours, or tweens replay. Avoid: closed-form sim (the game already has
it), clamp render dt, reset cosmetic particle state after a gap. Test [E-TIME-4].

**4.3 Tween leaks.** DOTween, LeanTween and Phaser tweens outliving their targets
(https://cyberagentgameentertainment.github.io/UnityPerformanceTuningBible/en/tuning_practice_third_party.html,
https://github.com/phaserjs/phaser/pull/6812). Avoid: tweens are values owned by their entity, no closures that
capture the scene. Test [E-ANIM-5].

**4.4 Loop seams** [UV, no incident found]: duplicated first/last frames stall; 7 fps on 60 Hz alternates 8 and 9
refreshes. Tests [E-ANIM-6, K-LINT-2].

## Not verified

Whether FB22038921 is fixed in iOS 27.x; any 10-minute thermal curve; whether Low Power Mode caps at 30 or 60;
the Unity "WaitForPresent spikes" issue (page gone); Godot #71257 details; postmortems for hit-test mismatches,
loop seams and app-size bloat; the Godot 5 s freeze (one report).
