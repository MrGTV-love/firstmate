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
The one exception is a Firstmate guard change on any path: its task brief links the [guard procedure](../../../docs/guard-spec.md#guard-procedure) and its [review checklist](../../../docs/review-rubric.md#guard-changes), and it lands only after a matching independent PASS recorded under that checklist for the final base and head.
If the [automatic PR lane](../../../docs/configuration.md#automatic-review-and-merge-configreview-runner) cannot show that it will wait for that PASS, Main, which owns the [Firstmate landing order](../ship-landing/SKILL.md#firstmate-train-landing-order), keeps the guard PR in draft until the existing independent lane records that PASS for the exact base and head, scope, checked tree, and executed-evidence verdict.
A guard change on a path with no PR draft, or a guard PR that cannot use that draft hold, stops before landing and goes to Main as a report.
The path's worker, automated gates, and captain approval remain authoritative:

- **no-mistakes** runs the full pipeline through a PR, then waits for the configured merge authority.
- **direct-PR** has the worker push and open a PR without the no-mistakes pipeline, then waits for the configured merge authority.
- **local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority before firstmate uses the guarded fast-forward merge path.
