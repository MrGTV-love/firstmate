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

Commands exercised:

```sh
bash tests/fm-dispatch-resolve.test.sh
bash tests/fm-dispatch-capacity.test.sh
bash tests/fm-quota-choose.test.sh
```

All three exited 0 through the measured-command wrapper.
After the regression groups deleted by the JevClient transport rewrite were ported to the local provider harness, the resolver suite was rerun on its own on 2026-10-14 with Node `v26.4.0`, Bun `1.3.14`, and macOS `/bin/bash` 3.2, and exited 0.
The resolver suite serves typed answers through a local HTTP endpoint to the real vendored client, with synthetic task text and no paid requests.
Its output, in order:

```console
ok - pool bias is removed by normalized nonadditive evidence, with explicit ties
ok - common headroom and economic urgency are normalized before weighting
ok - quota veto preserves required reasoning class
ok - an unmeasured usable pool remains disclosed uncertainty without blocking ranking
ok - the resolver runs its adapter with node when bun is absent
ok - vendored upstream Level 5 tests pass unchanged
ok - the rule Choice decides project-scoped and Claude-only rules without local text pre-checks
ok - session launch policy filters the selected rule after judgment and names an emptied rule
ok - Level 5 tier and effort map to the approved model matrix
ok - ambiguity and unsupported handler/capability decisions escalate
ok - privacy boundaries and provider errors preserve safe fallback
ok - captain approval and declared floors veto before weighted selection
ok - fixed questions, task extraction, and protected regions retain their privacy boundary
ok - rule floor: a known shortfall falls through to default
ok - per-rule confidence floors fall to the most probable runner-up that clears its own floor
ok - proven exhaustion activates only the declared model-matrix stand-in
ok - a powerful verdict filters declared stand-ins and every stand-in takes the route effort
ok - task-horizon feasibility still vetoes the quota winner
ok - absent key is off: one stderr line, exit 0, no network call or quota read
ok - help and bare-filename startup isolate environment credentials
ok - TYPESAFE_API_KEY= in .env activates the tool; environment and config overrides work
ok - key handling: bearer header only, never argv or child environments; the request carries task, project, and criteria only
ok - never-send list withholds the request on a match or a bad list, and never prints the value
ok - opt-in marked sections protect outgoing bodies and markers never send without the exact opt-in
ok - error diagnostics omit sensitive API bodies without blocking intake
ok - stock Bash resolver separates API, quota, local and total timing at millisecond precision, with input-only Jev cost
skip: no bash with EPOCHREALTIME is installed
ok - unavailable usage is unknown and a failed quota snapshot retains API cost
ok - quota-error model evidence accepts only safe Jev version ids
ok - successful resolution model evidence accepts only safe Jev version ids
ok - rules snapshots and shell quoting preserve the profile protocol
ok - no-rule fallback, Agy, Gemini, and documented configurations resolve
ok - ambiguous: confidence below the fixed floor hands the decision back
ok - per-rule confidence floor boundaries check each runner-up on its own probability; no declared floors keeps the global floor
ok - only the brief's task sections and scout tag reach the model, with a whole-brief fallback
ok - rule floor: unavailable evidence, including the OMP pool, escalates rather than falling through
ok - declared provider and profile floor evidence are applied in code
ok - nonnumeric spendPriority evidence is never ranked
ok - partial and missing quota evidence remain eligible but unranked
ok - provider-wide and exact quota rows combine into one limiting candidate
ok - default: no rule matched resolves among the default profiles
ok - tie: equal quota evidence never breaks by array order
ok - no rankable candidate: the tool escalates instead of guessing
ok - schema 6: native Codex and Pi lanes bind to their own account rows; schema 5 is unchanged
ok - task-horizon runway, OpenRouter coverage, and minimum-version guards
ok - quota evidence comes from one quota-axi --json read, and its failure is an error outcome
ok - API, transport, and response failures are error outcomes with exit 0
ok - typed OMP dispatch preserves pooled headroom, explicit stand-ins, and uncertainty
ok - configuration errors exit 2 before any network call
ok - typed intake resolves roles before quota ranking and detects concrete duplicates
ok - typed intake checks the chosen id against the pinned worker account's catalog
ok - chosen Codex and Pi entries never use supervisor catalogs and retain authoritative export retirement checks
ok - equivalent options pool behind the pick, and each resolve appends one private result record
ok - a pooled group with more probability than the answer choice is the pick when it clears its floor and the choice does not
# all fm-dispatch-resolve tests passed
```

