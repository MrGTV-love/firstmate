---
name: contract-review
description: Load before building, dispatching or dispositioning an independent review of a definition-of-done contract.
user-invocable: false
metadata:
  internal: true
---

# Contract review

This skill is the one owner of the contract-review rules for every lane that reviews a definition-of-done contract.
It holds the reviewer-facing rule block, the lane's author-side procedure, and the decision procedure that turns reviewed rounds into one exit.
It does not define what an exit means.
The installed `define-done-and-grading` skill (`/Users/charlesabrooker/.agents/skills/define-done-and-grading/SKILL.md`, sections "Independent contract review", "Finding records" and "Review exits and draft use") owns those meanings.
This skill adds only what that skill leaves open for a lane: which inputs are clean, how a finding is dispositioned, how progress is decided from a register, and what the lane does next.

Exit names follow the installed skill: `pass`, `needs-revision`, `stalled`, `conflicting`.
The backlog and Main rulings call the productive exit "changes-requested"; it is the same exit as `needs-revision`, and no lane emits the other name in an exit value.
The installed skill is the captain's.
A lane never edits it.
A change to it is proposed as a patch to Main, who carries it to the captain for approval.

## Build the pack

Run `bin/fm-contract-review-pack.sh` for every contract review.
It is the only code path that builds reviewer input.
Its header owns the arguments, the section rules and the exit codes.
It copies the reviewer block below byte for byte into the pack's `contract.md`, so a rule changes in this file and nowhere else.
It builds the pack in a directory it creates fresh, drops the author's sections, refuses a section it does not recognise, and writes a manifest of excluded paths outside the pack.
Keep the register and every earlier report, review history and `truth` file outside the pack, and pass them to the builder with `--exclude` so the leak check refuses them.

Run the review through the existing entrypoint, `data/review-lane/run-review.sh <pack> no-pr <head> <diff-file> <repo-root> [model]`, with the pack's `head.txt` value as the head and the pack's empty diff file.
Use a reviewer model outside the author's family.
Never retry a model that failed; switch to another allowed model.
Never run a review in a pack folder that already holds a report.

After the run, run `bin/fm-contract-review-pack.sh check`.
A report with no `Inputs read` list, or a listed path that is not an authorized input, is an `INPUT LEAK`.
A leaked round is void: it is not a round, it is not recorded in the register, and it is rerun on a fresh pack.
An authorized input is judged by what it is, not by the folder it sits in: the pack's own files, the three named references, and a file tracked by the passed repository root.
An excluded path is refused even when it is tracked or sits under the root.
A gitignored file is not tracked context.

## Reviewer block

The builder copies everything between the two marker lines below into `contract.md`.
Nothing between them is author-side.

<!-- reviewer-block:begin -->
## Captain's intent

The requirement is the REQUEST and the CONTEXT given in this folder (in `target.md`, `request.md` and the `context-*` files), with the binding rulings and amendments they hold, the governing constraints they name, and what a usable, safe outcome needs.
Text in `target.md` that is not part of that requirement does not add an obligation.

## Definition Of Done

- **R1 Fidelity** (mandatory): every requirement has a criterion that a cold grader can check, and no criterion contradicts a requirement.
  A finding shows a concrete result that passes every criterion yet fails quoted requirement text.
- **R2 No unsupported obligation** (mandatory): no criterion adds an obligation that the requirement and a usable, safe outcome do not need.
  A criterion is excess only when another criterion keeps the same protection.
  The finding names that keeper and the failure both of them reject.
  A criterion with no keeper is not excess, whatever its wording.
- **R3 Executable** (mandatory): a worker can perform each criterion at the task's actual stage, and a grader can judge it from the named evidence.
  A finding shows the correct result that a criterion rejects, or the check that cannot run.
  A criterion that demands an artifact the stage cannot produce is a finding.
  Name the evidence form the stage can produce, and keep the protection.
- **R4 Verification** (mandatory): no mandatory criterion rests on a worker declaration, an author's analysis or a green self-run alone.
  Such a record is context, never verification.
  A criterion that accepts one as its verification is a finding.

