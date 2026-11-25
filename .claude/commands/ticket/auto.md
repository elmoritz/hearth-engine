---
description: Autonomously implement, prove, review and land every ticket of one milestone, one after another. Blocked tickets are parked and the loop carries on. Resumable; can run unattended overnight. Ends with the milestone audit, follow-up filing and the retrospective.
argument-hint: <milestone, e.g. engine-01> [--max-rounds N] [--max-tickets N] [--unattended] [--until HH:MM]
---

# /ticket:auto

Run brief → (challenge) → implement → gate → review → land over one milestone until nothing eligible is left. Each ticket gets a fresh `ticket-implementer` and a fresh `ticket-reviewer` per round. This session only orchestrates: it keeps verdicts and bookkeeping, never implementation detail, and neither reads nor writes engine code. Everything it needs to know about a ticket arrives as a report of a dozen lines or a script's exit code.

The rulebook is `docs/process/README.md`. Tickets are GitHub issues (HE-NNN is issue #NNN); every ticket read and write goes through `scripts/tickets`. Sections are written by putting the content in a file under `.build/tickets/` and running `scripts/tickets section N --heading "<Heading>" --file <file> --event "<verb>"`. A `scripts/tickets` call that exits `1` or `2` is never pushed through: log `halt tickets <subcommand> <exit>` and wrap up. Exit `3` comes only from `claim`.

The user's starting input: $ARGUMENTS

## Arguments

- **Milestone** `<M>`: required. `scripts/tickets milestone list` shows them; if the one named does not exist, stop and say so.
- `--max-rounds N`: review rounds per ticket. Default `3`.
- `--max-tickets N`: after `N` tickets shipped, landed or parked in this session, stop at the next checkpoint with a **session stop** and let a fresh session carry on. Default `0` (off). Set it when the retrospective shows this session's context growing.
- `--unattended`: nobody is watching. Never call `AskUserQuestion`. The start gate counts as **Start**. Anything that needs the owner goes to the run log and the report.
- `--until HH:MM`: local-time deadline; earlier than now means tomorrow. Past it the loop stops at the next checkpoint.

## Run state on disk

Everything lives in `.build/auto-loop/` (gitignored):

- `run.log`: one appended line per event, `<ISO time> <HE-N|loop> <event> <detail>`, written with `echo "$(date -u +%FT%TZ) ..." >> .build/auto-loop/run.log`. Events: `start <M> <args>`, `sync <sha>`, `claim`, `challenge <CONCEDE|OBJECT> <k>`, `implement-done`, `blocked`, `full <run_dir> <exit>`, `full-reuse <run_dir>`, `review <n> <verdict> <k findings>`, `fix <n>`, `infra`, `owner <question> <answer>`, `rebased`, `shipped`, `landed-unapproved`, `approved`, `parked`, `stashed`, `resumed`, `audit <n> findings`, `followups <f> filed <i> inbox`, `retro <f> findings <a> applied`, `stop`, `session-limit <n> tickets`, `halt <reason>`, `end`. This file is the source of truth: after a context compaction re-read it instead of trusting memory.
- `caffeinate.pid`, `STOP` (if this file exists the loop stops at the next checkpoint; remove it at start), `report-<date>.md`.
- `followups/`: drafts written by the agents and by this session. They survive across runs until filed; never clear the directory.

**This session drafts too.** A rebase conflict, a flaky test the gate caught, a ticket parked for an ambiguity, a dispute the reviewer dropped that points at a doc gap, a gate step that was skipped: write `followups/loop-<ISO date>-<k>-<slug>.md` with `source: loop`.

**Checkpoints** are before picking a ticket and before each review round. At a checkpoint, if `STOP` exists or the deadline has passed: log `stop`, leave an in-flight ticket claimed on its branch (the next run resumes it), and wrap up.

**Session stop.** At the checkpoint before picking, if `--max-tickets` is reached and the queue still has an eligible ticket: log `session-limit <n> tickets` and wrap up short (steps 1, 7 and 8 of *Step 2*). The report's first line says `Session limit reached after <n> tickets; start a fresh session with the same command to continue`.

## Step 0: preflight

1. **Stay awake.**
   ```sh
   mkdir -p .build/auto-loop .build/tickets && rm -f .build/auto-loop/STOP
   nohup caffeinate -dims >/dev/null 2>&1 & echo $! > .build/auto-loop/caffeinate.pid
   ```
   Every exit path ends it with `kill "$(cat .build/auto-loop/caffeinate.pid)"`.
2. **Log** `loop start <M> <args>`, then `scripts/land.sh --sync`. Exit `0`: log `sync <main sha>`; the first `sync` of a milestone is its start commit, which the audit needs. Exit `8` (`main` and `origin/main` have diverged): log `halt main-diverged`, stop. Exit `9`: `halt origin-unreachable`, stop. Exit `3`: `halt main-held`, stop.
3. **Resume interrupted work.** `scripts/tickets list --stage in-progress --label claimed:auto-loop --milestone <M> --json`. For each, its branch is `git branch --list '*/HE-N-*'`:
   - tree dirty on that branch: `git stash push -u -m "auto-loop interrupted HE-N <ISO time>"`, log `stashed`. Never discard it.
   - `git switch main`.
   - the branch has commits of its own (`git log main..<branch>`): it resumes at step 1.4 before anything new is picked; log `resumed`.
   - no branch or no commits: `scripts/tickets unclaim N`.
4. **Clean tree at home.** `git status --porcelain` is empty and the checkout is on `main` (`git switch main`). Otherwise stop (`--unattended`: log `halt dirty tree`). If `git worktree list --porcelain` shows another worktree on `refs/heads/main`: `halt main-held`.
5. **Baseline.** `scripts/gate full` on `main` (see *Gate runs*). Red: log `halt main is red` and stop, since the loop cannot tell its own breakage from existing breakage. Exit `3`: `halt infra`, stop. If its output shows a step skipped for a reason other than "no Package.swift yet" or "no probes yet", write a loop draft.
6. **Queue.** `scripts/tickets queue <M> --json`: `eligible`, `waiting` (with `waiting_on`) and `parked`, sorted by `(priority, -effort)`.
7. **Start gate.** Show the queue (resumed first, then eligible, waiting with what they wait on, parked). Without `--unattended`, ask via `AskUserQuestion`: "Run the auto loop over <M> (<n> tickets)?", header "Auto loop", options **Start** (Recommended), **One ticket**, **Cancel**. After it, ask nothing until wrap-up, except a reviewer's `Needs owner:` question.

## Step 1: loop

`parked` and `landed` start empty (`landed` is seeded from this milestone's `landed-unapproved` lines in `run.log`). Repeat:

1. **Checkpoint, then pick.** Re-run the queue. Eligible = its `eligible` group, plus every `waiting` ticket whose `waiting_on` are all in `landed` (their code is on `main`; only the owner's approval is open), minus `parked`. Take the first. None left: wrap up.
2. **Brief.** `python3 -I scripts/catalogue.py brief N`. If it prints `NOT IN CATALOGUE`, carry on; the implementer reconciles the stale side in its plan. Log `claim`.
3. **Implement.** Read the ticket's fields from the queue row.
   - Risk `high`, or effort `L` or `XL`: launch `ticket-implementer` with `plan HE-N`. On `STATUS: PLANNED`, launch `design-challenger` with `HE-N` and the numbers of the queue's tickets that wait on it; log `challenge <verdict> <k>`. Then `SendMessage` the same implementer: `build HE-N` plus the objections verbatim (or "the challenger concedes"). If it cannot be continued, launch a new one with the same prompt.
   - Otherwise: launch `ticket-implementer` with `implement HE-N`.

   Read its report:
   - `BLOCKED: main is red`: log `halt main is red`, wrap up.
   - `BLOCKED: infra`: log `halt infra`, park nothing, wrap up (the ticket resumes next run).
   - `BLOCKED: already claimed`: add to `parked` without touching the ticket, continue.
   - any other `BLOCKED`: **park**, continue.
   - `DONE`: log `implement-done`.
4. **Review rounds**, round = 1…max-rounds, each starting with a checkpoint. The base is `git merge-base main <branch>`, computed fresh each round.
   1. **Proof.** `git switch <branch>`; the tree must be clean. If `scripts/gate --covers <RUN_DIR from the report> <branch> --ticket N` exits `0`, log `full-reuse <run_dir>`. Otherwise run `scripts/gate full --ticket N --base <base>` yourself and log `full <run_dir> <exit>`.
      - exit `3`: log `infra`, run it once more; a second `3`: `git switch main`, log `halt infra`, wrap up. Never park for infrastructure.
      - exit `1`: no review this round. Send the gate's failing lines to the implementer as `fix HE-N`, each a `blocker` (step 4), and count the round.
   2. **Review.** Launch a new `ticket-reviewer` (foreground) with: ticket, branch, base, round, `GATE: <run_dir>`, and from round 2 the implementer's `DISPUTED` lines. Then `git switch main`. Log `review <n> <verdict> <k findings>`.
   3. **Decide.**
      - `INFRA`: log `infra`, repeat the round once without counting it; twice: `halt infra`, wrap up.
      - `APPROVE`: **close**, continue with the next ticket.
      - a finding ending in `Needs owner:`: attended, ask it via `AskUserQuestion` (the reviewer's options, the recommended first), write the answer to the issue (`--heading "Owner decision" --event "owner decision"`), log `owner <question> <answer>`, and send findings plus decision to the implementer. `--unattended`: park with the question as the reason.
      - `CHANGES_REQUESTED`: go to 4.
   4. **Fix.** One `SendMessage` to the same implementer, `fix HE-N` with the full findings list; a new `ticket-implementer` with the same prompt if it cannot be continued. Log `fix <n>`. `BLOCKED: infra`: halt as above; any other `BLOCKED`: park. Then the next round on the new head.
   5. After the last round without `APPROVE` on a green gate: park, with the open findings as the reason.

### Close (approved)

1. Write `.build/tickets/HE-N-agent-review.md`: one line per round (`Round n: <verdict>, <k> findings (<severities>); gate <run_dir> exit <code>` or `covered by <run_dir>`), then the open `minor` findings verbatim.
2. If the reviewer's `REFERENCES:` is not `none`, or `.build/tickets/HE-N-ids.txt` has `device` lines, write `.build/tickets/HE-N-awaiting.md`: under `Reference images` each candidate's path and `shasum -a 256`, under `Device ids` the ids. Otherwise make sure no such file exists.
3. `scripts/loop-close.sh N <branch>`:
   - `0`: shipped.
   - `10`: landed, in review, waiting for the owner. Add N to `landed`. This is a normal outcome, not a park.
   - `4`: `main` moved. `git rebase main <branch>`; a conflict: `git rebase --abort` and park. Otherwise log `rebased`, run `scripts/gate full --ticket N --base <new base>` unless `--covers` still holds, and run the script again. A red gate after the rebase goes back to the implementer as a `fix`, once; then park.
   - `3`: another worktree holds `main`. Attended: ask the owner to put that worktree on another branch, then run it again. `--unattended`: `halt main-held`, wrap up.
   - `8`: `halt main-diverged`, wrap up. `9`: `halt origin-unreachable`, wrap up. `1`: `halt tickets close 1` with its output, wrap up.

### Park (blocked or not approved)

1. `git switch main`. The branch stays as it is.
2. Write the reason (the blocked reason, or the open findings verbatim) to `.build/tickets/HE-N-park.md` and run `scripts/tickets park N --reason-file .build/tickets/HE-N-park.md --branch <branch>` (no `--branch` when there is none).
3. Add to `parked`, log `parked`. Tickets that depend on it drop out of eligibility by themselves.

## Gate runs

Every build and test goes through `scripts/gate`. This session starts a full run with Bash `run_in_background: true` and `timeout: 7200000`, then waits for its completion notification in the same turn: one wait per run, no `sleep` loop, no `tail` of a log in flight, no status checks in between. Read the last line (`gate: exit <n> ...`) and, when it is not `0`, the step lines above it. If the wrapper died, `scripts/gate --wait <run_dir>` finishes it. Exit `2` means another gate is running in this checkout: wait on that one. While a gate is in flight nothing switches the working tree.

## Step 2: wrap up

1. Home is on `main` and clean, apart from an in-flight ticket left for resume.
2. **Milestone audit**, when at least one ticket landed in this run and the queue is empty: `scripts/gate full` on `main` unless a covering run exists; then launch `engine-auditor` with `MILESTONE: <M>`, `START: <the sha of the milestone's first sync line>`, `HEAD: <main>`, `GATE: <run_dir>`, `REPORT_FILE: .build/auto-loop/audit-<M>.md`. Log `audit <n> findings`. It is advisory: nothing it says reopens a ticket.
3. **Follow-ups.** If a ticket closed or a draft is waiting, run `/ticket:followups <M>`: read `.claude/commands/ticket/followups.md` and follow it in this session, with `--unattended` when this run is. Log `followups <f> filed <i> inbox`.
4. **Retrospective**, when the queue is empty (not on a session stop, `STOP`, deadline or halt): run `/milestone:retro <M>`: read `.claude/commands/milestone/retro.md` and follow it in this session; with `--unattended` pass `--report-only`. Log `retro <f> findings <a> applied` (or `report-only`).
5. **The owner's turn, attended only.** For each ticket waiting under `## Awaiting owner` in this milestone (`scripts/tickets list --stage in-review --milestone <M> --json`), ask one `AskUserQuestion` per ticket: "HE-N <title>: <k> reference image(s), <d> device id(s)", header "HE-N", options **Approve** (the references are right, and the device ids are measured or accepted as owed), **Later** (stays in review), **Reject** (say what is wrong; it becomes a loop draft and the ticket stays in review). List the image paths first so the owner can open them. On **Approve**: write `--heading "Owner approval" --event "owner approval"` with the date, the paths and hashes, and what was said about the device ids; then `scripts/tickets close N --as shipped`; log `approved`.
6. **Ship, attended only.** If the milestone has no open ticket left, ask "Ship <M>?" (**Ship** / **Not yet**); on Ship: `scripts/tickets milestone ship <M>`. Unattended runs never ship a milestone: the report says "approve the waiting tickets, read the retro, then ship".
7. Stop `caffeinate`. Log `end`. Write the report to `.build/auto-loop/report-<date>.md` and print it.
8. If `PushNotification` is available: "Auto loop on <M>: <s> shipped, <l> awaiting you, <p> parked<, halted: reason>."

```
Auto loop on <M>: <s> shipped, <l> landed and awaiting the owner, <p> parked, <w> waiting on parked work. <Stopped by STOP / deadline / halted: reason>

Shipped:
- HE-N <title> — <rounds> round(s), <i> ids proven, <k> mutants answered
Awaiting the owner:
- HE-N <title> — <k> reference image(s): <paths>; device ids: <ids>
Parked:
- HE-N <title> — <one-line reason> (branch <branch>)
Left for resume:
- HE-N <title> — on <branch>, round <n> (stash: <message>)
Waiting:
- HE-N <title> — on HE-M
Audit (.build/auto-loop/audit-<M>.md):
- <n> findings; first: <the auditor's TOP line>, or "not run: <reason>"
Follow-ups:
- <backlog, inbox, folded, dropped>, or "none"
Retrospective (docs/retros/<M>.md):
- <f> findings: <a> applied, <d> dropped, <t> filed; or "report only: run /milestone:retro <M>"; or "not run: <reason>"
Needs a human:
- <every inbox decision brief's question> (HE-N), or "none"
Infra events: <count, or "none">
```

## Running it overnight

**A fresh session per run**, used for nothing else. Everything a run needs is on disk, so a new session loses nothing, while a session carried across runs re-reads its whole history on every step.

```sh
mkdir -p .build/auto-loop
claude -p "/ticket:auto engine-01 --unattended --until 07:00" --permission-mode bypassPermissions \
  2>&1 | tee -a .build/auto-loop/session.log
```

With `--max-tickets N`, repeat until the report no longer starts with `Session limit reached`:

```sh
while :; do
  claude -p "/ticket:auto engine-01 --unattended --max-tickets 4 --until 07:00" --permission-mode bypassPermissions \
    2>&1 | tee .build/auto-loop/session.log
  grep -q '^Session limit reached' .build/auto-loop/session.log || break
done
```

Stop it gracefully with `touch .build/auto-loop/STOP`. After a crash or a usage limit, run the same command again; preflight resumes the in-flight ticket.

## Hard rules

- One ticket at a time. Never two implementers in parallel: they share `main`, the package and the build directory.
- Ticket state changes only through `scripts/tickets`. Code lands on `main` only through `scripts/land.sh` (inside `scripts/loop-close.sh`), as a fast-forward that is pushed. The loop's home between tickets is `main` in the checkout it runs in; no other worktree may hold `main`. This session never commits on `main` except the retrospective's changes.
- Never amend, force-push, `--no-verify`, or push yourself. No `gh` writes, no pull requests.
- Never `swift build`, `swift test` or `xcodebuild` directly. Use `scripts/gate`.
- Don't overrule the reviewer or the gate. A ticket lands only on `APPROVE` together with a green full run that covers the landed head.
- Never approve a reference image, and never count a device id or a skipped test as passed. A ticket that owes the owner something lands and waits.
- Never weaken the gate to get through a night: no `GATE_TSAN=0`, no lowered `GATE_DIFFCOV_MIN`, no smaller mutant budget from this session. A step that cannot run is a `halt` or a draft, and a change to it is the retrospective's.
- Audit findings are advice. They reach the backlog only through `/ticket:followups`.
- Don't edit tickets outside the one in flight, except through the resume, park and close steps above, and the wrap-up.
- This Mac runs other projects' loops. Kill only a PID you recorded; never `pkill`, `killall` or a simulator command you did not start.
