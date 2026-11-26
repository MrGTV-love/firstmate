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
The independent different-family review may run before no-mistakes or in parallel with CI, rather than waiting until CI is green.
When no-mistakes makes no code changes beyond the reviewed head, or merges only clean base content proven by `bin/fm-review-record.py`, that PASS carries forward to satisfy the standing merge rule.
When pipeline fixes modify code after an earlier read, run a scoped closure re-review on the final head covering the changed lines and any open items (`docs/review-rubric.md`).
Never hold work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer authority for one from security, architecture, or risk alone.
A separate review or audit is allowed only when the captain explicitly requests that deliverable or the authorized task is a knowledge-only review; one named question remains scoped to that question.
If fast-path risk needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate.
The path's worker, automated gates, and captain approval remain authoritative:

- **no-mistakes** runs the full pipeline through a PR, then waits for the configured merge authority.
- **direct-PR** has the worker push and open a PR without the no-mistakes pipeline, then waits for the configured merge authority.
- **local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority before firstmate uses the guarded fast-forward merge path.
