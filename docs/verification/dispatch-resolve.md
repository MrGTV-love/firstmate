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

The tests invoke the actual dispatch adapter's `prepare`, `apply`, and `validate` CLI paths without calling a provider.
They drive maximally positive semantic answers against incompatible positive project/kind facts, exercise predicate conjunction, disjunction and negation, preserve capability and ambiguity thresholds, and reject negative selectors, unregistered project ids, and missing predicate references.

The fixture [`dispatch-resolve-20261024.json`](../../tests/fixtures/dispatch-resolve-20261024.json) retains only rule choices and coarse reasons from the 136 logged resolves assessed on 2026-10-24.
Thirty-two records carry the old human-workflow escalation reason.
Every record's rule-choice structure is replayed using fixed semantic answers, and none can produce the deleted workflow/profile escalation.
The ledger did not retain task text, raw answers, project or kind, so this is a structural replay, not reconstruction of historical model judgments, wrong-pick rates, or a new live clear rate.
No paid replay was performed.

## Clone-bound public resolver smoke

On the same host and date, the focused public-interface command was:

```sh
FM_DISPATCH_BINDING_ONLY=1 bash tests/fm-dispatch-resolve.test.sh
```

It exited 0 with:

```console
ok - B1 removes free-text project input and rejects missing, unrelated, redirected and absent clone bindings
```

This exercises the real shell resolver, scaffold, registry binding, policy adapter, and loopback HTTP provider with synthetic text and credentials.
It rejects the removed `--project` inputs `Vernant` and ` vernant` before sending, rejects a missing first-line metadata header even when task prose contains a valid-looking record, and rejects unrelated paths, a redirected symlink, and a registered but absent clone.
It also rejects an unregistered project in positive rule selection before sending.
A generated Vernant brief then selects only a Vernant-applicable rule despite maximally positive answers for a non-Vernant rule.
The recorded clone-path header does not reach the provider.

## Public resolver regression entry point

```sh
bash bin/fm-test-run.sh tests/fm-dispatch-resolve.test.sh
```

The established suite includes the acceptance and clone-binding cases above and exercises quota ranking, uncertainty and tie handling, task-horizon feasibility, request batching, removed workflow labels, session launch restrictions, model/effort floors, approval gates, credential isolation, never-send filtering, frozen rules/index snapshots, chosen-account model checks, private result logging, and the observe-only shadow picker.
It runs the Node fallback when Bun is absent and the unchanged vendored Level 5 tests.
Its promoted-Vernant-ship case retains the original scout marker and appends the current ship specification, then verifies ship-only routing and the current specification in the provider request.
Fenced, non-authoritative ship and scout declarations exercise neighboring boundaries.
On the same host and date, `bash tests/fm-dispatch-resolve.test.sh` exited 0 and ended with `# all fm-dispatch-resolve tests passed` for this clone-binding cutover.
The optional fast-clock case reported `skip: no bash with EPOCHREALTIME is installed`; stock macOS Bash timing coverage ran.
The scaffold and bootstrap suites also exited 0 on that host.

## Verification boundary

The resolver returns the same clear/non-clear status and shell-quoted profile protocol to every supported worker adapter; this change does not alter launch or runtime-backend mechanics.
The public suite uses several candidate harness profiles, not new authenticated sessions on every runtime.
Catalog, authentication, launch authorization, and worker-side validation remain owned by their existing interfaces.
No live provider request or worker spawn is needed for the deterministic project/kind guarantee.
A live semantic replay still requires a separate spend and data-egress authorization.
