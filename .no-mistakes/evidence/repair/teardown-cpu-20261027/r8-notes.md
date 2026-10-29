# Round 8 test-phase notes (HEAD 609f8093, no source change)

Driver: r8-wake-case-driver.sh (evidence dir only; runs the EXISTING case via the suite's FM_TEST_ONLY hook).
Observation overhead: bash builtin `time` around wait_for_exit (no fork); identical poll/TERM/KILL logic;
on timeout only: one extra is_live_non_zombie recheck + cp of case dirs BEFORE TERM (never triggered this round);
on EXIT: cp of TMP_ROOT before the suite's normal fm_test_cleanup. No ps/ancestry probes added, no traps in product.
Seeded mode: only state/open-loops.json = {"schema":"fm-open-loops.v1",generated_epoch=now,home,complete:true,rows:[]}
(same serialization as tests/fm-watch-open-loops.test.sh publish_ledger). Cadence markers untouched.
Note: tests/lib.sh exports FM_OPEN_LOOPS_BIN=/usr/bin/true, so the missing-ledger launch in this suite starts /usr/bin/true.

## Ledger counterfactual (sequential, one at a time, all assertions + wait_for_exit 40 unchanged)
| case | mode | rc | wait_for_exit wall | .open-loops-started |
|---|---|---|---|---|
| first-signal | original | 0 pass | 5.406s, 2.957s | present |
| first-signal | seeded | 0 pass | 2.924s, 2.775s | absent |
| stale | original | 0 pass | 2.619s | present |
| stale | seeded | 0 pass | 3.749s | absent |
| not-working stale | original | 0 pass | 3.329s | present |
| not-working stale | seeded | 0 pass | 5.206s | absent |
Result: no reproduction in any run; seeding was faster in 1 of 3 and slower in 2 of 3.
The ledger hypothesis is NOT supported. No fixture repair retained. No timeout snapshot exists (no timeout occurred),
so the final-sleep-gap counterfactual has no supporting evidence and was NOT applied.

## Presentation (predeclared N=3, original, all retained)
See r8-presentation-samples.txt. 3/3 pass. No failing held invocation captured, so no same-invocation localization possible.
Queue-held drains (1.3s) were faster than their no-holder controls (2.6-3.5s) in all 3 samples; no-holder controls varied 2181-4810ms.
Prior evidence (kept, contradictory): r6 13092 vs 3296 fail; round2 22943 vs 3490 fail; earlier 10649 vs 6724 fail;
r6 paired base 7b5c75cc presentation held 7128 vs control 8136; fm-wake-queue-at-base-main.log shows first-signal timeout at base.
Missing observation: same-invocation boundary timing inside a FAILING held drain (needs temporary private drain instrumentation; not done).
Drain sources bin/fm-timeout-lib.sh, but its new process recording is inactive unless FM_TEST_PROCESS_RECORD is set (home-summary trees only); drain does not launch home-summary refresh; fm-guard.sh diagnostics are gated off without opt-in. Source reading only, not a timing proof.

## Full suite (unchanged, one run, started 01:46:04)
In-suite timing: queue held=1396ms control=2484ms; presentation held=3405ms control=3943ms (within margin). Terminal status: see r8-fm-wake-queue-full.meta when written.
RESULT: exit=1 at 01:52:17 (load 1m 57.81). 22 ok, then FAIL test_not_working_stale_enqueue_before_suppressor: wait_for_exit owned pid 70260 exceeded 40 polls; ps at timeout: "70260 49443 S bash .../bin/fm-watch.sh" (watcher LIVE, non-zombie) -> final-sleep-gap explanation disfavored; suite stopped at first failure. Same case passed in isolation this round (orig 3.329s, seeded 5.206s). No fixture state was retained before TERM in the full run (unmodified suite).
