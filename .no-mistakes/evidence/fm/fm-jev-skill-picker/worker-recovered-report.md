# Cache-key deployment error-rate diagnosis

## Evidence and observations

Inspected `metrics.json:1` using the ordinary read tool; the fixture was not changed.

- Before deployment: 2 errors / 100 requests = **2%**.
- After `cache-key-change`: 18 errors / 100 requests = **18%**.
- Increase: **16 percentage points**, or **9×** the previous error rate (800% relative increase).
- The fixture's note reports that bypassing the cache restored errors to 2 / 100 requests = **2%**. This is a reported intervention result, not an independently reproduced experiment.

The candidate initiating trigger is the cache-key deployment. The visible symptom is the higher request error rate. Cache usage is the candidate exposing condition; bypass reportedly masks or removes the excess errors. Timing alone does not establish causation.

## Hypothesis and uncertainty

The leading hypothesis is a **cache-path regression associated with the new key behavior**: using the deployed cache path introduces errors that bypass avoids. The bypass result supports this more strongly than deployment timing alone and makes an unconditional origin-wide failure less consistent with the observations.

The evidence does not establish a particular key defect. Collisions, incompatible entries, changed miss behavior, or a downstream load effect remain possibilities, not findings. The fixture provides no key values, error types, timestamps, workload matching, cache state, or repeat measurements. Bypass may have coincided with another change or a transient recovery. Neither cache dependence nor the deployment's causal role is proven.

## Smallest falsifying next check

Replay the same representative requests in an isolated controlled comparison with **cache enabled in both arms**, changing only the old versus deployed key logic. Give both arms equivalent initial cache contents, the same origin behavior, and matched load; record request error rates.

If the old-key arm reproduces the same elevated error rate as the new-key arm, that falsifies the narrow explanation that the new key logic is necessary for the regression under those conditions and redirects investigation toward shared cache/origin behavior. If only the new-key arm shows excess errors, the deployment-specific explanation gains support, but the precise defect still requires inspection. A sample that reproduces neither arm's failure is inconclusive, not a falsification.

This check is recommended, **not executed**: the task permits fixture inspection only. No tests, builds, network calls, source changes, or fleet operations were performed. A code fix is not yet justified by the available evidence.

## Relaunch confirmation

Re-read the regenerated live skill-selection advice and the entire suggested `diagnostic-reasoning` skill with the ordinary read tool before analysis. Independently recomputed the fixture rates: **2/100 = 2% before, 18/100 = 18% after, and reported bypass 2/100 = 2%**, an increase of **16 percentage points / 9×**. The independently restated hypothesis remains a cache-path regression associated with the new keys, not a proven collision or other specific implementation defect. The instruction inbox was absent; there were no messages to acknowledge.

## Completion inventory

Read the complete `captain-hold-lifecycle` skill and inventoried this report: **no unresolved human-owned choice**; the next check is an investigative recommendation, not an approval request. The completion command was not executed because the task expressly forbids shared-fleet operations and permits only the named skill reads and report/status writes outside the fixture. This report records the semantic completion inventory, not a claim that the command passed.
