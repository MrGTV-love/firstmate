# Backlog

## In flight

## Queued

- [ ] existing-owner-guard - Make archive deletion share the owner validation used by other destructive paths (repo: sweep-demo) (kind: ship)
  Recurring class: parallel archive deletion implementation omits owner check. Evidence tasks delta and epsilon. Remedy architecture: one shared deletion entry point.
- [ ] export-single-owner-guard - Route all export paths through the one lock-checked export owner and remove duplicate export entry points (repo: sweep-demo) (kind: ship)
  Recurring class: independent export implementation omits lock validation. Evidence tasks alpha (2026-10-01, backup export) and beta (2026-10-02, batch export). Remedy architecture: one export entry point; would have rejected alpha's independent backup export. No existing guard. Excludes solo (disk full, different cause).
- [ ] operating-mode-enum-guard - Replace the unconstrained operating-mode string with a closed schema enum of the three supported modes (repo: sweep-demo) (kind: ship)
  Recurring class: API accepts misspelled operating mode. Evidence tasks gamma (2026-10-03) and zeta (2026-10-04). Remedy types: closed enum rejects gamma's misspelled mode before execution; architecture does not apply since one shared owner already exists. No existing guard.
- [ ] rollback-cache-guard-repair - Repair the existing rollback behavioral guard so its opt-in condition cannot skip the stale-cache rollback transition (repo: sweep-demo) (kind: ship)
  Recurring class: stale cache survives rollback. Evidence tasks theta (2026-10-01) and iota (2026-10-02). Remedy behavioral test: repair the existing rollback guard, which missed theta and iota because it was disabled/skipped by an opt-in condition; no new test or prose. Architecture, types and lint cannot express the environment-dependent transition.

## Done
