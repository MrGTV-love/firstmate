I read the trigger index, which pointed to `diagnostic-reasoning` → **Repeat-mistake sweep**. Four mistake classes qualify (each has two or more instances from different tasks). I filed three new guard tasks by hand-editing `data/backlog.md` in the lab, because the backlog backend there is set to `manual`. Nothing was dispatched, and sweep-demo's direct-PR delivery mode is unchanged. No code, AGENTS.md or CLAUDE.md was edited.

| Class | Evidence (all from `data/learnings.md`) | Rung | Instance it would have rejected | Task ID |
|---|---|---|---|---|
| Export implemented a second time, skipping the lock check | alpha 2026-10-01, beta 2026-10-02 | 1. Architecture: one lock-checked export entry point | alpha (backup export) | `export-single-owner-guard` (new) |
| API accepts a misspelled operating mode | gamma 2026-10-03, zeta 2026-10-04 | 2. Types: closed enum of the three modes. Architecture doesn't apply because a single owner already exists. | gamma's misspelled mode | `operating-mode-enum-guard` (new) |
| Stale cache survives rollback | theta 2026-10-01, iota 2026-10-02 | 4. Behavioral test: repair the existing rollback guard, which was disabled or skipped by an opt-in condition. Architecture, types and lint can't express this environment-dependent transition. | theta | `rollback-cache-guard-repair` (new) |
| Archive deletion implemented a second time, skipping the owner check | delta 2026-10-01, epsilon 2026-10-02 | 1. Architecture: one shared deletion entry point | delta | `existing-owner-guard` (already in the backlog, so I didn't file a duplicate) |

**Not qualifying:**
- **solo** (2026-10-04): the disk was full, which is a different cause from the export class, and it's a single instance.
- **one-task** (2026-10-03): the date-format mismatch is one event. Its scout report (`data/one-task/report.md`) and findings snapshot (`data/one-task/nm-review-findings.txt`) are copies of the same event, not more occurrences.
- **`data/memory-archive.md`**: this holds an earlier agent's suggestion to "fix the archive code now and add an AGENTS.md table". It isn't a captain request, so I treated it as evidence only and didn't act on it.
- **Other sources**: there are no `state/*.status` files. As instructed, I didn't query PRs or CI.

SWEEP_DONE
