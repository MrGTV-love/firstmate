# H3abc timing fix: live evidence (test phase)

Environment: CI-like Ubuntu 24.04 container (image fmci-linux, aarch64, `--cpus 4`), worktree mounted read-only,
CI job settings FM_CONC_N=2 LANES=4 ROUNDS=5 WORK=0.15 BURNERS=1. Runner: mutants/run-in-linux.sh.
The macOS host was at load ~107 on 18 CPUs, so H3abc there timed out (h3abc-head-macos-load107.out).

Mutants (mutants/make.py) change only the fixture's sampler or verdict; the real bin/ tools run underneath.
- base-gap035.py / head-gap035.py: one 35 ms extra sampler pause after the first sighting (max gap 56-67 ms, p99 30 ms).
- head-gap3.py: one 3 s sampler blackout (a real miss).
- head-nocheck.py: judge_nested no longer calls sampler_saw_every_worker.

| File | What | Result |
|---|---|---|
| h3abc-head.out | head H3abc, no injection | PASS, 24/24 seen, gaps 30/30 ms |
| h3abc-base-noinject.out | base H3abc, no injection (control) | PASS, max gap 33 ms |
| h3abc-base.out | base + 35 ms pause, 3 tries | FAIL x3 (max gap 66/56/57 ms) |
| h3abc-head-gap.out | head + 35 ms pause, 3 tries | PASS x3 (max gap 58/67/57 ms, 24/24 seen) |
| h3abc-mutant.out | head + 3 s blackout; miss control; no-check mutant | FAIL naming 10 workers; PASS; FAIL |
| miss-control-repeats.out | head miss control x5 | PASS x5, unseen workers non-empty each time |
| soak-mutant.out | head + 3 s blackout, H7a soak | FAIL naming 14 of 120 workers |
| full-run.out | whole proof file at head, CI=true | 39 PASS; 2 lint cases fail for lack of git metadata |
| lint-cases-triage.out | those 2 cases: base same container; head with a git repo | base FAIL the same way; head PASS |
