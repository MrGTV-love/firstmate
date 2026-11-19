# G14 evidence index (test phase, head 9418fb9b)

| Item | Disposition | Evidence |
|---|---|---|
| G141 help before FM_HOME, live | pass (live) | G141/live-transcript.txt, G141/near-miss-and-home-set-transcript.txt |
| G141 gate-agent refusal kept | pass (live) | G141/live-transcript.txt (NO_MISTAKES_GATE=1, exit 3 on base and head) |
| G141 gate-worktree refusal (context) | info | G141/gate-worktree-refusal-transcript.txt |
| G142 measurement | not applicable here (no threshold); PR-body harm statement not checked by test phase | G142/measurement.md |
| G14W exact-head different-family review | not run by test phase; pending the outer review step | none in this phase |
| G14V paired cases | head pass, base red on the --help case | G14V/paired-summary.txt, G14V/head-fm-send-strict.log, G14V/base-fm-send-strict-with-head-test.log |
| G14V registry lint test | see G14V/guard-lint.log | G14V/guard-lint.log |
