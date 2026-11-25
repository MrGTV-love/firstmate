# Test step evidence: head 762cd358f (fixes R6-2, R7-1, R8-1 on top of 6e85b4253)

Host limit Main 1850 binds this host: no run reaches bin/fm-teardown.sh, and no test
starts, signals or kills a process. Everything here sources the product libraries in
plain bash under bin/fm-proc-budget.sh --own-procs 128.

1. helper-cases-head.txt: 8 helper-level cases at head, all ok (two new ones and six
   related ones).
2. helper-cases-pre-fix-red.txt: the two new cases against bin/ of 6e85b4253 fail
   (.claude/.opencode not preserved; an unreadable lock time gives rc=2 plus a test error).
3. direct-release-real-git.sh: the driver. Real git lock with Vernant's text, real
   `git worktree unlock`, real non-forced `git worktree remove`, real preserve and final
   proof. Stubbed: launcher liveness, holder scan, ownership scan, landing proof,
   Git-protects check, admitted-bundle recheck.
   - direct-release-real-git.head.txt: foreign and own-nested are removed. .claude,
     .opencode, .cache and notes files are preserved with SHA256SUMS. own-late refuses
     and the lock goes back on. foreign-late preserves the changed bytes again, and the
     earlier preserve is kept aside. foreign-late-cache (R8-1 sequence: .cache/run.bin
     changes before the unlock) re-preserves 'rerun' and keeps the old bytes aside.
     live-launcher refuses before the unlock.
   - direct-release-real-git.pre-fix-6e85b4253.txt: same driver on the pre-fix code.
     Each released copy loses its .claude and .opencode files. own-late is removed.
4. helper-cases-all-30-head.txt: all 30 r5/pr400 library cases, one at a time. The first
   26 ran in one loop that hit its time limit; the last 4 ran in a second loop.

## Round 2 (Main 3893): full CLI runs, head 762cd358f

All runs drive the real bin/fm-teardown.sh in a scratch FM_HOME with a fake Treehouse
pool slot under ~/tmp/nm-01M87E3D-test-cli-{a,b,c} (removed afterwards). Driver:
cli/cli-scenario.sh, one scenario at a time per stream (cli/batch.sh). Each result is in
cli/scenario-<name>.txt with its command and FACT lines.

| Scenario | Run | Verdict |
|---|---|---|
| R6-1/S1 foreign | r6-foreign-release | PASS: lock released by the script, unforced remove, .claude/.opencode preserved with SHA256SUMS |
| R8-1 foreign, ship task | r8-foreign-held | PASS: copy with top-level .cache + notes held by the base kept-files rule, never unlocked or changed |
| R6-1 own nested | r6-own-release | PASS |
| R7-1 adversarial | r7-own-late-claude | PASS: refused, lock restored, late file kept |
| R8-1 adversarial | r8-foreign-late-change | PASS: new .cache and .claude bytes re-preserved, old preserve kept aside |
| Live launcher / S2 | live-launcher | PASS: refused naming pid, no unlock, no signal |
| S2 open-file holder | s2-open-file-holder | PASS |
| S3 accept / refuse | s3-squash-accept, s3-squash-refuse | PASS / PASS |
| S4 attended / unattended | s4-bundle-attended, s4-bundle-unattended | PASS / PASS |
| S5 bundle / PR credit | s5-bundle-credit, s5-pr-credit | PASS / PASS |
| S6 late record at unlock | s6-late-record-at-unlock | PASS |
| missing-interpreter modes | cli/test_the_default_driver_interpreter_and_the_override_close_the_same_way.txt | ok (suite case) |
| driver unavailable | cli/test_dead_launcher_lock_is_released_when_the_driver_is_unavailable.txt | ok (suite case) |

Notes:
- attempt1-* files: an earlier run of the driver expected a foreign ship-task copy with
  .cache/notes to be released. The product held it under the base kept-files rule (same
  code on base 032c4871b). That expectation was wrong, not the product.
- The first S3/S4 runs failed before teardown ran: the driver did not strip the suite's
  `|| exit 1` source line. They were fixed and rerun green.
- R6-2 (unreadable lock time counts as live) has no CLI surface: the lock file must stay
  readable while its mtime is unreadable. It is covered only by the helper-level case
  test_pr400_launcher_start_epoch_is_exact_in_the_repeated_hour (round 1).
- Library regression: the 30 r5/pr400 cases from round 1 (helper-cases-all-30-head.txt).

## Session 3 (2026-11-24, head 762cd358f): authoritative results are in rerun-s3/

The sections above and the cli/, cases/, live/, library/ folders come from earlier
attempts of this test step (cli/README.md "Partial, stopped" was written before those
runs finished). This session re-drove every scenario itself. See rerun-s3/README.md:
14 of 14 CLI arms PASS through the real bin/fm-teardown.sh, 30 of 30 library cases ok,
the missing-interpreter suite case ok (its suite exit cleanup lost a race with a detached
home-summary refresh, rc=1 after the "ok" line), and one setup probe (tab path) that did not reach
the foreign direct release with a pre-existing top-level .cache. Not tried: --force (a forced
removal route, not the direct release) and a foreign copy inside an own nested copy.
