# Jev production integration cookbook

Thirty small decision patterns, grouped by the application problem they solve. Use the linked starter code as a starting point, not as a production policy.

**All samples are demonstrations, not calibrated production policies.** Thresholds, weights, rubrics, confidence values, and mock test outcomes are not evidence of real-world accuracy or safety. Jev produces decision signals; application code validates inputs, checks permissions, and owns effects.

## Run locally

Use Node.js 24. Commands and snippet imports in these guides assume the standalone `templates/starter/` directory is the working directory, with `src/core/`, `src/levels/`, and `tests/` present. Save a guide's TypeScript snippet as `example.ts` in that working directory, then run its command. The examples print decisions or simulate state; they do not execute shell commands, send messages, or place orders.

Set `JEV_BACKEND=mock` explicitly for deterministic, offline snippets. No API key is needed in mock mode. For authorized live inference, the default selects a nonblank `TYPESAFE_API_KEY` first, then `OPENROUTER_API_KEY`; without either, construction fails rather than silently using mock. An explicit constructor `provider` overrides selection; outside test isolation, `JEV_BACKEND` also overrides key-based selection. Provider and credentials are fixed at construction, with no fallback to another provider after failure. Direct TypeSafe is not live-verified; perform an authorized smoke test before relying on that transport.

Keep credentials server-side. Load them before constructing the client or first using the shared client; the client does not load `.env` files itself. These guides require no other model, agent harness, or presentation app.

Run the full offline starter suite, not just the level tests:

```bash
npm test
```

The script explicitly selects mock and runs all bundled tests: core and level examples, HTTP-stub client tests, support-routing policy tests, and usage-ledger tests. No install, API credentials, or network access is needed. `live.test.ts` was intentionally omitted from the portable starter. Default `node:test` isolation also prevents ambient keys from selecting a live provider unless explicitly opted in. Offline tests validate contracts, wiring, and application policy, not semantic accuracy, prompt-injection resistance, or production calibration.

## The integration contract

`validated input state -> typed questions -> validated answers -> application policy -> permitted effect`

| Primitive | Use for | Answer and important boundary |
| --- | --- | --- |
| `noul(...)` | One yes/no judgment | `noul` in `[0,1]`; near `0.5` is uncertain. No separate confidence field. |
| `choice(...)` | One declared route, action, or candidate | `choice`, option `probabilities`, `confidence`; 1 to 255 options. A valid key can still be the wrong decision. |
| `score(...)` | An ordered rubric | Fractional `score` in `[0, levels - 1]`, `legend`, `probabilities`, `confidence`; 2 to 10 levels. Not an arbitrary numeric measurement. |

Use [helpers](../../templates/starter/src/core/helpers.ts), [types and validators](../../templates/starter/src/core/types.ts), and the [client](../../templates/starter/src/core/client.ts). The [mock](../../templates/starter/src/core/mock.ts) uses token overlap, not understanding. Its confidence is the largest option probability; do not use it to calibrate live confidence.

Ask independent questions about the **same state** together. Use separate, concurrency-limited requests when each item needs its own isolated state. Keep state small and explicit; question IDs identify answers for code, not the substance of the question. The starter returns a union of answer types rather than providing full per-key inference. Level wrappers cast answers; live responses are contract-checked, while mock responses bypass that check.

## Keep the complete result

`JevClient.systemOne(...)` returns answers, usage, model, provider extensions, and:

- `raw.request` and `raw.requestText`: the serialized request snapshot, without transport credentials or headers.
- `raw.response` and `raw.responseText`: the unenriched provider payload and exact response body text. Mock responses use synthetic JSON. Top-level answers and usage are separate from the raw payload.
- `meta`: provider, requested/resolved model, elapsed milliseconds, attempts, and `cost` as `{ amount, source }`. Cost is USD: valid nonnegative provider `usage.cost` is `reported`; otherwise caller-supplied `pricing` can produce `estimated`; absent trustworthy cost is `{ amount: null, source: "unknown" }`. Mock cost is `{ amount: 0, source: "mock" }`. There are no built-in price assumptions, and unknown is not zero.

