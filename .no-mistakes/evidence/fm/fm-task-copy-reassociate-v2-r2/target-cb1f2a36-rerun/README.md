# Live validation: `fm-control <task> reassociate` and its lifecycle (second drive at `cb1f2a36`)

Branch `fm/fm-task-copy-reassociate-v2-r2`, target `cb1f2a36`, plus one fix made in this test step (see "Defect found").

## How it was driven

- A disposable lab home made by `bin/fm-lab-home.sh create`, with its tmux directory from `bin/fm-lab-home.sh tmux-dir` (see `lab-env.sh`).
- A throwaway git project with a bare `origin`, outside every repository.
- The real `treehouse` binary, with its pool root pinned inside the throwaway directory.
- A private tmux server on socket `fm-lab`.
- The lab home's session lock taken by `bin/fm-lock.sh` for the real Claude harness that ran this test step.
- Real `bin/fm-spawn.sh` launches of real Claude workers (four ships, one scout, one secondmate), each told to reply `idle`.
- No stubs for `fm-control`, `fm-teardown`, `fm-spawn`, `fm-merge-local`, `fm-crew-state`, `fm-home-seed`, `fm-captain-hold`, `treehouse`, `tmux`, `git`, or `ps`.
- The worker S5 steps (commit, cut a fresh copy, carry the work over, rebase) were done with plain git commands, which is what a worker does.
- `drive.sh` ran each step and wrote its output to the numbered log.

Fixtures written by hand, and why:

- One `data/secondmates.md` line for a home that does not exist (`ghost`), to drive the unreadable-home paths. It was removed after each use.
- One `pr=` line appended to a live record (files 06, 07, 14).
- A stand-in `gh` on `PATH` for files 06 (third case) and 07 only. It answers `gh pr view <url> --json state -q .state` with `OPEN` or `MERGED`. It stands in for GitHub, not for the product. The second case of file 06 uses the real `gh`.
- A plain file at `state/terminal-outcomes` (file 12), to make a teardown step fail after the slot return. It was removed before the re-run.
- `state/.lock` and `state/.lock-session` set to a lab worker's live Claude pid and another session id, then restored (file 14, case 8c).
- One `done:` line appended to `state/labgate.status`, which is what a worker does (file 09a).
- `phase=complete` changed to `phase=launching` in one relaunch journal, then restored (file 09b), to drive the guard.

## Defect found, and fixed in this step

After a successful `fm-control <task> relaunch`, `fm-control <task> reassociate` refused for ever:
"task ... has an unfinished relaunch transaction ...; reconcile it before reassociating".
A finished relaunch keeps its journal `state/<id>.control-relaunch` with `phase=complete` until teardown.
The check refused when the file existed, whatever its phase. No command clears a finished journal.

- Before the fix, live: `09a-reassociate-after-relaunch-REFUSED-before-fix.log`.
- Fix: `bin/fm-control.sh`, `do_reassociate`. A journal that is this task's and reads `phase=complete` no longer refuses. Every other journal still refuses.
- New test: `tests/fm-control-reassociate.test.sh`, `test_finished_relaunch_journal_does_not_block_reassociation`.
- The new test fails on the committed code: `20-regression-test-fails-before-fix.log`.
- After the fix, live, same lab and same journal: `09b-reassociate-after-relaunch-fixed.log`, and again in file 12.

## Files, in the order they were produced

