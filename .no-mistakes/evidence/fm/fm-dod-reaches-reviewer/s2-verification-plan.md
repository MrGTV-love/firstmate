# Verification plan
Author-supplied verification evidence, not captain intent or authorization to broaden scope.

## Task Definition Of Done
These are the criteria this task is graded against.
Firstmate fills each placeholder from the Captain's intent above, as observable outcomes with exact literals copied from their sources.
If the criteria live in a finished file instead, an unfenced line `DoD file: <absolute path>` inside this section points to it; a fresh spawn checks that file once, and you read it before you start.

Capability in plain words: DOD-CAP: badge reflects build state after refresh.

### Mandatory items
Each item has Source, Expected, Verify, Edge/negative, Evidence place, and Authority (agent, gate, or grader).
1. DOD-ITEM-1: refresh keeps the green badge.
   - Verify: browser test reloads page.

### Supporting items
- DOD-SUPPORT: docs updated.

### Hard gates
- DOD-GATE: no API change.

### Honesty rule
DOD-HONESTY: claim only what tests prove.

## Out-of-scope list
Out of scope: legacy-paragraph exclusion L1
- legacy list item L2
- spec exclusion S1: do not redesign the badge.
#1 priority is not touching the CSS.
- spec exclusion S3: no API changes.

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
