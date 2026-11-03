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

### Admission rule

Subject to the one-start minimum and pause-only backstop below, the first waiter in class order is admitted when, in bytes:

```text
projected  <=  budget        where  budget = available_bytes + held
projected  =   the reservations of the counted runs  +  S for the new run
```

| A counted run that is | reserves | why |
|---|---|---|
| waiting on remote CI: its open step is `ci` with status `running`, no agent pid is recorded and no launch-gate reservation is live | only the resident memory it holds (0 while no process of it is visible) | it uses memory again only when a fix round starts, and that agent starts only through the [launch gate](#launch-gate), which secures capacity first |
| visible in the reading at any other step, or with a live launch-gate reservation | its resident memory or `A`, whichever is larger | startup memory alone is not its demand; memory above `A` is counted as it is, never capped at `R`, `S` or a recorded peak |
| not visible yet: just registered, between steps, with an unreadable step, or a launch-gate start the reading cannot see | `R` | the reading cannot show what it will use, so it is never read as idle |

| Symbol | Meaning | Source |
|---|---|---|
| `R` | one run's reservation while the reading cannot see it: the 75th percentile (nearest rank) of the per-run peak resident memory of recorded no-mistakes runs, leaving out runs still running that are not CI-ready yet, so their peak may still rise | `peak_bytes` of every `no-mistakes:` entry with at least 2 samples in the root home's `state/.memory-calibration.json`, written by `bin/fm-mem-guard.sh probe`, leaving out every run whose `runs` row is `status = 'running'` with `ci_ready_at IS NULL`, parked or not; CI-ready running runs are ranked |
| `S` | the new run, which may reach the largest peak recorded for any run | the largest peak of every such entry, running or not (a peak so far is a lower bound, so it never makes `S` too low) |
| `A` | the active-run term: the largest per-run concurrent demand of every run but the largest, `(sum - largest) / (count - 1)` over each error-free reading of this host and RAM size that saw at least 2 no-mistakes run trees, rounded up | the root home's `state/memory-readings.jsonl`, read-only and re-read when it changes |
| `available_bytes` | free, file-backed and purgeable pages, never compressed or swapped memory | one `bin/fm-mem-guard.py` `admission_sample()` reading: a waiting start may reuse one up to 2 s old, but each grant takes a new reading, with the process-count reading, so a signal that turns bad after a healthy read cannot admit |
| `held` | resident memory the counted runs hold now, summed over their process trees and never capped; a run the reading cannot see yet holds 0 | the same reading, keyed `no-mistakes:<repo_id>/<run id>` |

A counted run's resident memory appears in both `projected` and `budget`, so memory a run holds is never treated as free for new starts, and only the part of its reservation it does not hold yet must fit in `available_bytes`.
The open step is the highest-ordered `step_results` row in `running` or `fixing`, read with the run rows.
With no other counted run, one start is admitted even when the rule does not fit, a one-start minimum, so a large `S` or a low `available_bytes` never holds an idle host closed; the pause-only backstop below still pauses that start.
The admission and waiting lines print every input: the counted runs, each run's reservation and why (`reserved=[run:kind:bytes]`, `holding_only=[...]`, `:unseen` for a run the reading cannot see), the projection, the budget, `R`, `A`, `S` and the class.
The records belong to the host: they must name this host and its RAM size.
The owning home is `FM_HOME`, else the `FM_DURATION_HOME` that `bin/fm-spawn.sh` exports to workers, else the checkout holding the engine; a secondmate home reads its root home's records, found by `fm_firstmate_root_home` in `bin/fm-secondmate-parent-lib.sh`, the same walk the records' writer uses; a walk that fails takes the fallback below.

`R` and `S` are measurements, and taking the 75th percentile as `R` is a policy choice (Main 2473 ruling).
`A` is a measurement with no chosen margin: because `S` covers one run at the largest recorded peak, `k x A + S` is at least the summed run memory of every recorded reading with `k` runs, so the projection never falls below what the record measured in use together.
Measured on the root home's records of 2026-11-03 (373 readings, 347 of them with at least 2 runs): `A` is 1.82 GiB and `S` 13.39 GiB; the most run memory recorded at once was 20.1 GiB, with 10 and with 12 runs.
At 12 visible runs the projection is at least 12 x 1.82 + 13.39 = 35.2 GiB, against 88 GiB under the previous rule, which reserved `R` for every counted run at once.
The replay of every recorded reading against both rules, including the only pressure-2 episode (2026-11-02 21:11Z to 22:44Z), is in the task's private evidence; the pressure hold refuses every reading of that episode, and the rule alone never projects below the run memory a reading measured.
The protection still has residuals: a run admitted just before pressure rises is not visible in the reading until it registers and grows, and an agent that raises its own memory after it starts is bounded by the next decision and the pressure hold, not by its reservation.

Process count is not a reservation: a run's tree peaked at 34 processes against the host's 10,666 per-user cap, and every recorded pile-up was a runaway `bash` chain, not a run tree.
Processes appear only in the backstop below.

### Fallback

With fewer than 2 recorded runs left to rank for `R`, a calibration or readings record for another host or RAM size, an unreadable record, no recorded reading of this host with at least 2 runs for `A`, or no native memory facts on this platform, the start is admitted while `counted < max(1, floor(logical CPUs / 3))`.
That is the previous count limit, kept only until the host has measured runs; a missing record never refuses a start and never reads as an empty host.

### Pause-only backstop

While either signal reports an actual overload, or cannot be read, no new start is admitted and a notice names the reason:

- the memory reading is unreadable or would make `bin/fm-mem-guard.sh admit` exit 75 (native pressure level 2 or higher, or a required fact unavailable; `admission_evaluate` returns the same list);
- `bin/fm-proc-guard.py` reports a pile-up (user process count above its fixed 60 % warning line of the host's per-user cap, a proc-guard constant) or cannot read the count or, on macOS, the per-user cap.

Nothing running is stopped, paused or reprioritised.
This backstop covers the tail the reservation does not: a run that grows past what it reserves, memory used outside the runs, and process pile-ups.
It only delays a start; the unreadable run database or CPU count still refuses with 125.

### Launch gate

A run waiting on remote CI reserves nothing beyond what it holds, so its capacity is secured when its fix round resumes, before the fix agent starts.
`bin/fm-cpu-pass.sh launch-gate -- AGENT [ARGS...]` is the agent launcher's final exec: the daemon starts the launcher named by `agent_path_override` in `~/.no-mistakes/config.yaml` in the run worktree, and the launcher's last line `exec <firstmate>/bin/fm-cpu-pass.sh launch-gate -- <agent> "$@"` keeps the gate as the agent's parent.
The [engine header](../bin/fm-cpu-pass.py) owns its exact sequence, refusal text, hold bound and process hygiene; in short:

1. It maps its working directory to exactly one `runs.worktree_dir`; an unmapped or ambiguous directory or an unreadable database refuses, visibly, and never passes through.
2. A launch for any step other than `ci` runs the agent at once, unchanged, because that run is already counted.
3. A `ci` launch waits in this same class-ordered queue in class `other` and asks this same rule for one more active run, with its own run counted as a waiter.
4. On admission it publishes the run's reservation, a lock file it holds for the agent's life, under the start lock, then starts the agent at once without waiting for it to appear in memory, then releases the lock.
   Every later decision counts that run at `R` while it is invisible and at its resident memory or `A` afterwards, until the agent's process tree has exited.
5. It holds at most the daemon's per-invocation agent budget minus the 99th percentile of completed CI-fix invocation durations, and refuses at that bound.

A refusal exits 75 with one line naming the cause and the next action; the daemon logs it as `warning: CI fix failed` and does not fail the run.
Each refusal spends one of the run's `auto_fix.ci` attempts; after the last one the CI findings park as the ordinary ask-user decision, whose owner answers it once capacity has returned.
Every hold, admission after a hold and refusal also appends one check wake to the root home's wake queue, the durable record supervision drains.
The live launcher is captain-private host configuration outside this repository: the gate protects nothing until that one line is applied, and a fix-round agent launched through any other path is not gated.

Queued classes are ordered `merge-train`, `machinery`, `vernant-build`, then `other`, with arrival order within each class.
Admission never preempts an already granted start or stops running work.
The short start lock covers the observation-to-daemon-registration gap, so participating simultaneous starts cannot all spend the same observed headroom, and a burst of ready starts is admitted back to back while the formula fits, with no spacing between them.
The [engine header](../bin/fm-cpu-pass.py) owns the registration handoff, failure behavior and the limit of read-only coordination with starts that bypass it.
Unusable run-database, CPU-count, memory or process observations do not imply an empty host.

Every route that begins a new run joins this one queue, judged by the facts the no-mistakes CLI itself uses: `no-mistakes rerun` always creates a run, and `no-mistakes axi run` creates one only with an intent input (`--intent TEXT`, `--intent -`, `--intent-file PATH` or their `=` forms); without one it reattaches an active run or exits 2.
The engine's `fresh_pipeline_start` finds the `no-mistakes` binary at any position and by basename, so a wrapper prefix (`env`, `fm-mem-guard.sh run --`, an absolute path) does not hide a start, as `env ... fm-mem-guard.sh run -- no-mistakes axi run --intent-file ...` once did.
A shell's `-c` string, after the shell's other options (`bash -l -c`, `bash -o pipefail -c`), is read as a command line split at its control operators, newlines and redirections, so `cd x&&no-mistakes axi run --intent ...` is a start too.
`bin/fm-duration.py run` routes such a command through this owner before starting its execution clock; its `--pipeline-priority` option selects the class.
`bin/fm-mem-guard.sh run` hands its command to `pipeline-start --only-fresh` after its own memory reading: a new run queues in class `other`, and every other command runs unchanged.
Generated worker delivery instructions name both routes.
Existing-run reattachment, responses and status reads do not requeue, restart a run or consume another start.
Only the measured runner the owner re-executes skips a second admission, through an internal argument it consumes, and a wrapper inside an admitted command that routes the identical no-mistakes invocation again sees the digest the owner exports in `FM_PIPELINE_START_ADMITTED` and runs it without queueing twice; the wrapped client and every descendant receive no other exemption, so any other nested fresh start queues like any other.
The digest comes from the same reading that judges the start, so the outer and inner routes agree on a literal `-c` string.
A nested start the outer reading cannot see as the same one queues behind the outer start's lock: a `-c` string whose text a shell expansion changes (`~`, `$VAR`, `$(...)` or a glob), or a script that starts the run.
When that nested start is the outer start's only run, the outer never registers a run, so the wait never ends until someone stops it, and every later fresh start on the host waits behind it.
Every route resolves the same pool directory from `HOME`, so every home and worker of one user shares one queue; a home whose checkout predates this route does not ask the queue at all until that home is updated.
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
