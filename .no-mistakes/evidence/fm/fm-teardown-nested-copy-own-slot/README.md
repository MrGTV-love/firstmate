# Live validation: fm-teardown-nested-copy-own-slot (head b2d005bff, base 9d516486)

Drivers (in this folder): `live-409-lab.sh` and `live-409-lab-bundle.sh` (same, plus a `bundle` variant, a captain hold,
umask 022 and file-mode listing). Each run mints a marked lab home (`bin/fm-lab-home.sh env`), a real local bare origin
and clone, a real Treehouse pool (`TREEHOUSE_ROOT` in a temp dir), a real nested git worktree at
`<slot>/.claude/worktrees/task-x1-v2`, real tmux on the lab's private socket dir, and a real `tasks-axi` backlog row.
Only gh, gh-axi and no-mistakes are stubbed (no forge, no shared daemon). It runs the real `bin/fm-teardown.sh` and
records before/after snapshots, `treehouse status`, tmux windows and the backlog. Lab homes and worlds are removed after.

Slot mode `tmuxget` (the `live-S-*` runs) acquires the slot like bin/fm-spawn.sh: the task's tmux window runs an
interactive `treehouse get`, so the slot is process-held ("in-use"), not durably leased.
The older `live-<letter>-*` runs (no `S-`) used `treehouse get --lease` (pre-leased slot); their "leased (held by task-x1)"
lines after D/E come from that pre-lease, not from teardown.

| Run (live-…) | Code | Shape | Claim | Fixture | Flags | Result |
|---|---|---|---|---|---|---|
| S-A0-gate409-first-run | head | plain | mine | landed | --force --drop-file | exit 0; copy removed; slot returned (available); claim, record, inbox, status, tasktmp gone; window closed |
| S-BASE-A0-gate409-first-run | base | plain | mine | landed | --force --drop-file | exit 1 "…task-x1-v2 is not managed by treehouse"; before failing it leased the slot, wrote backlog-close + teardown-return-pending + captain-drop.md and deleted branch fm/task-x1-v2 |
| S-A-gate409-landed | head | plain | mine | landed + the two gate-409 leftover files | --force --drop-file | exit 0; same as S-A0; both leftovers gone; row closed "dropped" |
| S-B-gate409-slot-unlanded | head | plain | mine | slot root unlanded + leftovers | --force --drop-file | exit 1 naming slot and HEAD; record, inbox, status, tasktmp, copy, claim, branch, leftovers byte-identical; window alive; only guard-events.jsonl added |
| S-BASE-B-gate409-slot-unlanded | base | plain | mine | slot root unlanded | --force --drop-file | exit 1 "not managed by treehouse" after leasing the slot, writing both markers + captain-drop.md and deleting the branch ref |
| S-C1-plain-copy-dirty-unforced | head | plain | mine | staged change in copy + leftovers | none | exit 1 "has uncommitted changes"; unchanged (guard-events.jsonl added) |
| S-BASE-C1-plain-copy-dirty-unforced | base | plain | mine | staged change | none | exit 1, also unchanged (this row does not show the ordering fix) |
| S-I-gate409-refuse-then-land-rerun | head | plain | mine | slot unlanded + leftovers | forced; then plain re-run after pushing slot HEAD to main | first exit 1 unchanged; re-run exit 0, slot returned, everything retired |
| S-D1 / S-D2 other-claim | head | plain / prior | other-task | landed | --force --drop-file | identical: copy kept, claim kept, no return, record retired (R3 decided outcome) |
| S-E1 / S-E2 no-claim | head | plain / prior | none | landed | --force --drop-file | identical: copy kept, no return, record retired |
| S-F-plain-mine-normal | head | plain | mine | landed | none | exit 0; copy removed; slot returned |
| S-J-plain / S-J-prior bundle-held-forced | head | plain / prior | mine | d5 shape: slot HEAD + copy commit unlanded, one verified bundle, captain hold filed | --force --drop-file, umask 022 | identical: exit 0, copy removed, slot returned, row stays captain-held; captain-drop.md and preserved-bundles/<sha>.bundle mode 600 |

Earlier pre-leased runs: A, B, C1, C2, C3, D1, D2, E1, E2, F, G, H, I, BASE-A, BASE-A0 (same pattern of results on head).

Not reproduced: the d5 text "reserved pool slot  lost its durable lease" with inbox/status/tasktmp deleted. Base failed in
this lab at an earlier step (real treehouse refuses `return` on the nested path) after writing markers and deleting the ref.

Suite: `targeted-pool-tests.txt` (11 named tests from tests/fm-teardown-pool.test.sh, all ok, rc=0).
