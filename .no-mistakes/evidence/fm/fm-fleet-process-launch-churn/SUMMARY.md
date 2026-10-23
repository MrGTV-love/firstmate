# Live validation: watcher check wait without per-tick process launches

All runs used the real `bin/fm-watch.sh` in a disposable lab home made by `bin/fm-lab-home.sh create`.
"base" = commit 4d1dc7d5e (git archive snapshot). "target" = 62c6fd2af (this worktree).
A PATH shim logged each `sleep`, `dirname`, and `perl` launch with its parent PID.

| Scenario | base | target |
|---|---|---|
| 12 s custom check: `sleep` launches by watcher main shell | 80 (`sleep 0.1`) | 0 |
| 12 s custom check: unique watcher descendants seen by 10 ms `ps` sampling | 169 | 62 |
| 12 s custom check: `dirname` launches, whole run | 41 | 14 (all in child scripts outside scope) |
| 12 s custom check: wake output delivered | yes (14.2 s) | yes (13.7 s) |
| Hung TERM-ignoring check, 3 s timeout: leader + child killed | yes | yes (perl and no-perl) |
| Hung check: `sleep` launches by watcher main shell | 20x `0.01` + 17x `0.1` + 1x poll `15` | 1x poll `15` (+1 perl); no-perl: 1x `0.20` + poll `15` |
| Check leaves TERM-ignoring descendant: output delivered, descendant killed | n/a | yes (perl: 1 perl, 0 sleep; no-perl: 1x `0.20` + 1x `1.00`) |
| Watcher started as `bash fm-watch.sh` from bin/ and `bash bin/fm-watch.sh` | n/a | wakes with check output, rc 0 |
| 15 changed libs x 3 source modes (absolute/relative/bare): dir vars, rc, function count | identical | identical |
| New tests from tests/fm-watcher-lock.test.sh run against base code | both FAIL | both pass (whole file rc 0, 0 not ok) |
