# Live validation: close a landed task beside foreign copies (held-copy rule)

Driver: `live-scenarios.sh` (uses `live-lab.sh`). It runs the real `bin/fm-teardown.sh` from the run worktree against a disposable marked lab home (`bin/fm-lab-home.sh create`), real git (bare origin, clone, linked worktrees), the real `treehouse` v3.1.4 on a private pool, real `lsof`, real `tasks-axi`. Only tmux, herdr, cmux, zellij, gh, gh-axi, no-mistakes and docker are shadowed by no-op stubs so no fleet pane or external service is touched. Each lab is removed in the same turn.

Authoritative log per scenario (earlier logs hold my own check/setup mistakes that I fixed and re-ran):

| # | Scenario | Result | Log |
|---|----------|--------|-----|
| S1 | Landed task closes beside a clean foreign copy whose only blocker is a unique ignored file (plain-get slot); copy untouched, slot reserved under a durable lease, one record line; rerun leaves it untouched | pass | live-S1-S3.log |
| S2 | Same, foreign copy holds commits on no remote | pass | live-S1-S3.log |
| S3 | Two foreign copies (one per hold class): both stay, two five-field record lines | pass | live-S1-S3.log |
| S4 | Own work NOT landed + held-class foreign copy: close refused, nothing removed | pass | live-S4-S7.log |
| S5 | Foreign copy with an untracked file: whole close refused | pass | live-S4-S7.log |
| S6 | Process outside the teardown runs in the foreign copy: refused, names pid, process not signalled | pass | live-S6-rerun.log |
| S7 | `--force --drop-file` never holds a foreign copy with unpushed commits: refused | pass | live-S7-S8-S11-rerun.log |
| S8 | `--force --drop-file` on a clean landed foreign copy with a unique ignored file: preserved with SHA-256, copy released, no hold | pass | live-S7-S8-S11-rerun.log |
| S9 | No foreign copy: ordinary close, real treehouse releases the lease | pass | live-S8-S12.log |
| S10 | origin unreachable (landing cannot be checked): refused not held; origin restored, rerun holds and closes | pass | live-S8-S12.log |
| S11 | Control characters in a held file name: shown as `?`, copy path quoted with `printf %q` | pass | live-S7-S8-S11-rerun.log |
| S12 | Own copy nested in the slot beside a held foreign copy: only the own copy is removed | pass | live-S8-S12.log |
| B  | Base commit 065c13165 on S1/S2: S2 is REFUSED (the stuck class); S1 removes the foreign copy after preserving its ignored file | reproduces the problem | live-BASE-S1-S2.log |

Targeted existing tests: all 31 cases added by this branch in `tests/fm-teardown.test.sh` run and pass (`targeted-teardown-tests.log`, `EXIT=0`).

Notes on my own mistakes, fixed before the final runs:
- First S6 check read stdout; the refusal names the pid on stderr. Fixed the check, re-ran, pass.
- First S7/S8 omitted `--drop-file`, which `--force` requires; S7 had passed for the wrong reason. Fixed, re-ran, pass.
- First S11 put the ESC byte in the copy directory name; git quotes that path and the slot's ordinary dirty check (`report_worktree_dirt`, untouched by this branch) refuses first. Moved the byte into the ignored file name, as the branch's own test does.
