# Live evidence: supervisor reads that run out of time say "unknown"

All live runs drive the real scripts in `bin/` from the gate worktree against
throwaway task homes (temp git origin, project clone, task copy, state dir, real
SQLite run record). Stand-ins: the forge CLI (`gh-axi`), the no-mistakes daemon
CLI, and (crew-state only) a tmux pane. The SQLite lock in L1 and the reaper run
is a real exclusive lock; the reader runs SQLite's real 30 s busy wait.

| File | What it shows |
|---|---|
| `live-after/transcript.txt` | L1a locked record -> exit 75 "unknown", no REFUSED, no guard event. L1b answered record -> REFUSED + teardown-unlanded deny. L2a silent daemon -> exit 75 UNKNOWN. L2b `--force` -> goes on, records `no-mistakes-unknown.log`, one silent read only. L3 slow CPU-busy daemon (20 s vs 5 s stall) -> not cut, parked run aborted. |
| `live-before-R4-1/transcript.txt` | Same L1a on commit `0414e3c1b^`: the locked read was a REFUSED + deny (the bug R4-1 fixed). |
| `live-reap/transcript.txt` | Real `fm-idle-session-reap.sh reap` -> real teardown on a locked record: `lock-skipped`, no `.refused` memo, no deny; next pass with the answer -> refused + memo. |
| `live-crew-state/after.txt` | Real `fm-crew-state.sh` with only `FM_CREW_STATE_NM_TIMEOUT=3`: the completion gate's silent read stops at ~4 s, state unknown. |
| `live-crew-state/before-R4-3.txt` | Same on `0414e3c1b^`: the read was still waiting at 313 s. |
| `tests/*.log` | Focused existing test cases for the changed behavior. |
| `drivers/*.sh` | The driver scripts used. |
