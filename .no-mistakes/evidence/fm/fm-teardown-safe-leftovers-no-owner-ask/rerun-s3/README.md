# Test step, session 3 (2026-11-24), head 762cd358f: fresh re-drive of every scenario

This folder holds the results this session ran itself. The other files in the parent
folder come from earlier attempts of this test step. They are not the source of this
session's verdicts.

Driver: cli-scenario.sh (copy of ../cli/cli-scenario.sh; EV points here; one arm added:
r8-foreign-cache-tabpath). Each arm builds a scratch FM_HOME, state, data and config, a
fake Treehouse pool slot, a throwaway project and origin, and a fake closeout driver
under ~/tmp/nm-01M87E3D-rerun-{a,b,c} (removed after the run). Then it runs the real
bin/fm-teardown.sh of the worktree once, under bin/fm-proc-budget.sh --own-procs 128.
batch.sh runs one arm at a time per stream. progress.txt lists each result.

Results (scenario-<arm>.txt holds the command, stdout/stderr extracts and FACT lines;
scenario-<arm>.artefacts holds stdout, stderr, the git worktree argv log, the driver
argv log, the data listing and the preserve SHA256SUMS):

| Arm | Result |
|---|---|
| r6-foreign-release | PASS: script unlocks, unforced remove, .claude/.opencode preserved with SHA256SUMS |
| r8-foreign-held | PASS: foreign copy with top-level .cache + notes is held, never unlocked, byte-identical |
| r6-own-release | PASS: own nested copy released; .cache, .claude, .opencode, notes preserved with sums |
| r7-own-late-claude | PASS: late .claude file at the unlock refuses, lock restored, file kept |
| r8-foreign-late-change | PASS: new .cache and changed .claude bytes preserved with sums; old preserve kept |
| live-launcher | PASS: live launcher named, no unlock, no signal, copy stays locked |
| s2-open-file-holder | PASS: holder pid and file named, not signalled, no unlock |
| s3-squash-accept / s3-squash-refuse | PASS / PASS |
| s4-bundle-attended / s4-bundle-unattended | PASS / PASS |
| s5-bundle-credit / s5-pr-credit | PASS / PASS: exactly one credit in the driver argv |
| s6-late-record-at-unlock | PASS: final proof stops the removal, lock restored |
| r8-foreign-cache-tabpath | NOT A PRODUCT FAIL: setup probe. A tab in the copy path makes git quote the slot's '?? ".claude/worktrees/fc\ttab/"' line, so the exact-line nested-worktree skip (Main 1888) does not apply and the slot root refuses as dirty. Nothing was unlocked or removed. So the tab-path hold exception does not reach the direct release at the CLI. Not tried: --force (a forced removal route, not the direct release) and a foreign copy inside an own nested copy. |

broken-by-driver-edit/: the first r7-own-late-claude and r8-foreign-late-change runs.
I edited cli-scenario.sh while those bash processes were reading it, so they ran the
wrong arm and hit a syntax error (rc=2). Both were re-run cleanly (PASS above).

library/: all 30 r5/pr400 library cases, run one at a time with ../case-run.sh against
this worktree's bin/: 30 of 30 ok (summary.tsv). They source the real libraries; they
are helper-level runs, not CLI runs.

suite-test_the_default_driver_interpreter_and_the_override_close_the_same_way.txt: the
suite case, run alone through tests/fm-teardown-cleanup.test.sh (it reaches bin/fm-teardown.sh).

Suite case result: "ok - the default interpreter and the explicit override close the
kept-copy task the same way, and with a missing interpreter a dead launcher's lock is
released directly with the unique ignored file and the .claude/channel-outbox files
preserved". Then the suite's exit cleanup printed "rm: .../fm-teardown-tests.4QDjRd:
Directory not empty" and the runner returned rc=1. The leftover was
retained-config-override-missing/state/.home-summary-refresh.lock.steal* and
.home-summary-refresh.log ("summary producer returned a malformed ledger document"),
written by a detached home-summary refresh (pid 85935, gone) during or after the rm.
bin/fm-teardown.sh starts that refresh (--detach) on every completed close. This branch
does not change the refresh code, but it makes the missing-interpreter modes close instead
of refuse, so they now start it. In a one-case run the suite cleanup comes right after the
last teardown, so the two can race; the full suite order puts other cases in between. Scratch roots and case.* dirs were removed after.
