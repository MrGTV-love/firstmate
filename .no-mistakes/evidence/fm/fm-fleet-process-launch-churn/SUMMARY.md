# Live validation: watcher check-wait process launches (head 95417c6a6 vs base 3da01711e)

All runs: real bin/fm-watch.sh, fresh marked lab FM_HOME (bin/fm-lab-home.sh create), private TMUX_TMPDIR, one registered custom check, PATH shims log each sleep/dirname/uname launch with its parent PID.

| Scenario | base 3da01711e | head 95417c6a6 |
|---|---|---|
| Watcher main-shell `sleep` launches while one slow check runs | 107 in 27 s | 0 in 26 s (export), 0 in 26 s (worktree), 0 in 11 s (relative path) |
| Max beat age during that check (grace 6 s) | 1 s | 2-3 s |
| `dirname` launches from watcher start to first check | 39 | 12 |
| `dirname` launches while sourcing fm-watch.sh (3 runs each) | 21, 21, 21 | 0, 0, 0 |
| Leftover TERM-ignoring descendant, no Perl on PATH | killed, 21 sleep launches in cleanup | killed, 1 `sleep 0.20`, no perl error, exit 0 |
| Same, intermediate rev 5dc166289 (pre review fix) | - | `perl: command not found` (grace lost) |
| Hung check past FM_CHECK_TIMEOUT=3, with/without Perl | - | killed at ~3 s, watcher exit 0 (normal wake) |
| Lib dir resolution, 13 files x 6 path forms | identical to head | identical to base |

Files: live-wait-*.txt, live-wait-*.launches.log, live-stop-*.txt, startup-source-dirname.txt, lib-dir-resolution-base-vs-head.txt, targeted-tests.log, harness/.
