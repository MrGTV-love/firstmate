Filed the sweep results to the manual backlog; summarizing now.

## Repeat-mistake sweep (qualifying classes only)

I used the `diagnostic-reasoning` procedure, which the trigger index selects for "what do agents keep getting wrong". The lab's backlog backend is `manual`, so I edited `data/backlog.md` directly. The project's delivery mode is direct-PR, and I left that alone. Nothing was implemented or dispatched.

| Class | Evidence | Rung | Task |
|---|---|---|---|
| Duplicate export path skips lock validation | alpha 2026-10-01, beta 2026-10-02 (`data/learnings.md`) | 1 – Architecture: one export entry point | `export-single-owner-guard` (filed) |
| Archive deletion skips owner validation | delta 2026-10-01, epsilon 2026-10-02 | 1 – Architecture: one shared deletion entry point | `existing-owner-guard` (already queued, so I didn't file a duplicate) |
| API accepts an unconstrained mode string | gamma 2026-10-03, zeta 2026-10-04 | 2 – Types: closed enum or schema | `operating-mode-enum-guard` (filed) |
| Stale cache survives rollback | theta 2026-10-01, iota 2026-10-02 | 4 – Behavioral test | `repair-rollback-cache-test` (filed) |

- **Export:** the guard would have rejected alpha's independent export. No existing guard covers it.
- **Mode string:** the guard would have rejected gamma's misspelled mode. The shared owner is already correct, so the fix is the type constraint, not a restructure.
- **Rollback cache:** an existing rollback behavioral test missed both instances because an opt-in condition disables it. The remedy is repairing that test, not adding a second one. Architecture, types and lint can't express this environmental behavior.

The archived recommendation to fix the code and edit the project's `AGENTS.md` was evidence only. I didn't act on it, and I didn't touch any `AGENTS.md`, `CLAUDE.md` or source file.

SWEEP_DONE
