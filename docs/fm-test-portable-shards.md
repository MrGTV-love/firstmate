# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

Both hint tables were refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
Use the slowest successful `duration_ms` per script across their uploaded portable timing artifacts and completed `FM_TEST_END` log markers, with the two version/platform exceptions below.
All artifact records were cross-checked against the corresponding job's markers.
This covers all 24 parallel and 201 serial members; an existing live-capability skip is a portable-runner measurement, not a timing claim for the unavailable live integration.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

The earlier 2026-09-17 serial baseline covered all 176 serial scripts at refresh time, using successful per-script records in the `fm-test-timing-portable-serial-*` artifacts of the complete green [run 35279383618](https://github.com/kunchenguid/firstmate/actions/runs/35279383618) and the available completed shards of [run 35282466441](https://github.com/kunchenguid/firstmate/actions/runs/35282466441), retaining the slower successful sample where both existed.
The 2026-09-30 refresh supersedes those shared entries.

Two serial-5 jobs were cancelled at their 30-minute cap and uploaded no artifact.
Their completed log markers supplement the complete runs, but a cancelled job's wall time is only a lower bound and its unfinished or never-started scripts have no completed sample.
A failed script's duration is excluded even when its lane uploaded an artifact.
Three supplemental hints come from completed successful shards of the partial [run 37654991238](https://github.com/MrGTV-love/firstmate/actions/runs/37654991238) on 2026-10-07: `tests/fm-session-launch-policy-inherit.test.sh` measured 16144 ms on shard 4, `tests/fm-session-launch-policy-receipt.test.sh` measured 2166 ms on shard 9, and `tests/fm-session-launch-policy.test.sh` measured 229671 ms on shard 7.
All three shard summaries report `failed=0`, and each measured row reports `exit=0` and `gate_skip=false`.
The new `tests/fm-omp-wake-restore-live-e2e.test.sh` hint is its successful 51 ms record from portable serial shard 3 of [run 37663635202](https://github.com/MrGTV-love/firstmate/actions/runs/37663635202) on 2026-10-07.
That shard completed with zero failures; the live test took its opt-in capability skip, so this hint models ordinary portable CI gate evaluation, not live wake-recovery runtime.
The 2026-10-08 merge-integration refresh uses successful per-script `FM_TEST_END` markers from [run 37821346234](https://github.com/MrGTV-love/firstmate/actions/runs/37821346234). It adds the newly merged serial members that completed successfully and refreshes existing members whose successful measurements grew by more than 30 seconds; other established weights remain conservative historical maxima. Failed invocations of the capacity, watcher-ledger, teardown, and runner suites are excluded, even though their jobs completed and uploaded artifacts.
The new weights require ten serial shards to fit the unchanged 1200000 ms packing target. The runner and workflow matrix both use ten; no execution timeout was raised.
The capacity suite's 56263 ms hint is the successful Ubuntu `FM_TEST_END` baseline from upstream [run 37739997864, serial shard 9](https://github.com/kunchenguid/firstmate/actions/runs/37739997864/job/113188261544). It is not a measurement of this integration repair: the local repaired run passed the live-worker teardown but later failed the next spawn's existing backlog-read bound, so its duration is excluded.
In particular, run 36664663190's serial 5 finished in 22m15s with an assertion failure, not a timeout; treating that as a healthy whole-lane sample would hide the failure.
Collect successful per-script measurements for every member before calculating a split.

The former combined `tests/fm-supervision-host.test.sh` measured 789123 ms in run 36669175457 after the merged [host runtime fix](https://github.com/kunchenguid/firstmate/pull/6179), and subsequently grew beyond the packing target.
It is now two independently runnable serial members: `tests/fm-supervision-host.test.sh` owns report, dispatch, drain, and host-loop cases; `tests/fm-supervision-host-hook.test.sh` owns the real Claude re-arm integration, including successor delivery and takeover cases whose names do not mention Claude.
Both source `tests/fm-supervision-host-helpers.sh`, which initializes and cleans a separate fixture environment for each invocation.
Both execution lists run each case through the same existing registered-home process cleanup before starting the next; EXIT uses that cleanup too. This prevents live fake sessions and watcher cycles from earlier cases loading later ones, while preserving every within-case restart, takeover, and failure assertion.
The split host group's 413717 ms hint and host+hook group's 70651 ms hint are successful Ubuntu CI measurements from run 37821346234, replacing the historical host-only interval estimate and local Darwin hook measurement. These measure the actual independently runnable groups after per-case cleanup, not a subtraction from a combined suite.
The merged combined suite's completed 1328905 ms invocation in [run 37787876056](https://github.com/MrGTV-love/firstmate/actions/runs/37787876056/job/113347216521) exceeded the 1200000 ms packing target; the job subsequently hit its unchanged 30-minute limit. Splitting the execution lists and releasing each case's registered live fixtures addresses the indivisible work and accumulating fixture load rather than raising that limit.
The split-group CI samples supersede the earlier unhealthy local full-host attempts, whose durations remain excluded. `--check-coverage` still requires every group and packed shard estimate to fit the 1200000 ms target; passing that model does not prove healthy new-head job runtime.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
The session-start hint retains its pre-optimization maximum until CI measures the shorter fixture-only home-summary bound; do not discount a local speedup from CI packing weights.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints, with the Pi typecheck pinned to the job that installs its prerequisite.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the three-tier timeout policy in [Timeouts](#timeouts) below.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
[Verification inputs](#verification-inputs) owns the measurement provenance and exceptions.
Thirteen supplemental hints come from the complete green [run 37404365422](https://github.com/MrGTV-love/firstmate/actions/runs/37404365422), whose nine serial shard summaries all report `failed=0`: every then-unhinted serial script measured with `exit=0` and `gate_skip=false`.
Fork-main supplemental maxima are retained where they exceed the shared baseline, including the former combined host's 877426 ms in [run 37774962436](https://github.com/MrGTV-love/firstmate/actions/runs/37774962436) (historical calibration only after the split) and skill-pick's 120549 ms in [run 37778222434](https://github.com/MrGTV-love/firstmate/actions/runs/37778222434).
An unfinished or failed invocation is not a healthy duration sample.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Shard selection checks the complete assignment generator before consuming its output; a generation failure refuses the lane instead of returning a successful partial list.
Runner regressions check standalone shard unions with five, six, and twenty added scripts, and require a failed producer to refuse without publishing a partial list.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Its header and `--help` own the modeled-budget check and output fields; read the current estimates from `--check-coverage` instead of retaining copied lane sums here.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget and refusal one millisecond above it through the executable runner.
The boundary, inventory-growth, generation-failure, and duplicate-refusal fixtures share tiny serial timing inputs independent of production hint growth; the boundary case raises only its seeded script to the tested limit. The separate real-repository coverage check continues to validate the actual timing table and packing budget.
The longest script, `tests/fm-watch-triage.test.sh`, is the indivisible floor for this layout.
The estimates use per-file maxima from different runs, not measured rebalanced jobs or an end-to-end latency guarantee.
The baseline watch-triage samples range from 944375 to 1074843 ms, while each observed completed portable job adds at most 30 seconds beyond its summed scripts in these runs.
Even so, maxima from five runs do not establish a P95 or guarantee future headroom.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" -R kunchenguid/firstmate --dir "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/fm-test-timing-portable-serial-*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards); neither replaces inspection of actual CI timing artifacts.

Merge-integration fixtures preserve teardown's completion and custody prerequisites: capacity releases an unfinished worker only through retained captain-authorized discard words, and a missing-copy spend case records its merged PR before ordinary completion. Neither fixture bypasses process auditing or local-slot ownership.
Captain-hold cleanup fixtures initialize the synthetic project registry in their shared home builder, including for missing-copy scouts. Interrupted-return cases require teardown's actual worktree-return failure before checking the retained record and answer/replay behavior.
The Herdr recovery lab loads its run, backlog, and wake dependencies once in the parent shell, shared by the offline process smoke and later live cases. The smoke loads the production local-state collector and executes inventory and reaping in a subshell; it verifies owned-process removal and unrelated-process survival.
The retained open-work scan fixture observes the complete ledger's actual overdue obligation before beginning its unchanged watcher-delivery wait, matching the synchronous collector fixtures' publication-before-delivery ordering. Its shared launcher sets unrelated cadence intervals above the missing-file age sentinel, so empty fixture homes do not start real summary refreshes or checks. Collector and delivery timeout values are unchanged; collector survival, no overlapping scans, and durable wake checks remain required.
The runner and CPU-pass fixtures resolve their generated Python wrappers' shebangs through `sys.executable`, not `command -v`: a PATH entry can be a shell-based version-manager shim, which macOS cannot use to interpret another script's Python body.
Collector deadline fixtures require cancellation to prevent a third source attempt, not require exactly two attempts: the real overall deadline can expire before the fixture's second-attempt alarm. An initialized attempt log represents early expiry without inventing source activity, and the same boundary applies to origins, PR checks, PR state, and questions.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns two canonical CI partitions, each attempting full source-aware ShellCheck analysis and running workflow validation and backend-purity checks.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, changed-source selection, shared-cache invalidation, initial analysis flags, fallback reporting, and seeded finding parity.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, or paid runner provisioning is part of this layout.

The [lint script header](../bin/fm-lint.sh) owns local dependency discovery, conservative unresolved-import selection, and successful-result cache controls; these do not replace full joint source analysis.
Regression fixtures exercise cross-file missing-argument findings through direct and private source routines, deleted sources, concurrent reuse, changed binaries, and the separation between fast and full analysis.
Spawn, control, and remote secondmate relaunch obtain configuration inheritance through their shared launch-policy import rather than importing it again.
The shared Claude-launcher library uses that caller-provided configuration dependency rather than importing it a second time.
Spawn also obtains classification and PR helpers through its definition-of-done import, and timeout helpers through its backlog-transition import, instead of duplicating those source graphs with direct imports.
The policy library's lazy wake import uses the existing canonical-owner analysis boundary, while the wake owner remains in the complete lint inventory.
`tests/fm-test-run.test.sh` verifies changed status and UTC owners through the runner's authoritative consuming-family map.

A same-host Darwin cold comparison on 2026-10-04 (UTC), using ShellCheck 0.11.0 with `/usr/bin/time -l "$SHELLCHECK" --norc --external-sources -- <root>`, recorded the following direct analyzer high-water RSS in bytes, wall seconds, and starting 1-minute load.
The before source was the pre-partition implementation; the after source was the ownership-corrected working copy, not a committed-head or CI validation.
Both roots exited 0 before and after, without success-cache reuse.

| Root | Before RSS bytes | After RSS bytes | Before wall seconds | After wall seconds | Before load | After load |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `tests/fm-pending-reply.test.sh` | 1,555,906,560 | 923,418,624 | 63.47 | 127.55 | 26.43 | 57.77 |
| `bin/fm-watch.sh` | 1,342,930,944 | 1,507,655,680 | 138.85 | 215.09 | 30.96 | 47.61 |

Pending-reply's observed peak was lower, but watcher's was higher and both wall times increased under higher host load; these measurements do not establish a general cold-memory or latency improvement.
Seeded joint checks retained SC2119 across the pending import seams, watcher UTC import, and resolve caller; owner-only and hidden-source counterfactuals did not retain that call-dependent finding.
Cache reuse remains a local optimization, not a Linux CI duration, aggregate RSS, or P95 claim.
macOS cannot exercise the CI address-space limit; required-bounds coverage must still run on a host that can enforce it.

The longer-term performance objective remains a complete green run under fifteen minutes including start delay, but the current watch-triage floor alone exceeds that objective.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The layout uses fifteen long-lived Linux jobs (ten serial, two parallel, Herdr, two lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession without cancelling main pushes or changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, timing aggregate | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, portable serial shards, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.

Inside `tests/fm-remote-secondmate-lifecycle-e2e.test.sh`, the remote recovery watcher wait allows 150 seconds of polling: the watcher's 120-second relaunch bound plus startup and wake overhead.
It still requires a successful relaunch, exactly one captain-facing wake, the durable wake and relaunch records, a fresh live remote endpoint, and the preserved host route.
This fixes the former 30-second observation window, which could stop a healthy relaunch before its own deadline; it does not change production relaunch bounds or CI job timeouts.

[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly three distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
