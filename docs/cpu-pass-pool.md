# CPU pass pool

The CPU pass pool is one host-wide budget for CPU-heavy test bursts.
A test script, a parallel test worker, or a load test takes a pass before it runs and returns it when it ends.
When every pass is held, the next burst waits for one instead of adding to the run queue.

Burst passes count CPU workers, not agents.
Fresh Firstmate-driven pipeline starts additionally queue through this same pool's start-admission owner, described below.
Interactive agents, lanes, sessions and existing-run reattachments do not request start admission.

This page owns the cross-repository protocol.
`bin/fm-cpu-pass.sh` is its reference implementation; the [`bin/fm-cpu-pass.py` header](../bin/fm-cpu-pass.py) owns command behavior, while `bin/fm-cpu-pass.sh --help` lists subcommands and each subcommand's `--help` lists its options.

## Why file locks

The pool uses Python's standard-library `fcntl.flock` over one lock file per pass, not GNU parallel's `sem`.
A kernel file lock is released when its last owning descriptor closes, including on `SIGKILL`.
Only the pool owner retains slot descriptors; commands and their exec children never inherit them, so surviving worker children cannot hold a master's reservation after its command ends.
Ordinary termination signals keep that owner until its command exits; killing the owner with `SIGKILL` releases its passes even if descendants survive.
The pool has no stale slot state to repair; `sem` keeps its own bookkeeping that must notice dead holders.
`python3` is already a runtime dependency of Firstmate's runner and of the Python projects that will join the pool, so the pool adds no new install, while `sem` would add Perl-based GNU parallel and its citation prompt to every host and CI image.
Any language with `flock` can join the protocol below without calling a Firstmate script.

## Protocol

Every participant on a host follows these rules, so one pool is shared by every Firstmate home, worktree, and repository of the same user.

1. **Directory:** `FM_CPU_POOL_DIR` when set, else `$HOME/.cache/fm-cpu-pool`, created with mode `0700` and owned by the user.
2. **Size:** the host's logical CPU count (`os.cpu_count()`, which is `hw.ncpu` on macOS), with no environment override.
   Load average does not shrink the pool: it includes interactive sessions that never take passes, so a load-based gate would hold tests back indefinitely on a host whose baseline load comes from idle sessions.
3. **Passes:** pass `i` is an exclusive, non-blocking `flock` on `slot-<i>.lock` for `i` in `0..size-1`.
   The pool owner alone holds the close-on-exec slot descriptors until its direct command exits; descendants do not inherit reservation ownership.
   A holder may write one line into each slot it holds, `pid=<pid> passes=<k> since=<epoch> label=<text>`, for status display.
   Firstmate publishes that record as each slot is acquired, including while a request is still collecting passes.
4. **Turnstile:** a request first takes an exclusive `flock` on `turnstile.lock`, then collects slots until it holds all it asked for, keeping the slots it already holds, then releases the turnstile.
   Only the turnstile holder collects, so two multi-pass requests cannot deadlock and a large request is not starved by small ones.
   Both locks are polled with backoff; a request queues and never fails for lack of a pass.
5. **Count:** a request asks for exactly as many passes as the CPU-bound workers it will run (one for one test script, `W` for `pytest -n W`).
   Callers read `size` and use that same positive count for their workers and reservation; a count below one or above the pool size is a usage error and never starts work.
   This validation also applies to nested and degraded execution; without Python, oversized counts are refused when the host CPU count can be read using `sysctl` or `getconf`.
6. **Nested work:** a holder exports `FM_CPU_PASS_HELD=<k>` to the work it runs.
   A participant that finds `FM_CPU_PASS_HELD` set runs without taking another pass, because taking another could deadlock a full pool.
   With a positive inherited count, nested work never runs more concurrent CPU-bound workers than that count; a caller needing parallel nested work reserves enough passes before starting the outer work.
   An explicit pass request above a positive inherited count is a usage error; the [`fm-test-run.sh` header](../bin/fm-test-run.sh) owns the runner's concurrency-reduction behavior.
   The marker must be a nonnegative decimal integer in both Python and no-Python execution; a malformed marker is a usage error, while `0` denotes degraded work with no reservation or concurrency limit.
