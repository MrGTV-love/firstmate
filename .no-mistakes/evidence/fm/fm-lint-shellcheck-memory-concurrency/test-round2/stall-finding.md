# New finding: host-pool admission stalls when `ps` is slow and the budget keeps a deep queue

Observed 2026-11-04 about 12:18-12:45 local time, worktree head 0818f43f0 plus the T1 test-only edit (no product code changed).
Host load average 98 to 110 on 18 CPUs; other fleet lint runs were active.
Snapshot of the stalled state: `stall-snapshot.txt` (same directory).

## What was observed
- Test: `bash tests/fm-lint-slots.test.sh test_memory_budget_bounds_the_aggregate_across_homes`, cold step (four runs, four HOMEs, shared pool `.../fm-lint-memory-budget.rVkeZf/shared`, budget = 2.5 x the recorded 137856 KiB stand-in peak).
- In about 25 minutes, 3 of the 12 cold roots started (`mem.starts.spans`: the last start at 1793816636, then none).
- For about 20 minutes no slot was held: `lsof` showed no process holding `slot.0` except a waiter that was probing it. The gate pid in `slot.0` (25841) was dead. The pool was empty, and "an empty pool always admits one root".
- 7 waiter gates were queued (tickets 4 to 10, runs 4716, 4743, 4758 and 4830).
- One waiter that was not first in line (27755, ticket 7) had all 9 slot files open, with a `ps` child running. Each of the other waiters also had a `ps` child running (`(ps)` or `ps -axww -o pid=,stat=,command=`), 4 to 6 s old.
- `ps -axww -o pid=,stat=,command=` took 3.92 s on this host. `ps -axo pid=,ppid=,rss=` took 0.49 s.
- I stopped the run with TERM to the four `fm-lint.sh` pids. The test then reported `not ok - a stand-in lint run failed (rc=143)`.

## Likely mechanism (inferred; lsof does not show which process holds the admission.lock flock)
- `bin/fm-lint-cache.pl` gate: when a free count slot exists and the head ticket is another request's, each waiter runs `$stopped_owners` (a `ps` call) after 1 s, inside its locked scan (the `elsif (defined $next)` branch). It holds `admission.lock` while that `ps` runs.
- A waiter that has been blocked on `admission.lock` for 1 s runs `$stopped_gate` (`ps -axww`, 3.9 s here) outside the lock.
- So the head request spends most of its time in its own slow `ps`. When it tries the lock, a waiter that is not first in line often holds the lock for a whole `ps` call. The head rarely gets the lock, so admission nearly stops.
- Base 9c5874baa has the same two `ps` paths. But on base, 8 gates fit under the count cap of 9 and no request waits. With the memory budget, a free count slot that the budget cannot use is normal, and the queue is deep. So the budget exposes this path all the time.

## Why it matters
- Nothing bounds this wait. Queue time does not count against the root deadline (by design), so a lint step can wait without limit.
- The cited real runs cannot show this. `m3.md` records `Can't exec "ps": Operation not permitted` from the stopped-owner check. In that sandbox `ps` failed fast, so the slow-`ps` path was never exercised.
- This is not caused by the T1 test edit, which changes only `tests/fm-lint-slots.test.sh`.

## Not done here
- No product fix. The recorded rulings make T1 test-only and require "no admission-model change". A fix (for example, no `ps` call while `admission.lock` is held, or fewer calls) needs the owner's decision.
