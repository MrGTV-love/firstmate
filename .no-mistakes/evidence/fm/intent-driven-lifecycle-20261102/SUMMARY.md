# Test step evidence: run 01M6KS2CS6GX0GDVNTT34X3QMC at c2be9593474c6e561bbae42ca343e23fceef7a38

All commands ran from the clean run worktree. Suites ran one at a time, each under its own
`bin/fm-duration.py run test.tests/<suite>.test.sh` owner (scripts/suite-c2be9593.sh). No real-login lab,
no agent CLI and no Herdr lifecycle ran. Labs were model-free and used disposable `bin/fm-lab-home.sh` homes,
and each lab was torn down.

## Full suites run in this run (exact clean c2)
- fm-dod-lib: exit 0, 43 ok. Log: fm-dod-lib.c2be9593.log
- fm-documentation-audiences: exit 0, 5 ok, 0 not ok. Log: fm-documentation-audiences.c2be9593.log
- fm-spawn-dispatch-profile: exit 0, 101 ok, 6564548 ms at load 112->73. It finished naturally under its owner.
  The harness background ceiling was set to 7200000 ms, so it did not stop the suite.
- fm-task-delivery: exit 0, 42 ok, 1665787 ms, 19:46:51Z-20:14:37Z. It ran alone. It was rerun because the reused receipt was not serial (see below).
- Timing receipts: command-durations.jsonl (timed_out=false, exit 0 for all four)
- Progress: suites-progress.txt

## Full suites reused from run 01M6JWCK13QKYX35VNMKYBVERE (same exact commit, not replayed)
Applicability: that run's suite-c2be9593.sh refused any head except exact clean c2be9593. This run is at the same
commit, so the whole tree is identical.
Serial check: no other file in that evidence directory was written inside these windows (find -newermt, second precision).
- fm-control-relaunch-recovery: exit 0, 45 ok (12:23:44Z-12:41:10Z)
- fm-control-relaunch-backends: exit 0, 102 ok (12:54:11Z-13:15:13Z)
- fm-control-relaunch: exit 0, 82 ok (13:15:35Z-13:26:26Z)
NOT reused: that run's fm-task-delivery c2 receipt (13:29:48Z-13:37:43Z) overlapped with scenario4-order-check.c2be9593.log
(written 13:29:55Z-13:30:11Z, a recovery test case). This run reran the suite on its own.
Copies: reused-01M6JWCK13QKYX35VNMKYBVERE/ (original: /Users/charlesabrooker/.no-mistakes/evidence/01M6JWCK13QKYX35VNMKYBVERE/)

## Scenarios
1/7. scenario1-4-emitted-launch-brief.md + scenario1-4-emitted-order.log: a real emitted reconciliation-only launch brief has role(1) < cue(10, count 1) < alignment(26) < outcomes(40) < recovery contract(60). Order check exit 0.
   lab-modelfree.log: role cue_count=1, order role(1) < cue(10) < alignment section(26) < outcomes(40). 0 of 36 rubric lines missing. Base role: cue 0.
   The profile suite case "actual ship/scout launch commands deliver the worker role contract" (cue exactly once in each brief kind) passed.
2. lab-modelfree.log: the docs-only brief is identical between base and head (0 diff lines). The placeholders are identical.
3. lab-s3.log: the filled no-mistakes brief gives plan exit 0, with the alignment section, "pass, fail, or unresolved" and "is pending, never pass", and 0 of 36 rubric lines missing.
   scenario3-unfilled.log: the unfilled brief gives plan exit 1 with the DoD-shape refusal.
4. scenario4-negative.log:
   - Head: both cases pass.
   - D (cue printed twice): both cases fail.
   - R (cue moved after the rubric): both cases still pass. No permanent test checks cue-before-rubric order.
   scenario4-negative.wrong-case.log: the first attempt called the wrong case. It is kept as a raw record.
5. scenario5-helper.log: the head case passes (exit 7 status reported, live unowned PID refused). The M1 kill -0 mutant and the M2 marker-first mutant both fail.
6. scenario6-identity-cf.log: A (head) passes the promotion case. B (git init removed, TMPDIR inside the checkout) fails it.
8. scenario8-doc-check-head.log: fm-doc-audience-check ok. scenario8-doc-negative.log: a renamed rubric heading gives exit 1, unresolved anchor in crew-brief-authoring.
Recovery counterfactual (D3): reused recovery-cf-c2-*.log from the prior run at c2. Not replayed.

## Limits carried forward unchanged
- The first fm-task-delivery start in the prior run was interrupted (exit 143, timed_out=false). Its owned cleanup proof is lost. This run does not prove it.
- The earlier ~/.claude/settings.json change: writer unknown, delta lost. Not read, not restored, not called benign.
- D5 (PR, CI and independent review) and D6 (guarded landing) are downstream and pending.
