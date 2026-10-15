# Live lab: project-lock hold times, base vs this branch

Host: macOS arm64, 18 CPUs, load average about 8 during the runs (2026-10-15 17:39-17:46 CDT).
Treehouse v2.3.1-fm.e58947de (installed), real tmux 3.x on a private lab socket, real git with a local bare origin.
Lab home minted with `bin/fm-lab-home.sh create`; pool isolated with `TREEHOUSE_ROOT=<lab>/work/pool`.
Every task is a real `bin/fm-spawn.sh` launch (raw launch command `bash -c "sleep 3600" fm-worker __BRIEF__`, so no model runs) and a real `bin/fm-teardown.sh` (no --force).
Base code = `git archive 8221de43` extracted into the lab; head code = this worktree at 540c9690.
Lock samples come from `lockwatch.sh` (50 ms polling of the project lock directory and its pid file); the product's own `.holds` log is copied as `lab/project-lock.holds`.

## Teardown lock hold (one teardown each, worker process still running, so teardown reaps it)

| Code | Teardown wall time | Project lock holds | Total held |
|------|--------------------|--------------------|-----------|
| base 8221de43 (run-base) | 9.87 s | one hold, 9.44 s | 9.44 s |
| base 8221de43 (run-base2) | 9.60 s | one hold, 9.17 s | 9.17 s |
| head 540c9690 (run-head) | 11.55 s | 0.18 s + 0.24 s + 0.58 s | 1.00 s |
| head 540c9690 (run-head2) | 11.93 s | 0.17 s + 0.24 s + 0.47 s | 0.88 s |
| head 540c9690 (td-sa, standalone) | 11.36 s | 0.18 s + 0.29 s + 0.58 s | 1.05 s |

## Fresh spawn started 1 s after teardown first takes the lock (same trigger both runs)

| Code | Spawn started | Spawn took the lock | Spawn finished | Teardown still running when spawn finished? |
|------|---------------|---------------------|----------------|----------------------------------------------|
| base (run-base2: teardown sf, spawn sg) | +1.45 s | after 9.1 s wait (when teardown released) | 13.68 s after start | no - spawn finished 5.5 s after teardown ended |
| head (run-head2: teardown sh, spawn si) | +2.51 s | 1.3 s later (its pre-lock base fetch, no wait) | 7.27 s after start | yes - teardown ended 2.1 s later |

In both head races the new spawn got a different slot (slot 2) while the retiring slot (slot 1) was durably leased by teardown; no slot was double-leased and the retiring slot was returned only after its processes were reaped.

## Reservation-window races (teardown paused with SIGSTOP right after its first lock hold, a real fresh spawn runs, teardown resumed)

- run-win-landed (scout sj retiring, scout sk fresh): Treehouse gave sk the same slot 1 and sk replaced the claim. Resumed teardown printed the reassigned warning, exit 0, retired only sj (meta removed, backlog Done). Slot 1 kept sk's claim and live process lease (owner_pid 57104, `treehouse status` in-use); slot not returned, no refusal.
- run-win-unlanded / -pushed / -detached (ship la with an unlanded commit 3111d89, scouts sl/sm/sn fresh): installed Treehouse never handed out la's slot (it holds a commit not on the base), so each fresh spawn got a new slot (4, 5, 6). Teardown refused every time ("the ship deliverable is not landed"), exit 1, la.meta and its In-flight backlog row kept, la's commit and claim untouched. The exact R15-1 interleaving (fresh spawn resetting a slot that holds unlanded work) cannot be formed with this Treehouse; tests/fm-teardown.test.sh `test_reservation_window_reassignment_reproves_own_landing` covers it with a modeled allocator and passes.
