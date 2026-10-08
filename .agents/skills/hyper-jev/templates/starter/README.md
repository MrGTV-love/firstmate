# Hyper Jev starter

A backend-only Jev integration with the original core, thirty examples, and offline tests. Node 24, TypeScript, zero runtime packages. Use cases are teaching examples, not pre-calibrated production policies.

## Run offline

```sh
npm test
npm run demo
```

Both commands explicitly select the deterministic mock. No credentials, install, or network are needed. The mock tests contract shape and wiring, not semantic accuracy.

## Run live when authorized

Inject `TYPESAFE_API_KEY` or `OPENROUTER_API_KEY` into the process environment, then run `npm start`. If using a private local `.env`, run `node --env-file=.env src/example.ts`. The client does not load files itself.

TypeSafe wins when both keys exist. OpenRouter is used only when the TypeSafe key is absent. Selection and credentials are fixed at client construction. Missing keys cause an error. `JEV_BACKEND` or constructor options can override selection explicitly. A failed request never switches providers.

## Files to adapt

| Path | Responsibility |
| --- | --- |
| `src/core/` | Transport, typed contract, builders, offline mock |
| `src/decisions/support-routing.ts` | Validated input, reviewable policy, complete result retention |
| `src/example.ts` | Initialize once, run one request, print metadata without raw customer data |
| `src/usage-ledger.ts` | Process-local reported/estimated costs, unknowns, failures, and mock counts |
| `src/levels/level01/` through `level10/` | Thirty examples, three per pattern |
| `tests/` | HTTP-stub tests, policy boundaries, deterministic example tests |

For an existing backend, copy the core and only the needed decision module. Inject one shared client after loading secrets. Preserve the result's raw payloads in restricted storage when required. Do not expose those payloads on a public API just because the service returns them internally.

## Static checks

Runtime tests need no packages. For TypeScript checking:

```sh
npm install
npm run typecheck
```

Commit the generated lockfile in your destination application. This template intentionally has no installed dependencies or lockfile tied to the source repository.

## Before production

Calibrate thresholds on labeled data. Add your authentication, request-size/concurrency limits, durable telemetry, spend limits, and audit retention policy. Guard side effects with deterministic permissions and confirmations independent of model confidence.

The core is identical to the project client. The bundled examples include focused adaptations: a typed state snapshot in feed filtering, mixed-depth taxonomy leaf retention, ambiguity as an execution veto, and review questions aligned with their state fields. Regression tests cover the behavior fixes.

The examples can return narrower domain objects for teaching clarity. Use the `{ decision, result, policyVersion }` service shape when production auditability matters. Direct TypeSafe requires an authorized live smoke test in your environment. Offline tests are not live validation.