7. **Degrade, never block:** a participant that cannot use the pool (no `flock`, no pool directory, a foreign-owned directory) runs its work without a pass and says so once.
   Degradation notices use `--log-fd` (default stderr), separate from the work's stdout, including when Python is unavailable.
   The pool governs throughput; it is not a safety boundary, and a broken pool must not stop every test on the host.
8. **Waiting stays outside work bounds:** take passes before starting any per-test or per-worker timeout, so time spent queued never counts toward that timeout.
   A caller's own overall budget, such as a harness command limit, still includes the wait.
   For a fresh pipeline start, that limit ending the wait means no run was created; the recovery is the re-issue rule under Fresh pipeline starts, not a reattach.

## Calling it

From a shell, with Firstmate's `bin/` reachable:

```sh
workers=$(bin/fm-cpu-pass.sh size)
bin/fm-cpu-pass.sh run --passes "$workers" --label "my-suite" -- pytest -n "$workers"
bin/fm-cpu-pass.sh status
bin/fm-cpu-pass.sh size
```

A repository that cannot assume a Firstmate checkout implements the protocol directly with its language's `flock`, as rules 1-8 describe.
The [`bin/fm-test-run.sh` header](../bin/fm-test-run.sh) owns Firstmate's runner integration.

## Fresh pipeline starts