No Bash with `EPOCHREALTIME` was installed on that host, so the fast-path check printed its skip line instead of running.

The public-interface assertions cover one-request batching, the rule Choice deciding project-scoped and Claude-only rules with every rule offered, the session launch policy filtering the selected rule after judgment and escalating when it empties that rule, the Node fallback when Bun is absent, Haiku max and powerful-class effort floors, unrounded ambiguity boundaries, desktop thresholds, approval and quota-floor vetoes, a `fast` answer preferring quota-passing Haiku/Luna candidates (including a usable cheap pool with unmeasured limits) and ranking the whole rule when every cheap one is vetoed or has established short runway, a `powerful` verdict never taking a cheap declared stand-in, a fast verdict's stand-in taking the route effort with Haiku at max, a known rule-floor shortfall falling through to the default array, runner-up fallback below a declared `min_confidence`, and the declared model-matrix stand-in only on proven exhaustion.
When all components are known, they exercise both directions of the headroom/economic-urgency tradeoff and verify that extreme economic scalars are normalized before weighting.
The recorded `--dispatch-route` class and effort constrain stand-ins after the resolver returns: `test_spawn_route_class_constrains_stand_ins` in `tests/fm-omp-harness.test.sh` covers launch, including a manual launch without a route staying unchanged, and `test_quota_recovery_keeps_the_typed_route_class` in `tests/fm-control-relaunch.test.sh` covers recovery for a `powerful` and a `fast` route.
Privacy coverage checks outgoing requests rather than implementation source text.

