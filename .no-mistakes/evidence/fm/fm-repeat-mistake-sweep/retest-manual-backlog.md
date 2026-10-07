# Backlog

## In flight

## Queued

- [ ] existing-owner-guard - Make archive deletion share owner validation (repo: sweep-demo) (kind: ship)
  Class: parallel archive deletion implementation skips owner check; tasks delta 2026-10-01 and epsilon 2026-10-02. Architecture: one shared deletion entry point.

- [ ] export-single-owner-guard - Route all exports through the validated export owner (repo: sweep-demo) (kind: ship)
  Class: duplicated export implementation skips lock validation; tasks alpha 2026-10-01 (learnings.md) and beta 2026-10-02 (learnings.md). Architecture: one export entry point, remove independent export paths (e.g. export.sh); would have rejected alpha. No existing guard.

- [ ] operating-mode-enum-guard - Constrain API operating mode to a closed enum/schema (repo: sweep-demo) (kind: ship)
  Class: shared API owner accepts unconstrained mode string; tasks gamma 2026-10-03 and zeta 2026-10-04 (learnings.md). Types: enum/schema of the three fixed modes; would have rejected gamma's misspelling. Owner architecture already correct; no existing guard.

- [ ] repair-rollback-cache-test - Repair skipped rollback behavioral test so stale cache after rollback fails (repo: sweep-demo) (kind: ship)
  Class: stale cache survives rollback; tasks theta 2026-10-01 and iota 2026-10-02 (learnings.md). Behavioral test: existing rollback test is disabled by an opt-in condition and missed both; repair it (make it run unconditionally) and cover the recorded transition. Architecture/types/lint cannot express it.

## Done
