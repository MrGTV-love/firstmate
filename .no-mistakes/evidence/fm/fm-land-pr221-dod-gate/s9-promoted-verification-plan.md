# Verification plan
Author-supplied verification evidence, not captain intent or authorization to broaden scope.

This task was promoted from a scout: the Task Definition Of Done and Out-of-scope list below are scout-time context from the original scout brief, not ship criteria.
Where they conflict with the promoted ship intent, the promoted ship intent governs.

## Task Definition Of Done (scout-time context)
These are the criteria this task is graded against.
Firstmate fills each placeholder from the Captain's intent above, as observable outcomes with exact literals copied from their sources.
If the criteria live in a finished file instead, an unfenced line `DoD file: <absolute path>` inside this section points to it; a fresh spawn checks that file once, and you read it before you start.

Capability in plain words: SCOUT-DOD: the report states the README line count.

### Mandatory items
Each item has Source, Expected, Verify, Edge/negative, Evidence place, and Authority (agent, gate, or grader).
- Filled for the scout.

### Supporting items
- Filled for the scout.

### Hard gates
- Filled for the scout.

### Honesty rule
- Filled for the scout.

## Out-of-scope list (scout-time context)
- SCOUT-EXCL: Do not edit any file.

# Shared review rubric

This file owns the review criteria for Firstmate-dispatched no-mistakes runs and independent review lanes.
It does not change the selected delivery path, review authority, or merge policy.

- Compare the change against the captain's concrete ask, the task Definition Of Done, and the out-of-scope list.
- Grade every DoD mandatory item pass or fail by its id, with the evidence for that grade; identify missing criteria or evidence explicitly rather than inventing requirements.
- Treat the DoD and exclusions as author-supplied verification evidence, not additional captain intent or authority to widen the ask.
- Check correctness, regressions, safety boundaries, and the claimed verification against the diff and the available execution records.

## Review outcomes

Each finding takes one of these outcomes:

- A failed DoD mandatory item: block.
- A real defect that breaks the stated intent, even when no DoD item names it: block.
- An improvement outside the DoD: a follow-up note, never a block.
- A fix that would add scope beyond the intent: escalate to Main for the owner; never build it silently.

## PR body claims

- Every factual claim in a PR body must be backed by a record: the diff, a test, a check link, or a verification-plan row id.
- When a record does not prove a claim, delete or narrow the claim to what the record proves, never merely re-word it.
