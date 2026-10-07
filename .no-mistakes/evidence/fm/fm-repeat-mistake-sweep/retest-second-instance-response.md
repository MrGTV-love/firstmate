Both second occurrences qualify for a guard, so I filed one proposed task for each in the lab backlog. I used the `diagnostic-reasoning` repeat-mistake sweep. This home's backend is `manual`, so I hand-edited `data/backlog.md` under `## Queued`. Nothing was implemented or dispatched. The project's `AGENTS.md`/`CLAUDE.md` and source files are untouched, and the project stays `direct-PR`.

**Class 1: raw command used instead of the approved wrapper (2 instances)**
- **Evidence:** lint-a (2026-10-01, `data/learnings.md`) and lint-b (2026-10-06, `data/lint-b/report.md`).
- **Rung:** lint. The wrapper architecture already exists, and types can't constrain shell command text.
- **Guard that missed:** the existing shell-lint owner has no rule for this invocation, so the remedy is to repair it there. The rule's error message should name the wrapper as the fix.
- **Instances it would have rejected:** the lint-a and lint-b scripts. The lint-b reproduction becomes the fixture.
- **Task filed:** `guard-raw-command-lint`

**Class 2: subjective editorial judgment stated as proven cause (2 instances)**
- **Evidence:** docs-a (2026-10-05, `data/learnings.md`) and docs-b (2026-10-06, `data/docs-b/report.md`).
- **Rung:** docs. No architecture, type, lint or behavioral check can decide an editorial judgment, so no mechanical guard exists to have missed it.
- **Placement:** the existing contributor docs that own reviewer guidance, chosen through the `firstmate-coding-guidelines` knowledge-placement tree. The wording should require separating observed fact from judgment, which would have flagged docs-a and docs-b.
- **Task filed:** `guard-editorial-causal-claims-docs`

The archived recommendation in `data/memory-archive.md` is not an authorization, and I did not act on it.

SWEEP_DONE
