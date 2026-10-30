# Live evidence at commit 19d052be0 (test round for the final branch head)

The files one folder up are from an earlier commit of this branch. This folder
holds the new evidence for the current head.

Every live run below drives the REAL scripts in `bin/` from the gate worktree
against throwaway homes (temp git origin, project clone, task copy, state dir,
pool, real SQLite run record). Stand-ins: the no-mistakes daemon CLI, the forge
CLIs (`gh-axi`, `glab`), `treehouse`, `tmux`, and (inactive-reconcile only)
`fm-crew-state.sh`. The SQLite lock in L1 and the reaper run is a real
exclusive lock. Drivers built on test helpers are generated from that test
file without its runner. Before/after replays extract the old `bin/` and
`tests/` with `git archive` into a temp dir.

| File | What it shows |
|---|---|
| `live-teardown/transcript.txt` | L1a locked run record: exit 75 "unknown", no REFUSED, no guard event. L1b answered record: REFUSED + teardown-unlanded deny (harm still caught). L2a silent daemon: exit 75 UNKNOWN "nothing more was closed". L2b `--force`: goes on, writes `no-mistakes-unknown.log`. L3 CPU-busy daemon 20 s vs 5 s stall: not cut, run aborted. L4 `--force`, 2 roots (nested copy + slot), stall 8 s: ONE silent read, 16 s wall (R1 latch). L5 no `--force`, root 1 run aborted, root 2 silent: exit 75, "nothing more was closed" (R3-1). L6 secondmate home, report-step gate read silent: exit 75 UNKNOWN, nothing delivered; `--force`: delivered marked "(acceptance unknown: no-mistakes read stalled)". |
| `live-teardown-L6-reruns.txt` | The first L6 run took 68 s per teardown with a 3 s stall. Five reruns took 7 to 8 s, with the same result. |
| `live-reap/transcript.txt` | Real `fm-idle-session-reap.sh reap` over a locked record: `lock-skipped`, no `.refused` memo, no deny event. The next pass, after the lock is released: refused + memo. |
| `live-merge-prune.txt` | Real `fm-merge-prune.sh` running the real teardown. MP1 silent daemon, prune stall 6 s < teardown read stall 15 s: the prune does NOT cut teardown; teardown exits 75 and the retry reason is the UNKNOWN line. MP1b daemon answers: the retry reaps. MP2 daemon quiet 25 s then answers (prune stall 6 s): not cut, reaped. |
| `live-inactive-reconcile.txt` | IR1 `report` gives 75 for an unknown acceptance; `report --force` delivers it marked unknown. IR2 `scan --startup` behind a REAL watcher scan stuck on a silent gate read: returns in 2.6 s (budget 3 s), no pass. IR3 child a's lock held, b slow: child c is reached on scan 2. |
| `live-inactive-reconcile-before-02b291521.txt` | Same IR2/IR3 on `02b291521`: the startup scan waited 63.8 s; c was NEVER reached in 5 scans (the cursor froze). |
| `live-crew-state.txt` | Real `fm-crew-state.sh`, only `FM_CREW_STATE_NM_TIMEOUT=3`: the silent completion-gate read stops after about 4 s. State is unknown, not blocked. |
| `live-crew-state-noperl.txt` / `-before.txt` | Real `fm-crew-state.sh` on a PATH with no perl: "PR open" now; "PR state unknown (unreadable)" on `c4b00ad04` (before the R2 fix). |
| `tests/*.log` | Focused existing test files for the changed scripts. |
| `drivers/*.sh` | The driver scripts used. |
