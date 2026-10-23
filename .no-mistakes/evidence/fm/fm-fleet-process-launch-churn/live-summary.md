# Live watcher validation: base e9e48e1a2 vs head 59a4eb20d

Driver: live/drive.sh (real bin/fm-watch.sh, full watcher process, disposable lab home from
bin/fm-lab-home.sh create, fake tmux, logging shims for sleep/dirname/perl; runs under nice -n 10
and bin/fm-proc-budget.sh). Base = `git archive e9e48e1a2` extracted to a temp dir. Each lab removed after its run.

| Scenario | Base | Head |
|---|---|---|
| 12 s slow check: watcher-child `sleep` launches in check window | 59 x `sleep 0.1` | 0 |
| same, max beat age during check (grace 6 s) | 2 s | 3 s |
| same, check output delivered as wake, watcher exit status | yes, 0 | yes, 0 |
| TERM-ignoring STOPped check, 3 s timeout: check gone after | 3 s, 15 x `sleep 0.1` | 3 s, 0 sleeps |
| Leader exits, TERM-ignoring descendant left: descendant removed | yes, 20 x `sleep 0.01` + 1 x `sleep 0.1` | yes, 1 x perl |
| Same descendant, no Perl on PATH (timeout/gtimeout present) | removed, 21 sleeps | removed, 1 x `sleep 0.20`, no stderr errors, exit 0 |
| Slow check, no Perl on PATH | 67 x `sleep 0.1` | 0 |
| `dirname` launches from start until check began | 39 | 12 (remaining are detached helpers: home-summary, open-loops, fleet-snapshot, ff-lib, contributions, check-register) |
| Leftover lab processes after watcher TERM | 0 (1 transient in base no-perl descendant run) | 0 |

Counterfactual: the two new tests in tests/fm-watcher-lock.test.sh fail against base code
(per-tick `0.1` sleeps; no-Perl `0.01` sleeps) and pass at head.
