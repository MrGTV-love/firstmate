# Serial hint refresh (Main decision 020, option d)

Date: 2026-10-24. Branch: fm/fm-control-reattribute-endpoints-after-reboot, on top of c679e6b1e.

## Source runs (newest three green CI runs on main)

- 40121540044 (head cced61811, the base commit)
- 40121241146 (head f6b1ab9c9)
- 40106598762 (head 30f233bc9)

Each run's 20 `fm-test-timing-portable-serial-*` artifacts are in `artifacts/<run>/`. All 60 shard summaries report `failed=0`.

## Policy applied (docs/fm-test-portable-shards.md, refresh procedure)

- For every path: the slowest `duration_ms` with `exit == 0` across the three runs (`measured-max.txt`).
- Every sample, with its source file: `all-samples.tsv`.
- All 304 serial members were measured in all three runs. All 302 old hints were replaced. The two members with no hint (`fm-jev-guard-producer`, `fm-work-progress`) were added.
- Old table: `table-before.txt`. New table: `table-after.txt`. Per path old and new: `final-old-vs-new.txt`.
- Result: 173 hints rose, 128 fell, 1 stayed, and 2 were new.

## Two documented exceptions

1. `tests/fm-pi-windows-shell-invocation.test.sh` keeps 5121 ms. The policy says native-Windows-only scripts keep their separate measurement. CI only records its capability skip (749 to 981 ms, `gate_skip=true`, "native Windows Node required").
2. `tests/fm-control-relaunch-backends.test.sh`: the main samples have no adopt cases, because main does not have them yet.
   - Main samples: 399970, 514105, 504740 ms. Slowest: 514105 ms (run 40121241146).
   - Adopt factor (local macOS estimate, not CI): the whole group took 639 s, and 576 s without the adopt case. The adopt case took 63 s there. It is scaled to 67.46 s for the later reused-PID test, using a local run of the case alone: 54.4 s with that test, 50.8 s without it (`../packing-budget/adoption-case-timed-run.txt`).
   - Hint: 514105 x (576 + 67.46) / 576 = 574316 ms.

## Control-relaunch groups (old hint -> new hint)

| Group | Old | New | Main samples |
|---|---|---|---|
| fm-control-relaunch.test.sh | 236000 | 294441 | 294441, 281827, 290495 |
| fm-control-relaunch-recovery.test.sh | 389000 | 405144 | 398280, 405144, 399384 |
| fm-control-relaunch-backends.test.sh | 537402 | 574316 | 399970, 514105, 504740 (+ adopt factor) |

## Totals and packing

- Serial hint sum before: 24016125 ms. After: 23336104 ms. The cap is 20 x 1200000 = 24000000 ms.
- `--check-coverage` passes (`check-coverage-after.txt`): `serial_max_ms=1167127`, `serial_budget_ms=1200000`, 20 shards, `serial_unhinted=0`.
- Per-shard sums: `per-shard-packing-after.tsv`. They range from 1166553 to 1167127 ms.
- The limit, the shard count, and the parallel lanes did not change.
