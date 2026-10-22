# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The serial hints were refreshed on 2026-10-13 from the successful per-suite records in the behavior timing aggregates of three main runs: [38309507694](https://github.com/MrGTV-love/firstmate/actions/runs/38309507694), [38310126183](https://github.com/MrGTV-love/firstmate/actions/runs/38310126183), and [38312847224](https://github.com/MrGTV-love/firstmate/actions/runs/38312847224).
Retain the slowest successful sample per current serial member, including larger earlier measurements below; exclude failed or unfinished scripts.
The split supervision-host member uses its independently measured 413717 ms baseline rather than the obsolete combined suite's 877426 ms sample.
The triage split's initial calibration is described in [Portable serial CI shards](#portable-serial-ci-shards).

The 2026-10-21 refresh reweights the serial hints from the slowest successful `duration_ms` per script in the `fm-test-timing-portable-serial-*` artifacts of three pull-request runs on the 26.04 image: [39639146109](https://github.com/MrGTV-love/firstmate/actions/runs/39639146109), [39645969594](https://github.com/MrGTV-love/firstmate/actions/runs/39645969594), and [39656115805](https://github.com/MrGTV-love/firstmate/actions/runs/39656115805).
`ubuntu-latest` moved to 26.04 between the 2026-10-13 measurement and these runs, and unchanged suites grew by between 1.26x and 4.81x: teardown 787194 to 1404727 ms, watch-triage-waits 1026519 to 1433371 ms, control-relaunch 884225 to 1318470 ms, remote-secondmate-lifecycle 564382 to 898093 ms, omp-harness 625895 to 791063 ms, session-start 437462 to 654059 ms, open-loops 204038 to 550435 ms, control-reassociate 98757 to 347235 ms, and project-capacity 56739 to 273100 ms.
The stale table modelled every serial shard at 19.3 minutes while shards 2, 3, and 7 actually took 29.7 to 30.3 minutes in [run 39656115805](https://github.com/MrGTV-love/firstmate/actions/runs/39656115805), because it packed another 5 to 11 minutes of work behind three suites that each now cost 20 to 24 minutes; the modelled serial total moves from 290.1 to 390.0 minutes, which is the 280 hinted members plus the four that still run at the default weight.
A stale table is what makes the packing guard pass while a real shard overruns, so this refresh reuses successful samples only and excludes the failed or unfinished scripts, exactly as the procedure above requires.
The corpus grows from fifteen to eighteen serial shards, which packs the slowest shard at 23.9 minutes.
The per-shard packing check below then refused eighteen and nineteen shards, because one shard packed 1282762 ms and 1202486 ms of several scripts behind a 898093 ms largest suite, so the corpus moves to twenty serial shards, the fewest that pass.
The packing target stays at 1200000 ms, and the 60-minute job timeout is unchanged.
The guard checks each shard on its own: it refuses a shard whose packed sum is above the target and above that shard's own largest script.
So a shard that holds `tests/fm-watch-triage-waits.test.sh` alone may exceed the target, and no other shard may borrow that size; `serial_indivisible_ms` reports the largest single script.
If every shard must return under 1200000 ms without that exception, splitting `tests/fm-watch-triage-waits.test.sh` is the agreed follow-up, the same way the former combined watch-triage suite was split below.
The two parallel lanes now pass `--jobs 3`, the `PORTABLE_PARALLEL_JOBS` count, because their membership is exactly the proven-isolated set.
The recorded four-way proof of that set in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) ran on a macOS host, where `tests/fm-pi-primary-types.test.sh` gate-skipped and `tests/fm-pr-merge.test.sh` failed, so those two members are not yet proven to pass concurrently.
The first three-wide run on the 26.04 image is [run 39757092565](https://github.com/MrGTV-love/firstmate/actions/runs/39757092565) of PR #198 at head `2f5fd300`: all 30 jobs passed, the workflow finished in 23 minutes, and the two parallel jobs took 20 and 13 minutes against 33 and 28 minutes when they ran serially in [run 39709903843](https://github.com/MrGTV-love/firstmate/actions/runs/39709903843) at head `12a9cef0`, before either job passed `--jobs`; both members the macOS proof missed exited zero there (`fm-pr-merge` in 907277 ms, `fm-pi-primary-types` in 4187 ms, no gate skip), which is one sample beside a proof rather than a replacement for it.
The same run's `portable-serial-4of20` job, which holds `tests/fm-remote-secondmate-lifecycle-e2e.test.sh`, passed ([job 119751733879](https://github.com/MrGTV-love/firstmate/actions/runs/39757092565/job/119751733879)), and the cause of that suite's growth on the 26.04 image is still unproven.
The proven-isolation admission accepts or refuses an explicit `--jobs` on these lanes like any other selection, and `tests/fm-ci-workflow.test.sh` holds the workflow to `PORTABLE_PARALLEL_JOBS`.
`--check-coverage` bounds the modeled makespan packed into the effective bin count, so the two parallel jobs now have a packing bound beside their 60-minute job timeouts.
The makespan model packs the lane's hinted work into `min(PORTABLE_PARALLEL_JOBS, PORTABLE_PARALLEL_EFFECTIVE_JOBS)` bins rather than into the raw job count, and `--check-coverage` reports that count as `parallel_effective_jobs`.
A four-vCPU runner saturates: the lane that summed 33.5 minutes serially finished in 20 minutes three abreast and its recorded per-script wall times rose to a 57.9 minute sum, so three jobs deliver about two jobs of throughput.
Raising `--jobs` past `PORTABLE_PARALLEL_EFFECTIVE_JOBS` therefore changes neither the model nor the guard; rebalancing or splitting the lanes, or refreshing the hints, does.
The guard compares the modeled makespan with the 1200000 ms budget, and the model reads about sixteen percent below measured wall time: the lane that finished in 20 minutes models at 1004772 ms.
So 1200000 ms bounds a real lane near 24 minutes, a fifth above the measured 20 minute lane, and the model now reports 983606 ms against it.
A concurrent run starts its scripts in the `--list-scheduled` order, which is the order the makespan model packs.

The earlier shared hint tables were refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
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
`tests/fm-review-agent-select.test.sh` has a serial hint of 14400 ms that is a local macOS arm64 sample, not a CI measurement: one successful `bin/fm-duration.py run` invocation on 2026-10-15 UTC; replace it with completed healthy CI measurements when available.
`tests/fm-duration.test.sh` has a serial hint of 7990 ms that is a local macOS arm64 sample, not a CI measurement: one successful `bin/fm-test-run.sh --jobs 2` invocation on 2026-10-13 UTC (`exit=0`, `gate_skip=false`), because no CI serial shard has run the new suite yet; replace it with completed healthy CI measurements when available.
`tests/fm-nm-read-cache.test.sh` has a serial hint of 22000 ms that is a conservative bound, not a CI measurement: the latest local macOS arm64 sample is one successful `bin/fm-duration.py run` of the suite on 2026-10-17 UTC (`exit=0`, tree CPU 4.4 s, 37 s wall on a host at load 66), and the hint stays at the bound the packing check below was run against instead of dropping to that sample, because no CI serial shard has run the suite yet; replace it with completed healthy CI measurements when available.
The existing fourteen serial shards were full (`serial_max_ms=1199961` before this suite), so the suite brought a fifteenth serial shard (`serial_shards=15 serial_max_ms=1121528`); this is a dated packing check on 2026-10-17, not a CI duration.
`tests/fm-jev-guard.test.sh` now uses a conservative 475590 ms local macOS arm64 sample from its complete frozen-source run on 2026-10-17, including all final pass markers, because real three-try deadline regressions outgrew its former 70429 ms CI hint.
This is not an Ubuntu measurement; replace it with successful completed CI samples when available.
The new `tests/fm-omp-wake-restore-live-e2e.test.sh` hint is its successful 51 ms record from portable serial shard 3 of [run 37663635202](https://github.com/MrGTV-love/firstmate/actions/runs/37663635202) on 2026-10-07.
That shard completed with zero failures; the live test took its opt-in capability skip, so this hint models ordinary portable CI gate evaluation, not live wake-recovery runtime.
The Jev native guard hints come from successful portable gate evaluations in [run 38679288718](https://github.com/MrGTV-love/firstmate/actions/runs/38679288718), attempt 1: the `pull_request` event records head `2b6268384a91da03d02631250a4e3154f5d2ef4d` and base `3dac70173544419de0d828dbaab4e205008495b1`, and checkout tested merge `a278da0cd2732a7b130055510dfe4fcea8b579a2`.
`tests/fm-jev-guard-claude-live-e2e.test.sh` measured 368 ms on serial shard 12 ([artifact 11948070157](https://github.com/MrGTV-love/firstmate/actions/runs/38679288718/artifacts/11948070157)) with the prompt-submitting opt-in unset; `tests/fm-jev-guard-omp-live-e2e.test.sh` measured 293 ms on serial shard 8 ([artifact 11948210706](https://github.com/MrGTV-love/firstmate/actions/runs/38679288718/artifacts/11948210706)) with omp absent.
Both records have `exit=0` and `gate_skip=true`; they model portable gate evaluation only, not native guard runtime, and failed suite measurements from that run are excluded.
The 2026-10-08 merge-integration refresh uses successful per-script `FM_TEST_END` markers from [run 37821346234](https://github.com/MrGTV-love/firstmate/actions/runs/37821346234). It adds the newly merged serial members that completed successfully and refreshes existing members whose successful measurements grew by more than 30 seconds; other established weights remain conservative historical maxima. Failed invocations of the capacity, watcher-ledger, teardown, and runner suites are excluded, even though their jobs completed and uploaded artifacts.
The 2026-10-10 refresh uses the slowest successful (`exit=0`) `FM_TEST_END` marker per script from the portable serial jobs of [run 38082072235](https://github.com/MrGTV-love/firstmate/actions/runs/38082072235) (PR, 19c0b75c), [run 38086081689](https://github.com/MrGTV-love/firstmate/actions/runs/38086081689) (PR, 75d4c9d5), and green main [run 38082583435](https://github.com/MrGTV-love/firstmate/actions/runs/38082583435) (97389b41).
Run 38086081689's serial 11 was cancelled at its 30-minute cap because the stale omp-harness and teardown hints packed both suites into that shard.
It refreshes the members whose successful measurement grew by more than 30 seconds: contributions, control-relaunch, idle-session-reap, omp-harness, open-loops, pi-watch-extension, proc-budget, procevent, session-start, teardown, wake-queue, watch-idle-reap, and watch-open-loops.
It adds the twelve unhinted serial members that completed successfully: claude-nested-home-live-e2e, contributions-read-saved, fleet-snapshot-contribution-cleanup, fleet-snapshot-fleet-cost, fleet-snapshot-rolling-window, jev-guard, omp-fallback-chain-live-e2e, omp-reboot-live-e2e, omp-task-session-live-e2e, orphan-safety, pi-watch-loader-live, and spawn-claude-start-confirm.
The failed wake-queue invocation of run 38082072235 and the cancelled shard's unfinished backend-zellij invocation are excluded; other weights are unchanged.
The former combined watch-triage suite exceeded the 1200000 ms packing target; its execution lists are now independently runnable signal/delivery and stale/wait groups, described below.
The runner and workflow matrix then used fifteen serial shards with the unchanged packing target and execution timeouts.
The capacity suite's 56263 ms hint is the successful Ubuntu `FM_TEST_END` baseline from upstream [run 37739997864, serial shard 9](https://github.com/kunchenguid/firstmate/actions/runs/37739997864/job/113188261544). It is not a measurement of this integration repair: the local repaired run passed the live-worker teardown but later failed the next spawn's existing backlog-read bound, so its duration is excluded.
In particular, run 36664663190's serial 5 finished in 22m15s with an assertion failure, not a timeout; treating that as a healthy whole-lane sample would hide the failure.
Collect successful per-script measurements for every member before calculating a split.

The former combined `tests/fm-supervision-host.test.sh` measured 789123 ms in run 36669175457 after the merged [host runtime fix](https://github.com/kunchenguid/firstmate/pull/6179), and subsequently grew beyond the packing target.
It is now two independently runnable serial members: `tests/fm-supervision-host.test.sh` owns report, dispatch, drain, and host-loop cases; `tests/fm-supervision-host-hook.test.sh` owns the real Claude re-arm integration, including successor delivery and takeover cases whose names do not mention Claude.
Both source `tests/fm-supervision-host-helpers.sh`, which initializes and cleans a separate fixture environment for each invocation.
Both execution lists run each case through the same existing registered-home process cleanup before starting the next; EXIT uses that cleanup too. This prevents live fake sessions and watcher cycles from earlier cases loading later ones, while preserving every within-case restart, takeover, and failure assertion.
The split host group's 413717 ms hint and host+hook group's 70651 ms hint are successful Ubuntu CI measurements from run 37821346234, replacing the historical host-only interval estimate and local Darwin hook measurement. These measure the actual independently runnable groups after per-case cleanup, not a subtraction from a combined suite.
The merged combined suite's completed 1328905 ms invocation in [run 37787876056](https://github.com/MrGTV-love/firstmate/actions/runs/37787876056/job/113347216521) exceeded the 1200000 ms packing target; the job subsequently hit its unchanged 30-minute limit. Splitting the execution lists and releasing each case's registered live fixtures addresses the indivisible work and accumulating fixture load rather than raising that limit.
The split-group CI samples supersede the earlier unhealthy local full-host attempts, whose durations remain excluded. `--check-coverage` still requires every packed shard estimate to fit the 1200000 ms packing target unless that shard holds one script alone; passing that model does not prove healthy new-head job runtime.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
The session-start hint retains its pre-optimization maximum until CI measures the shorter fixture-only home-summary bound; do not discount a local speedup from CI packing weights.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints, with the Pi typecheck assigned to the job that explicitly installs its npm prerequisites and records their resolved versions rather than relying on image-global tools.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the three-tier timeout policy in [Timeouts](#timeouts) below.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.
Since these lanes run three abreast, a concurrent artifact records each script's wall time under contention rather than its own cost, so take the serial-era sample (a run of the same lane before it passed `--jobs`, as the 2026-10-22 refresh below does) or divide a concurrent sample by the observed inflation, because a concurrent sample would otherwise count the contention twice.

The parallel hints were last refreshed on 2026-10-22 from one run: the `fm-test-timing-portable-parallel-*` artifacts of [run 39709903843](https://github.com/MrGTV-love/firstmate/actions/runs/39709903843) at head `12a9cef0`, where both parallel jobs ran their scripts serially, before either passed `--jobs`.
Each hint is that run's successful `duration_ms` for the script, and the lane sums of that run's membership were 2008808 ms and 1677716 ms (33.5 and 28.0 minutes).
This is one sample per script, not the slowest of several green runs that the procedure above asks for, so a script that ran fast in that run is under-hinted until the next refresh.
Serial-era durations are the right unit for this model because it applies its own contention factor: a concurrent artifact already contains the slowdown from sharing the four-vCPU runner, and `PORTABLE_PARALLEL_EFFECTIVE_JOBS` would count that slowdown a second time.
Against the 2026-10-17 table below, `tests/fm-captain-hold-keyed-answers.test.sh` fell from 257148 ms to 185475 ms, `tests/fm-composer-lib.test.sh` from 218757 ms to 192576 ms, and `tests/fm-pi-primary-types.test.sh` from 5993 ms to 2395 ms.
The other 26 hints rose, among them `tests/fm-lint.test.sh` from 737853 ms to 758806 ms and `tests/fm-test-run.test.sh` from 304481 ms to 444553 ms.

The parallel hints were first refreshed on 2026-10-17 from the `fm-test-timing-portable-parallel-*` artifacts of eight green main runs: [38904559722](https://github.com/MrGTV-love/firstmate/actions/runs/38904559722), [38957463780](https://github.com/MrGTV-love/firstmate/actions/runs/38957463780), [38979006411](https://github.com/MrGTV-love/firstmate/actions/runs/38979006411), [38979776735](https://github.com/MrGTV-love/firstmate/actions/runs/38979776735), [38990827989](https://github.com/MrGTV-love/firstmate/actions/runs/38990827989), [39001838488](https://github.com/MrGTV-love/firstmate/actions/runs/39001838488), [39010291930](https://github.com/MrGTV-love/firstmate/actions/runs/39010291930), [39013019461](https://github.com/MrGTV-love/firstmate/actions/runs/39013019461).
Each retained member then carried its slowest successful (`exit=0`, `gate_skip=false`) `duration_ms` across those runs.
The 2026-10-22 refresh above replaced every hint from that table, so these values are history and not the provenance of the current hints.
The 2026-10-17 refresh moved `tests/fm-lint.test.sh` from 252498 ms to 737853 ms, `tests/fm-composer-lib.test.sh` from 9521 ms to 218757 ms, and `tests/fm-test-run.test.sh` from 156781 ms to 304481 ms.
Stale hints of that size made the two lanes look balanced while one carried over 1.2 times the other's real work.
The six captain-hold group hints of that table were not slowest-run samples because the groups did not exist in those runs.

## Captain-hold groups

The former combined `tests/fm-captain-hold-lifecycle.test.sh` measured between 773304 ms and 1259266 ms in those eight runs against a 343658 ms hint.
No lane packing could place a single 21-minute member beside the other shard-2 members inside a 30-minute job.
Its 116 cases now run exactly once across six independently runnable files, each under about 5 minutes of measured CI work:

| File | Area |
|---|---|
| `tests/fm-captain-hold-lifecycle.test.sh` | holds, origins, inventories, the completion gate, recorded answers, deferral, and the secondmate parent channel |
| `tests/fm-captain-hold-sweep.test.sh` | the finished-board sweep and bound captain keys at the sweep |
| `tests/fm-captain-hold-keyed-answers.test.sh` | the keyed-answer intake, default and done releases, and replay after interruption |
| `tests/fm-captain-hold-reconcile.test.sh` | reconcile requests, verified closes, operational-key closes, legacy identities, and record divergence |
| `tests/fm-captain-hold-cleanup.test.sh` | cleanup of captain-held rows, relocated backlogs, merge entrypoints, and the beads backend |
| `tests/fm-captain-hold-archive.test.sh` | the done-archive lookup, the archive-setting reader, and its refusals |

All six source the unchanged definitions and fixture setup in `tests/fm-captain-hold-lifecycle-helpers.sh`; each invocation has its own temporary root, registered cleanup, and final process inspection, so the final `ok -` line appears once per file.
A helper used by one group lives beside that group's cases, and a helper used by several lives in the shared file.
Selecting one case by name still works in the file that owns it.
`tests/fm-test-run.test.sh`, in `test_captain_hold_groups_share_helper_changed_selection`, requires every group to be independently selectable and a change to the shared helpers to select all six.
The six files stay in the proven-isolated set and the parallel lanes; `bin/fm-test-isolation-proof.sh` lists them and [fm-test-isolation-proof.md](fm-test-isolation-proof.md) records the concurrent proof.

The first group hints (143236, 173175, 199013, 247202, 257148, and 264427 ms) came from the timestamped case completions in the job log of [run 39006546434](https://github.com/MrGTV-love/firstmate/actions/runs/39006546434), attempt 2, where the combined file finished in 1284127 ms.
Successive timestamp differences between `ok -` reports assign every interval to its case, and the 31.7 s final cleanup interval is shared across the groups in proportion to their case time.
This replayed observed CI work and was not a measurement of independently launched groups.
The 2026-10-22 refresh above replaced those six hints with the groups' own timing artifacts.

Five cases run their independent matrix cells at once through `run_cells_in_parallel`, the way the retry matrix already did: the origin-first matrix, and the keyed-release cases for interrupted releases, completed releases, repeated answers, and legacy releases.
Each cell builds its own homes under unique names, and a failing cell fails the case with the tail of its log.
No case body, assertion, or `ok -` line was shortened or removed.

## Teardown groups

The former combined `tests/fm-teardown.test.sh` was an indivisible member: serial shard 2 of [run 39838628417](https://github.com/MrGTV-love/firstmate/actions/runs/39838628417) held it alone, its script time was 1587660 ms, and that job finished 26 minutes 49 seconds after the workflow started against the 1200000 ms packing target.
Its 333 cases now run exactly once across three independently runnable files:

| File | Area |
|---|---|
| `tests/fm-teardown.test.sh` | the landed-work proof and refusal matrix: fork and local-only landing, squash-merge and PR-head proofs, content fallback, task archives, pipeline-input ties, PR-check head records, dirty-worktree diagnostics, legacy records, and index-lock recovery |
| `tests/fm-teardown-pool.test.sh` | pool slots, leases, custody, and returns: reservation before cleanup, proved landing after a wait, return-pending records across a refusal, reassigned and enclosing slots, reassociated and prior copies, nested slots, and subordinate cleanup custody |
| `tests/fm-teardown-cleanup.test.sh` | post-close cleanup: the bounded process reap, foreign and held copies with the closeout driver, private no-mistakes launch agents, Docker stacks with their retained records, Herdr projection journals, and secondmate delivery and retirement |

All three source `tests/fm-teardown-helpers.sh`, which owns every fixture and assertion helper plus the working tree's temporary root, the birth-identity fixture registry, and the EXIT cleanup.
Each invocation owns its temporary root, its registered cleanup, and its own process inspection, so the final `ok -` line appears once per file.
Every case still builds and tears down its own sandbox through `make_case`, and selecting one case by name still works in the file that owns it.
The three files stay serial in the CI lanes: `bin/fm-test-isolation-proof.sh` lists them beside the landing and lock-race reason, which keeps them out of the mixed PORTABLE pool.
A local `--family pr-forge` run at an admitted job count runs them concurrently with the family, and [fm-test-isolation-proof.md](fm-test-isolation-proof.md#pr-forge-admitted) records the 2026-10-22 proof of that membership.
`tests/fm-test-run.test.sh` holds the partition: `test_teardown_groups_register_each_case_once` requires the three case lists to be a duplicate-free cover of the 333-case inventory with every case registered by the file that defines it, and `test_teardown_groups_share_helper_and_stay_selectable` requires each group to be independently selectable, a shared-helper change to select its pr-forge family, and that family to keep all three.

The first hints (272355, 439235, and 876070 ms) are the former combined 1587660 ms measurement apportioned by the groups' measured local Ubuntu 26.04 container times (199413, 321599, and 641441 ms of a 1162453 ms total), not by a CI measurement of the separate files.
On the pre-rebase 332-case inventory, the intact suite and the three groups reported the same 335 `ok -` lines and no failures in that container, which is the behavior-parity evidence for the split.
The rebase then added upstream's `test_closeout_refusal_reports_tail_and_preserves_complete_output`, taken verbatim into `tests/fm-teardown-cleanup.test.sh`, which makes the inventory 333; the 2026-10-22 pr-forge isolation proof ran all three group files to exit 0 on that 333-case head.
Replace these hints from the groups' own `fm-test-timing-portable-serial-*` artifacts as soon as a CI run measures them.

The same refresh raised the four successful measurements that grew by more than 30 seconds - `fm-teardown` (split above), `fm-pr-check-security` (342666 to 420272 ms), `fm-control-relaunch` (1318470 to 1358153 ms), and `fm-spawn-compact-adviser-disable-remote` (294998 to 352918 ms) - and added the four measured but previously unhinted serial members `fm-api-key-guard-lib` (3850), `fm-copy-sweep` (207702), `fm-friction-ledger` (2020), and `fm-jev-guard-audit` (1281 ms).
Measurements come from the successful per-script `duration_ms` records in that run's `fm-test-timing-portable-serial-*` artifacts.
The serial lane still passes `--check-coverage` at the unchanged twenty shards, and the largest remaining single script is `fm-watch-triage-waits` at 1433371 ms, so splitting that suite is the way to a packed shard below it.

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
`tests/fm-spawn-retained-copy.test.sh` has a supplemental local, non-CI hint of 59225 ms from a successful runner invocation on macOS arm64 on 2026-10-10 UTC (`exit=0`, `gate_skip=false`). This makes its newly classified allocation coverage measurable without relaxing the unhinted-share guard; replace this platform-specific sample with completed healthy CI measurements when available, rather than treating it as CI performance evidence.
An unfinished or failed invocation is not a healthy duration sample.
On 2026-10-07, 32 previously missing hints were added from successful completed per-script records in the portable-serial timing artifacts of [run 37619080376](https://github.com/MrGTV-love/firstmate/actions/runs/37619080376).
That run was not green: its successful records supplement the retained baseline, while failed and unfinished invocations supply no hints.
Capability skips measure only the portable gate path, not the opt-in live scenario.
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
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies through the executable runner that a lone script above the budget is accepted, that a multi-script shard summing to exactly the budget is accepted, and that the same shard one millisecond above it is refused as exceeding its own largest script.
The boundary, inventory-growth, generation-failure, and duplicate-refusal fixtures share tiny serial timing inputs independent of production hint growth; the boundary cases raise the seeded script, plus three more scripts to 700000 ms in the packed-shard refusal fixture, and every other member stays at its tiny fixture hint. The separate real-repository coverage check continues to validate the actual timing table and packing budget.
The family-admission regression executes fixture members through the real runner and checks execution, the proven worker cap and external-path refusal, rather than nesting watcher lifecycle suites and their independent startup deadlines. Those real suites retain their own complete lane membership.
The former combined `tests/fm-watch-triage.test.sh` measured 1355995-1429810 ms in the latest three main runs, so no shard count could fit it within the unchanged 1200000 ms packing target.
Its 159 existing cases now run exactly once across `tests/fm-watch-triage.test.sh` (93 classifier, signal, delivery, and heartbeat cases) and `tests/fm-watch-triage-waits.test.sh` (66 stale, wait, escalation, and away-mode cases).
Both source the unchanged definitions and fixture setup in `tests/fm-watch-triage-helpers.sh`; each invocation has its own temporary root and registered watcher cleanup.
The stock macOS `FM_TEST_ONLY` regression remains selectable through the original script.
No sleeps, production deadlines, test assertions, or case bodies were shortened or removed.
Initial group hints are 415321 ms for signal/delivery and 1026519 ms for stale/wait, derived from the timestamped case completions in the same three successful CI invocations.
Each log contains the identical ordered sequence of 159 `ok -` reports; successive timestamp differences assign every elapsed interval to its case, including suite startup in the first interval.
Sum the slowest observed interval per retained case and charge the maximum final cleanup interval (1613 ms) to each new group.
This conservatively replays observed CI work, but is not a measurement of independently launched groups; refresh both hints from their own successful runner artifacts after CI exercises the split.
The upstream-sync merge added `tests/fm-project-mode.test.sh` and `tests/fm-self-repo-role.test.sh` to the serial lane; their default weights packed the largest shard at 1210091 ms.
Their hints (496 ms and 7316 ms) and the `tests/fm-secondmate-busy-contract-live-e2e.test.sh` hint (5810 ms, replacing an unmeasured 90000 ms estimate) are the successful `exit=0`, `gate_skip=false` records from the serial shards of [run 38679906333](https://github.com/MrGTV-love/firstmate/actions/runs/38679906333) on 2026-10-15; the live suite's record measures the ordinary portable gate path, not its opt-in live scenario.
On 2026-10-15, `bin/fm-test-run.sh --check-coverage` reported `serial_shards=14 serial_unhinted=0 serial_max_ms=1198243 serial_budget_ms=1200000`; this is a dated packing check, not a measured new-head CI duration.
Before integration, the guard repair's native hints produced `serial_shards=14 serial_unhinted=0 serial_max_ms=1197356 serial_budget_ms=1200000`; that historical packing check does not describe the rebased head.
Rebasing the repair onto `8221de43a082aef5d0368cfdfb9512810b0d71e5` preserves both sets of measured hints but invalidates prior reviewed-head continuity and downstream head evidence.
The existing pipeline must restart validation from Review and refresh downstream checks and PR evidence for the integrated head; neither historical estimate is a new-head CI pass.
The estimates use per-file maxima from different runs, not measured rebalanced jobs or an end-to-end latency guarantee.
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
[`tests/fm-open-loops.test.sh`](../tests/fm-open-loops.test.sh) owns collector deadline coverage for origins, PR checks, PR state, and questions, including proof that the named reader triggers cancellation rather than the REST helper's cache or lock reads.
Herdr lifecycle fixtures model both registration and foreground processes: an unregistered live harness is not a shell-only husk, and live-owner attribution may refuse before checkout inspection. Refusal coverage checks unchanged metadata and endpoint state with no lifecycle input. Fake omp executables answer the supported-version probe separately from catalog or environment output, and generated-extension fixtures include their runtime imports and host registry API.
Changed-only selection classifies retained-spawn coverage in `backend-dispatch`; a task-copy production change selects it alongside `secondmate` safety coverage.
The Jev guard suite reads ledger permission bits through Node's filesystem API on both Linux and macOS; a BSD/GNU `stat` fallback can mix filesystem diagnostics into the mode and falsely reject a private ledger.
The bearings Perl-timeout fixture includes `uname` for the PR library's cached platform lookup during contribution coverage, while still excluding `timeout` and `gtimeout`. A stalled GitHub read must therefore reach the Perl bound and return the ordinary snapshot with PR availability disclosed, rather than exit during dependency initialization.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns three canonical CI partitions, each attempting full source-aware ShellCheck analysis and running workflow validation and backend-purity checks.
Its `fm_lint_partition_weight_hints` table contains the slowest successful per-root duration from the two partitions' `partition-N.roots.tsv` sidecars in the same three main runs used by the latest serial refresh.
The seven captain-hold roots have no lint measurement of their own yet: their rows divide the former combined file's 12745 ms in proportion to each file's bytes, so refresh them from the next three main runs' sidecars.
The four teardown rows (`tests/fm-teardown-cleanup.test.sh` 4219, `tests/fm-teardown-helpers.sh` 2194, `tests/fm-teardown-pool.test.sh` 2043, and `tests/fm-teardown.test.sh` 1830) divide the former combined file's measured 10286 ms by each file's line share; they are not measurements, so replace them from the lint sidecars of the next three Ubuntu main runs.
The telemetry records ShellCheck 0.11.0 on Linux x86_64, Ubuntu 24, image `20261004.327.1`.
Longest-processing-time packing uses those durations, not direct file bytes: equal byte totals previously carried 1240 and 1781 seconds of measured lint work in run 38312847224.
The script header owns missing-root fallback and partition syntax; local worker balancing and its telemetry weight fields still use direct bytes.
Refresh the duration table from successful `end` records' `duration_ms`, retaining complete canonical root coverage independently of hints.
`tests/fm-lint.test.sh` proves the measured-cost selection with equal-byte roots whose independently seeded durations require a different split.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, changed-source selection, shared-cache invalidation, initial analysis flags, fallback reporting, and seeded finding parity.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, or paid runner provisioning is part of this layout.
The [lint script header](../bin/fm-lint.sh) owns host-wide slot controls and queue-time accounting; `tests/fm-lint.test.sh` covers the CPU-derived cap, concurrent admission, per-run fair share between unequal runs, FIFO progress without barging past older or stopped waiters, cache-hit slot bypass, ungated fallback, inherited-slot lifetime, and queued-root timing.

The [lint script header](../bin/fm-lint.sh) owns local dependency discovery, conservative unresolved-import selection, and successful-result cache controls; these do not replace full joint source analysis.
Regression fixtures exercise cross-file missing-argument findings through direct and private source routines, deleted sources, concurrent reuse, changed binaries, and the separation between fast and full analysis.
Spawn, control, and remote secondmate relaunch obtain configuration inheritance through their shared launch-policy import rather than importing it again.
The shared Claude-launcher library uses that caller-provided configuration dependency rather than importing it a second time.
Spawn also obtains classification and PR helpers through its definition-of-done import, and timeout helpers through its backlog-transition import, instead of duplicating those source graphs with direct imports.
The policy library's lazy wake import uses the existing canonical-owner analysis boundary, while the wake owner remains in the complete lint inventory.
`tests/fm-test-run.test.sh` verifies changed status and UTC owners through the runner's authoritative consuming-family map.
ShellCheck 0.11.0 can treat a dynamically named `printf -v` in a subshell-sourced library as a write to `$!`. The timeout TERM-forwarding and Herdr recovery fixtures annotate only the resulting SC2031 false positives at immediate background-PID captures; launches, waits, and cleanup assertions remain unchanged.

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

The longer-term performance objective remains a complete green run under fifteen minutes including start delay; a passing packing model does not establish that latency.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The layout uses twenty-six long-lived Linux jobs (twenty serial, two parallel, Herdr, three lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession without cancelling main pushes or changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, changed-file selection (including retired assets), and bounded `--jobs` mechanics.
Changed-file selection maps the flat omp bordered captures to `fm-composer-lib.test.sh` and the native-band captures, including both 18.8.1 directory and linked-worktree layouts, to `fm-composer-native-band.test.sh`; unrelated flat captures still require a consumer mapping.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix.
The bounds sit at true extremes, far above healthy duration, so a loaded runner slowing a healthy lane does not reach them, and they are never a target for new work to grow into.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, timing aggregate | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, portable serial shards, macOS stock Bash | 60 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Heavy | Herdr | family-run step 60 minutes under a 120-minute job-level last-resort backstop | Across the last 30 completed `ci.yml` runs (run numbers 425 to 454), the 29 successful family-run steps took 13m51s to 17m12s. Three times the longest is 51m36s, so the step is capped at 60 minutes, an extreme hang tripwire a loaded runner does not reach. It fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.

Inside `tests/fm-remote-secondmate-lifecycle-e2e.test.sh`, the remote recovery watcher wait allows 150 seconds of polling: the watcher's 120-second relaunch bound plus startup and wake overhead.
It still requires a successful relaunch, exactly one captain-facing wake, the durable wake and relaunch records, a fresh live remote endpoint, and the preserved host route.
This fixes the former 30-second observation window, which could stop a healthy relaunch before its own deadline; it does not change production relaunch bounds or CI job timeouts.
The same test declares its inherited config inputs in `remote_env`, so adding unrelated production defaults cannot lengthen its bounded inheritance and launch-barrier setup.

[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly three distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 60-minute budget, and the Herdr family-run step is the 60-minute tripwire below its 120-minute job backstop with an `always()` teardown after it.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
