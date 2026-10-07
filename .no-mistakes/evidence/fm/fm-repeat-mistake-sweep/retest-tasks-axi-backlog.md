# Backlog

## In flight

## Queued

- [ ] existing-owner-guard - Make archive deletion share owner validation (repo: sweep-demo) (kind: ship)
  Class: parallel archive deletion implementation skips owner check; tasks delta 2026-10-01 and epsilon 2026-10-02. Architecture: one shared deletion entry point.

- [ ] export-owner-guard - Route all exports through the single validated export owner (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Class: duplicated export implementation skips lock validation. Instances: alpha 2026-10-01, beta 2026-10-02. Rung: architecture (one shared export entry point; remove the independent implementations). Would have rejected: alpha (backup export in projects/sweep-demo/export.sh). No existing guard.
- [ ] mode-enum-guard - Constrain API operating mode to a closed enum (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Class: shared API owner accepts unconstrained mode string. Instances: gamma 2026-10-03, zeta 2026-10-04. Rung: types (closed enum/schema of the three fixed modes). Would have rejected: gamma misspelled mode. Single-owner architecture already correct.
- [ ] rollback-cache-test-repair - Repair skipped rollback stale-cache behavioral test (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Class: stale cache survives rollback. Instances: theta 2026-10-01, iota 2026-10-02. Rung: behavioral test; repair the existing rollback test whose opt-in condition skips this transition, so it runs and fails on the recorded case. Would have rejected: theta. Existing guard missed it; do not add a second.
## Done
