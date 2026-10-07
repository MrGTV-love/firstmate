---
name: diagnostic-reasoning
description: >-
  Agent-only procedure for diagnosing reported bugs and recurring mistakes.
  Use before scoping a reported bug and before acting on a diagnostic report.
  Also use when the captain asks what agents keep getting wrong or for a repeat-mistake sweep, and when a second instance of an already-seen mistake class surfaces.
  Owns end-user-aligned reproduction, causal separation, divergent-path and history inspection, counterfactual testing, disconfirming evidence, the strongest-guard-first remedy order, and the repeat-mistake sweep.
user-invocable: false
metadata:
  internal: true
---

# diagnostic-reasoning

Use this procedure before scoping a reported bug and before acting on a diagnostic report.
This skill is the single owner of Firstmate's bug-diagnosis reasoning procedure.
Firstmate applies it when briefing delegated investigation and evaluating the resulting evidence, without taking over project-specific investigation itself.

## Establish the observed behavior

Start from the end user's experience rather than an internal error string or an implementation hypothesis.
Require an end-to-end reproduction aligned with the real user path whenever it is feasible and safe.
If a faithful reproduction is not feasible, record the exact limitation and use the closest representative path without presenting it as equivalent evidence.
Capture the expected behavior, observed behavior, setup, inputs, and repeatability before assigning a cause.

Separate these three facts explicitly:

- The **initiating trigger** is the event, input, or transition that starts the faulty behavior.
- The **masking condition** is the independent state, environment, timing, cache, configuration, or path difference that hides or exposes the fault.
- The **visible symptom** is what the end user or operator can actually observe.

Do not collapse those facts into one label.
A masking condition may explain why a fault appears only sometimes without being the initiating cause, and the visible symptom may be several layers downstream from both.

## Test the causal explanation

Inspect the failing path and a proven path where the intended behavior is known to work.
Compare their inputs, state transitions, dependencies, timing, and control flow to find the earliest meaningful divergence.
Inspect relevant history, including blame, commits, migrations, and prior implementations, when it can explain why the paths diverged or which invariant was intended.
Do not treat the most recent nearby change as causal without evidence.

Identify the smallest counterfactual that should change the outcome if the leading explanation is true.
Change one condition at a time where practical, and record whether the symptom appears, disappears, or remains unchanged.
Seek disconfirming evidence deliberately: name what observation would falsify the leading explanation, run that check when feasible, and retain contradictory results instead of explaining them away.
Compare the final explanation against the proven path and show why the proposed causal boundary accounts for both the failure and the success.

## Scope and act on the result

A diagnosis brief should ask for the reproduction, trigger/mask/symptom separation, divergent and proven path comparison, relevant history, smallest counterfactual, and disconfirming evidence in the report.
A diagnostic report should distinguish observed facts from hypotheses and state any unresolved uncertainty that could change the recommended scope.
Before acting on the report, verify that its claimed cause explains the end-user reproduction and the proven path without relying on an untested masking condition.
If a load-bearing element is missing, route a focused follow-up investigation instead of treating confidence or implementation detail as proof.
A diagnosis or implementation-ready recommendation is evidence, not authorization to change code.
Implementation still requires the captain's request or another existing lifecycle authority, and the reproduction should become the regression test when a fix is authorized.

## Recurring mistakes: strongest guard first

When one class of mistake recurs, a one-time fix or a new prose prohibition is the weakest remedy.
Prefer the strongest guard that makes the mistake impossible or loudly rejected, in this order:

1. **Architecture** - change the structure so the mistake cannot be expressed, such as one owner for a contract, one entry point, or removing the option.
2. **Types** - make the wrong shape fail validation, such as a schema, an enum, or a typed interface.
3. **Lint** - add a check whose error message names the fix, in the project's own lint owner.
4. **Behavioral test** - add an executable test that fails on the recorded mistake; the diagnostic reproduction becomes that regression test.
5. **Docs** - use only where no mechanical guard can express the rule, and place it through the `firstmate-coding-guidelines` knowledge-placement tree.

Choose the first rung that would have rejected a recorded instance of the mistake, and name that instance.
A guard that would not have caught a recorded instance is not a remedy.
When a guard already exists and missed the instance, the remedy is repairing that guard.
Stop at the first rung that works rather than stacking several.
Some judgments cannot be reduced to a deterministic check; say so and use the strongest rung that honestly applies.
This ladder only orders remedies, so the diagnosis-is-evidence rule above still holds and every remedy ships through a normal task following normal intake and the project's delivery mode.

## Repeat-mistake sweep

Run the sweep when the captain asks what agents keep getting wrong, or when you notice a second instance of a mistake class while handling other work.
Nothing schedules it automatically.
The sweep reads and files; it never fixes.

1. Read the evidence: `data/learnings.md` and `data/memory-archive.md`, the `state/*.status` events still on disk, scout reports under `data/<id>/report.md`, no-mistakes findings snapshots under `data/<id>/nm-*-findings.txt`, and failed CI runs and review findings on recent task PRs read through `gh-axi`.
2. Group instances into mistake classes by root cause, using the trigger, masking condition, and symptom separation above, not by matching wording.
3. Count evidence per class: list every instance with its source and date.
   A class qualifies for a guard at two or more instances from different tasks.
4. For each qualifying class, pick the ladder rung, name the recorded instance it would have rejected, and name any existing guard that missed.
5. File each proposed guard as an ordinary backlog task following the configured-backend contract in [`docs/configuration.md`](../../../docs/configuration.md#required-tools-and-manual-mode), after checking the backlog for an existing item on the same class.
   Use `bin/fm-tasks-axi.sh add` for tasks-axi homes and the documented manual path for manual homes.
   Dispatch follows normal intake and the project's delivery mode.
   Never fix inline, and never edit a project's `AGENTS.md` or `CLAUDE.md`; guidance for firstmate's own material goes through `firstmate-coding-guidelines`.
6. Report each qualifying class with its evidence count, chosen rung, and filed task id.

A learnings entry records the gotcha until a guard lands; it is never the remedy for a class that qualified for one.
