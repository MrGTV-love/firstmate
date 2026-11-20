# Live validation: fm-copy-sweep supersedence route (target 268a85ec5)

All runs use throwaway worlds under a temp root: a temp FM_HOME, a Treehouse pool slot
clone with a local bare origin, and real `git worktree` nested copies locked as Vernant
copies. The real `bin/fm-copy-sweep.sh --apply` and `bin/fm-teardown.sh` run in them.
Vernant's `closeout_pr.py` and the `gh` forge read are scripted stand-ins that log argv
(hard gate: the real driver must not run against any clone). Driver answers are scripted.

| File | What it shows |
|---|---|
| live-sweep-harness.sh | The harness. Runs the real sweep for scenarios S1-S6 and dumps each world. |
| live-sweep-transcript.txt | Full S1-S6 transcripts: records file, task metas, forge answers, sweep output, driver argv log, gh log, worktree list. |
| live-sweep-summary.txt | PASS/FAIL per check, first run (one S6 expectation was wrong; see the note at its end). |
| live-sweep-transcript-S6.txt, live-sweep-summary-S6.txt | S6 re-run with the corrected expectation: 14/14 PASS. |
| case-sweep-lane-base.txt | Suite case: secondmate lane copy takes its base from the lane task, not the secondmate record. |
| case-sweep-no-record-all-sites.txt | Suite case: no-record argv equal to base at every no-record call site. |
| case-sweep-pre-entry-head.txt | Suite case: checkout on the PR head at the pre-entry read is refused with an empty driver log. |
| case-teardown-route-foreign-own.txt | Suite case: teardown foreign and own nested copies use the exact --pr argv. |
| case-teardown-failing-record.txt | Suite case: each failing record condition keeps the foreign copy with no driver call. |
| case-teardown-base-disagree.txt | Suite case: teardown keeps a copy whose task base disagrees with the remote default. |
| case-teardown-failing-record-run1-timed-out.txt | First run of that case. My own 900 s limit cut it on a busy host after 13 of 14 conditions (all kept). The re-run above finished: exit 0. |

## Reasons read from the transcripts (not only the checks)
- S2 closed: "the forge shows PR 8 as CLOSED, not MERGED". S2 open: "the forge shows PR 9 as OPEN, not MERGED".
- S3 policy: "the merge commit does not hold the copy's entry at policy.txt ... not proved landed".
- S4 onhead: "the clone's primary checkout is on PR 7's head branch main". (The harness check `line_has onhead "head"` is weak because the copy name holds "head"; the reason was confirmed by reading this line.)
- S6 eqrel and inside: "the task's recorded base release disagrees with the remote's default branch main".
- S6 split: "the task records that name the copy disagree on the base branch (main and release)".
- S6 prior: held earlier by the classifier (HELD-LIVE-TASK). The resolver's drop of prior_worktree= is therefore not observable through the sweep.
