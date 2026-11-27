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

## Intent-to-test alignment

- Assess verification evidence collectively and proportionately against the captain's concrete ask and the task Definition Of Done (DoD), not the implementation's explanation; no single test needs to prove the entire outcome.
- Ask whether stated intent could be violated while all tests pass, or whether compliant behavior could fail these checks:
  - For a finding, name the requirement, a concrete plausible false-pass or false-rejection path, and the evidence needed to distinguish it; do not invent requirements or demand universal coverage.
- Establish external guarantees through observable outcomes and verification independent of the mechanism under test, including relevant harm prevention and legitimate completion:
  - Internal records and mocks remain valid mechanism evidence, and persisted state may itself be the intended output, but internal agreement alone does not establish an external guarantee.
- Preserve the semantic acceptance contract, not literal test code:
  - Builders may revise mechanism assertions, fixtures, APIs, or test oracles with justification and independent review showing the existing obligations remain protected.
  - Green end-to-end tests alone do not authorize weakening a unit assertion that protects an obligation.
  - Builders may not redefine, remove, or weaken accepted outcomes or their required protection to obtain a pass; changing accepted outcomes or granting waivers requires escalating to Main for the owner.
- Distinguish a demonstrated intent-breaking defect from missing evidence for a mandatory DoD item:
  - Apply the existing review outcomes, guard-reassessment requirements, and scope-escalation rules below.

## Review outcomes

Separate blocking findings (`FAIL`) from non-blocking notes (`NOTE`) strictly by materiality.
A blocking finding must name the violated requirement or obligation and a concrete, reachable failure path in the code, tests, or safety boundary.
Speculative, contrived, or unreachable sequences never block a verdict.

Each finding takes one of these outcomes:

- A failed DoD mandatory item: block.
- A mandatory item whose evidence can only be produced downstream of this review, for example after merge, install or release: listed by id as pending with the evidence still owed.
  It is never graded pass and does not by itself block the verdict for proceeding; the review's PASS means every item assessable now passed, not final acceptance, and the pending items stay open until that downstream evidence exists.
- Any other unresolved mandatory item, such as one assessable now but not assessed, one missing its required verification evidence, or one with an open contract question: block until its evidence or the owner's decision is obtained.
- A real defect that breaks the stated intent, even when no DoD item names it: block.
  That covers reachable failures such as data loss, broken safety boundaries, or wrong product behavior.
- An improvement outside the DoD: a follow-up note, never a block.
- Non-material findings - wording, comments, style, test naming, doc phrasing, PR body text, minor cleanup, or contrived sequences: a non-blocking `NOTE`, never `FAIL`, and never a reason to move a head that already passed.
- A change that lets a guard permit more than before, such as an added exception, allow-list entry, trust carve-out, relaxed threshold or widened scope: block with verdict FAIL, even outside the DoD where the follow-up-note outcome would otherwise apply, unless the PR cites a recorded reassessment of that guard's harm model, such as `data/<id>/report.md` or an explicit reassessment section in the PR body, and the change follows it.
- Removing a guard rule that such a recorded reassessment recommends: not a block.
- A fix that would add scope beyond the intent: escalate to Main for the owner; never build it silently.

## Re-reviews (closure checks)

A pull request gets one full independent review; after a `FAIL`, each follow-up review is a closure check scoped to the prior blocking findings and the incremental fix diff.

- Grade every prior blocking finding as `MET` or `NOT MET` against the new head with concrete evidence.
- Raise a new blocking finding during a closure check only when it is material and introduced by the fix diff itself.
- Do not re-audit unchanged code for fresh nits, wording, style, or paperwork.
- When every prior blocking finding is `MET` and the fix diff introduces no new material defect, return `VERDICT: PASS`.

## PR body claims

- Every factual claim in a PR body must be backed by a record: the diff, a test, a check link, or a verification-plan row id.
- When a record does not prove a claim, report it as a non-blocking `NOTE` naming the overstatement so the author or Main can edit the PR description directly on the forge.
- PR-body phrasing and missing citations are not part of the commit head; they never produce `FAIL`, never require a new commit, and never trigger a code re-review.
