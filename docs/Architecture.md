# Architecture

The engine as it stands, kept current by the tickets that change it. A ticket that adds a module, a public type, an
invariant or an extension point updates this file in the same branch; the reviewer checks it and the milestone audit
reads the whole milestone against it. It describes what exists. Plans live in tickets, reasons in `Decisions.md`.

As of HE-9 the engine draws flat and textured quads, opaque or premultiplied-over, headless (the harness's
foundation since HE-1) and on screen through a frame loop: display link, frame-rate policy, lifecycle gate and
pipelines warmed at init, one render pass per frame or the two-pass fallback. Since HE-21 a frame description is
written to and read from a versioned scene file (D18).

## Invariants

Numbered so a review can cite them. Each names where it comes from; an invariant with a catalogue id is also a test.

1. **Time is injected.** No clock read outside the display-link adapter (E-HAR-2, lint `clock`).
2. **A frame is a function of an immutable description and a time.** The render thread reads only an immutable
   `Sendable` frame description (E-API-2). Same inputs, same pixels on one GPU (E-HAR-3).
3. **Game-agnostic.** No consumer type, name or rule in the engine (D5, lint `agnostic`). The engine never reads a
   kit manifest (D21).
4. **One GPU boundary.** Metal 3-era API and Apple5 features only, behind one small internal GPU protocol (D4,
   E-API-3). Capabilities are probed by feature.
5. **Typed errors, never a crash** (E-HAR-4, lint `crash`).
6. **Swift 6 strict concurrency, warnings as errors, no dependencies** (E-API-1, lints `concurrency`, `deps`).
7. **Proof has rules** (D22): references are human-approved, skipped is not passed, every golden test has a
   negative control, scenes carry checkable intent.
8. **The engine never owns the host's state.** It reads the host's pause flag, lifecycle and interaction and
   reports `contentRate`; it never writes them (E-LIFE-3, `research/engine-pitfalls.md` 1.7). It renders on demand:
   nothing changing, no frame (D3, E-RATE-2).
9. **No pipeline after warm-up.** Every pipeline is built at init, off the main thread; the set is frozen
   (E-PSO-1..3).

## Module map

One package (`Package.swift`: Swift 6 language mode and warnings as errors on every target, no dependencies; iOS
26.4 and macOS 14 as the development host, D19).

| Target | Path | Owns | May import |
|---|---|---|---|
| `HearthEngine` | `Sources/HearthEngine` | The engine: values, errors, the frame plan, the GPU boundary, shaders, the frame loop | Metal, QuartzCore, Foundation, os |
| `HearthHarness` | `Sources/HearthHarness` | What tests, and later the viewer, the benchmark app and the D22 harness tool, are built on: device probe, receipts, golden comparison, synthetic corpus, scene catalogue | `HearthEngine`, Metal, Foundation, CryptoKit |
| `HearthEngineTests` | `Tests/HearthEngineTests` | The E and B suites that run on the Mac; `Fixtures/` holds a scene file of every version the engine reads (E-SER-2) | both |

The engine imports nothing of the harness. Inside `HearthEngine`:

- **Values** (`EngineTime.swift`, `PixelImage.swift`, `FrameDescription.swift`, `EngineError.swift`): plain `Sendable`
  values with no GPU object and no closure.
- **`SceneFile`** (`SceneFile.swift`, `SceneJSON.swift`): the scene file of D18. A scene is a list of tile layers
  and a list of views (D24); a view is a name, a `RenderTarget` and a `FrameDescription`. Version 1 names its layers
  and holds nothing else of them; their content is D16's (#25) and comes as a later version. The bytes are UTF-8
  JSON with one spelling (E-SER-3): keys sorted by UTF-8 bytes, two-space indent, a container that is empty or holds
  only scalars on one line, `Float` as Swift's shortest round-trip decimal without a trailing `.0`. `SceneJSON` is
  the engine's own writer and parser, not `JSONEncoder`: a number keeps its text and becomes a `Float` once,
  correctly rounded, so floats round-trip bit for bit (E-SER-1); the parser bounds nesting at 32 and never traps.
  Decoding reads `format`, then `version` (outside `supportedVersions` is `unsupportedSceneVersion`, whatever the
  body), then the body of that version; unknown, missing and duplicate keys are refused. Encode and decode check the
  same rules (names non-empty and unique, target sides in range, rectangles finite), so whatever encodes decodes.
  Textures are named, never embedded. Names compare as `String`s (canonical equivalence) while the bytes follow
  the scalars, so `==` scenes may encode differently; one value always encodes the same. `RenderOptions` are not
  in the file: they are the replaying caller's choice.
- **`FramePlan`** (internal): a frame validated against a target and turned into vertices and draws. Pure; every
  refusal (target size, format, a quad that is not finite, a missing texture) is decided here, before a Metal call
  exists.