The thirty level wrappers mostly return narrow domain decisions, not the complete client result. For a service boundary, follow [routeSupport](../../templates/starter/src/decisions/support-routing.ts): inject a client, validate input, pass cancellation, and return `{ decision, result, policyVersion }`. See its [policy tests](../../templates/starter/tests/support-routing.test.ts) and the [client tests](../../templates/starter/tests/client.test.ts).

[UsageLedger](../../templates/starter/src/usage-ledger.ts) separates mock calls, reported/estimated USD, unknown-cost calls, and failures; its [tests](../../templates/starter/tests/usage-ledger.test.ts) cover those categories. It is process-local observation, not a durable billing ledger or spend limit. Failed requests can have unknown charges. Raw payloads can contain sensitive application data even though transport headers are excluded; restrict retention and redact before logging or exposing them.

## All thirty examples

Exports below are exact runtime names. Each implementation link targets the bundled starter, not the original application. Each level also re-exports its helpers through `index.ts`.

| # / guide | Implementation and exports | Input | Output summary |
| --- | --- | --- | --- |
| 01A [Single decisions](01-single-decisions.md) | [injection-gate.ts](../../templates/starter/src/levels/level01/injection-gate.ts): `injectionGate` | Message | `{ injection, noul }`; injection when `noul > 0.5`. |
| 01B [Single decisions](01-single-decisions.md) | [urgency-gate.ts](../../templates/starter/src/levels/level01/urgency-gate.ts): `urgentGate` | Message, threshold default `0.7` | `{ act, noul }`; act at or above threshold. |
| 01C [Single decisions](01-single-decisions.md) | [ticket-classifier.ts](../../templates/starter/src/levels/level01/ticket-classifier.ts): `classifyTicket` | Message | `{ department, confidence }`; billing, technical, sales, other. |
| 02A [Fan-out](02-fan-out.md) | [support-triage.ts](../../templates/starter/src/levels/level02/support-triage.ts): `triageTicket` | Ticket | `{ route, priority }`; engineering/billing/product/human, high/normal. |
| 02B [Fan-out](02-fan-out.md) | [resume-screening.ts](../../templates/starter/src/levels/level02/resume-screening.ts): `screenResume` | Resume, job description | `{ proceed, signals: { distributed, senior, fitScore } }`. |
| 02C [Fan-out](02-fan-out.md) | [sponsor-qualification.ts](../../templates/starter/src/levels/level02/sponsor-qualification.ts): `qualifySponsorForm` | `{ name, description, opportunity }` | `{ autoReply, isSponsor, category, specificity }`. |
| 03A [Composite scoring](03-composite-scoring.md) | [ticket-priority.ts](../../templates/starter/src/levels/level03/ticket-priority.ts): `ticketPriority`, `combinePriority`, `PRIORITY_QUESTIONS`, `PRIORITY_WEIGHTS` | Ticket; combiner accepts three Score answers | `{ priority, parts }`; weighted normalized signals. |
| 03B [Composite scoring](03-composite-scoring.md) | [code-review-risk.ts](../../templates/starter/src/levels/level03/code-review-risk.ts): `codeReviewRisk`, `CODE_REVIEW_QUESTIONS` | Diff, commit message | `{ risk, needsHumanReview }`. |
| 03C [Composite scoring](03-composite-scoring.md) | [idea-verdict.ts](../../templates/starter/src/levels/level03/idea-verdict.ts): `ideaVerdict`, `IDEA_QUESTIONS` | Pitch | `{ verdict, score }`; kill/fix/ship. |
| 04A [Confidence gating](04-confidence-gating.md) | [account-actions.ts](../../templates/starter/src/levels/level04/account-actions.ts): `routeAccountAction`, `decideAccountAction` | Message; policy accepts Choice answer | `AccountAction`: auto/confirm with action, or human with reason. |
| 04B [Confidence gating](04-confidence-gating.md) | [shell-command-gate.ts](../../templates/starter/src/levels/level04/shell-command-gate.ts): `gateShellCommand`, `decideCommandSafety` | Command, cwd; policy accepts Choice + two Nouls | `{ classification, run, requiresHuman, confidence }`. |
| 04C [Confidence gating](04-confidence-gating.md) | [citation-check.ts](../../templates/starter/src/levels/level04/citation-check.ts): `checkCitation`, `decideCitation` | Claim, quote, source context; policy accepts Choice + Score | `{ supported, flagForReview, confidence }`. |
| 05A [Routing](05-routing.md) | [intent-router.ts](../../templates/starter/src/levels/level05/intent-router.ts): `routeIntent`, `decideIntent` | Message; policy accepts Choice + Score | `IntentRoute`: lookup/human with reason, or llm with context key. |
| 05B [Routing](05-routing.md) | [model-router.ts](../../templates/starter/src/levels/level05/model-router.ts): `routeModel`, `decideModel` | Task; policy accepts Choice + Score | `{ model: fast/powerful, effort: low/high, rationale }`. |
| 05C [Routing](05-routing.md) | [agent-router.ts](../../templates/starter/src/levels/level05/agent-router.ts): `routeAgent`, `decideAgent` | Task, repository name; policy accepts Choice + Score + Noul | `{ profile, effort, needsDesktopAccess, rationale }`; five profiles. |
| 06A [Interactive decisions](06-interactive-decisions.md) | [editor-tone-watch.ts](../../templates/starter/src/levels/level06/editor-tone-watch.ts): `watchEditorTone` | Draft | `{ tone, urgency, readsAsAI, suggest }`; three scores plus suggestion. |
| 06B [Interactive decisions](06-interactive-decisions.md) | [feed-filter.ts](../../templates/starter/src/levels/level06/feed-filter.ts): `filterFeed` | `{ id, author, text }[]` | `{ id, hide, reason }[]`, in input order. |
| 06C [Interactive decisions](06-interactive-decisions.md) | [adaptive-form.ts](../../templates/starter/src/levels/level06/adaptive-form.ts): `adaptiveForm`, `decideForm` | Answer text; policy accepts Choice + Score | `{ controls, rationale }`; allowlisted form-control names. |
| 07A [Guardrails](07-guardrails.md) | [claim-verification.ts](../../templates/starter/src/levels/level07/claim-verification.ts): `verifyClaims` | Claims, transcript | `{ claim, supported, needsReview }[]`. |
| 07B [Guardrails](07-guardrails.md) | [rag-passage-gate.ts](../../templates/starter/src/levels/level07/rag-passage-gate.ts): `classifyPassages` | Question, passage strings | `{ index, keep, reason }[]`, in input order. |
| 07C [Guardrails](07-guardrails.md) | [tool-risk-middleware.ts](../../templates/starter/src/levels/level07/tool-risk-middleware.ts): `toolRiskMiddleware`, `decideToolCall`, `TOOL_RISK_FLOOR`, `TOOL_RISK_BAR` | Tool name/args, available tool names; policy accepts Choice + Score | `ToolDecision`: execute, confirm, or block. |
| 08A [Decision loops](08-decision-loops.md) | [pacman-loop.ts](../../templates/starter/src/levels/level08/pacman-loop.ts): `pacmanStep`, `pacmanLoop`, `PAC_GRID`, `PAC_WALLS`, `PAC_POWER`, `PAC_PELLETS` | Game state; loop accepts ticks, callback, initial positions | Direction/strategy/danger/trapped; loop returns `PacTick[]`. |
| 08B [Decision loops](08-decision-loops.md) | [element-picker.ts](../../templates/starter/src/levels/level08/element-picker.ts): `pickElement` | Goal, `{ selector, role, text }[]` | `{ selector, confidence }` from supplied elements. |
| 08C [Decision loops](08-decision-loops.md) | [trading-loop.ts](../../templates/starter/src/levels/level08/trading-loop.ts): `tradingStep`, `tradingLoop` | Market state; loop accepts prices, callback, symbol | `TradeAction`: buy with size, sell, hold, exit with reason; loop returns `TradeTick[]`. |
| 09A [High cardinality](09-high-cardinality.md) | [wikiracing.ts](../../templates/starter/src/levels/level09/wikiracing.ts): `pickWikiLink` | Current page, target, title/snippet links | `{ title, confidence, probabilities }`. |
| 09B [High cardinality](09-high-cardinality.md) | [hierarchical-classify.ts](../../templates/starter/src/levels/level09/hierarchical-classify.ts): `hierarchicalClassify` | Document, taxonomy, beam width, callback | Ranked `{ path, confidence }[]`; callback receives `BeamStep`. |
| 09C [High cardinality](09-high-cardinality.md) | [shortlist-rerank.ts](../../templates/starter/src/levels/level09/shortlist-rerank.ts): `rerankShortlist` | Query, `{ id, text }[]`, keep threshold | Descending `{ id, score, keep }[]`. |
| 10A [Dynamic questions](10-dynamic-questions.md) | [command-gate.ts](../../templates/starter/src/levels/level10/command-gate.ts): `buildCommandChoiceBlock`, `gateAgentCommand` | Command, cwd | Builder: `{ question, detected }`; gate: `{ run, requiresConfirmation, classification, detected, confidence, gate }`. |
| 10B [Dynamic questions](10-dynamic-questions.md) | [authored-router.ts](../../templates/starter/src/levels/level10/authored-router.ts): `authorRouterBlock`, `routeTaskWithAuthoredBlock` | Target keys/descriptions; task for routing | Builder: Choice block; router: `{ target, confidence, gate }`. |
| 10C [Dynamic questions](10-dynamic-questions.md) | [review-rubric.ts](../../templates/starter/src/levels/level10/review-rubric.ts): `buildReviewRubric`, `judgePullRequest` | Diff counts, touched paths, commit message | Builder: `{ block, effort, derivedRisks }`; judge: `{ reviewClass, effort, gate, derivedRisks }`. |

