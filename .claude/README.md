# .claude

Project-scoped Claude configuration. The rulebook these files work under is `../docs/process/README.md`.

- `commands/ticket/auto.md`: `/ticket:auto <M>`, the autonomous loop over one milestone.
- `commands/ticket/followups.md`: `/ticket:followups <M>`, files what the loop noticed and did not do.
- `commands/milestone/retro.md`: `/milestone:retro <M>`, the retrospective; `../docs/retros/README.md`.
- `agents/`: `ticket-implementer` and `ticket-reviewer` (one fresh pair per ticket), `design-challenger` (before
  code, for high-risk or large tickets), `engine-auditor` (once per milestone, advisory), `followup-filer`.
- `settings.json`: a `SubagentStop` hook that keeps every agent's numbers for the retrospective after its transcript
  is cleaned up.

Tickets are GitHub issues in `elmoritz/hearth-engine`, on the IdleVillage board; `../scripts/tickets` is the only way
to read or change them. Creating and refining tickets by hand still uses the game repo's `/ticket:new` and
`/ticket:refine` with `TICKETS_REPO=elmoritz/hearth-engine`.
