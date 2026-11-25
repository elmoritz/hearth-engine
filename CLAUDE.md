# hearth-engine

Swift + Metal 2D renderer; first consumer is IdleVillage (`../idle-village-game`). Read `README.md`, then
`docs/Decisions.md` and `docs/TestCatalogue.md` before changing anything. `docs/research/` holds the evidence.
`docs/Architecture.md` is the engine as built; `docs/process/README.md` is how it gets built.

## Working agreement

- Tests first: every feature lands with the catalogue tests that cover it (ids in commit messages and test names).
  A test without a catalogue id is a catalogue change, made in the same commit.
- The engine stays game-agnostic: no IdleVillage types, names or rules. Consumer tests (K, C, U ids) live in the
  IdleVillage repo.
- No clock reads outside the display-link adapter; time is always injected (E-HAR-2).
- Metal 3-era API and Apple5 features only (Decisions D4); Swift 6 strict concurrency; no dependencies.
- The owner is a senior iOS developer: peer-level, no basic explanations. No emojis in code, filenames or commit
  messages.

## Building a milestone

- `/ticket:auto <M>` implements a milestone ticket by ticket; `/ticket:followups <M>` and `/milestone:retro <M>` end
  it. Tickets are GitHub issues (HE-NNN is #NNN), read and written only through `scripts/tickets`.
- Build and test only through `scripts/gate` (`fast` while working, `full` as the proof). Never `swift build`,
  `swift test` or `xcodebuild` directly.
- For a ticket, read its brief (`python3 -I scripts/catalogue.py brief N`) instead of the whole catalogue.
- A test carries its catalogue id in its function name. Skipped is not passed. An agent never approves a reference
  image. `main` moves only through `scripts/land.sh`; nobody keeps it checked out.