Shared level exports: [normalized](../../templates/starter/src/levels/level03/normalize.ts), [CONFIDENCE](../../templates/starter/src/levels/level04/confidence.ts), and [JevToolkit](../../templates/starter/src/levels/level10/toolkit.ts) with `ask`, `buildChoiceBlock`, and `gate`. Interfaces and unions are exported beside each implementation.

## Before production

1. **Validate numbers in code.** Check finite values, ranges, units, positive denominators, integer loop limits, and ordered thresholds. Jev is not a calculator or a numeric input validator. Validate runtime payloads even when TypeScript types compile.
2. **Separate prediction from permission.** Confidence is not authorization. Security classifiers must not be the sole safeguards. Enforce authentication, tenant scope, tool/argument allowlists, filesystem/network restrictions, approvals, and idempotency outside Jev. Review, denial, and errors take precedence over positive flags.
3. **Handle uncertainty and failure.** Add a safe fallback or review path for ambiguous decisions, invalid responses, timeouts, and provider failures. The client defaults to a configurable 30-second total live deadline, including retries and response bodies, and at most three attempts for selected HTTP statuses on the same provider; level functions generally propagate errors. Do not turn an exception into permission to act.
4. **Control work.** Bound item counts, concurrency, tokens, latency, loop iterations, and spending. The declared token-budget constant is not enforced. Array examples use unbounded `Promise.all`; interactive samples do not implement debounce, abort, or latest-state checks.
5. **Check response-derived math.** The live validator checks answer types, options, distributions, score ranges, confidence, token counts, and exact Score legend keys/descriptions. Pure helpers such as `normalized()` still trust their arguments: validate hand-built or independently loaded answers, or normalize against the known rubric. Application units, weights, and business limits remain code responsibilities.
6. **Evaluate with real labels.** Keep pure policy boundary tests separate from mock wiring tests and a labeled live evaluation set. Test paraphrases, negations, adversarial input, distribution shifts, and domain-specific false-positive/false-negative costs. A valid answer shape is not a correct answer.
7. **Version and observe.** Pin a model via `JevClient` options or the per-call model option in an adapted integration. Retain the complete result internally and record question/policy versions, requested/resolved model, decision, latency, attempts, `meta.cost`, and reviewed outcomes. Level wrappers use a shared client resolved on first use and discard most metadata. Its request events contain raw state, so redact sensitive data before logging and detach listeners when done.

The focused guides describe existing behavior and missing boundaries separately. Fix the documented source quirks before relying on the affected policies.
