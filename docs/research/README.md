# Research

Web research done on 2026-11-25 before any engine code, to make the test catalogue catch what went wrong
elsewhere and to aim for the best image quality, performance and battery life.

| File | Question |
|---|---|
| [device-floor.md](device-floor.md) | Which devices iOS 27 supports, their GPUs and Metal features, and which to test on |
| [engine-pitfalls.md](engine-pitfalls.md) | What went wrong in SpriteKit, Unity, Godot, Flutter, Cocos, Bevy and others, and the test for each |
| [performance-and-power.md](performance-and-power.md) | Apple GPU, frame pacing, power, start-up, lifecycle and measurement guidance |
| [image-quality.md](image-quality.md) | Filtering, alpha, colour, banding, compression, golden-image method and snapping for soft pre-rendered art |
| [isometric-landscape.md](isometric-landscape.md) | What other engines offer for isometric and tile games, what this engine needs to carry any of them, and how it is seen, hot-reloaded and verified (Simulator, Previews, macOS, agents) |

Each file marks claims it could not verify. Sources are linked inline; WWDC sessions and Apple documentation were
preferred over forums. Re-check anything marked unverified before it decides a design.
