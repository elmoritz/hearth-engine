# Architecture

The engine as it stands, kept current by the tickets that change it. A ticket that adds a module, a public type, an
invariant or an extension point updates this file in the same branch; the reviewer checks it and the milestone audit
reads the whole milestone against it. It describes what exists. Plans live in tickets, reasons in `Decisions.md`.

As of HE-1 the engine is the test harness's foundation: a headless offscreen path that draws flat and textured
quads, and the tools every later ticket proves itself with.

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

## Module map

One package (`Package.swift`: Swift 6 language mode and warnings as errors on every target, no dependencies; iOS
26.4 and macOS 14 as the development host, D19).

| Target | Path | Owns | May import |
|---|---|---|---|
| `HearthEngine` | `Sources/HearthEngine` | The engine: values, errors, the frame plan, the GPU boundary, shaders | Metal, Foundation |
| `HearthHarness` | `Sources/HearthHarness` | What tests, and later the viewer, the benchmark app and the D22 harness tool, are built on: device probe, receipts, golden comparison, synthetic corpus, scene catalogue | `HearthEngine`, Metal, Foundation, CryptoKit |
| `HearthEngineTests` | `Tests/HearthEngineTests` | The E and B suites that run on the Mac | both |

The engine imports nothing of the harness. Inside `HearthEngine`:

- **Values** (`EngineTime.swift`, `PixelImage.swift`, `FrameDescription.swift`, `EngineError.swift`): plain `Sendable`
  values with no GPU object and no closure.
- **`FramePlan`** (internal): a frame validated against a target and turned into vertices and draws. Pure; every
  refusal (target size, format, a quad that is not finite, a missing texture) is decided here, before a Metal call
  exists.
- **`GPU/GPUBackend`** (internal protocol, invariant 4) and **`GPU/MetalBackend`**, its only conformer. `warm`
  probes the device (programmable blending by building the single pass's own final stage, the texture limit by
  allocation; never a family name) and builds every pipeline of `PipelineKey.precompiled` concurrently, off the
  caller's thread, before the renderer exists (E-PSO-3). The set is then frozen: a key outside it is a
  `gpuFailure`, never a build (E-PSO-1). One `encode` serves the offscreen target (then a blit readback) and a
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
- `PixelImage`: RGBA8, row-major, top row first; sides in `1...16384`.
- `EngineTime`: absolute seconds as `Double`; `phase(period:)` wraps on the CPU.
- `EngineError`: `noDevice`, `missingTexture`, `malformedAssetHeader`, `unsupportedFormat`, `invalidTargetSize`,
  `invalidQuad`, `opaqueAfterBlended`, `textureTooLarge`, `gpuFailure`. Every throwing function is `throws(EngineError)`.

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
- **Time**: `render` takes no time while the engine has no animated value of its own; time enters through
  `HarnessScene.frame`. The first engine-side animated value adds the parameter. The display-link adapter, the one
  file allowed to read a clock, produces `EngineTime`.
- **Scenes**: a new subsystem adds a `HarnessScene` to `catalogue()` and its parts to `postcard`.
- **Serialisation**: `FrameDescription` is a plain value so it can become the scene file of D18 unchanged.
