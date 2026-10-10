# Client operations

Use [client.ts](../templates/starter/src/core/client.ts) with its sibling core files. It uses native fetch and exposes the same `systemOne(state, questions, options)` interface for TypeSafe, OpenRouter, and the offline mock.

## One-time provider selection

The constructor resolves this order:

1. Explicit `options.provider`.
2. Offline `node:test` isolation, unless `JEV_LIVE=1` was explicitly set.
3. Nonblank `JEV_BACKEND` override.
4. Nonblank `TYPESAFE_API_KEY` selects TypeSafe.
5. Nonblank `OPENROUTER_API_KEY` selects OpenRouter.
6. Otherwise throw a missing-credentials error.

Keys are trimmed. Unknown backend names and an explicit backend without its required key fail immediately. The constructor snapshots the credential, endpoint, model, pricing, and timeout settings. Changing environment variables afterwards does not alter that instance. The key check does not make a network request or validate account credit.

**Fallback means key-based selection at startup, not retrying through another provider.** A TypeSafe 401, 402, 429, outage, timeout, or malformed response never causes an OpenRouter request. Explicit configuration overrides automatic preference intentionally.

```ts
import { JevClient } from "./src/core/client.ts";

// Load environment first. Prefer TypeSafe, otherwise OpenRouter.
const client = new JevClient();

// For a dependency-injected secret, name its provider explicitly.
function clientFromSecret(secret: string) {
  return new JevClient({ provider: "typesafe", apiKey: secret });
}

// Tests and offline development only.
const mock = new JevClient({ provider: "mock" });
```

An explicit `apiKey` requires an explicit live `provider` in constructor options. The client cannot infer which service issued an arbitrary key. Use a new instance to rotate credentials.

## Options

| Option | Meaning |
| --- | --- |
| `provider` | `typesafe`, `openrouter`, or `mock` |
| `apiKey` | Explicit credential for the named live provider |
| `baseUrl` | Full trusted endpoint URL, not an origin or untrusted user input |
| `model` | Provider-supported model ID, otherwise the provider's Jev alias |
| `timeoutMs` | Total request budget including backoff and body consumption, default 30,000 ms |
| `retryDelayMs` | Exponential backoff base, default 500 ms, plus up to 20% jitter |
| `pricing` | Optional `{ inputPerMillion, outputPerMillion }` in USD |

`systemOne` accepts a per-call `{ model, signal }`. A caller signal can shorten the deadline. Prefer one configured model per accounting scope when using custom pricing. Per-call model overrides reuse the instance's configured rates, so supply appropriate pricing or leave estimates disabled when rates differ.

## Retry behavior

| Condition | Behavior |
| --- | --- |
| HTTP 429, 502, 503, 529 | Retry on the same provider, at most three total attempts |
| Other HTTP statuses | Fail immediately, including auth, credit, and request errors |
| Invalid JSON or invalid answer contract | `ContractError`, no retry |
| Network failure | Propagate once, no automatic retry |
| Caller abort or deadline | Abort fetch/backoff, no further attempts |

Backoff doubles per retry, includes jitter, and honors valid numeric or HTTP-date `Retry-After` values **up to an 8-second delay cap**. Malformed headers do not disable backoff. The total deadline spans all attempts. If your provider mandates a longer cooldown, schedule the next job outside this bounded client rather than repeatedly invoking it early.

Only decision inference is retried. Side-effecting business actions need separate idempotency and permission checks. The client refuses redirects so credentials are not redirected to another endpoint. Only configure `baseUrl` from trusted application settings.

## Keep the full result

```ts
import { JevClient } from "./src/core/client.ts";
import { choice } from "./src/core/helpers.ts";

const client = new JevClient();
const result = await client.systemOne({ message: "I was charged twice" }, {
  department: choice("Who should handle message?", {
    billing: "Invoices, duplicate charges, refunds",
    technical: "Software failures and outages",
    other: "None of the above",
  }),
}, { signal: AbortSignal.timeout(10_000) });

const answer = result.answers.department;
if (answer.type !== "choice") throw new Error("Expected Choice");
const route = answer.confidence < 0.65 || answer.choice === "other"
  ? "human"
  : answer.choice;
const outcome = { route, result }; // Internal service result, not a public HTTP response.
```

