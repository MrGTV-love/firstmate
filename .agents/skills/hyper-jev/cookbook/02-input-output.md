# Input and output

## The HTTP contract

Both providers receive JSON decision requests, not chat messages:

| Provider | POST endpoint | Default model | Key |
| --- | --- | --- | --- |
| TypeSafe | `https://api.typesafe.ai/v1/systemone` | `jev-latest` | `TYPESAFE_API_KEY` |
| OpenRouter | `https://openrouter.ai/api/alpha/decisions` | `~typesafe/jev-latest` | `OPENROUTER_API_KEY` |

Send `Authorization: Bearer <key>` and `Content-Type: application/json`. These are the endpoint/model identifiers used by this repository. Verify live availability before rollout. Do not substitute `/chat/completions`.

### Request: three independent questions in one call

```json
{
  "model": "jev-latest",
  "state": { "ticket": "Payment failed twice. Customers cannot complete checkout." },
  "questions": {
    "blocked": {
      "type": "noul",
      "instructions": "Is the author of ticket unable to proceed?",
      "criteria": { "true": "Work cannot continue and no workaround exists", "false": "Work can continue" }
    },
    "department": {
      "type": "choice",
      "instructions": "Which team should handle ticket?",
      "criteria": { "technical": "Broken software or checkout", "billing": "Invoices and refunds", "other": "None of these" }
    },
    "severity": {
      "type": "score",
      "instructions": "How much does the issue in ticket prevent work?",
      "criteria": ["Cosmetic only", "Workaround exists", "Work blocked with no workaround"]
    }
  }
}
```

For OpenRouter the required body change is its model ID. The client handles the endpoint and key.

### Illustrative response, not a live measurement

```json
{
  "model": "example-versioned-model",
  "answers": {
    "blocked": { "type": "noul", "noul": 0.96 },
    "department": {
      "type": "choice",
      "choice": "technical",
      "probabilities": { "technical": 0.9, "billing": 0.08, "other": 0.02 },
      "confidence": 0.86
    },
    "severity": {
      "type": "score",
      "score": 1.75,
      "legend": { "0": "Cosmetic only", "1": "Workaround exists", "2": "Work blocked with no workaround" },
      "probabilities": { "0": 0.05, "1": 0.15, "2": 0.8 },
      "confidence": 0.78
    }
  },
  "usage": { "input_tokens": 210, "output_tokens": 48 }
}
```

The client adds metadata and raw-body retention without rewriting the wire response. Provider-specific fields such as optional `usage.cost` must survive.

## What the types mean

| Type | Question input | Answer | Application use |
| --- | --- | --- | --- |
| Noul | Instructions, optional true/false descriptions | `noul` in [0,1] | Probability of yes, threshold in code |
| Choice | Allowed IDs mapped to descriptions or null | Selected ID, all probabilities, confidence | Route to finite handlers |
| Score | Ordered descriptions from low to high | Weighted position, legend, all probabilities, confidence | Combine dimensions or prioritize |

A Noul near zero is a strong **no**, not low confidence. Near 0.5 it is ambiguous. Noul has no separate `confidence` field. Define both yes and no boundaries when abstention matters.

Choice confidence is a second axis. A highly confident `destructive` classification means the risky class is strongly supported, not that it is safe to execute. Use returned confidence rather than recomputing it as the winning probability.

For a Score with N levels, the result ranges from 0 to N−1 and can be fractional. A three-level `score: 1.75` is not 1.75 out of 10. Normalize with `score / (N - 1)` when combining scales. Keep arithmetic and weights in code.

## State, instructions, and IDs

- `state` is a string, JSON object, or JSON array. Supply the smallest relevant evidence, not an entire conversation by default.
- `instructions` is a string or structured object. Explain the judgment here, not only in the question ID.
- Question IDs correlate requests with answers. The provider contract treats them as code-facing identifiers, not model instructions.
- Choice IDs are the values code dispatches on. Use descriptions to explain them. Check runtime IDs against the allowed set before side effects.
- Keep questions and untrusted state separate. Separation aids auditing but is not itself a security boundary.

## Limits and validation

[types.ts](../templates/starter/src/core/types.ts) defines 1–255 Choice options and 2–10 Score levels. The source documents an approximate 64,000-token budget across state and questions. That constant is not a tokenizer or an enforced size limit. Add service-level byte/token limits and verify current provider limits before deployment.

The client checks question shapes before HTTP and live answer types/distributions before returning. Distributions must cover the declared options and sum approximately to 1. Contract validation protects shape, not truth.

TypeScript types disappear at runtime. Validate external JSON, input size, candidate IDs, and permissions before calling the client. Reject empty options, unknown types, and invalid rubrics rather than coercing them into plausible-looking requests.
