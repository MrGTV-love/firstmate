# 09. High-cardinality decisions

[Catalog and runtime setup](README.md). Demonstrations only, not calibrated production policies.

When candidates exceed one Choice, reduce the set in code, traverse a taxonomy, or score a bounded shortlist independently. The source enforces a 255-option maximum per Choice; it does not make arbitrarily large workloads cheap or safe.

## Three implementations

- **[pickWikiLink](../../templates/starter/src/levels/level09/wikiracing.ts)**: current page + target page + title/snippet links -> Choice keyed by link titles -> `{ title, confidence, probabilities }`. Use to select only a known outgoing link. Empty and oversized lists throw. Despite its opening comment, the function does **not** pre-filter more than 255 links; the caller must do that. It also does not fetch pages or implement a navigation loop.
- **[hierarchicalClassify](../../templates/starter/src/levels/level09/hierarchical-classify.ts)**: document + taxonomy + beam width (default 2) -> a Choice for each expanded parent -> ranked `{ path, confidence }[]`. Code multiplies parent scores by child probabilities and retains the best beam entries, rounding final scores to three decimals. Completed leaves carry forward and compete with newly expanded children for the next beam. Use for bounded traversal of large taxonomies; beam pruning can still discard lower-ranked paths. Returned confidence is accumulated path probability, not the model's confidence field or calibrated path accuracy.
- **[rerankShortlist](../../templates/starter/src/levels/level09/shortlist-rerank.ts)**: query + id/text candidates -> one three-level fit Score per isolated candidate -> descending `{ id, score, keep }[]`. Keep uses `score >= keepThreshold`, default `1.0`. It expects a shortlist; it does not retrieve one. Its rubric contains refund-policy-specific examples, so adapt it for other domains before evaluation.

## Try it

Save as `example.ts` in the starter root. Stable IDs connect each result back to application-owned data.

```ts
import { rerankShortlist } from "./src/levels/level09/shortlist-rerank.ts";

const candidates = [
  { id: "history", text: "Our company was founded in 2015." },
  { id: "policy", text: "Refunds are available within 30 days of purchase for unused licenses." },
];
const ids = new Set(candidates.map((c) => c.id));
if (ids.size !== candidates.length) throw new Error("Duplicate candidate IDs");
const ranked = await rerankShortlist("What is the refund policy?", candidates, 1.5);
if (!ranked.every((r) => ids.has(r.id))) throw new Error("Unknown result ID");
console.log(ranked);
```

```bash
JEV_BACKEND=mock node example.ts
npm test
```

## Boundaries and tests

[Existing tests](../../templates/starter/tests/level09.test.ts) cover a real link among 40 options, oversized link rejection, a taxonomy's expected winning branch, callback data, and reranking order. The test named “keep honors the threshold” only asserts sorting; add explicit keep-boundary assertions.

The bundled implementation preserves completed leaves in the next candidate pool while expanding their siblings, then sorts and applies the beam-width limit. The [starter regression tests](../../templates/starter/tests/starter-regressions.test.ts), included in `npm test`, verify that an early leaf and a deeper sibling leaf both survive with beam width 2. This fixes accidental leaf loss; it does not guarantee exhaustive search or preservation of every leaf after pruning.

A callback fires once per expanded parent, not once per depth. Request count depends on the beam and tree; there is no general two-request guarantee. Validate a finite positive integer beam width, acyclic tree, maximum depth, total node/request budget, unique sibling names, and at most 255 children per parent.

## Production policy

Link titles and taxonomy sibling names become object keys; duplicates silently collapse. Prefer stable unique candidate IDs with a retained mapping, and verify returned membership before acting. Reranking also needs unique IDs, bounded list size/concurrency, a finite threshold in the score range, and a deterministic tie-break policy. Its unbounded `Promise.all` fails the batch on one rejection and ignores confidence.

For graph navigation, add visited-state detection, maximum hops, timeout, allowed destinations, and a no-progress fallback. Candidate validity prevents invented options, not an incorrect or unauthorized selection. Mock ordering tests do not demonstrate retrieval quality or the accuracy claims mentioned in source comments.