| Field | Purpose |
| --- | --- |
| `answers` | Validated typed judgments used by application policy |
| `usage` | Provider token counts and additional usage fields |
| `model` | Actual resolved model ID returned by the provider |
| `meta` | Provider, requested/resolved model, elapsed milliseconds, attempts, cost |
| `raw.request` | Parsed snapshot of the exact serialized request |
| `raw.requestText` | Exact JSON string sent as the request body |
| `raw.response` | Original parsed provider payload, without client enrichment |
| `raw.responseText` | Exact response body text, including formatting and unknown fields |

The result's `answers` and `usage` are cloned separately from the raw response so application edits do not alter the preserved provider object. Do not mutate `raw` itself. Preserve the text fields if byte-for-byte JSON reproduction matters. Authorization headers are not included.

Mock raw bodies are synthetic. Raw retention is in memory, not persistent storage. The current client retains raw bodies for **successful, contract-valid responses**. Non-success HTTP bodies are discarded, and malformed response bodies are not attached to errors. Do not claim this starter is a complete failed-attempt audit recorder. Add a reviewed, privacy-aware error-audit path if your service requires one.

## Cost per call

`result.meta.cost` is `{ amount, source }`. Amount is USD or `null`.

| Source | Calculation |
| --- | --- |
| `reported` | Finite nonnegative `usage.cost`, including a reported zero |
| `estimated` | Input/output token counts multiplied by explicitly configured per-million rates |
| `unknown` | No valid reported cost and no configured estimate, amount is `null` |
| `mock` | Synthetic offline response, amount is zero |

Estimates use `(input_tokens × inputPerMillion + output_tokens × outputPerMillion) / 1_000_000`. There is no hardcoded current Jev price in the client. Take rates from your actual provider/model agreement and version them with deployment configuration. Never promote an estimate into a measured bill.

```ts
import { JevClient, type JevPricing } from "./src/core/client.ts";

function createPricedClient(approvedRates: JevPricing) {
  return new JevClient({ pricing: approvedRates });
}
```

The final response's usage does not necessarily include charges for earlier attempts. Track attempts separately and reconcile totals with provider billing. Do not multiply final usage by attempt count and call it measured cost.

## Aggregate without hiding uncertainty

The starter includes [UsageLedger](../templates/starter/src/usage-ledger.ts), a small process-local example:

```ts
import { JevClient } from "./src/core/client.ts";
import { routeSupport } from "./src/decisions/support-routing.ts";
import { UsageLedger } from "./src/usage-ledger.ts";

const client = new JevClient();
const ledger = new UsageLedger();
try {
  const outcome = await routeSupport(client, "The API crashes");
  ledger.record(outcome.result);
  // Send outcome.result.raw to approved restricted storage if required.
} catch (error) {
  ledger.recordFailure(); // Failure cost is unknown, not zero.
  throw error;
}
console.log(ledger.snapshot()); // Totals only, no customer payloads or keys.
```

It separates reported USD, estimated USD, unknown-cost successes, failed calls, and mock calls. It sums usage for successful live responses only. It is not durable, distributed, a provider invoice, or a hard budget enforcer. Record each result once. Avoid double-counting it in both a listener and a service wrapper.

## Observers and accounting scope

`client.on(listener)` observes request and response events and returns an unsubscribe function. `client.calls` counts validated logical calls, not successful responses or HTTP attempts. It is not a billable usage counter.

Listeners run synchronously and can throw. Keep them nonthrowing and handle asynchronous storage failures explicitly. A failing listener must not cause application code to retry an already-completed decision and count it twice. Prefer explicit service-level recording when the storage operation must be awaited.
