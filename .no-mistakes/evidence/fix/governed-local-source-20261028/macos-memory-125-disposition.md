# macOS test_memory_tree_over_limit 125: Test-phase disposition

Head: 9609c7169f6c27f3b74fa51f92bd0fdc6cfbf0ce. Host: Darwin 27.0.0 arm64.
Python: pyenv 3.13.6 (/Users/charlesabrooker/.pyenv/versions/3.13.6/bin/python3).
Context: the native no-mistakes Test agent, this run (01M64MA08ACXYHWXY8R4SJ7ZMA).

## Disposition: UNRESOLVED (causal closure not proven)

A new sufficient producer was reproduced, but the original stderr is lost, so it
cannot be bound to the historical failure.

## What ran (public executable interfaces only)

1. `bash tests/fm-proc-budget.test.sh` full file, beside fm-task-delivery:
   exit 0, 37 ok (proc-budget-run1.log). Memory case: 99.
2. Same full file beside the full `tests/fm-test-run.test.sh`: exit 0, 37 ok
   (proc-budget-run2-concurrent.log). Memory case: 99.
3. memory-headroom-counterfactual.sh / memory-headroom-sweep.sh: the exact test
   payload through the public nested wrapper (outer 2 GiB, inner 128 MiB),
   behind a fork-free FIFO gate. One condition varies: sleeping processes of
   the SAME user, started OUTSIDE the wrapped tree after the outer wrapper set
   its limit.

## Established mechanism (reproduced)

- Every `fm-proc-budget.sh` call, including `--memory-kib`, applies the default
  own-process budget: RLIMIT_NPROC = (this user's process count at start) + 1500.
- RLIMIT_NPROC on macOS counts ALL processes of the uid. Other same-user
  processes started later (a concurrent full test run, other agents) spend the
  wrapped tree's headroom.
- Control arm: 99 in every trial (3 + 3 + 2 trials).
- Headroom fully consumed: 128 in 3/3 (bash `fork: Resource temporarily
  unavailable` in the inner wrapper).
- Headroom near the edge, with normal host churn: one trial gave **125** with
  stderr `fm-proc-budget.sh: fork: Resource temporarily unavailable` (x2) then
  `fm-proc-budget: cannot start memory reader; command not started`
  (bin/fm-proc-budget.sh:228-230 after the FM_PROC_BUDGET_DIR substitution at
  :113 failed to fork). One other edge trial gave 128. The rest gave 99.
- Trigger: other same-user processes grow by about 1500 after the outer wrapper
  starts. Mask: on a quiet host the count swing is small (this run: about 300
  peak swing at load 12-16 during a concurrent full fm-test-run). Symptom: 125
  or 128 instead of 99.

## Limits and unknowns

- The historical stderr was lost, so it is unknown whether the historical 125
  came from this path or from another allowed 125 producer (reader timeout at
  REPLY_SECONDS=0.5, unreadable sample, cleanup_error).
- The historical host's same-user process count during that run is unknown.
- No code was changed. Any remedy (for example a different budget for the
  memory test, or a memory mode that does not apply the per-user process
  budget) changes test or wrapper semantics and needs a human decision.
