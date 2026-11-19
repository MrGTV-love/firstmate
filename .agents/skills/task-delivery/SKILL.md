---
name: task-delivery
description: Load before selecting, executing, supervising, or reviewing a task's delivery path.
user-invocable: false
metadata:
  internal: true
---

# Task delivery

The selected delivery path owns its own rigor.
When no-mistakes is selected, it owns its pipeline's review, fixes, tests, documentation, push, PR, and CI.
For Firstmate guard changes on any path, link the [guard procedure](../../../docs/guard-spec.md#guard-procedure) and its [review checklist](../../../docs/review-rubric.md#guard-changes) from the task brief and obtain the qualified verdict before landing.
If the [automatic PR lane](../../../docs/configuration.md#automatic-review-and-merge-configreview-runner) cannot show that it will wait for a qualified PASS, keep the PR in draft until an existing independent lane supplies one.
For unrelated work outside no-mistakes, follow the faster path without requiring an independent reviewer or holding for a manual clean verdict.
Do not stack redundant reviews or infer authority for one from security, architecture, or risk alone.
A separate review or audit beyond the selected path and guard procedure is allowed only when the captain explicitly requests that deliverable or the authorized task is a knowledge-only review; one named question remains scoped to that question.
If unrelated fast-path work needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate.
The path's worker, automated gates, and captain approval remain authoritative:

- **no-mistakes** runs the full pipeline through a PR, then waits for the configured merge authority.
- **direct-PR** has the worker push and open a PR without the no-mistakes pipeline, then waits for the configured merge authority.
- **local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority before firstmate uses the guarded fast-forward merge path.
