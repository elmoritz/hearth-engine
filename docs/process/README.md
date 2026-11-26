# How the engine gets built

Tickets are GitHub issues in `elmoritz/hearth-engine` on the IdleVillage board (HE-NNN is issue #NNN). A milestone
is built by `/ticket:auto <M>`: one ticket after another, each implemented, proven by the gate, reviewed and landed
on `main` without a human in between. The owner decides three things only: which tickets a milestone holds, whether a
reference image is right, and what the retrospective changes.

This file is the shared rulebook. The commands (`.claude/commands/`) and agents (`.claude/agents/`) say who does
what and when; they point here for the rules, so a rule is written once.

## The pieces

| Piece | What it is |
|---|---|
| `scripts/tickets` | Every ticket read and write. A shim over the game repo's script with this repo as the target |
| `scripts/catalogue.py` | The catalogue as data: a ticket's ids, its **brief**, and the id-to-test **trace** |
| `scripts/gate` | The only way to build and test. `fast` for the implementer's loop, `full` as the proof |
| `scripts/lint.py` | The catalogue's "a lint fails on ..." rules, with `// lint:allow <rule> - <why>` |
| `scripts/mutate.py` | Mutation check over the changed lines: would a test notice? |
| `scripts/perf.py` | Probes against `docs/perf/baseline.json`: a tripwire on the Mac, not the device budgets |
| `scripts/land.sh` | Fast-forwards `main` to an approved branch and pushes it |
| `scripts/loop-close.sh` | Posts the review, lands, and ships a ticket or leaves it waiting for the owner |
| `scripts/retro/extract.py` | Turns a milestone's logs and transcripts into `docs/retros/<M>.metrics.json` |
| `/ticket:auto <M>` | The loop over one milestone |
| `/ticket:followups <M>` | Files what the loop noticed and did not do |
| `/milestone:retro <M>` | Measures how the milestone was built and changes the process |
| `ticket-implementer`, `ticket-reviewer` | One fresh pair per ticket |
| `design-challenger` | Attacks the plan of a high-risk or large ticket before code exists |
| `engine-auditor` | Reads the whole milestone's diff once, at the end, for what no single ticket shows |
| `followup-filer` | Verifies drafts against the code and writes the tickets |

## A ticket's life

1. **Brief.** `scripts/catalogue.py brief N` writes `.build/tickets/HE-N-brief.md`: the ticket, the catalogue rows of
   its ids, the Decisions and the research sections it cites. Agents read the brief, `CLAUDE.md` and
   `docs/Architecture.md`. They open the catalogue, Decisions or research only where the brief is not enough: the
   three together are about 135 KB, a brief is 7 to 17 KB.
2. **Plan and test matrix**, on the issue, before code. A ticket with risk `high` or effort `L`/`XL` stops here for
   the `design-challenger`; changing a plan costs one message, changing an implementation costs a review round.
3. **Build, tests first**, in small commits on `<type>/HE-N-<slug>`.
4. **Gate.** The implementer loops on `scripts/gate fast --ticket N` and finishes with one
   `scripts/gate full --ticket N --base <base>` on a clean tree. That run is the proof: the loop reuses it when
   `scripts/gate --covers` says it still matches the head, and runs its own otherwise.
5. **Review**, by a fresh agent that reads the diff and the gate's evidence and runs nothing.
6. **Land.** `APPROVE` with a green full run on the landed head, then `scripts/loop-close.sh`. A ticket that owes
   the owner something (below) lands and waits in review; everything else closes as shipped.

## Test rules

The catalogue says what must be true. These rules say what a test has to look like to count.

1. **Ids in names.** Every test carries its catalogue id in its function name, because that is the name the
   results report: `` @Test func `E-HAR-1 a red quad reads back where placed`() ``, or `E_HAR_1_redQuad`. A display
   name alone (`@Test("E-HAR-1 ...")`) is invisible to the trace. A test with no catalogue id is a catalogue change
   in the same commit (`CLAUDE.md`).
2. **The catalogue's pass column is the assertion.** Thresholds are quoted from it, never loosened to get a test
   through. A threshold that turns out wrong is a catalogue change with a reason, in the same commit, and the
   reviewer reads it.
3. **A matrix, not a list.** Each id gets rows of kind `happy`, `unhappy` and `edge`. Unhappy: every typed error
   the code can throw (E-HAR-4) is thrown by a test. Edge: zero, one and the maximum; odd sizes; empty and full;
   time 0, negative and very large (E-TIME); NaN and infinity where a float comes from outside; the first and last
   element; the exact boundary of every comparison.
4. **Analytic before stored.** A golden test compares against a value computed in the test wherever one exists.
   A stored reference image is a candidate until the owner approves it (*What the owner decides*).
5. **A negative control for every golden test** (E-PROOF-3): a companion run with the feature broken that must
   fail. A comparison that cannot fail proves nothing.
6. **Properties for pure code.** Projection, sorting, packing, time and tween maths get property tests over a
   seeded generator (fixed seeds, at least 1000 cases): round trips, monotonicity, a strict weak order, results
   independent of input order. Example tests pin the catalogue's numbers; properties find what nobody listed.
7. **Deterministic.** No clock, no sleep, no unseeded randomness, no dependence on test order or on running alone.
   The gate runs the suite in parallel, serially and again, and fails a test whose result differs.
8. **Skipped is not passed** (E-PROOF-2). A GPU test skips without a device; the done-check then fails.
9. **Every changed line is reached and noticed.** Diff coverage under 90% fails the gate. Every surviving mutant is
   answered: a new test, or one line in the ticket's Evidence saying why the change is equivalent.
10. **Numbers the catalogue states get a probe.** A row that names a count (draws per frame, pipelines, bytes)
    gets a `PERF` count probe (`scripts/perf.py`), so the next ticket cannot raise it unnoticed.
11. **A bug found in review gets a regression test** named for the id it violated.

## The gate

`scripts/gate` prints one line per step and the failing lines. Read that; open `.build/gate/<run>/<step>.log` only
for a step that failed. Exit `0` green, `1` the code's fault, `2` another gate is running here, `3` infrastructure.
The steps and their switches are in the script's header. Two points matter everywhere:

- Nothing else builds or tests. No `swift build`, `swift test` or `xcodebuild` by hand: the lock, the logs, the
  receipts and the retrospective's numbers all hang on the gate.
- A full run covers a later head only when nothing a test can read changed since: `docs/` (except the catalogue
  and `docs/perf/`), `.claude/` and root Markdown. `scripts/gate --covers RUN_DIR [REV]` answers it.

Until the engine writes its own receipts (HE-28), the gate's `summary.json` and the trace are the receipt. Once
E-PROOF-2 ships, the done-check reads the engine's.

## What the owner decides

- **Reference images** (D22 rule 1). An agent never approves one. A ticket that adds or changes a stored reference
  lands with the candidates and waits in review under `## Awaiting owner`, with each image's path and hash. Tickets
  that depend on it carry on. The owner approves at the loop's wrap-up, or later; until HE-28 ships its approval
  records, the approval is the `Owner approval` section the loop writes from the answer.
- **Device ids.** Ids with prefix `D`, or kind `M` alone, are measured on the test devices (D2). The loop cannot
  prove them, lists them as owed, and never counts them as passed.
- **Open Decisions.** A ticket that needs an open decision settled returns `BLOCKED` with the question; the loop
  parks it. An agent does not decide D1.
- **The retrospective's changes** (`docs/retros/README.md`).

## Branches and commits

- The loop's home is `main`, in the checkout it runs in, and no other worktree holds `main`. Work happens on
  `<type>/HE-N-<slug>` (`feat`, `fix`, `tech`, `docs`); `main` moves only through `scripts/land.sh`, by
  fast-forward, and is pushed in the same step.
- Commit messages: `<area>: <what> (HE-N; E-HAR-1, E-HAR-2)`: the ticket and the catalogue ids the commit touches.
  Explicit pathspecs, no amend, no force-push, no `--no-verify`, no emojis.
- Every commit builds. A new test may be committed red ahead of the code that makes it pass.
- Ticket text lives on the issue (`scripts/tickets section`), never in a commit.

## Follow-ups

Anything out of a ticket's scope that is worth doing becomes a draft in `.build/auto-loop/followups/`, one concern
per file, with what was seen, where (`file:line`), why it matters and how it was found. Agents never edit other
tickets. `/ticket:followups` verifies them at the end of the milestone and files only what clears the bar.

**The bar.** A concern becomes a ticket when at least one holds:

- it is a correctness, safety or data-loss risk in the engine or a wrong claim in the catalogue or Decisions;
- it already cost something measurable: a review round, a parked ticket, a halt, a red or repeated gate run, or a
  gate step that could not run;
- a named next ticket needs it, or will be built wrong without it;
- it was seen before: a second sighting of a concern that was noted once.

Below the bar it is **noted**: recorded in `.build/auto-loop/harvested.tsv` with its title, not filed. Style,
naming, a cheaper way to write the same thing, a one-off oddity and "might matter later" are below the bar.

## Run state

`.build/auto-loop/run.log` is the loop's memory: one line per event, `<ISO time> <HE-N|loop> <event> <detail>`.
A session that lost its context re-reads it. `.build/gate/` holds every gate run, `.build/tickets/` the briefs and
section drafts, `.build/retro/` what the retrospective needs after transcripts expire. All of it is gitignored.
