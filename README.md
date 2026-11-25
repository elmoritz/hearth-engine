# hearth-engine

A small Swift + Metal 2D renderer for cozy, pre-rendered, soft-lit sprite games on iOS and iPadOS. Its first
consumer is IdleVillage, an isometric idle builder whose art comes from a Blender-based asset kit.

Status: **planning.** No code yet. The test catalogue is written first, so the engine is built against it.

## Goals, in order

1. **Image quality** that matches the art as rendered in Blender: no halos, seams, shimmer or banding.
2. **Battery life** for a game that stays on screen for long stretches: render only when something visibly changes,
   one render pass, low bandwidth.
3. **Performance** with headroom on the oldest supported device (iPad (9th gen), A13), smooth pacing at 60 and
   120 Hz.
4. **Determinism:** every frame is a function of an injected time and an immutable frame description, so it can be
   tested pixel by pixel.

## Scope

In: textured quads, layered sprites with additive glow, part motion (spin, sway, flipbook), isometric depth order,
a tile ground, particles, tweens, a colour-grade lookup table, fog, dither, offscreen capture, frame-rate policy,
lifecycle handling. Decided on 2026-11-25 (Decisions D12-D22), so the engine can carry any isometric or tile game:
an engine-owned grid projection with elevation, box-based depth sorting, retained tile layers, picking, a macOS
viewer and a headless harness for agents and tests. Out: text (the host draws it in SwiftUI), physics, audio, 3D,
a scene editor, any game rules.

## Platform

iOS and iPadOS 26.4+, every device iOS 27 supports (GPU feature floor: Apple5, the A12Z iPad Pro). Metal 3-era API
behind a small GPU protocol; Metal 4 brings no gain at this scale and the floor devices lack it (Decisions D4,
with its revisit triggers). Swift 6 strict concurrency, no dependencies. macOS on Apple silicon is a development
host only (tests, viewer, harness), not a product platform (D19).

## Docs

- [docs/TestCatalogue.md](docs/TestCatalogue.md): the acceptance suite (engine, device, build, and the consumer's kit,
  adapter and UI suites).
- [docs/Decisions.md](docs/Decisions.md): decided and open design decisions.
- [docs/research/](docs/research/README.md): the research behind both.
