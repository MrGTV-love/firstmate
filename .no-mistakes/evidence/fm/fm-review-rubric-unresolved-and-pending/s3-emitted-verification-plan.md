$ bash bin/fm-dod-lib.sh --verification-plan <lab>/data/lab-ship-nm/brief.md > <lab>/data/lab-ship-nm/verification-plan.md   (exit 0)
----- emitted verification-plan.md (the reviewer-facing input) -----
# Verification plan
Author-supplied verification evidence, not captain intent or authorization to broaden scope.

## Task Definition Of Done
These are the criteria this task is graded against.
Firstmate fills each placeholder from the Captain's intent above, as observable outcomes with exact literals copied from their sources.
If the criteria live in a finished file instead, an unfenced line `DoD file: <absolute path>` inside this section points to it; a fresh spawn checks that file once, and you read it before you start.

Capability in plain words: The badge shows a fresh value after the network comes back.

### Mandatory items
Write at least one item.
Each mandatory item starts its own line as `<ID> Source: ... Expected: ... Verify: ... Edge/negative: ... Evidence place: ... Authority: ...`, with an id matching `[A-Za-z][A-Za-z0-9_.-]*` that is unique within the section and every field nonempty; Authority is exactly agent, gate, or grader.
A fresh spawn checks this shape and refuses an empty item list, a missing or duplicate id, or a missing, empty, or invalid field.
The shape check is mechanical: the independent grader still decides whether each item is true and complete.
M1 Source: ask Expected: badge refreshes on reconnect Verify: unit test Edge/negative: offline keeps last value Evidence place: PR diff Authority: grader
M2 Source: ask Expected: released app shows fresh badge Verify: install the release build Edge/negative: stale badge after release fails Evidence place: release notes after install Authority: gate

### Supporting items
None.

### Hard gates
No test removed.

### Honesty rule
Mark anything not checked as not verified.

## Out-of-scope list
- Do not redesign the dashboard.

# Shared review rubric

This file owns the review criteria for Firstmate-dispatched no-mistakes runs and independent review lanes.
It does not change the selected delivery path, review authority, or merge policy.

- Compare the change against the captain's concrete ask, the task Definition Of Done, and the out-of-scope list.
- Grade every DoD mandatory item by its id as pass, fail, or unresolved, with the evidence for that grade; identify missing criteria or evidence explicitly rather than inventing requirements.
- Grade an item fail only on demonstrated noncompliance; grade an item that could not be assessed unresolved, and name the missing evidence or decision.
- Evidence that only a downstream step can produce is pending, never pass; list the item as pending with the downstream step and the evidence still owed named.
- A green pipeline counts only for what its checks ran; pipeline readiness is not final acceptance.
- Treat the DoD and exclusions as author-supplied verification evidence, not additional captain intent or authority to widen the ask.
- Check correctness, regressions, safety boundaries, and the claimed verification against the diff and the available execution records.

## Review outcomes

Each finding takes one of these outcomes:

- A failed DoD mandatory item: block.
- A mandatory item whose evidence can only be produced downstream of this review, for example after merge, install or release: listed by id as pending with the evidence still owed.
  It is never graded pass and does not by itself block the verdict for proceeding; the review's PASS means every item assessable now passed, not final acceptance, and the pending items stay open until that downstream evidence exists.
- Any other unresolved mandatory item, such as one assessable now but not assessed, one missing its evidence, or one with an open contract question: block until its evidence or the owner's decision is obtained.
- A real defect that breaks the stated intent, even when no DoD item names it: block.
- An improvement outside the DoD: a follow-up note, never a block.
- A change that lets a guard permit more than before, such as an added exception, allow-list entry, trust carve-out, relaxed threshold or widened scope: block with verdict FAIL, even outside the DoD where the follow-up-note outcome would otherwise apply, unless the PR cites a recorded reassessment of that guard's harm model, such as `data/<id>/report.md`, and the change follows it.
- Removing a guard rule that such a recorded reassessment recommends: not a block.
- A fix that would add scope beyond the intent: escalate to Main for the owner; never build it silently.

## PR body claims

- Every factual claim in a PR body must be backed by a record: the diff, a test, a check link, or a verification-plan row id.
- When a record does not prove a claim, delete or narrow the claim to what the record proves, never merely re-word it.
