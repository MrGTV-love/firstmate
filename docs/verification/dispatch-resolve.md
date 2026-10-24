# Typed dispatch resolution verification

Audience: maintainer verification.

The [operator contract](../configuration.md#typed-dispatch-resolution-env-typesafe_api_key) owns policy, structured rule predicates, privacy, quota weights, and uncertainty paths.
The [vendor provenance](../../bin/ten-levels/SOURCE.md) owns the upstream commit and adaptations.
This record describes offline contract behavior, not calibrated model accuracy or task-completion forecasts.

## Deterministic routing and historical structure

Verified 2026-10-24 on macOS arm64 with Node `v26.4.0`, Bun `1.3.14`, and TypeScript `7.0.2`.
The executable acceptance command was:

```sh
node --experimental-strip-types --no-warnings --test tests/fm-dispatch-level5.test.ts
```

It exited 0 with:

```console
✔ T6(a): repository and kind facts make non-Vernant rules unreachable for Vernant ships
✔ T6 predicates combine in code, preserve complements, and never pool independent support
✔ T6(b): replay all 136 logged rule structures offline without Q7 escalation
✔ Q9 desktop capability keeps its boundary; obsolete workflow answers remain inert
✔ malformed fact selectors and missing semantic references fail before provider access
ℹ tests 5
ℹ pass 5
ℹ fail 0
```

The tests invoke the actual dispatch adapter's `prepare` and `apply` CLI paths without calling a provider.
They drive maximally positive semantic answers against incompatible repository/kind facts, exercise predicate conjunction, disjunction and negation, preserve capability and ambiguity thresholds, and reject invalid fact selectors and missing predicate references.
The baseline adapter fails the fact-scoped selection and removed-workflow escalation cases.
The same command was re-run on the same host on the review-fix working tree based on commit `9c97cdd7c`, after malformed schemas received their own validator exit status, and again passed 5 of 5.

The fixture [`dispatch-resolve-20261024.json`](../../tests/fixtures/dispatch-resolve-20261024.json) retains only rule choices and coarse reasons from the 136 logged resolves assessed on 2026-10-24.
Thirty-two records carry the old human-workflow escalation reason.
Every record's rule-choice structure is replayed using fixed semantic answers, and none can produce the deleted workflow/profile escalation.
The ledger did not retain task text, raw answers, project or kind, so this is a structural replay, not reconstruction of historical model judgments, wrong-pick rates, or a new live clear rate.
No paid replay was performed.

## Public resolver regression entry point

```sh
bash bin/fm-test-run.sh tests/fm-dispatch-resolve.test.sh
```

On the same host on 2026-10-24, at commit `f10c20f1b` (before the review fixes), this command exited 0 with:

```console
# all fm-dispatch-resolve tests passed
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=562499
```

The optional `EPOCHREALTIME` fast-path case printed `skip: no bash with EPOCHREALTIME is installed`; stock macOS Bash timing coverage ran.
The established suite invokes the acceptance cases above and exercises the public shell resolver through a loopback HTTP provider using synthetic text and credentials.
It covers request batching, deterministic fact exclusion through the complete resolver, removed workflow labels, session launch restrictions, model/effort floors, approval and quota gates, credential isolation, never-send filtering, frozen rules/index snapshots, chosen-account model checks, private result logging, and the observe-only shadow picker.
The same script exercises the Node fallback when Bun is absent and leaves the unchanged vendored Level 5 tests in place.
Its promoted-Vernant-ship case retains the original scout marker and appends the current ship specification, then verifies ship-only routing and the current specification in the actual provider request.
A fenced, non-authoritative ship heading exercises the neighboring boundary.
These are offline policy and transport checks, not evidence of semantic accuracy from the provider model.

That pass predates the review fixes and does not validate them.
The suite now also covers a fenced scout declaration inside an ordinary ship brief, scout detection from the unfenced `# Setup` section, escalation of project-scoped rules without `--project`, an old-format rules file failing closed with exit 2, an override directory's own judgment reaching the request, an adapter runtime failure reported as `status: error` rather than a malformed rules file, a conflicting highest-support tie that stays `ambiguous` in either rule order despite a declared floor, and malformed-schema diagnostics that name the failing check.
No complete run of this entry point on the current code is recorded here; the pipeline's test step owns that evidence.

## Verification boundary

The resolver returns the same clear/non-clear status and shell-quoted profile protocol to every supported worker adapter; this change does not alter launch or runtime-backend mechanics.
The public suite uses several candidate harness profiles, not new authenticated sessions on every runtime.
Catalog, authentication, launch authorization, and worker-side validation remain owned by their existing interfaces.
No live provider request or worker spawn is needed for the deterministic project/kind guarantee.
A live semantic replay still requires a separate spend and data-egress authorization.
