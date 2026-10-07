# Backlog

## In flight

## Queued

- guard-raw-command-lint [sweep-demo] - Add a shell-lint rule rejecting the raw command in favor of the sole approved wrapper
  Mistake class: shell scripts invoke the forbidden raw command instead of the approved wrapper. Evidence (2): lint-a (2026-10-01, data/learnings.md), lint-b (2026-10-06, data/lint-b/report.md).
  Ladder rung: lint. Architecture already exists (the wrapper) and types cannot constrain shell command text. Existing guard that missed: the shell-lint owner has no rule for this invocation, so repair it there.
  Recorded instance rejected: lint-a and lint-b scripts. The error message must name the wrapper as the fix. The lint-b reproduction becomes the fixture for the rule.
  Proposed only; dispatch follows normal intake and the project's direct-PR delivery mode. Do not edit the project's AGENTS.md or CLAUDE.md.

- guard-editorial-causal-claims-docs [sweep-demo] - Place reviewer guidance on stating subjective editorial tradeoffs as proven cause
  Mistake class: stakeholder explanations present a subjective editorial judgment as an established causal fact. Evidence (2): docs-a (2026-10-05, data/learnings.md), docs-b (2026-10-06, data/docs-b/report.md).
  Ladder rung: docs. No architecture, type, lint, or behavioral check can decide an editorial judgment; no mechanical guard exists to have missed it.
  Place the rule in the existing contributor docs that own reviewer guidance, chosen through the firstmate-coding-guidelines knowledge-placement tree. Wording should require separating observed fact from judgment. Would have flagged docs-a and docs-b.
  Proposed only; dispatch follows normal intake and the project's direct-PR delivery mode. Do not edit the project's AGENTS.md or CLAUDE.md.

## Done
