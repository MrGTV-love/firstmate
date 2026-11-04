# Test round 3, final head bfc0c27b08e090c1aaf320e0f96dc613328ffaef
Product code at this head equals 0818f43f0: `git diff 0818f43f0..HEAD` lists only `tests/fm-lint-slots.test.sh`.

## Scenario tests, real bin/fm-lint.sh and gate with a stand-in ShellCheck
Runner: `run-tests.sh`. Index: `index.txt`. One log per test, each with its command, load and result.

## Base versus head, real ShellCheck
`m4-identity.txt`: `--list-files`, each `--partition`, a clean fixture, a findings fixture, and `--fast` give identical output and exit codes (clean 0, findings 1).

## Four HOMEs, real ShellCheck, three roots of about 280 MiB
Script: `real-four-home.sh`. Result: `real-four-home.txt`, per-phase logs beside it.
Measure: each analysis logs its own start, end and maximum resident size. The figure is the largest sum over overlapping analyses.
- No budget: 2240592 KiB, 8 at once (budget used later 735360 KiB).
- Budget, empty history: 562448 KiB, 2 at once, within 735360 KiB, 12 of 12 roots.
- Budget, with history: 562448 KiB, 2 at once, within 735360 KiB, 12 of 12 roots.

## Admission progress when ps is slow (FAIL)
Rule, set before any result: `stall-rule.txt`. Driver: `stall-driver.sh`. Table: `stall-table.txt`. One file per run: `stall-*.txt`. Snapshot of an empty pool with queued waiters: `stall-snapshots-head-slow-p4.txt`.
The delays are added to real /bin/ps through a PATH shim: `-axww` 4 s, the `-p` call 0.5 s or 4 s, `-axo` 0.5 s. Round 2 measured `-axww` at 3.92 s and `-axo` at 0.49 s on this host at load about 100.
Each root holds 1 s. Head and base controls ran in the same window (load 44 to 73).
Earlier record on the same product code with the real ps: `../test-round2/stall-finding.md`, 3 of 12 roots in about 25 minutes.

## Cited, not driven here
- /Users/charlesabrooker/firstmate/data/fm-lint-shellcheck-memory-concurrency/evidence/m3.md lines 27-39, at f5796a05.
- .../evidence/m5.md lines 7-11, at f5796a05.
- .../evidence/m2.md, first design.
- .../evidence/t1.md item 2, at 0818f43f0: 3.69 and 3.70 GiB within 4 GiB; no-budget control 9.85 GiB.
head-real-ps         longest_start_gap_s=11.3 wall=40s timed_out=0 exit_codes= 0 0 0 0
head-slow-ps         longest_start_gap_s=94.2 wall=272s timed_out=0 exit_codes= 0 0 0 0
head-slow-ps-2       longest_start_gap_s=78.3 wall=200s timed_out=0 exit_codes= 0 0 0 0
head-slow-p4         longest_start_gap_s=149.4 wall=276s timed_out=0 exit_codes= 0 0 0 0
base-cap2-real-ps    longest_start_gap_s=2.5 wall=50s timed_out=0 exit_codes= 0 0 0 0
base-cap2-slow-ps    longest_start_gap_s=3.6 wall=50s timed_out=0 exit_codes= 0 0 0 0
base-cap2-slow-p4    longest_start_gap_s=4.8 wall=50s timed_out=0 exit_codes= 0 0 0 0

Notes on the snapshot files:
- `stall-snapshots-head-slow-ps.txt` was taken after that run ended (roots_done=12). It shows no stall.
- `stall-snapshots-head-slow-p4.txt` has three snapshots, all taken during that run: 19:32:07 and 19:33:08 (roots_done=2), and 19:34:39 (roots_done=5).
- Base used a cap of 2 because at the default cap of 9, base never queues 8 workers.
- Each root holds 1 s, so a start gap of G seconds means at least G-1 seconds with no stand-in running.
- Limits of the real four-HOME run: roots of about 280 MiB, and the figure uses maximum resident size only, not footprint.
