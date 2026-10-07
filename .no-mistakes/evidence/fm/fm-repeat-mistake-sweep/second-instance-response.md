Both repeated mistake classes qualify for a guard, and I filed one backlog task for each. I only read files and edited the lab `data/backlog.md`. The home uses the manual backend, so I added the tasks by hand under `## Queued`. The backlog had no existing item for either class. Nothing was fixed or dispatched, and no tests or pipelines ran. The project's delivery mode is direct-PR.

**1. Raw shell command used instead of the sole approved wrapper**
- **Evidence (2 instances):** lint-a (learnings, 2026-10-01) and lint-b (`data/lint-b/report.md`, 2026-10-06).
- **Chosen guard:** rung 3, lint. Architecture already has a single wrapper owner, and types can't apply to shell text. The rule goes in the repository's existing shell-lint owner. Its error message names the wrapper as the fix.
- **Instance it would have rejected:** the lint-a script.
- **Existing guard that missed it:** none. No lint rule exists yet.
- **Task ID:** `guard-shell-raw-command-lint`

**2. Editorial tradeoff stated as an established causal fact**
- **Evidence (2 instances):** docs-a (learnings, 2026-10-05) and docs-b (`data/docs-b/report.md`, 2026-10-06).
- **Chosen guard:** rung 5, docs. Editorial judgment can't be honestly checked by architecture, types, lint or a behavioral test. The task adds reviewer guidance to the existing contributor docs, placed through the `firstmate-coding-guidelines` knowledge-placement tree. Guidance doesn't guarantee rejection.
- **Instance it addresses:** the docs-a explanation.
- **Existing guard that missed it:** none.
- **Task ID:** `guard-editorial-tradeoff-reviewer-guidance`

SECOND_INSTANCE_DONE
