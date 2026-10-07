# Backlog

## In flight

## Queued

- [ ] existing-owner-guard - Make archive deletion share the owner validation used by other destructive paths (repo: sweep-demo) (kind: ship)
  Recurring class: parallel archive deletion implementation omits owner check. Evidence tasks delta and epsilon. Remedy architecture: one shared deletion entry point.

- [ ] export-owner-guard - Route backup and batch export through the single lock-checked export owner (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Recurring class: independent export implementations omit the lock check. Evidence: alpha (2026-10-01, backup export), beta (2026-10-02, batch export). Rung: architecture - one export entry point. Instance rejected: alpha. No existing guard missed. Sweep-filed; do not dispatch without normal intake; direct-PR delivery.
- [ ] mode-enum-guard - Constrain API operating mode to a closed schema enum of the three supported modes (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Recurring class: API accepts misspelled operating mode via unconstrained string. Evidence: gamma (2026-10-03), zeta (2026-10-04). Rung: types - closed schema enum (architecture cannot help: one shared owner already exists). Instance rejected: gamma. No existing guard missed. Sweep-filed; direct-PR delivery.
- [ ] rollback-cache-guard-repair - Repair the rollback behavioral test so it runs unconditionally for the stale-cache transition (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Recurring class: stale cache survives rollback. Evidence: theta (2026-10-01), iota (2026-10-02). Rung: behavioral test - repair the existing guard, which was disabled by an opt-in condition / skipped and missed both instances. Instance rejected: theta. Sweep-filed; direct-PR delivery.
## Done
