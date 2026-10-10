# 01. Single decisions

[Catalog and runtime setup](README.md). Demonstrations only, not calibrated production policies.

Use one narrow judgment when application code already knows the possible branches. Prefer a Noul for a yes/no signal and a Choice for mutually exclusive destinations. No generated prose needs parsing.

## Three implementations

- **[injectionGate](../../templates/starter/src/levels/level01/injection-gate.ts)**: message -> `is_injection` Noul -> `{ injection, noul }`. The sample sets `injection` when `noul > 0.5`. Use as an extra signal before handling untrusted text; application policy decides quarantine or review. It neither sanitizes the message nor prevents execution.
- **[urgentGate](../../templates/starter/src/levels/level01/urgency-gate.ts)**: message -> `is_urgent` Noul -> `{ act, noul }`. Default policy is `noul >= 0.7`, with a caller-supplied threshold. Use to prioritize a queue or propose an alert; code owns paging, deduplication, quiet hours, and escalation.
- **[classifyTicket](../../templates/starter/src/levels/level01/ticket-classifier.ts)**: message -> department Choice -> `{ department, confidence }`. Options are `billing`, `technical`, `sales`, `other`. Use to choose a queue from an allowlisted map. `other` is an escape hatch, not a guaranteed answer on unfamiliar input; the sample has no confidence fallback.

## Try it

Save as `example.ts` in the starter root. This records a routing proposal, not an external action.

```ts
import { injectionGate, urgentGate, classifyTicket } from "./src/levels/level01/index.ts";

const message = "The API returns 500 on the /invoices endpoint since this morning.";
const injection = await injectionGate(message);
if (injection.injection) {
  console.log({ next: "review", injection });
} else {
  const urgency = await urgentGate(message, 0.7);
  const routing = await classifyTicket(message);
  console.log({ urgency, routing });
}
```

```bash
JEV_BACKEND=mock node example.ts
npm test
```

## Boundaries and tests

[Existing tests](../../templates/starter/tests/level01.test.ts) cover obvious injection vs normal text, urgent vs routine text, technical routing, and department membership. They are mock wiring checks, not semantic validation.

Add policy tests at `0.5` for injection and just below/at/above the urgency threshold. Validate custom thresholds as finite values in `[0,1]`. Add empty input, low-confidence routing, input-size limits, negated urgency, quoted attack text, and request failure cases. Do not assert that every unrelated input must select `other`.

## Production policy

- Security classifiers must not be the sole safeguards. A negative injection result is not proof of safety; keep instruction/data separation, least privilege, and effect-level authorization.
- Confidence is not authorization, and urgency is not entitlement. An urgent billing ticket still requires account checks.
- For repeated judgments on the same message, consider [one-call fan-out](02-fan-out.md). The snippet intentionally performs separate calls so the early gate is visible.
