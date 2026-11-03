# Live lab evidence: fm-teardown plain nested copy in own claimed slot (head 6197e9b41)

Lab: disposable FM_HOME from `bin/fm-lab-home.sh env`, private tmux socket (TMUX_TMPDIR),
real `treehouse` v3.1.7-fm with `TREEHOUSE_ROOT` in a temp dir, real git, real tasks-axi,
real tmux windows `firstmate:fm-<id>` running `sleep`. Stubs only for no-mistakes (shared daemon),
gh/gh-axi (forge) and docker. Scripts: lab/lab-lib.sh, lab/run.sh. Per-case snapshots: lab/cases/<case>/.

| case | record | slot custody | fixture | args | result |
|---|---|---|---|---|---|
| base1 run1 (BASE 012b72f34) | plain | durable lease | landed + gate-409 leftovers | --force --drop-file | rc=1 "reserved pool slot  lost its durable lease"; window killed, inbox/status/tasktmp deleted, return-pending slot= empty (bug reproduced) |
| base1 run2 (HEAD) | same broken state | | | --force --drop-file | rc=0, copy removed, slot returned (available), claim/record/markers gone |
| g409b run1 (HEAD) | plain | durable lease | slot root unlanded commit + leftovers | --force --drop-file | rc=1, names slot root + HEAD ce130b60..., snapshot NO DIFFERENCE (leftovers byte-equal, window alive, lease kept) |
| g409b run2 (HEAD) | plain | | slot commit landed on origin/main | --force --drop-file | rc=0, copy removed, slot available, claim/record/inbox/status/tasktmp/markers gone, window gone, backlog done |
| plain1 | plain | durable lease | landed | (none) | rc=0, same end state |
| lapsed1 | plain | lapsed process lease (crewmate) | landed + leftovers | --force --drop-file | rc=0, leased in place then returned, available |
| other1 / other1p | plain / prior_worktree | lease | claim names other-task | (none) | both rc=0, copy kept, claim kept, lease kept, no return (identical) |
| dirty1 / dirty1p | plain / prior_worktree | lease | nested copy staged change | (none) | both rc=1 "has uncommitted changes", NO DIFFERENCE |
| held1 | plain | lapsed | foreign unlanded copy in slot | --force | rc=1 foreign copy refusal, NO DIFFERENCE (held rule does not apply under --force) |
| held2 run1 | plain | lapsed | foreign unlanded copy + held-copy record path is a directory | (none) | rc=1 held-copy record refusal, NO DIFFERENCE: no lease taken (treehouse status still unleased), leftovers byte-equal |
| held2 run2 | plain | | record writable | (none) | rc=0 held close: slot leased to task-held2, claim kept, foreign copy byte-identical, held record written |

Targeted existing tests (drive the real script with stubbed treehouse): targeted-pool-tests.txt, targeted-other-tests.txt.
