# macOS test_memory_tree_over_limit 125: Test round 2 disposition

Head: 9609c7169f6c27f3b74fa51f92bd0fdc6cfbf0ce (unchanged since round 1; no code edits).
Context: native no-mistakes Test agent, run 01M64MA08ACXYHWXY8R4SJ7ZMA, round 2.
Python: pyenv 3.13.6.

## Disposition: UNRESOLVED (no causal closure)

Round 2 results (public interfaces only):
1. proc-budget-concurrent.log: full tests/fm-proc-budget.test.sh beside the full
   tests/fm-test-run.test.sh and full tests/fm-task-delivery.test.sh: EXIT=0, 37 ok,
   memory case 99.
2. proc-budget-solo.log: same file alone: EXIT=0, 37 ok, memory case 99.
3. memory-headroom-counterfactual.log: exact payload through the public nested
   wrapper. Control arm 99 in 2/2. Consume arm (1700 same-user sleepers started
   outside the tree after the outer limit was set) 128 in 2/2, with
   "fork: Resource temporarily unavailable"; the payload never started (no pids).

Round 1 also saw one edge trial give 125 with
"cannot start memory reader; command not started" (round-1 memory-headroom-sweep.log).

## What this means
- The wrapper fails closed under same-user fork exhaustion (125/128, never a false 99,
  payload not run). That matches the documented internal-error contract.
- The test's 99 expectation depends on same-user process headroom
  (RLIMIT_NPROC = user count at outer start + 1500, counted per uid on macOS).
  That is a sufficient producer of the historical 125, not a proven one.
- The original stderr is lost. Other allowed 125 producers (reader reply over
  REPLY_SECONDS=0.5, unreadable sample, cleanup_error) are not excluded.
- Any remedy changes test or wrapper semantics. A human must decide.
