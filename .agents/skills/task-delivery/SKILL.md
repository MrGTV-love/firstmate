---
name: task-delivery
description: Load before selecting, executing, supervising, or reviewing a task's delivery path.
user-invocable: false
metadata:
  internal: true
---

# Task delivery

The selected delivery path owns its own rigor.
When no-mistakes is selected, no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI; otherwise follow the faster path without adding an independent reviewer.
Never hold work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer authority for one from security, architecture, or risk alone.
A separate review or audit is allowed only when the captain explicitly requests that deliverable or the authorized task is a knowledge-only review; one named question remains scoped to that question.
If fast-path risk needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate.
The one exception is a Firstmate guard change on any path: for that change only, its required independent review overrides the manual-verdict hold and the separate-review limit above, including the "alone owns review" wording, as needed for that review; anti-stacking and every other rule above still apply.
Its task brief links the [guard procedure](../../../docs/guard-spec.md#guard-procedure) and its [review checklist](../../../docs/review-rubric.md#guard-changes), and the change lands only after the matching independent PASS that the checklist defines.
If the [automatic PR lane](../../../docs/configuration.md#automatic-review-and-merge-configreview-runner) cannot show it will wait for the PASS required by the review checklist, Main, which owns the [Firstmate landing order](../ship-landing/SKILL.md#firstmate-train-landing-order), keeps the guard PR in draft from first exposure until that PASS is recorded and its report has been verified.
If a PR subject to that draft requirement cannot be opened as a draft, stop before opening it and report the limitation to Main.
Local-only and other non-PR delivery are not newly prohibited; existing authority verifies the required PASS before authorized landing.
The path's worker, automated gates, and captain approval remain authoritative:

- **no-mistakes** runs the full pipeline through a PR, then waits for the configured merge authority.
- **direct-PR** has the worker push and open a PR without the no-mistakes pipeline, then waits for the configured merge authority.
- **local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority before firstmate uses the guarded fast-forward merge path.
