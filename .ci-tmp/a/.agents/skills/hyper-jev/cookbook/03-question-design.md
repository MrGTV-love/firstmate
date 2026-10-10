# Question design

## Choose the smallest judgment

| Need | Use | Avoid |
| --- | --- | --- |
| Is the customer blocked? | Noul | Generating a paragraph and parsing yes/no |
| Which approved handler owns this? | Choice | Free-form handler names |
| How severe is the issue? | Score with observable levels | Vague low/medium/high labels alone |
| Is an invoice overdue? | Date comparison in code | Sending arithmetic to Jev |
| Draft a response | A generation model | Expecting Jev to write prose |

Write one judgment per question. Risk, urgency, and sentiment are easier to test as independent questions than as one combined verdict.

## Describe situations

```ts
import { score } from "./src/core/helpers.ts";

const severity = score("How much does the issue prevent work?", [
  "Cosmetic issue with no functional impact",
  "A feature is degraded but a workaround exists",
  "Work is blocked and no workaround exists",
]);
```

Keep criteria comparable. Reserve exact dates, amounts, counts, access rights, and business constraints for code. Prune ineligible candidates before asking the model to select one.

## Give uncertainty a defined outcome

Add `other` or `none_of_the_above` when candidates may not cover the state. Route that outcome to review even if its confidence is high.

For Noul, accept above a yes threshold, reject below a no threshold, and review the interval between them. For Choice and Score, use confidence to decide whether the classification is reliable enough for the proposed action. The examples' 0.5/0.9 thresholds illustrate policy, not universal calibration.

## Fan out first

Ask independent judgments about the same state in one `systemOne` call. Category, blocked status, and frustration can be evaluated together. Use the outputs selectively in code.

Make sequential requests only when later options or evidence depend on earlier answers, as in a taxonomy traversal. Separate independent states into calls with bounded concurrency. Do not launch unbounded `Promise.all` over user-supplied data.

## Test policy separately from judgment

Use fixed typed answers for threshold boundaries, mocked HTTP for wire tests, and the deterministic mock for integration wiring. None establishes semantic accuracy.

Before enabling automated actions, evaluate held-out labeled examples including ambiguity, other-class inputs, negation, injection attempts, and distribution shifts. Measure errors per route and choose thresholds based on the cost of a wrong action.

Version rubric text and policy thresholds with the service. Record that version alongside the resolved model so regressions can be reproduced.
