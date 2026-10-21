# Live watcher validation: base ff899e92a vs HEAD b6509161c

Driver: `python3 -I drive.py <repo> <worktree> <out> <scenario> [noperl]` (this directory).
Each run: fresh marked lab home from `bin/fm-lab-home.sh create`, plain FM_HOME, stock /bin/bash 3.2.57,
real `bin/fm-watch.sh`, a registered custom check (`bin/fm-check-register.sh`), PATH shims logging every
PATH-resolved external start (pid, ppid, name). Lab removed after each run. Base = `git archive ff899e92a`.

| Scenario | Base | HEAD |
|---|---|---|
| Slow check, 60 s window: direct watcher children | 249 (245 sleep, 4 touch) | 4 (4 touch, 0 sleep) |
| Slow check: max beacon age / watcher alive | 14.94 s / yes | 14.70 s / yes |
| Startup to first beacon: external starts | 106 (dirname 22, uname 3) | 79 (dirname 1, uname 2) |
| 5 s check completes: wake line + exit 0 | yes, 0.876 s after finish, 21 sleeps | yes, 0.968 s after finish, 0 sleeps |
| Leader exits, TERM-ignoring descendant holds pipe | wake ok, descendant killed, 3.31 s | wake ok, descendant killed, 3.39 s |
| Same, no perl on PATH (timeout present) | wake ok, killed, 21 sleeps | wake ok, killed, 2 sleeps (one per bounded wait) |
| TERM-ignoring check past 3 s timeout: check gone after | 5.51 / 5.11 / 5.37 s, ~35 sleeps | 6.41 / 6.26 / 5.19 s, 2 sleeps |
| Same, no perl | 5.39 s, 35 sleeps | 3.88 s, 3 sleeps |

All timeout runs: watcher stayed alive, no check children left, beacon fresh (<=15.2 s, throttle cadence).

Regression tests (HEAD, FM_TEST_ONLY, /bin/bash bin/fm-test-run.sh tests/fm-watcher-lock.test.sh): 4/4 ok.
New no-perl test on 770877c08 (pre-fix commit): fails with `perl: command not found` (regress-noperl-on-770877c.log).

Note: HEAD's outer-deadline detection uses `read -t 1`, so enforcement of a hung check can land up to ~1 s
later than base's 0.1 s sleep poll (observed up to 6.41 s vs 5.51 s for a 3 s timeout). The deadline value itself is unchanged.
