# Architecture

The engine as it stands, kept current by the tickets that change it. A ticket that adds a module, a public type, an
invariant or an extension point updates this file in the same branch; the reviewer checks it and the milestone audit
reads the whole milestone against it. It describes what exists. Plans live in tickets, reasons in `Decisions.md`.

No code yet: the sections below hold only what is already decided. HE-1 fills in the module map.

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

Filled in by HE-1: targets, what each owns, and which may import which.

## Public surface

Types a consumer touches, one line each, added as they land.

## Extension points

Where a later ticket is expected to plug in (a second GPU back end, D4; the Simulator's two-pass path, D18).