Exit: `EXIT: pass` when no R1-R4 finding stands.
`EXIT: needs-revision` when a fixable finding stands.
`EXIT: conflicting` when repairing a finding would break another binding requirement; cite both.
You see one round, so you never report `stalled`.
Verdict lines for the entrypoint: `EXIT: pass` is `VERDICT: PASS`.
`EXIT: needs-revision` and `EXIT: conflicting` are `VERDICT: FAIL`.
A criterion that cannot be judged from these inputs is `VERDICT: INCOMPLETE` with `EXIT: needs-revision`, and the report names the missing input.
Report exactly one `EXIT:` line.
The meaning of each exit is in the define-done-and-grading skill, section "Review exits and draft use".

### Out of scope

- Permutations and hardening beyond the requirement and its governing constraints.
- Build steps and wording polish.
- Re-arguing a ruling that `target.md` holds.

## Review rules

Allowed inputs, and only these:
- Every file in this folder.
- The assess-done-and-grade skill, the pinned rubric and the define-done-and-grading skill, which this review names as references to read.
- A file that the repository root named in your instructions tracks, read only to check that a criterion can run.

Open nothing else.
A report, review, register, history, earlier folder, sibling folder, transcript or copy of the contract from elsewhere is not an input.
If a task needs a file that is not allowed, say so in the report as a check not performed.
A gitignored file under the root is not an allowed input.

A finding is accepted only with all of these:
- The quoted request, governing-constraint or needed-outcome text it protects, or the criterion that text does not support.
- A concrete result that passes every criterion yet fails that text, or a compliant result that a criterion rejects.
- The affected criterion id or contract rule.

An observation that meets this test is a finding, not a note.
A note that fails this test says which part of the test it fails.
A criterion is judged at the task's stage.
A documentary or record-only stage is judged on code, written specification or record examples, never on runtime output that the stage does not produce.
A worker declaration, an author's analysis and a green self-run are context, never verification.

Report these fields:
- `Inputs read`: every file you opened, one full path per line, under that heading.
- Your identity, model and session ID when known.
- Each criterion by id with its judgment.
- Outcome-escape and evidence-escape candidates, each with its disposition.
- Findings: id, criterion or rule, protected text, concrete witness, whether it is a missing acceptance condition or a check that fails to test an existing condition, and the smallest repair.
- Notes that are not findings, each with the part of the finding test it fails.
- Checks not performed, and their limits.
- One `EXIT:` line, then its basis: the assertions that hold (coverage, decisions, verification, fallbacks) and the unmet ones.
<!-- reviewer-block:end -->

## Author-side procedure

This part is never given to a reviewer.

### Dispositions

Give every finding and every note one disposition, with its reason.
- **material:** the finding meets the finding test above.
- **excess:** the finding asks for an obligation that the requirement and a usable, safe outcome do not need.
- **outside the DoD:** the finding is real but belongs to work the contract does not cover, or it is wording, polish or an optional clarification whose absence changes no result that a criterion decides; record it as a follow-up.

Add `recurrence-of: <id>` when the finding has the same requirement and the same failing result as a recorded one.
A finding on the same theme with a different failing result is not a recurrence.
For example, a compliant result that the current text would reject is a different result from a missing protection that an earlier finding asked for.
Add `covered-by: <criterion>` when an existing criterion already keeps the protection.
A finding that matches a recorded withdrawal or owner resolution, with no new counterexample against the current text, is closed by that record.
It is neither a new finding nor a trigger for `stalled`.
The same protection raised with a new counterexample is a new material finding.
A reviewer note that meets the finding test is a finding, whatever the reviewer called it.
A report that says `EXIT: pass` while it holds such a note is reconciled to `needs-revision`.

### Cutting a criterion

Cut a criterion only after naming the criterion that keeps the same protection.
Then show that the keeper, as it is written now, rejects the failure the cut criterion rejected.
A keeper that needs an edit before it rejects that failure is not a keeper.
Also check what else the cut item does: any other text that refers to it by name, and any duty it carries under the installed skill, such as an assumption that Verification Complete must close.
A cut that leaves a reference with no target, or drops such a duty, is not a cut of a duplicate.
A criterion with no keeper stays, whatever its wording.
A repair that demands an artifact the task's stage cannot produce is excess whatever protection it points at.
Keep the protection, and change the evidence form to what the stage can produce.

