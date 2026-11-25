# Retrospectives

How each milestone was built, what that cost, and what changed about the way of working because of it.

`/milestone:retro <M>` (`.claude/commands/milestone/retro.md`) runs after a milestone's follow-ups are filed and
before it ships. It looks at the process: the commands, the agents, the scripts and the docs that steer them. What
the milestone built is the reviewers' and the auditor's business.

A retro's changes are applied in the same session, after the owner has discussed each finding. They do not become
tickets. The one exception is a finding about the engine's code, tests or catalogue, which needs an implementer and
a review, so it is filed as a ticket.

## `<milestone>.metrics.json`

Written by `scripts/retro/extract.py <M>`, committed with the report. Numbers only, no transcript paths.
Transcripts are deleted after 30 days, so this file is what later retros compare against.

| Key | What it holds |
|---|---|
| `span`, `loop_windows` | When the milestone ran, and each loop run inside it (from `.build/auto-loop/run.log`, read in every checkout) |
| `coverage` | Sessions and agents found; agents known only from the hook's record; tickets the log says shipped with no agent transcript on this Mac |
| `tok_eq_totals` | Cost by bucket: `agents`, `orchestrator` (the loop session inside a loop window), `attended` (a session on a milestone ticket's branch), `overhead` (everything else inside the span) |
| `outcomes`, `review_rounds` | Tickets by outcome (`shipped`, `landed` and waiting for the owner, `parked`), and by how many review rounds they took |
| `agent_types` | Per agent type: count, API calls, tokens, median and largest agent, largest context, wall time, tool calls, tool errors, sleep polls |
| `tickets` | Per ticket: the loop's events (claim, implement time, challenge, rounds with verdict and findings, fixes, full runs, infra, outcome), its agents and their cost, attended cost |
| `sessions` | Per session: cost by bucket with peak and median context, compactions, seconds spent waiting per tool, slash commands used, the session's recorded cost in USD |
| `overhead_by_branch` | Where the unattributed work happened |
| `test_runs` | Every `scripts/gate` run in the span: tier, exit, wall time, seconds per step (`steps_s`), `failed_steps`, surviving mutants, flaky tests, diff coverage |
| `agents` | One row per agent |

`tok_eq` is one number per API call, in input-token equivalents: input + 1.25 x cache write + 0.1 x cache read +
5 x output. Use it to compare, not to bill.

Two limits to keep in mind when reading:

- A session that is neither a loop nor on a ticket branch is attributed by date alone. It lands in `overhead`.
- A loop logs in the checkout it ran in. A worktree removed before the retro takes its `run.log` with it.

The extractor also writes `.build/retro/<M>/outliers.md` (not committed): the tickets that did not go straight
through, the agents far above their type, repeated commands, tool errors and red runs, each with
`<transcript>:<line>`.

`.build/retro/agents.jsonl` holds one record per finished subagent, written by the `SubagentStop` hook in
`.claude/settings.json` (`extract.py --hook`). The extractor falls back to it for an agent whose transcript is gone.

## `<milestone>.md`

Written by `/milestone:retro`:

1. **Numbers**: this milestone beside the previous one. Tickets and outcomes, review rounds, cost by bucket, cost
   per shipped ticket, median implementer and reviewer, gate time by step, surviving mutants and diff coverage per
   full run, flaky tests, tool errors.
2. **Last retro's actions**: each action from the previous report with the metric it named, and whether it worked,
   did not, or cannot be told yet.
3. **Keep**: what went well and should not be changed by accident.
4. **Findings**: `F1...Fn`, ranked by what they cost. Each has the evidence (numbers, or what a transcript shows),
   the cause in the process (the instruction or script that produced it, or failed to prevent it), the proposed
   change as a diff against a named file, and the metric that should move.
5. **Decisions**: one row per finding, filled in during the discussion: applied (with the commit), changed (how),
   dropped (why), or filed (the ticket).

A finding needs evidence from more than one place, or one occurrence that was expensive. One odd moment in one
transcript is not a finding.