The suite drives only argv, environment, stdout, stderr, and exit status.
It observes request bodies and headers captured at the local provider, call records from fake `quota-axi` and `omp`, and pass-through spies on the Bun or Node helper, `quota-axi`, `omp`, and `dirname` that record argv and whether the key reached their environment.
It proves the absent key prints one stderr line, nothing on stdout, exits 0, launches no helper, makes no request, and never reads quota, and that help and bare-filename startup scrub an environment key before their first child.
It proves a `.env` key turns the tool on, the environment wins over it, and `FM_CONFIG_OVERRIDE` selects the rules directory.
Under both Bun and Node, it proves the key arrives only as the provider's bearer header and never appears on any child argv, in any child environment, in the request body, or in output.
It proves the request names `jev-latest`, carries the project as `repository` and the task text as `task`, batches the Level 5 questions with one rule Choice offering every rule's `when` plus the fixed neutral option, and never carries `why`, `use` profiles, quota, approvals, or confidence floors.
It proves the task text is only the privacy-filtered brief's task sections read by the shared brief-heading parser, with a scout line only for a scout brief and never a ship brief's delivery mode, or the whole privacy-filtered brief when it has neither section.
Synthetic fixtures cover the [never-send contract](../configuration.md) ("Never-send list") through outgoing-request capture.
Case-insensitive, whitespace-collapsed literal matches in the task text, project name, or rule criteria withhold the request, as do an inherited list in a secondmate home, a directory, broken symlink, or inaccessible link target at the list path, markers without the exact directive, malformed markers, and invalid directives.
Each withheld request prints one `dispatch-resolve: off (...; nothing sent)` line, makes no request and no quota read, and never prints the listed value or the key.
Enabled marked regions are removed before extraction, including inside code fences and for the whole-brief fallback, and a literal outside a removed region still withholds.
It proves an HTTP error never echoes the key, response body, or request text, and leaves API time, quota time, and cost unknown with no quota read.
It checks stage accounting under `/bin/bash` with a fake whole-second `date`: API time (the client's elapsed time, at least the provider's delay), quota time, and local time are integer milliseconds that sum to the total, with input-only Jev cost.
It checks that a response missing usage is an `error` whose usage, cost, API time, and returned model stay unknown rather than zero, that a quota failure keeps the paid call's cost and returned Jev version, and that only numeric Jev version ids are reported on clear and quota-error results.
It proves resolution uses the rules snapshot Jev received even when the file is replaced mid-request, and that dynamic fields are flattened so one shell-quoted `profile:` line keeps its argument boundaries.
It proves absent, default-only, and empty-rules files return `no rules to match` without a model or quota request, a broken rules-file symlink exits 2 as unreadable, and Agy, explicit-provider Gemini, and the documented example configuration resolve.
It proves the fixed 0.6 floor is inclusive and returns `ambiguous` with candidate evidence below it.
It proves a declared `min_confidence` is checked against the rule's own probability as the pick and as a runner-up, including a runner-up exactly at its floor, and that a file without declared floors keeps the global floor on confidence unchanged.
It proves that a 0.51/0.49 split between rules, or between a rule and the neutral option, that select identical profiles, approval, floor, `select`, and fallback resolves with a `pooled:` line, while the same split between different profiles, between identical profiles with different approval or floor, or with a combined probability still below the floor stays `ambiguous`.
It proves a declared `min_confidence` is met by the pooled probability of the pick.
It proves a distinct answer choice at 0.3 against four options sharing 0.7 (0.2, 0.2, 0.15, 0.15) resolves to the pooled group, stood for by its most probable member, with the combined probability in the `pooled:` line and the log; that a pooled 0.55 against a distinct 0.45 stays `ambiguous` below the floor, as does a distinct 0.55 against a pooled 0.45; that a tie goes to the group holding the answer choice; that the floor of the member standing for the group applies; and that a choice clearing its own declared floor stays the pick over a larger pooled group.
It proves each resolve that reaches a status appends exactly one `data/dispatch-resolve.jsonl` record, one for each of `clear`, `ambiguous`, `escalate` (an approval-gated rule and an absent rules file), and `error`, in a fixed field set, and that no brief text, rule criterion, or credential is written.
It proves an unverifiable rule floor (a missing scope, a provider absent from the snapshot, or the OMP Codex pool) escalates rather than falling through to the default array.
It proves declared providers, known and unverifiable profile floors, nonnumeric `spendPriority`, partial providers, unknown exact-model rows, missing applicable rows, and limiting provider-wide bounds produce the candidate evidence and eligibility the contract states.
It proves a default choice resolves among the default profiles, equal quota evidence escalates as a genuine tie in either array order, and nothing rankable escalates.
It proves schema-6 account-row binding for Pi lanes, native Codex, and Pi native adapters (codex-home before default, independent of row order), schema-5 compatibility, and that a keyless schema-6 row is an invalid-snapshot `error`.
It proves runway is judged against the default 240-minute or a declared `task_horizon_minutes` horizon, which is never sent to the model.
An `established` projection shorter than the horizon on any applicable bound of the highest-ranked candidate escalates with no profile; it is never replaced by a lower-ranked candidate in its rule, another rule, or the default array, while a short lower-ranked candidate does not displace a feasible winner.
Through-reset, covering (including exactly at the horizon), early, absent-confidence, and unknown runway clear with any non-passing bound named in a warning, and `exhausted_now` vetoes.
It proves absent and credit-only OpenRouter rows stay eligible but unranked, an older, unparseable, or failed `quota-axi --version` read is an `error` naming the required minimum before any snapshot, and otherwise `quota-axi --json` is read exactly once and its failure is an `error`.
It proves a missing runtime, HTTP 429 (three attempts within the deadline) and 500 (not retried), a closed port, a dropped connection, a response slower than five seconds, a non-JSON body, and each invalid answer the client validates (distributions, choices, confidence, score range and legend, Noul bounds, missing answers, usage, and model) are `error` outcomes with exit 0, no profile, and no quota read.
It proves OMP routing uses the native pool report rather than quota-axi's Codex row, whole-pool exhaustion takes only the declared stand-in, and an unverifiable OMP or Codex floor or unknown pool capacity escalates without one.
It proves configuration errors, including duplicate profiles, provider-ID validation, and removed or unknown options, exit 2 before any network call.
The [fleet model-index contract](../configuration.md#fleet-model-index-configmodel-indexjson) owns the frozen rules/index and chosen-entry validation exercised here.
Roles resolve before quota ranking, a withheld indexed intake stops before any request, an index edit mid-request cannot change the resolved id, and role/literal duplicates refuse.
The chosen id is checked against the pinned worker account's catalog, and chosen Codex and Pi entries never use supervisor catalogs while export retirement checks still refuse.
The pooled-capacity suite verifies that saved resets and stale or unknown siblings are not counted as current headroom, percentages are not summed, and an incompletely measured account can remain serviceable without receiving a comparable headroom score.
The quota-helper suite continues exercising its separate eligibility and account-binding contract.

## Live twenty-brief evaluation

The original and Level 5 resolvers were exercised on the twenty most recently modified real Firstmate briefs, with identical captured quota and native OMP pool evidence and no spawns.
The final new routes were refreshed at the frozen quota observation time; production uses the current clock.
That evaluation ran a version with local Claude and project pre-checks, which have since been removed so the rule Choice decides; it has not been repeated for the current resolver.
The cohort used neither below-floor rule substitution nor the exhausted-capacity stand-in transition.
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
