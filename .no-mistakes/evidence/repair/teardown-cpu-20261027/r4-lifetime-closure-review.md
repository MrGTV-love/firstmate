# Round 4 fixture-lifetime closure review

Status: read-only factual review. No tests, product experiments, signals, AXI, or implementation. New private evidence only.

Committed fix inspected: `c1361cdac93d5cc557393b213da46985e9796416` (`no-mistakes(test): Wait for detached summary writers before fixture cleanup`), worktree HEAD c1361, clean except untracked `.nm-test-scratch/`. The committed diff is the same implementation inspected as mutable WIP.

## What the committed fix does

- `home_summary_register` writes a pid/start pidfile and a `wait` registry entry: `bin/fm-home-summary-refresh.sh:125-138`.
- Registration runs only for `--_worker` and non-detached parent mode: `:154-160`.
- The detached parent waits for its own registration before `--detach` returns: `:405-421`.
- `fm_test_wait_processes` waits for exact pid/start and `kill -0 -- -$pid` group absence: `tests/lib.sh:385-408`; cleanup fails and retains roots at the bound: `:460-472`.

## Gaps that remain in c1361

1. Nested modes remain unregistered. `--_log-failure`, `--_note-failure`, `--_release-lock` bypass the registration conditional at `bin/fm-home-summary-refresh.sh:154`, then source `fm-wake-lib.sh` at `:162`, whose line 51 creates the state directory. They are launched through `fm_run_timed` at `:454`, `:458`, and `:373`. If the detached parent is interrupted while one runs, cleanup has no record for it and can remove the root while that child can still create state.

2. Parent interruption before delayed worker registration remains. `--detach` waits only for the detached parent registration. The parent later starts the progress worker. If the parent dies after spawning work but before the worker’s registration append, `fm_test_wait_processes` can see the parent gone, remove its pidfile, observe no live entry, and remove the root while the worker is between spawn and registration. Re-reading the registry does not wait for a future entry.

3. PID-keyed record reuse remains. `record="$registry.$$"` at `:129` is keyed by PID, not by launch. A stale wait entry and a reused PID share the same pidfile path; the new process can overwrite the start identity or a stale entry can wait on a different new group. This is not per-launch ownership.

4. Child-group coverage remains incomplete. `fm_test_wait_processes` checks only `-$pid` for each recorded leader. `fm_duration.py` starts the worker with `start_new_session=True` (`bin/fm-duration.py:1079`), and on normal leader exit it does not wait for descendants (`:1164-1167`). The new test’s `assert_recorded_writers_gone` likewise checks only `kill -0 -- -$pid`. A descendant in another group is outside the wait.

The implementer’s acknowledged nested-group gap is real. The separate delayed-registration gap also defeats any general “group reuse can never delete too early” safety claim: a future worker can register after cleanup has already observed no live entries, so no existing group record can protect it.

## Evidence posture

- Four new lifecycle tests passed and failed the old implementation; four selected A/B runs exited 0.
- Those are positive-path lifecycle evidence, not closure. They do not exercise nested log/note/release modes, parent interruption before delayed worker registration, PID reuse, or descendant groups.

## Minimal corrections, proposals only

- Register every non-detached mode that sources wake-lib before source, especially `log-failure`, `note-failure`, and `release-lock`, using the existing registry.
- Replace `$registry.$$` with a unique `mktemp` record path per launch; carry that exact record through registration and waiting.
- Add a durable prelaunch reservation/worker-registration barrier so a future worker cannot appear after cleanup has seen no live entries.
- Record and wait on birth-aware group ownership, not merely `-$pid`; explicitly cover or reject descendant groups.

Merely delaying `--detach` return until the first worker registers does not fix later-loop worker launches or parent interruption universally.

Historical PID 45450 remains unattributed. This note does not claim external-producer or all-189-launch closure.
