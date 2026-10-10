# 05. Routing

[Catalog and runtime setup](README.md). Demonstrations only, not calibrated production policies.

Use Jev to select an application-owned handler, execution budget, or worker profile. Return a small routing record, then dispatch through an allowlisted registry. These functions do not invoke another model, start an agent, query a database, or grant desktop access.

## Three implementations

- **[routeIntent / decideIntent](../../templates/starter/src/levels/level05/intent-router.ts)**: message -> intent Choice + reasoning Score -> `IntentRoute`. Confidence `< 0.5` goes to human. Order status goes to lookup; product and return questions return `PRODUCT_CONTEXT` or `RETURNS_CONTEXT`. Complaints with score `> 1` go to human, otherwise `COMPLAINT_CONTEXT`. These are symbolic context keys, not retrieved content. Use when a deterministic lookup can replace a downstream generative response; Jev is still called to choose that route.
- **[routeModel / decideModel](../../templates/starter/src/levels/level05/model-router.ts)**: task -> fast/powerful Choice + effort Score -> `{ model, effort, rationale }`. Effort `> 1` selects high, otherwise low. There is **no low-confidence fallback**; anything other than choice `powerful` maps to fast in the pure function. Use to propose a cost/latency tier, then map aliases to approved deployments in code.
- **[routeAgent / decideAgent](../../templates/starter/src/levels/level05/agent-router.ts)**: task + repository name -> profile Choice, ambiguity Score, desktop Noul -> `{ profile, effort, needsDesktopAccess, rationale }`. Profiles are `deterministic_script`, `fast_agent`, `reasoning_agent`, `browser_agent`, `human`. Profile confidence `< 0.5` selects human; desktop Noul `> 0.5` sets the flag. Effort is the ambiguity score rounded to two decimals, not a token budget. Use to select an eligible worker, not to provision privileges.

## Try it

Save as `example.ts` in the starter root. Only Jev performs inference here.

```ts
import { routeIntent } from "./src/levels/level05/intent-router.ts";

const route = await routeIntent("Where is my order A-104? Has it shipped yet?");
switch (route.handler) {
  case "lookup": console.log({ proposedHandler: "order_lookup", reason: route.reason }); break;
  case "human": console.log({ proposedHandler: "review", reason: route.reason }); break;
  case "llm": console.log({ proposedContextKey: route.context }); break;
}
```

```bash
JEV_BACKEND=mock node example.ts
npm test
```

## Boundaries and tests

[Existing tests](../../templates/starter/tests/level05.test.ts) cover order lookup, unclear intent, easy/hard complaints, fast/powerful tasks, localized agent work, and low-confidence agent escalation.

Add boundaries at confidence `0.5`, reasoning/effort score `1`, and desktop Noul `0.5`. Test unknown routes, unavailable targets, missing context, exhausted budgets, and provider errors. The existing suite does not calibrate model quality, measure actual savings, or check desktop permissions.

## Production policy

- Resolve all returned aliases through static, reviewed maps. Do not interpolate route strings into commands, URLs, module paths, or credentials.
- Enforce user/tenant permissions at the selected handler. An order-status route does not prove ownership of the order.
- Add confidence fallback to model routing if uncertainty matters. Cost selection needs measured performance and budgets, not only labels such as fast or powerful.
- Desktop access is a request for a capability, not permission. Treat contradictory signals, such as a script profile with desktop access, as a policy case to review.
- “No LLM” comments in the intent sample mean no downstream generative call on the lookup path, not zero Jev inference.
