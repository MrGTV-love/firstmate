# Test round 2: T1 and test-4

Head: 0818f43f02547ab30bc9ccc9399706aa3c34f396, plus one uncommitted test-only edit to `tests/fm-lint-slots.test.sh` (`git diff --name-only` lists only that file).
Index of every command run: `index.txt`.

## T1 (test_memory_budget_bounds_the_aggregate_across_homes)

Reproduced before the edit: `bash tests/fm-lint-slots.test.sh test_memory_budget_bounds_the_aggregate_across_homes`
-> `not ok - four unbudgeted runs peaked at only 407808 KiB, so this test cannot show a bound: 407808 3 12`.
The ps sampler saw only 3 stand-ins at once where 8 run, because `ps` is slow on this host.

Edit (test-only):
1. The stand-in writes `<pid> <held from> <held until>` (Time::HiRes) to `<start-log>.spans` when it ends.
2. `fm_lint_memory_runs` has no ps sampler. It prints `<peak concurrent> <started>`. The peak concurrent count comes from a sweep over the spans.
3. The test computes the aggregate as `most x record`, where `record` is the stand-in peak that the pool recorded. The budget (2.5 x record) uses the same unit. A serial admission gives no overlap, so `most=1` and the test still fails.
4. The lone step holds the memory for 8 s, not 1.5 s.

Why the lone step failed (measured):
- After the switch to timestamps, the lone step still failed once (`not ok - a lone run with recorded roots peaked at 1 stand-ins ...: 1 3`).
- With a temporary debug line in the gate (now reverted), 8 lone runs logged 0 refusals (`fits=0` count 0), and 2 of 7 runs were serial. So the budget did not hold the second root back.
- Telemetry runs (`lone-hold4-telemetry.log`) show the second root starting 0.17 s to 2.28 s after the first at load average about 57. Cause: the admission and start latency of the second worker was longer than the 1.5 s hold. I do not split this into worker start versus the gate's own reads.
- At a 4 s hold, 1 of 6 runs was still serial (`lone-hold4-driver.log`, load average about 100). So the hold is now 8 s.

Result at the final edit:
- `budget-final.log`: ok, 248 s (unbudgeted: 8 12; no records: 2 12; records: 2 12).
- `budget-final2.log`: ok, 128 s (same counts).

## test-4: scenarios driven live in this sandbox (stand-in ShellCheck through the real bin/fm-lint.sh and gate)

| Scenario | Command | Result |
|---|---|---|
| Four HOMEs stay within the budget and finish every root | `bash tests/fm-lint-slots.test.sh test_memory_budget_bounds_the_aggregate_across_homes` | pass x2 (`budget-final.log`, `budget-final2.log`); one earlier run stalled, see `stall-finding.md` |
| A root larger than the budget runs alone; a killed run frees its charge | `... test_root_larger_than_the_budget_runs_alone_and_a_killed_run_frees_its_charge` | pass, 373 s |
| Unknown records, an unreadable table and a signalled gate charge the worst case | `... test_memory_charge_survives_unknown_records_and_an_unreadable_table` | pass, 80 s |
| A --fast record does not lower the full charge | `... test_fast_record_does_not_lower_the_full_charge` | pass, 162 s |
| One default pool for every HOME | `... test_default_pool_is_one_directory_for_every_home` | pass, 112 s |
| An over-bound root is ended and retried narrower | `... test_unbounded_root_over_resident_bound_is_ended_and_retried_narrower` | FAIL, 103 s: `the root was not ended at the bound: lint waited out the growing process` (the 15 s wall check; this is T2, which the user chose to ignore) |

## Cited, not driven here (read and confirmed on 2026-11-04)
- Real ShellCheck, two runs: `/Users/charlesabrooker/firstmate/data/fm-lint-shellcheck-memory-concurrency/evidence/m3.md` lines 27-39 (461 roots, aggregate max(rss, footprint) 9.46 GiB, 0 of 2737 samples over 12 GiB). Measured at f5796a05, not this head. In that sandbox `ps` was refused, so the slow-`ps` stall below was not exercised.
- Cold lint before and after: `.../evidence/m5.md` lines 7-11 (before 841.7 s; new design 1435.3 s with an empty history, 857.5 s with history) and `.../evidence/m2.md` (first design: 841.67 s before, 534.79 s after, 13.49 GiB both).

## New finding (not fixed: the rulings make T1 test-only and require no admission-model change)
`stall-finding.md`: on this host, with `ps -axww` at 3.9 s and 7 queued waiters, admission nearly stopped (3 of 12 roots in about 25 minutes, with an empty pool). Nothing bounds that wait.
