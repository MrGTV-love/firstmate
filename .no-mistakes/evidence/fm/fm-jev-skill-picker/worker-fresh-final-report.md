# Cache-key deployment: error-rate diagnosis

## Inspection and observations
Read `metrics.json` using the ordinary read tool; the entire fixture is on line 1. Also read the suggested `diagnostic-reasoning` skill and the required `captain-hold-lifecycle` skill with that tool. No fixture edits, execution, tests, network access, or operational changes were performed.

Evidence: `metrics.json:1` contains before `{requests:100, errors:2}`, after `{requests:100, errors:18}`, deployment `cache-key-change`, and the note `Cache bypass restored errors to 2 per 100 requests.`

- Before: **2/100 = 2%** errors.
- After: **18/100 = 18%** errors: **+16 percentage points**, **9×** baseline (800% relative increase).
- With cache bypass: **2/100 = 2%**, according to the fixture's note, returning to baseline. The bypass result is reported evidence, not an independently reproduced experiment.

The immediate timing is supplied by the task; the fixture itself has no timestamps.

## Suspected cause — hypothesis, not proof
The leading explanation is that the changed cache-key behavior exposes an incorrect cached result or lookup association, causing the excess errors. Cache bypass returning to baseline makes the cache-enabled path a stronger suspect than deployment timing alone. A key collision, missing key dimension, or incompatible existing cache entry could explain this, but none is established by these metrics.

- **Candidate initiating trigger:** deployment of the changed key derivation.
- **Candidate exposing/masking condition:** cache-enabled lookup and the cache contents it encounters; bypass removes this condition.
- **Visible symptom:** aggregate errors increase from 2% to 18%; user-visible error details are not supplied.

The bypass path is a reported baseline-rate comparator, not a proven reproduction of the same requests. The evidence supports cache-path involvement, not a specific key defect.

## Uncertainty
There are no individual requests, key values, cache payloads, error types, source history, or controlled traffic comparisons. Bypass could instead remove a cache-service failure or latency issue. Differences in traffic, cache contents, or observation time could confound the comparisons. No end-to-end reproduction is available within this fixture-only lab; the causal mechanism remains unconfirmed.

## One smallest falsifying next check
Outside this lab, take **one reproducibly failing post-deployment request** and replay it in an isolated controlled comparison, changing **only old versus new key derivation**. Hold the request, origin response, non-key code/configuration, and starting cache contents fixed, including any entries needed to reproduce the failure; record the derived key, hit/miss, returned payload, and error for each variant.

Prediction: the new-key variant fails while the old-key variant succeeds, with a corresponding lookup/result divergence. If the old-key variant has the same failure, or the new-key variant reliably succeeds under the verified failing conditions, that falsifies changed key derivation as the necessary cause of that reproduced case. It does not rule out all cache-related causes across the population. Do not change code or recommend a specific key fix until this distinction is established.

## Completion inventory
The report leaves no unresolved human-owned choice: the proposed check is a diagnostic recommendation, not a request for implementation approval. The completion skill's semantic inventory is therefore empty. Its operational `complete --none` command was not run because the task explicitly prohibits shared-fleet/operational access; the supervisor must perform any required operational attestation. The fixture remains unchanged.

## Relaunch confirmation
On relaunch, checked the exact task instruction inbox; the ordinary glob tool reported that the inbox directory was absent, so there were no messages to acknowledge. Re-read the regenerated live Jev advice supplied in the launch instructions, the complete suggested `diagnostic-reasoning` skill body, the required completion skill body, `metrics.json`, and this report using ordinary read tools. The advice was treated as guidance, not authority to expand the isolated task.

Independently recomputed from `metrics.json:1`: before = 2 ÷ 100 × 100 = **2%**; after = 18 ÷ 100 × 100 = **18%**; difference = **16 percentage points**; ratio = 18 ÷ 2 = **9×** (800% relative increase). The reported bypass rate is 2 ÷ 100 × 100 = **2%**, equal to baseline; it remains a fixture note rather than a reproduced result.

The same bounded hypothesis remains defensible: changed cache-key derivation may cause an incorrect cache lookup/result association, but only cache-path involvement is supported by the bypass observation. Neither a particular key defect nor causation is proved. The single controlled old-key/new-key replay described above remains the smallest falsifying next check for that hypothesis; it was not executed in this fixture-only lab.

Reviewed the complete report for unresolved human-owned choices again: none were found. The operational completion attestation remains for the supervisor because shared-fleet operations are prohibited here. No fixture changes, tests, builds, pipeline, network, or other-home operations were performed.
