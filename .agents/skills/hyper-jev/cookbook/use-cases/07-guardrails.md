# 07. Guardrails around content and tools

[Catalog and runtime setup](README.md). Demonstrations only, not calibrated production policies.

Use a second decision step to review candidate content or a proposed effect before your application accepts it. These functions return decisions, not enforcement. Security classifiers must not be the sole safeguards, and confidence is not authorization.

## Three implementations

- **[verifyClaims](../../templates/starter/src/levels/level07/claim-verification.ts)**: transcript state + one generated Noul question per claim -> `{ claim, supported, needsReview }[]` in one request. A probability `> 0.7` is supported; `[0.4, 0.7]` needs review; below `0.4` is unsupported without a review flag. Use to screen claims against a supplied source. Publish only according to a separate acceptance policy, never merely because `needsReview` is false.
- **[classifyPassages](../../templates/starter/src/levels/level07/rag-passage-gate.ts)**: question + one passage per request -> Choice among `relevant_clean`, `contradicts`, `injection`, `irrelevant` -> `{ index, keep, reason }[]`. Keep only relevant-clean at confidence `>= 0.5`. Use to propose a context subset; application code retains provenance and constructs the final context.
- **[toolRiskMiddleware / decideToolCall](../../templates/starter/src/levels/level07/tool-risk-middleware.ts)**: proposed tool/args + available tool names -> risk Choice + blast-radius Score -> execute/confirm/block. First, confidence `< 0.5` returns confirm. Otherwise destructive returns block; external effects below confidence `0.9` confirm; blast score `> 1.5` confirms non-read-only calls; remaining cases execute. The sample does not actually wrap or invoke a tool.

## Try it

Save as `example.ts` in the starter root. The proposed command is classified but never executed.

```ts
import { toolRiskMiddleware } from "./src/levels/level07/tool-risk-middleware.ts";

const availableTools = ["read_file", "bash"];
const proposed = { tool: "bash", args: { command: "git push --force origin main" } };
if (!availableTools.includes(proposed.tool)) throw new Error("Unknown tool");
const decision = await toolRiskMiddleware(proposed, availableTools);
console.log({ decision });
```

```bash
JEV_BACKEND=mock node example.ts
npm test
```

## Boundaries and tests

[Existing tests](../../templates/starter/tests/level07.test.ts) distinguish supplied claims, reject an obvious injected passage, and exercise several pure tool-policy branches.

Add exact claim boundaries `0.4` and `0.7`; empty claims; malicious claim text; passage confidence `0.5`; and tool confidence/blast boundaries `0.5`, `0.9`, and `1.5`. Empty claims currently create an invalid empty question map, so handle them before calling. Add unknown tools, malformed args, timeouts, and batch failures.

Two comments can overstate enforcement: low-confidence destructive classification returns **confirm**, not block, because the confidence branch runs first. High-confidence external effects can return **execute**. Test both deliberately. The policy also ignores blast-score confidence, and read-only bypasses the high-blast rule.

## Production policy

- `availableTools` is only model state, not an enforced allowlist. Validate tools, argument schemas, paths, destinations, actor permissions, and approvals in code. Keep execution and idempotency outside classification; do not allow approval text to substitute for a recorded approval.
- Claims are interpolated into question instructions while only the transcript is state. This reduces self-echo in the demo, not prompt-injection risk in general. Treat both as untrusted, bound their lengths/counts, and preserve source spans for review.
- Contradicting evidence can be exactly what a factual answer needs. The passage sample drops it; revise that policy if it would suppress corrections or conflicting sources. A clean label is not proof of safety or truth.
- Passage requests use unbounded `Promise.all`. Add concurrency limits and explicit failure handling. One transcript with many claims still has a shared request budget; split bounded batches when needed.