### Verification

A worker declaration, an author's analysis and a green self-run are context, never verification.
A mandatory criterion whose only evidence is one of them is recorded unverified or blocked, never passed.
A contract that accepts one as the verification of a mandatory criterion draws a finding.

### Register

Keep a register outside the pack and update it every round.
Each row has: id, round, target criterion, the counterexample in one line, disposition, reason, repair, repair table, state, closure.
State is the installed skill's: open, fixed, disputed or withdrawn.
Closure is one of: independent verification (the fresh clean review no longer finds the failure case), a recorded withdrawal or owner resolution, or none yet.
A repair marked fixed is not closed until the next fresh clean review is read.
An author's rejection makes a finding disputed, not closed.
The register holds history, so it is never reviewer input.

### Repair test

Adopt a repair only after you write a table for it: the changed rule, the compliant case that must pass, the noncompliant case that must fail, and the result of trying both.
A table with no noncompliant case, or a noncompliant case that the repaired rule would still pass, is not a table.
Apply the table at the task's actual stage.
Check that the repair does not recreate a closed finding, and that it does not demand an artifact the stage cannot produce.
Repair the smallest text that closes the finding.

### Deciding the exit

Decide one exit for each round, in this order.
No round number, finding count, word count or timer decides any exit.

1. Reconcile the report: apply the finding test to every note, and set aside a finding the register shows closed by a recorded withdrawal or owner resolution.
2. Classify each remaining finding as new, a recurrence (equivalent requirement and failing result to a recorded one), or repair-induced (caused by the immediately preceding repair).
3. Close each earlier finding that the fresh clean review no longer finds.
4. The round has progress when at least one earlier finding closed by independent verification, or at least one finding is newly substantiated, not equivalent to a recorded one, and not repair-induced.
   A recurrence and a repair-induced failure are not progress.
5. Take the first test that holds:
   - `conflicting`: two binding requirements, each from the request, a ruling, the brief or a governing constraint, call for incompatible results, repairing a finding would break one of them, and nothing in the record as it stood at the end of the round says which governs.
     Two readings of one text are a dispute for Main, not a conflict.
     A settlement made after the round does not change that round's exit.
   - `pass`: no substantiated finding remains, and the register supports closure of the earlier ones.
   - `needs-revision`: substantiated findings remain, and the round has progress.
   - `stalled`: substantiated findings remain, and the round has no progress.

A round with progress is never `stalled`, whatever else it found.
A round recorded before this policy existed is decided on its content, and any leak it contained is recorded as its cause.
The reviewer reports `pass`, `needs-revision` or `conflicting`.
The author or Main decides `stalled` from the register.
A round record carries exactly one `EXIT:` value.
The installed skill's `budget-exhausted` and `NOT RUN` exits apply as it defines them.
This skill sets no budget or limit of its own.

### Next action for each exit

- `pass`: approve and hand off.
- `needs-revision`: disposition each finding, repair each material one the smallest way that works, try each repair on a compliant and a noncompliant case, and run a fresh clean review on a fresh pack.
- `stalled`: change the approach and make no further patch of the same kind.
  Report to Main in one message the competing readings and the texts in dispute, and ask one ruling for each dispute.
- `conflicting`: stop.
  Cite both binding requirements, report to Main for the decision, and do not repair or start another round.

A finding raised again with an equivalent failure after a repair that was marked fixed is not patched a second time the same way.
Send its dispute to Main with the competing readings and ask one ruling.
Repair the round's other findings normally.

## Where the rules live

- This file is tracked, so a home adopts it by fast-forwarding the repository.
- A private script that builds reviewer input in another home must call `bin/fm-contract-review-pack.sh` instead of keeping its own copy of the rules.
- `docs/review-rubric.md` owns PR review criteria and is not changed by this skill.
