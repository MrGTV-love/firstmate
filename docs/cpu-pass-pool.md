# CPU pass pool

The CPU pass pool is one host-wide budget for CPU-heavy test bursts.
A test script, a parallel test worker, or a load test takes a pass before it runs and returns it when it ends.
When every pass is held, the next burst waits for one instead of adding to the run queue.

The pool bounds bursts, not agents.
Interactive agents, lanes, and sessions never ask for a pass and are never queued or capped.
Only the work that swings host load - suites sized to every core in every copy, parallel test workers, deliberate load generation - takes turns.

This page owns the cross-repository protocol.
`bin/fm-cpu-pass.sh` is its reference implementation, and its engine header (`bin/fm-cpu-pass.py`, also `bin/fm-cpu-pass.sh --help`) owns the command's waiting, notice, signal, and exit-status behavior.

## Why file locks

The pool uses Python's standard-library `fcntl.flock` over one lock file per pass, not GNU parallel's `sem`.
A kernel file lock is released when its last owning descriptor closes, including on `SIGKILL`, so the work inherits its slot descriptors and retains the reservation even if its wrapper dies.
When the work ends its descriptors close, so the pool has no stale state to repair; `sem` keeps its own bookkeeping that must notice dead holders.
`python3` is already a runtime dependency of Firstmate's runner and of the Python projects that will join the pool, so the pool adds no new install, while `sem` would add Perl-based GNU parallel and its citation prompt to every host and CI image.
Any language with `flock` can join the protocol below without calling a Firstmate script.

## Protocol

Every participant on a host follows these rules, so one pool is shared by every Firstmate home, worktree, and repository of the same user.

1. **Directory:** `FM_CPU_POOL_DIR` when set, else `$HOME/.cache/fm-cpu-pool`, created with mode `0700` and owned by the user.
2. **Size:** the host's logical CPU count (`os.cpu_count()`, which is `hw.ncpu` on macOS), with no environment override.
   Load average does not shrink the pool: it includes interactive sessions that never take passes, so a load-based gate would hold tests back indefinitely on a host whose baseline load comes from idle sessions.
3. **Passes:** pass `i` is an exclusive, non-blocking `flock` on `slot-<i>.lock` for `i` in `0..size-1`.
   The work inherits the slot lock descriptors, so wrapper death cannot release its reservation while it still runs.
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
   Nested work never runs more concurrent CPU-bound workers than the inherited count; a caller needing parallel nested work reserves enough passes before starting the outer work.
   Firstmate's runner reduces concurrency to the inherited count and reports the reduction on its notice fd; an explicit pass request above that count is a usage error.
   The marker must be a nonnegative decimal integer in both Python and no-Python execution; a malformed marker is a usage error, while `0` denotes degraded work with no reservation or concurrency limit.
7. **Degrade, never block:** a participant that cannot use the pool (no `flock`, no pool directory, a foreign-owned directory) runs its work without a pass and says so once.
   Degradation notices use `--log-fd` (default stderr), separate from the work's stdout, including when Python is unavailable.
   The pool governs throughput; it is not a safety boundary, and a broken pool must not stop every test on the host.
8. **Waiting stays outside work bounds:** take passes before starting any per-test or per-worker timeout, so time spent queued never counts toward that timeout.
   A caller's own overall budget, such as a harness command limit, still includes the wait.

## Calling it

From a shell, with Firstmate's `bin/` reachable:

```sh
workers=$(bin/fm-cpu-pass.sh size)
bin/fm-cpu-pass.sh run --passes "$workers" --label "my-suite" -- pytest -n "$workers"
bin/fm-cpu-pass.sh status
bin/fm-cpu-pass.sh size
```

A repository that cannot assume a Firstmate checkout implements the protocol directly with its language's `flock`, as rules 1-8 describe.
Firstmate's own `bin/fm-test-run.sh` takes one pass per executed test script, outside its per-script bound, and runs directly when it is already inside a pass; its header owns that wiring.

## Phase 1 cutover

F6 is installed and live on this host since 2026-10-08 00:54 in the private no-mistakes build `v1.86.1-private.f6.20261008`.
Its gate overlay disables the omp advisor and eager sub-agents for pipeline agents only.
This change delivers the Firstmate side of Phase 1: the pool, `fm-test-run.sh` wiring, the cross-repository contract, and the measurement recipe.
Phase 1 completes only when the Vernant participant lands as a separate Vernant-repository change, tracked as backlog item `vernant-cpu-pass-pool-participation`, alongside this Firstmate change and the live F6 overlay.

## Judging the pool

`bin/fm-load-report.sh` records host load and reads pipeline agent durations so a change to the pool can be judged on data; its engine header owns the sample format and verdict rules.

1. Only once Phase 1 is complete, note the time with `date +%s` and start one recorder per host: `nohup bin/fm-load-report.sh watch --interval 60 >/dev/null 2>&1 &`.
2. After 24 to 48 hours of normal fleet work, run `bin/fm-load-report.sh report --since <that epoch>`.
3. Read its two verdicts: `load_within_2x_cpus` (1-minute load p95 at or under twice the CPU count) and `converged_within_2_fix_rounds` (the fixed first ten pipeline runs that reached review and were created after the recorded cutover epoch, ordered by creation time then run id, completed successfully with at most two review-fix rounds and none hit a timeout).
   Failed and cancelled cohort members count as not converged.
   The convergence verdict is pending (`null` in JSON, `pending` in text) until ten review-reaching runs exist and every pending or running run that sorts at or before the tenth member is terminal, including runs that have not reached review yet.
   Once those earlier runs are terminal, cohort membership and the true or false verdict are fixed; later-created runs do not change them.
   Its list of timeout-class run errors should be empty.
4. Stop the recorder when the window closes.
