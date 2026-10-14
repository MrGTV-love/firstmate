# Typed dispatch resolution verification

Audience: maintainer verification.

The [operator contract](../configuration.md#typed-dispatch-resolution-env-typesafe_api_key) owns policy, privacy, quota weights, and uncertainty paths.
The [vendor provenance](../../bin/ten-levels/SOURCE.md) owns the upstream commit and adaptations.
This record describes exercised current behavior, not calibrated task-completion accuracy.

## Runtime and upstream contract

Verified 2026-10-14 (UTC) with Node `v26.4.0`, Bun `1.3.14`, and live TypeSafe responses identifying `jev-1.13.0`.
Level 5's independent workflow, ambiguity, desktop, model-tier, and effort questions run in one vendored `JevClient.systemOne` call alongside the existing rule Choice.
The client validates the response before Firstmate applies policy.
No worker was launched during the live evaluation.

```console
$ JEV_BACKEND=mock node --test bin/ten-levels/tests/level05.test.ts
ℹ tests 6
ℹ pass 6
ℹ fail 0
```

These unchanged upstream tests exercise intent lookup and complaint paths, model tiers, localized agent work, and the upstream low-confidence agent fallback.
Mock results are contract coverage, not live model-quality evidence.

## Public resolver behavior

Commands exercised through the measured-command wrapper:

```sh
bash tests/fm-dispatch-resolve.test.sh
bash tests/fm-dispatch-capacity.test.sh
bash tests/fm-quota-choose.test.sh
```

All three exited 0.
The resolver suite serves typed answers through a local HTTP endpoint to the real vendored client, with synthetic task text and no paid requests.
Its output includes:

```console
ok - pool bias is removed by normalized nonadditive evidence, with explicit ties
ok - common headroom, economic urgency, and feasible runway are normalized before weighting
ok - quota veto preserves required reasoning class
ok - deterministic Claude policy distinguishes execution requirements from mentions
ok - project and session launch pre-checks constrain judgment deterministically
ok - Level 5 tier and effort map to the approved model matrix
ok - ambiguity and unsupported handler/capability decisions escalate
ok - privacy boundaries and provider errors preserve safe fallback
ok - captain approval and declared floors veto before weighted selection
ok - fixed questions, task extraction, and protected regions retain their privacy boundary
ok - rule-specific confidence floors preserve the selected reasoning class
ok - exhaustion cannot bypass class and quota scoring through launch stand-ins
ok - task-horizon feasibility still vetoes the quota winner
```

The public-interface assertions cover one-request batching, explicit Claude requirements and intrinsic Claude-specific investigations without inference, project-specific pruning, session refusal before inference, Haiku max and powerful-class effort floors, unrounded ambiguity boundaries, desktop thresholds, approval and quota-floor vetoes, and no weaker-default substitution after a rule-floor failure.
When all components are known, they exercise both directions of the headroom/economic-urgency tradeoff and verify that extreme economic scalars are normalized before weighting.
Privacy coverage checks outgoing requests rather than implementation source text.
The pooled-capacity suite verifies that saved resets and stale or unknown siblings are not counted as current headroom, percentages are not summed, and an incompletely measured account can remain serviceable without receiving a comparable headroom score.
The quota-helper suite continues exercising its separate eligibility and account-binding contract.

## Live twenty-brief evaluation

The original and Level 5 resolvers were exercised on the twenty most recently modified real Firstmate briefs, with identical captured quota and native OMP pool evidence and no spawns.
The final new routes were refreshed at the frozen quota observation time; production uses the current clock.
A later intrinsic-Claude pre-check correction produced identical complete requests and deterministic selections for all twenty inputs.
The cohort used neither the removed below-floor rule substitution nor the unscored exhausted-capacity stand-in transition; public failing-before/passing-after regressions cover those separate class boundaries.
The full per-brief table, exact commands, preserved old resolver, captured stdout/stderr, and supporting inputs belong in private task evidence rather than this shared record.

| Measure | Original resolver | Level 5 resolver |
| --- | --- | --- |
| Clear | 14 | 12 |
| Ambiguous | 6 | 2 |
| Escalate | 0 | 6 |
| Error | 0 | 0 |

Every emitted new profile was an approved model from its selected rule and met the configured effort floor: zero weaker-class or below-floor selections were observed.
All twelve clear new profiles selected GPT-6.1 Sol at high through OMP.
The shared measured quota component was native OMP best-account headroom 0.72 versus Claude headroom 0.67; absent pool spendPriority and completion runway were disclosed, not fabricated or scored as zero.
This cohort offered no demonstrated safe effort reduction, and downstream worker-cost savings were not measured.
The extra uncertainty paths can increase escalation; this evaluation does not establish that the new clear rate or weights are optimal.

## Verification boundary

The resolver publishes the same clear/non-clear and shell-quoted profile interface to every supported worker adapter; this change does not alter adapter launch mechanics.
The live replay exercised Claude and OMP candidate evidence, not new sessions on every worker runtime.
Candidate catalog, authentication, launch authorization, and worker-side validation remain owned by their existing interfaces and are not proved by a routing dry run.