| File | What it shows |
| --- | --- |
| `00-lab-setup.log` | Lab tmux session, lock, project registry, first brief. |
| `01-spawn-labship.log` | Real spawn of ship `labship` into Treehouse pool slot 1. |
| `02-nested-reassociate.log` | Worker cuts a nested copy (d3 GRE-1937 shape). Reassociate re-points the record, brief, anchor and keeps the slot claim. Worker untouched. |
| `03-gate-and-unlanded-teardown.log` | New spawn refuses while the slot holds the live nested copy. Missing registered home: one warning line. Teardown refuses unlanded work. `--force` needs captain words. |
| `04-force-does-not-waive-slot-proof.log` | `--force --drop-file` and plain teardown both refuse a late slot commit that is neither landed nor anchored. |
| `05-move-back-and-anchor.log` | Moving back undoes the hop. Moving forward again anchors the slot HEAD. |
| `06-removed-copy-branch-gone.log` | Nested copy and its branch both gone: no `pr=` refuses; `pr=` not confirmed merged refuses (real `gh`, then stand-in `OPEN`). |
| `07-merged-pr-rerun-and-next-spawn.log` | Recorded PR reported `MERGED`: plain re-run returns the slot and records the ship as merged, no drop record. The next spawn succeeds. |
| `08-disjoint-reassociate-and-relaunch.log` | Move out of the pool (d1 shape): slot released and anchored. `fm-control relaunch` on tmux moves the pane into the replacement copy. |
| `09a-...-REFUSED-before-fix.log` | The defect: `fm-crew-state` says `worktree gone`, and reassociate refuses because of the finished relaunch journal. |
| `09b-reassociate-after-relaunch-fixed.log` | After the fix: reassociate succeeds, `fm-crew-state` reads the replacement copy (`done · status-log`). An unfinished journal still refuses. |
| `10-relaunch-after-second-hop.log` | A second relaunch after the second hop moves the pane out of the deleted prior copy. |
| `11-teardown-disjoint-and-unreadable-home.log` | Teardown refuses unlanded work, then after landing leaves the non-pool copy in place. A spawn with a missing registered home warns and proceeds. |
| `12-nested-relaunch-land-fail-after-return.log` | Nested move, relaunch, two more moves after the relaunch, landing. Teardown removes the nested copy, returns the slot, then a later step fails. The record stays. |
| `13-slot-handed-on-then-plain-rerun-records-landed.log` | The slot goes to a new task. A plain re-run records the first ship as done on local main, with no drop record, and leaves the new task's slot untouched. |
| `14-reassociate-refusals.log` | Nine refusals with a before and after fingerprint, then a positive control. |
| `15-secondmate-own-missing-home.log` | Plain retirement of a real secondmate whose own home is gone succeeds. |
| `16-scout-reassociate-and-relaunch-drift-guard.log` | Scout reassociation keeps scout fields and releases the slot. Relaunch refuses a pane that drifted to a path the record never named. |
| `17-final-teardowns.log` | Last ship and the scout torn down. Their non-pool copies are left in place. No records left. |
| `18-lab-teardown.log` | Lab tmux server, lab home and work directory removed. |
| `20-regression-test-fails-before-fix.log` | The new test against the committed `bin/fm-control.sh`. |
| `30-targeted-tests.log` | The change's five test files through `bin/fm-test-run.sh`, on the fixed worktree. |

## Not driven live

- `fm-crew-state` reading the replacement copy's no-mistakes pipeline run. It needs a real no-mistakes run in the copy. This test phase must not start or control another pipeline. File 09b shows the worktree and status-log paths instead.
- A stale `index.lock` that appears between the slot detach and the Treehouse return. It needs a lock planted in the middle of teardown.
- `fm-control relaunch` after a move on the Herdr backend. Only tmux was driven.
- Retiring a secondmate with `--force` when its own home is gone. A recorded decision declined that finding, so it was not driven again.

## Mistakes in my own setup, kept for honesty

- File 14, case 4: the first try hit the detached-HEAD refusal. Case 4b gives the sharper "another task's recorded worktree" refusal.
- File 14, case 8 and 8b: the pid I wrote into the lock was empty, then a `treehouse` subshell, so the lock read as stale. Case 8c uses a lab worker's live Claude pid.
- File 12: the first landing refused because the branch was behind local main. I rebased it as a worker would. The first block of that file shows the refusal.

## Left behind on the machine

- `bin/fm-spawn.sh` registers Claude workspace trust for each worker copy. Entries for the deleted lab paths under `~/tmp/fm-labw.tS1h2j/` remain in `~/.claude.json`. I did not edit that file.