Before a Firstmate-driven fresh/new no-mistakes run, including an authorized rerun, the existing pool's `pipeline-start` owner reads the host's `~/.no-mistakes/state.sqlite` read-only and one host memory and process reading.
It has no option or environment variable that selects another database.
It never admits by load average; in measured mode it admits by the memory the counted runs are measured to need, not by a CPU-count ratio, and the [fallback](#fallback) below uses the count limit.
A counted run is a `runs` row with `status = 'running' AND ci_ready_at IS NULL AND awaiting_agent_since IS NULL`; both of those columns are facts the daemon records.
A CI-ready run that is only monitoring its PR, and a run parked waiting for its agent, are still `running` but are not counted.
A run that leaves `running`, reaches CI-ready or parks for its agent releases its count implicitly; no daemon-lifetime lease or watcher is installed.

### Admission formula

The first waiter in class order is admitted when, in bytes:

```text
(counted + 1) x R + S  <=  B          where  B = available_bytes + held
```

| Symbol | Meaning | Source |
|---|---|---|
| `counted` | counted runs, as defined above | the run database, read now |
| `R` | the reservation of one run: the 75th percentile (nearest rank) of the per-run peak resident memory of recorded no-mistakes runs, leaving out runs still running that are not CI-ready yet, so their peak may still rise | `peak_bytes` of every `no-mistakes:` entry with at least 2 samples in the root home's `state/.memory-calibration.json`, written by `bin/fm-mem-guard.sh probe`, leaving out every run whose `runs` row is `status = 'running'` with `ci_ready_at IS NULL`, parked or not; CI-ready running runs are ranked |
| `S` | slack for one run reaching its tail: the largest peak of every such entry, running or not (a peak so far is a lower bound, so it never makes `S` too low) | same record, no run left out |
| `available_bytes` | free, file-backed and purgeable pages, never compressed or swapped memory | one `bin/fm-mem-guard.py` `admission_sample()` reading: a waiting start may reuse one up to 2 s old, but each grant takes a new reading, with the process-count reading, so a signal that turns bad after a healthy read cannot admit |
| `held` | resident memory the counted runs hold now, summed over their process trees with each run's share capped at `R`; a run the reading cannot see yet holds 0 | the same reading, keyed `no-mistakes:<repo_id>/<run id>` |

`B` is the memory the counted runs may still use plus what the host has free, so the inequality is the same as "the reservations of the counted runs, the new run and one tail run fit the host's available memory": a counted run's reservation is partly already held, and `held` counts that part once.
A run that holds more than `R` adds only `R` to `B`, so its excess is never treated as free memory for new starts.
A run that is registered but not yet visible in the reading therefore reserves its whole `R` in the next decision.
With no counted run, one start is admitted even when the inequality does not fit, a one-start minimum, so a large `S` or a low `available_bytes` never holds an idle host closed; the pause-only backstop below still pauses that start.
The record belongs to the host: it must name this host and its RAM size.
The owning home is `FM_HOME`, else the `FM_DURATION_HOME` that `bin/fm-spawn.sh` exports to workers, else the checkout holding the engine; a secondmate home reads its root home's record, found by `fm_firstmate_root_home` in `bin/fm-secondmate-parent-lib.sh`, the same walk the record's writer uses; a walk that fails takes the fallback below.
`R` and `S` are measurements; taking the 75th percentile as the reservation is a policy choice (Main 2473 ruling), made after replaying it against the recorded readings (the captain-private record `data/fm-admission-measured-reservations/measurements.md` holds the readings, per-phase peaks, the five proc-guard pile-up censuses and the replay under the capped-`held` formula).
Measured: the record frozen at epoch 1793568514 (41 readings over 5.3 hours) held 13 `no-mistakes:` entries with at least 2 samples; their largest peak, `S`, is 8.06 GiB, and `S` under the shipped rule is that value because `S` takes every qualifying entry.
Estimated: the replay of those 41 readings under the shipped formula, with `held` capped per run at `R`, takes `R` as the 75th percentile of all 13 runs, 3.988 GiB, because the run database keeps no history of past run status and so the rule that leaves runs not CI-ready yet out of `R` cannot be replayed.
On that replay the capacity (the largest `counted + 1` the formula admits) was 5 at minimum, 7 at median and 8 at maximum across the readings, against a fixed 6 under the previous count limit; the reading at 17:40 UTC stays at 7, so a start is admitted while `counted` is at most 6.
`R` and `S` re-derive from every probe, and the pause-only backstop, not a larger guess, is what bounds the tail.
Those peaks are tree snapshots and lower bounds; native memory pressure never reached level 2 in that window, so no measured margin exists and the formula keeps none.

Process count is not a reservation: a run's tree peaked at 34 processes against the host's 10,666 per-user cap, and every recorded pile-up was a runaway `bash` chain, not a run tree.
Processes appear only in the backstop below.

### Fallback

With fewer than 2 qualifying recorded runs, a record for another host or RAM size, an unreadable record, or no native memory facts on this platform, the start is admitted while `counted < max(1, floor(logical CPUs / 3))`.
That is the previous count limit, kept only until the host has measured runs; a missing record never refuses a start and never reads as an empty host.

### Pause-only backstop

While either signal reports an actual overload, or cannot be read, no new start is admitted and a notice names the reason:

- the memory reading is unreadable or would make `bin/fm-mem-guard.sh admit` exit 75 (native pressure level 2 or higher, or a required fact unavailable; `admission_evaluate` returns the same list);
- `bin/fm-proc-guard.py` reports a pile-up (user process count above its fixed 60 % warning line of the host's per-user cap, a proc-guard constant) or cannot read the count or, on macOS, the per-user cap.

Nothing running is stopped, paused or reprioritised.
This backstop covers the tail the reservation does not: a run that exceeds `R`, and process pile-ups.
It only delays a start; the unreadable run database or CPU count still refuses with 125.

Queued classes are ordered `merge-train`, `machinery`, `vernant-build`, then `other`, with arrival order within each class.
Admission never preempts an already granted start or stops running work.
The short start lock covers the observation-to-daemon-registration gap, so participating simultaneous starts cannot all spend the same observed headroom, and a burst of ready starts is admitted back to back while the formula fits, with no spacing between them.
The [engine header](../bin/fm-cpu-pass.py) owns the registration handoff, failure behavior and the limit of read-only coordination with starts that bypass it.
Unusable run-database, CPU-count, memory or process observations do not imply an empty host.

`bin/fm-duration.py run` automatically routes fresh `no-mistakes axi run` inputs and `no-mistakes rerun` through that owner before starting its execution clock; its `--pipeline-priority` option selects the class.
Generated worker delivery instructions require this measured route for fresh starts across harnesses and runtime backends.
Existing-run reattachment and responses do not requeue, restart a run or consume another start.
Only the measured runner the owner re-executes skips a second admission, through an internal argument it consumes; the wrapped client and every descendant receive no exemption, so a nested fresh start queues like any other.
A fresh-start call that ends - killed, timed out, or by its harness command limit - before it prints `fm-cpu-pass: pipeline-start admitted` was still queued and created no run.
Issue the same fresh start again through `bin/fm-duration.py run`, not a flagless reattach or a status read; the new request queues again from its own arrival time.
The admitted line proves only that the client was launched, not that a run exists, so after it the worker reattaches normally.
If that reattach refuses because no run is active and `no-mistakes axi status` shows no run created since the fresh-start call began, the start created no run and is issued again the same way; when status shows such a run, the worker reads its outcome and never starts another.
Admission adds no inherited CPU-worker budget, reduces no worker counts and serializes none of a task's required checks.
It is not start authority: explicit task admission, original intent and verification evidence, Test/Document and all other validation gates still apply.

The start gate does not use load average; post-deployment acceptance below still uses measured one-minute load p95, not a synthetic gate result.
Cross-project CPU-worker participation, including `vernant-cpu-pass-pool-participation`, remains a separate dependency.

## Phase 1 cutover

F6 is installed and live on this host since 2026-10-08 00:54 in the private no-mistakes build `v1.86.1-private.f6.20261008`.
Its gate overlay disables the omp advisor and eager sub-agents for pipeline agents only.
This change delivers the Firstmate side of Phase 1: the pool, `fm-test-run.sh` wiring, the cross-repository contract, and the measurement recipe.
Phase 1 completes only when the Vernant participant lands as a separate Vernant-repository change, tracked as backlog item `vernant-cpu-pass-pool-participation`, alongside this Firstmate change and the live F6 overlay.

## Judging the pool

`bin/fm-load-report.sh` records host load and reads pipeline agent durations; its [engine header](../bin/fm-load-report.py) owns the sample format and command behavior, while this recipe owns the measurement window and acceptance criteria.

1. Only once Phase 1 is complete, note the time with `date +%s` and start one recorder per host: `nohup bin/fm-proc-budget.sh -- bin/fm-load-report.sh watch --interval 60 >/dev/null 2>&1 &`.
2. After 24 to 48 hours of normal fleet work, run `bin/fm-proc-budget.sh -- bin/fm-load-report.sh report --since <that epoch>`.
3. Read its two verdicts: `load_within_2x_cpus` (1-minute load p95 at or under twice the CPU count) and `converged_within_2_fix_rounds` (the fixed first ten pipeline runs that reached review and were created after the recorded cutover epoch, ordered by creation time then run id, completed successfully with at most two review-fix rounds and none hit a timeout).
   Failed and cancelled cohort members count as not converged.
   The convergence verdict is pending (`null` in JSON, `pending` in text) until ten review-reaching runs exist and every pending or running run that sorts at or before the tenth member is terminal, including runs that have not reached review yet.
   Once those earlier runs are terminal, cohort membership and the true or false verdict are fixed; later-created runs do not change them.
   Its list of timeout-class run errors should be empty.
4. Stop the recorder when the window closes.
5. Compare per-purpose agent durations over a week and aggregate wall time with the pre-Phase-1 baseline; aggregate wall time must not worsen, review-fix time should be about 25 minutes, and post-merge defects must not rise.
   Neither report verdict measures post-merge defects or makes the before/after comparison automatically.