- **`GPU/GPUBackend`** (internal protocol, invariant 4) and **`GPU/MetalBackend`**, its only conformer. `warm`
  probes the device (programmable blending by building the single pass's own final stage; never a family name),
  takes the texture limit from the environment (8192 in the Simulator, 16384 elsewhere: Metal has no query and
  allocating past it trips validation) and builds every pipeline of `PipelineKey.precompiled` for the requested
  target formats concurrently, off the caller's thread, before the renderer exists (E-PSO-3). The on-screen loop
  warms the drawable's format only (5 pipelines), the harness both (10). The set is then frozen: a key outside it
  is a `gpuFailure`, never a build (E-PSO-1). `build` is the engine's only caller of `makeRenderPipelineState`
  and every build is counted in one place. One `encode` serves the offscreen target (then a blit readback) and a
  drawable, so the goldens prove the on-screen encode. `GPUCounters` (passes, draws, binds per frame; pipelines
  ever built, and on the main thread) back the audits and the PERF probes. Every allocation goes through
  `requireGPU`, so a refusal is an `EngineError.gpuFailure`.
- **`GPU/PassLayout`**: `GPUFeatures`, `GPURestrictions` (what a renderer may use; `.floor` is every optional
  feature off and the Simulator's 8192 limit), `GPUCapabilities` and the two pass layouts as data. Single pass: the
  target (don't-care, store) is attachment 0, the scene a memoryless `rgba16Float` attachment 1 (clear,
  don't-care) that the final stage reads through `[[color(1)]]`. Two passes (D18): the scene is a stored private
  texture the final stage samples. The final stage is a copy until grade, encode and dither arrive (#3, #11).
- **`GPU/PipelineKey`**: stage (solid, textured, final), blend, layout and target format; each key's attachments
  (in the single pass, scene stages never write attachment 0 and the final stage never writes attachment 1) and
  shader functions.
- **`GPU/MetalFrameSubmitter`**: the on-screen half: plans a frame, encodes it into the drawable with the shared
  encoder, presents (after the measured interval on the `CADisplayLink` path) and commits; vertices in a ring of
  three buffers; completions mapped to `CommandBufferOutcome` and handed to the loop on the main actor.
- **`Loop/`**: the frame loop. Pure parts: `FramePolicy` (D3's table, E-RATE-1), `FrameClock` (time from link
  targets, absolute, `dt` clamped to 0.1 s, `discontinuity` on a jump; E-TIME-2..4), `RateEstimator` (the delivered
  rate snapped to the display's cadences, E-RATE-4), `LifecycleGate` (E-LIFE-1), `PixelSize` (drawable size from
  layout, E-LIFE-4), `HostChecks` (E-PLIST-1). `FrameLoop` ties them to four seams, each faked in the tests:
  `DisplayLinkDriver`, `DrawableLayer`, `FrameSubmitter` and the host's `FrameSource`. `DisplayLink.swift` holds
  the `CAMetalDisplayLink` driver and the iOS `CADisplayLink` one (D9): the one file the clock lint exempts, though
  it reads no clock. `MetalLayerSurface` configures the host's layer once (`framebufferOnly`, three drawables,
  `.topLeft` gravity so a pending resize never scales old pixels). `SystemConditions` watches Low Power Mode and
  thermal state. A released loop invalidates its link and observers (`isolated deinit`): the run loop would keep a
  link firing for an owner that is gone. Command-buffer failures carry the activation they were submitted in; one
  from before the latest return to `.active` is logged and does not pause the loop.
- **`Shaders/Quad.metal`**: compiled by the build into the target's bundle. Nothing compiles shader source at run
  time. The Metal Toolchain it needs is checked by `scripts/metal-toolchain` before every build (B-TOOL-1).

Inside `HearthHarness`:

- **`HarnessGPU`**: the one place that asks for the system device. The provider is injectable and
  `HEARTH_NO_GPU=1` hides the device, so "no GPU" is testable (E-HAR-5).
- **`Receipt`**: outcomes by catalogue id; complete only with a GPU, at least one id and nothing skipped or failed.
  It holds the rule of E-PROOF-2; the file on disk comes with the harness tool.
- **`Golden/`**: `NearExact` (the catalogue's 2/255 on 99.9% and 8/255 on all, and `exact`), `FLIP` (LDR-FLIP from
  the paper: mean and 99th percentile), `GoldenCheck` (one comparison; a failure writes actual, expected and the
  difference map as PNG, a pass writes nothing). `PNGEncoder` writes stored-deflate PNG with no image framework.
- **`Corpus/SyntheticCorpus`**: the synthetic tier of D21, generated with integer arithmetic; no binary asset.
- **`HarnessScene`**: a named scene, its textures and its frame as a function of `EngineTime`. `catalogue()` is the
  scene catalogue of D19; `postcard` is its smoke-test scene.
- **`SplitMix64`**: the seeded generator of every property test. **`PixelImage.sha256`**: size and pixels.

## Public surface

`HearthEngine`:

- `OffscreenRenderer`: the headless entry point. `init(device:restrictions:) async` (the warm-up),
  `setTexture(_:image:)`, `render(_:target:options:)`, `capabilities`, `counters`. No view, no display link, no
  clock.
- `GPURestrictions`, `GPUFeatures`, `GPUCapabilities`, `GPUCounters`.
- `FrameDescription`: clear colour and an ordered list of `Quad`. `Quad`: a `PixelRect` in target pixels (origin
  top-left, y down) filled with an `RGBA8` or a whole texture named by `TextureID`, with a `Blend`: `.opaque`
  (blending off, the default) or `.premultipliedOver`. Opaque quads come first (E-PASS-3). Values are otherwise
  written verbatim; colour space and premultiplication of textures arrive with the colour pipeline (D1 is open).
- `RenderTarget` (size and `PixelFormat`), `RenderOptions` (`missingTexture`: throw, the default, or draw the
  fallback colour).
- `FrameLoop`: the on-screen entry point, `@MainActor`. `init(layer:device:configuration:source:events:) async`;
  the host sets `lifecycle`, `interacting`, `isPaused` and calls `layoutChanged(size:scale:)`, `setNeedsFrame()`,
  `invalidate()`; it reads `contentRate` and `stats`. `FrameLoopConfiguration` (link kind, high rate, start time,
  display maximum, restrictions, options, idiom). `FrameSource` (the host: `motion` and
  `frame(for: FrameContext)`), `FrameContext`, `FrameClock`. `FramePolicy`, `FrameConditions`, `FrameRate`,
  `FrameRateRange`, `ContentMotion`, `ThermalLevel`, `Lifecycle`, `DisplayLinkKind`, `DeviceIdiom`.
  `EngineEvent` (`warning`, `commandBufferFailed`, `frameRefused`), `EngineWarning`, `CommandBufferFailure`,
  `FrameLoopStats`.
- `SceneFile` (`layers`, `views`, `init(data:)`, `encoded()`, `view(named:)`, `format`, `version`,
  `supportedVersions`), `SceneView`, `SceneTileLayer`.
- `PixelImage`: RGBA8, row-major, top row first; sides in `1...16384`; a device may allow less (`textureTooLarge`).
- `EngineTime`: absolute seconds as `Double`; `phase(period:)` wraps on the CPU, `gpuSeconds(period:)` is the
  wrapped `Float` a shader sees, `frameIndex(framesPerSecond:count:)` and `progress(since:duration:)`.
- `EngineError`: `noDevice`, `missingTexture`, `malformedAssetHeader`, `unsupportedFormat`, `invalidTargetSize`,
  `invalidQuad`, `opaqueAfterBlended`, `textureTooLarge`, `gpuFailure`, `invalidSceneFile(path:reason:)`,
  `unsupportedSceneVersion`. Every throwing function is `throws(EngineError)`.

`HearthHarness`:

- `HarnessGPU` and its `Availability` (`current` is this process's probe); `Receipt`.
- Golden comparison: `GoldenCheck` with `GoldenTier`, `GoldenOutcome` and `GoldenError` (`sizeMismatch`,
  `artifactWriteFailed`, `invalidPixelsPerDegree`); `NearExact` with `NearExactTolerance` and `NearExactResult`;
  `FLIP` with `FLIPThreshold` and `FLIPResult`, for viewing conditions of 1 to 1024 pixels per degree;
  `PNGEncoder`.
- `SyntheticCorpus`, `CorpusProjection`, `CorpusEntry`, `HarnessScene`, `SplitMix64`, `PixelImage.sha256`.

## Extension points

- **A second GPU back end** (Metal 4, D4): a second conformer of `GPUBackend`. `FramePlan` is its input and stays
  API-free. The Simulator's two-pass path (D18) is not a back end but a `PassLayout` of the Metal one, selected by
  the probe; #29 proves it equivalent (E-PASS-4).
- **A pipeline**: a `PipelineKey.Stage` and its functions; `precompiled` grows with it, so the warm-up builds it.
- **Texture loading**: `OffscreenRenderer.setTexture(_:image:)` uploads an image directly. The container loader
  replaces the upload and keeps `TextureID`, and throws `malformedAssetHeader` and `unsupportedFormat` for the
  container's own header.
- **Time**: on screen, time enters through `FrameContext.clock`, from the link's target timestamps; offscreen,
  through `HarnessScene.frame`. `render` takes no time while the engine has no animated value of its own. Tweens
  and particles (#10) reset cosmetic state on `FrameClock.discontinuity`.
- **Frame-rate policy**: `FramePolicy.rate(for:)` is the whole table; a new input is a `FrameConditions` field.
- **Scenes**: a new subsystem adds a `HarnessScene` to `catalogue()` and its parts to `postcard`.
- **Serialisation**: a field of `FrameDescription` or `Quad` is a field of the scene file. Adding one, or the tile
  layers' content, is a new version: `SceneFile.version` and `supportedVersions` grow, `SceneFileCodec` decodes each
  supported version, and a `Fixtures/scene-v<N>.json` is added and never edited, so every earlier file keeps
  decoding (E-SER-2). The harness tool, the viewer and hot reload (D19, D20, D22) open scenes with
  `SceneFile(data:)`.
