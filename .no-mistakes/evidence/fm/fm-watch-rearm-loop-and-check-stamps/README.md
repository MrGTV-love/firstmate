# Test-phase evidence: watcher rearm loop and per-check sweep stamps

Head 6da31e83359ef35a14cf9ff7445b328dffba0ba1, base 9d516486d631432dfe05e9b1cff865d9941da655.
Base tree = `git archive 9d516486` extracted to /tmp/fmlive-base (deleted after the run); head tests copied onto it for the base runs.

## Live drives (real bin/fm-watch.sh and bin/fm-watch-arm.sh in a marked lab home from bin/fm-lab-home.sh env, torn down after each)
- live-sweep-sigkill-head.log / live-sweep-sigkill-base.log: five checks, SIGKILL while check 3 runs, watchers restarted as supervision does.
  Head: c1=1 c2=1 c3=2 c4=1 c5=1, c1 wake queued once and printed once. Base: c1=2 c2=2 (finished checks rerun), c1 row queued twice.
- live-takeover-head.log / live-takeover-base.log: plain arm, watcher blocked in a step-10 check, then `fm-watch-arm.sh --take-over <arm>`.
  Head: arm2 prints `attached`, 0 signals to the busy watcher, same watcher alive and lock holder after the step ends; later idle take-over TERMs it and a new arm owns the cycle.
  Base: the busy watcher is TERMed mid-check (check run lost, reruns), the next arm prints `check: rearm-resurface`.
- live-idle-takeover-fresh-home-{head,base}.log: idle take-over on a home with no recovery marker at all; both print one `check: rearm-resurface` (same on base and head, documented ordinary-close behavior).

## Test suites (real host, Stop hook, arm and watcher in scratch homes; env -i, fresh HOME, TMPDIR in /tmp)
- head-takeover-and-sweep-partial.log: fm-watch-takeover.test.sh all 6 ok on head (first run was cut by the tool's 10-minute limit during the sweep suite).
- head-sweep-and-preserve.log: fm-watch-sweep.test.sh 18 ok, fm-watch-downtime-preserve.test.sh 10 ok, exit 0.
- head-loop-18-cycles.log: S1 loop test with FM_TEST_LOOP_CYCLES=18, ok.
- base-with-head-tests-loop-and-busy.log: on base the S1 loop test, the step-9 and step-10 busy tests fail on their behavioral assertions.
- base-with-head-tests-sweep-cut.log: on base the TERM and SIGKILL third-check cut tests fail (c1 ran 2 times).
- head-regression-triage-and-host-hook.log: fm-watch-triage.test.sh and fm-supervision-host-hook.test.sh on head.
- drivers/: the live-drive scripts (sweep-cut.sh, takeover.sh, idle.sh); usage: <script> <tree-root> <label>
