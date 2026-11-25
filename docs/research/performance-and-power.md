# Performance and battery on Apple GPUs

Research of 2026-11-25, from Apple documentation, WWDC sessions and engineering sources.
Legend: unmarked = read on the source; **[S]** = search snippet or third party; **[UV]** = our inference.

## What matters most for an idle game

An idle game stays on screen for long stretches, mostly static. The three big levers, in order:

1. **Fewer presented frames:** render on demand, drop to a low cadence when only slow ambience moves.
2. **Less memory bandwidth:** clear and don't-care load/store actions, compressed and lossless-compressed
   textures, no extra passes.
3. **Darker pixels on OLED** (an art-direction lever: the night grade).

Shader micro-optimisation saves little for a sprite workload. Keep one render pass straight into the drawable.

## 1. Tile-based deferred rendering

- Tile memory has many times the bandwidth of device memory at much lower energy
  (https://developer.apple.com/documentation/metal/tailor-your-apps-for-apple-gpus-and-tile-based-deferred-rendering).
- **Load/store:** clear on load instead of a clear pass; store only what the next frame needs; `.dontCare`
  otherwise; never split a pass only because actions differ. WWDC19 606: one store changed to don't-care saved
  about 14 MB of bandwidth per frame; memoryless targets saved 60-85 MB of footprint
  (https://developer.apple.com/wwdc19/606, https://developer.apple.com/videos/play/wwdc2020/10632).
- **Memoryless** (`storageMode = .memoryless`) for any attachment that never leaves the pass.
- **Extra passes** cost a full-screen read and write each. If one is unavoidable, encode it before acquiring the
  drawable and acquire the drawable as late as possible.
- **Hidden surface removal** helps only opaque geometry. Order: opaque, then alpha-test/discard, then blended back
  to front. Our sprites are blended, so overdraw is the main fragment cost. Mitigations [UV]: opaque ground with
  blending off, tight sprite meshes instead of full quads, cut opaque interiors of large sprites, avoid `discard`.
  Measure overdraw as fragment invocations per stored pixel (Xcode GPU counters). Our target [UV]: 3x or less.
- `[[early_fragment_tests]]` where shaders write resources; write every colour attachment (WWDC20 10632).
- **Half precision:** fewer registers, often faster maths; use `h` literals. Colour, UV and tint in `half`;
  positions and **time** in `float`. A19/M5 doubles FP16 throughput (https://developer.apple.com/videos/play/tech-talks/111431/).
- **Lossless compression** is automatic on Apple5+ when the texture is not block-compressed, usage has no
  `.unknown`, `.shaderWrite` or `.pixelFormatView`, and it is not buffer-backed. Private storage and render targets
  get it by default; set `framebufferOnly = true`. Upload through a staging buffer and blit, not
  `replace(region:)`, which writes uncompressed. Check the "compression ratio" counter is above 1.0
  (https://developer.apple.com/documentation/metal/optimizing-texture-data, Tech Talk 111431).
- **Texture formats:** ASTC is 128 bits per block: 4x4 = 8 bpp, 6x6 = 3.56 bpp, 8x8 = 2 bpp; RGBA8 is 32 bpp. ASTC
  textures do not also get lossless compression. WWDC19: 16 MB uncompressed fell below 3 MB compressed with mips.
  ASTC quality on soft gradients: see image-quality.md 5.
- **Instancing and binding** [UV]: one atlas or texture array plus one instanced quad draw per blend state,
  per-instance data in a ring buffer; expect under 10 draws per frame. Bindless argument buffers and indirect
  command buffers are unnecessary at this size.

## 2. Frame pacing and power

- **Display link:** `CAMetalDisplayLink` (iOS 17+) is Apple's recommended Metal pacing path
  (https://developer.apple.com/documentation/quartzcore/cametaldisplaylink, sample
  https://developer.apple.com/documentation/metal/achieving-smooth-frame-rates-with-a-metal-display-link). DTS:
  "strongly advise using CAMetalDisplayLink over CADisplayLink" [S]. Caveat: Unity saw hangs on older iOS after a
  command-buffer timeout (engine-pitfalls.md 1.1), so keep a `CADisplayLink` fallback behind a switch.
  `MTKView` hides drawable timing; its on-demand modes are `isPaused` with or without `enableSetNeedsDisplay`.
- Recommended: `CAMetalLayer` + `CAMetalDisplayLink`, `framebufferOnly = true`, `maximumDrawableCount = 3`,
  paused whenever nothing animates.
- **Rates are hints** (WWDC21 10147, WWDC22 10083): the system picks the nearest valid cadence (40 on 60 Hz gives
  30). ProMotion iPhones reach 10 Hz [S], iPad Pro 24 Hz. Low Power Mode, "Limit Frame Rate" and thermal state cap
  or restrict. Above 60 Hz on iPhone needs `CADisableMinimumFrameDurationOnPhone` [S].
- **The screen follows the fastest animation on it:** a 60 fps SwiftUI overlay forces 60 over a 30 fps scene.
  WWDC22: lowering an overlay from 60 to 30 saved up to 20% of battery drain; dark OLED content saves up to 70% of
  display power. No Apple number for 20 vs 30 vs 60 fps scene power.
- `present(afterMinimumDuration:)` / `present(at:)` pace evenly; WWDC21's adaptive example smooths GPU time with
  an exponential moving average (alpha 0.25).
- **Policy proposal** [UV]:

  | Situation | Rate |
  |---|---|
  | Nothing visibly changes | 0 (paused) |
  | Slow ambience only (sway, smoke, grade drift) | preferred 20, range 10-30 |
  | Interaction (pan, zoom, tap feedback) | preferred 60, range 30-60; 120 on ProMotion optional |
  | Low Power Mode or thermal `.serious` | at most 30 |
  | Thermal `.critical` | 10-15, ambient effects off |

  Watch `ProcessInfo.isLowPowerModeEnabled` (`NSProcessInfoPowerStateDidChange`) and `thermalState`
  (`thermalStateDidChangeNotification`). Apple: fair = defer work, serious = reduce screen updates and animations,
  critical = stop nearly all work (https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum).
- **Game Mode** (`LSSupportsGameMode`) reduces background activity and Bluetooth latency; no battery benefit; DTS
  warns non-games may be rejected [S]. Not needed.
- **CPU-GPU sync:** never `waitUntilCompleted` per frame; a semaphore of 3 or `MTLSharedEvent` with a triple-buffered
  ring; no CPU readback in the frame; acquire the drawable late (`nextDrawable` can block up to 1 s and return nil) [S].

## 3. Start-up and hitches

- Create every pipeline at launch or asynchronously, never mid-frame; `.metallib` is precompiled by Xcode.
  Binary archives (`MTLBinaryArchive`, `metal-tt`) are optional for under 10 pipelines
  (https://developer.apple.com/documentation/metal/metal-binary-archives, WWDC22 10102). Metal 4's `MTL4Compiler`
  and serializer exist but are not available on the device floor.
- Textures: load off the main thread (`MTKTextureLoader` with explicit options, or our own container), private
  storage. `MTLIOCommandQueue` (Metal 3, WWDC22 10104) is overkill for a small atlas set [S].
- Memory: `os_proc_available_memory()`; react to memory warnings; regenerable caches `setPurgeableState(.volatile)`;
  never hard-code per-app limits (they changed in iPadOS 26.4 [S]).

## 4. Background and lifecycle

https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background:
stop committing on deactivate and pause the link; you may finish the frame in flight; `waitUntilScheduled()` on
the last buffer in did-enter-background. Later commits fail with `.notPermitted`; iOS 26.2 in-flight work reported
`accessRevoked` (code 8) [S]. Completion handlers must tolerate errors and never trap. Update `drawableSize` from
layout, never per frame. Also pause when the view is covered or off-screen [UV].

## 5. Measuring and testing

- **Instruments/Xcode:** Metal System Trace (GPU timeline, Thermal State track), GPU counters (overdraw,
  compression ratio, limiters), Energy gauge, Device Conditions (force thermal state), Animation Hitches.
- **Metal Performance HUD:** `MTL_HUD_ENABLED=1`, `MTL_HUD_LOG_ENABLED=1` (once-per-second log lines, filter
  "metal-HUD"); also from Developer settings on device
  (https://developer.apple.com/documentation/xcode/gaining-performance-insights-with-metal-performance-hud).
- **WWDC26 388:** on-device lookback Performance Trace; `metalperftrace collect --last 5h`, `overview --json`
  (FPS, skipped frames, frame time, CPU begin-to-present, GPU time, next-drawable wait, shader compile time,
  memory, per layer); `StateReporting` tags states such as "idle" vs "interacting".
- **XCTest metrics:** `XCTClockMetric`, `XCTCPUMetric`, `XCTMemoryMetric`, `XCTStorageMetric`,
  `XCTOSSignpostMetric`; CPU and memory reported unreliable in UI tests and `XCTHitchMetric` empty for an `MTKView`
  (https://developer.apple.com/forums/thread/842848) [S]. Swift Testing has no `measure`, so perf tests stay XCTest.
- **MetricKit (iOS 27, `MetricManager`):** `GPUTimeMetric`, `MetalFrameRateMetric` per named `CAMetalLayer`,
  `PixelLuminanceMetric`, `CPUTimeMetric`, `HitchTimeMetric`, `PeakMemoryMetric`, `MemoryExceptionDiagnostic`,
  signpost intervals (https://developer.apple.com/documentation/metrickit). Name our layer.
- **Validation:** `MTL_DEBUG_LAYER=1`, `MTL_SHADER_VALIDATION=1` (slow; own test configuration); `man MetalValidation`
  (https://developer.apple.com/documentation/xcode/validating-your-apps-metal-api-usage).
- **Headless golden images:** `MTLCreateSystemDefaultDevice()`, offscreen private texture, blit to a shared buffer.
  Works on Apple-silicon Macs; hosted CI runners often return a nil device
  (https://github.com/actions/runner-images/issues/1779) [S], so skip on nil and run on a self-hosted Mac.
  Apple does not guarantee numerical consistency across devices (https://developer.apple.com/forums/thread/808536) [S]:
  compare with tolerances, keep references per GPU family where exactness matters.

## 6. Metal 4

Metal 4 (WWDC25 205, https://developer.apple.com/videos/play/wwdc2025/205, https://metalbyexample.com/metal-4/):
new command queue, buffer and allocator types, argument tables, mandatory residency sets, `MTL4Compiler`, explicit
barriers (resources untracked, concurrent by default). Requires Apple7 (A14/M1). WWDC26 added ML/tensor and MetalFX
only, nothing for 2D. **Not available on the device floor** (A12Z, A13; see device-floor.md), so the engine uses the
Metal 3-era API. Keep the GPU layer behind a small protocol so a Metal 4 path can come later.

## Not verified

An Apple power figure for 20/30/60 fps; an official ASTC gradient guideline; exact ProMotion minimum rates on
current iPhones; whether `CADisableMinimumFrameDurationOnPhone` is still needed on iOS 27; GitHub arm64 runners
exposing Metal; `XCTHitchMetric` with `CAMetalLayer`; the WWDC23 10123 transcript.
