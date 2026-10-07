# 03. Composite scoring

[Catalog and runtime setup](README.md). Demonstrations only, not calibrated production policies.

Use separate rubric scores when reviewers need to understand why an item ranks highly. Jev estimates rubric positions; deterministic code normalizes, weights, rounds, and selects a band. This is more inspectable than asking for one unexplained overall number.

## Three implementations

- **[ticketPriority / combinePriority](../../templates/starter/src/levels/level03/ticket-priority.ts)**: ticket -> severity, frustration, report-quality Scores -> `{ priority, parts }`. Severity and frustration have three levels; report quality has four. Normalize to `[0,1]`, then combine with weights `0.6`, `0.3`, `0.1` and round to two decimals. Use to order a queue; code still sets service-level deadlines and tie-breakers.
- **[codeReviewRisk](../../templates/starter/src/levels/level03/code-review-risk.ts)**: diff + commit message -> security, complexity, convention-drift, commit-quality Scores -> `{ risk, needsHumanReview }`. Weights are `0.5`, `0.2`, `0.1`, `0.2`; commit quality is inverted so poor descriptions increase risk. Human review uses the **unrounded** risk `>= 0.5`, while returned risk is rounded. Use to add review, never to bypass required checks.
- **[ideaVerdict](../../templates/starter/src/levels/level03/idea-verdict.ts)**: pitch -> problem, demand, monetization, differentiation Scores -> `{ verdict, score }`. Weights are `0.35`, `0.25`, `0.2`, `0.2`. On the rounded total, `>= 0.7` is ship, `>= 0.4` is fix, otherwise kill. These are sorting labels for human discussion, not market evidence or launch authorization.

## Try it

Save as `example.ts` in the starter root.

```ts
import { ticketPriority } from "./src/levels/level03/ticket-priority.ts";

const result = await ticketPriority(
  "Checkout is broken for all customers, no workaround, losing revenue, repro included."
);
console.log({ priority: result.priority, components: result.parts });
```

```bash
JEV_BACKEND=mock node example.ts
npm test
```

## Boundaries and tests

[Existing tests](../../templates/starter/tests/level03.test.ts) check normalization on different rubric lengths, exact priority weights, output ranges, an auth-review example, and valid idea labels. `combinePriority` is a useful pure unit-test seam.

The shared [normalized](../../templates/starter/src/levels/level03/normalize.ts) divides by `Object.keys(answer.legend).length - 1`. It does not clamp or validate its own input. The finalized live client validates score ranges and exact legend keys/descriptions against the question before returning answers. Direct calls to the pure helper with hand-built or independently loaded answers bypass that protection: validate those inputs or normalize against the known rubric. Check finite numbers in application code.

Add tests for invalid legends, NaN, out-of-range scores, weight sums, monotonicity, and rounding near `0.4`, `0.5`, and `0.7`. A displayed risk of `0.50` can have `needsHumanReview: false` because the decision used an unrounded value. Test that behavior deliberately or change policy in the adapted code.

## Production policy

- Weights encode business priorities, not objective truth. Version them and evaluate with labeled examples and observed outcomes.
- Confidence is ignored by these composites. Add review for uncertain components rather than treating a weighted mean as certainty.
- Prevent a low aggregate from masking a critical issue. Security findings, failing tests, and compliance requirements need independent mandatory review rules.
- Pitch and diff text can omit evidence. Supply only relevant context, and do not claim the score verifies facts not present in that context.
