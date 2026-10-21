# Shared review rubric

This file owns the review criteria for Firstmate-dispatched no-mistakes runs and independent review lanes.
It does not change the selected delivery path, review authority, or merge policy.

- Compare the change against the captain's concrete ask, the task Definition Of Done, and the out-of-scope list.
- Verify each applicable DoD item against observable behavior and its evidence; identify missing criteria or evidence explicitly rather than inventing requirements.
- Treat the DoD and exclusions as author-supplied verification evidence, not additional captain intent or authority to widen the ask.
- Keep findings tied to the authorized change and its effects; do not demand an excluded redesign or unrelated improvement as a condition of completion.
- Check correctness, regressions, safety boundaries, and the claimed verification against the diff and the available execution records.
- Every factual claim in a PR body must be backed by a record: the diff, a test, a check link, or a verification-plan row id.
- When a record does not prove a claim, delete or narrow the claim to what the record proves, never merely re-word it.
