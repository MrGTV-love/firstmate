# Live validation: `fm-control <task> reassociate` and its lifecycle

Branch `fm/fm-task-copy-reassociate-v2-r2`, target `df9646cf`.
The files one directory up belong to an earlier test round on older code (`e4a0d4ff`).

## How it was driven

- A disposable lab home made by `bin/fm-lab-home.sh create` (see `lab-env.sh`).
- A throwaway git project with a bare `origin`, outside every repository.
- The real `treehouse` binary, with its pool root pinned inside the throwaway directory.
- A private tmux server on socket `fm-lab`.
- The lab home's session lock taken by `bin/fm-lock.sh` for the real Claude harness that ran this test step.
- Real `bin/fm-spawn.sh` launches of real Claude workers (four ships, three scouts, two secondmates), each told to reply `idle`.
- No stubs for `fm-control`, `fm-teardown`, `fm-spawn`, `fm-merge-local`, `fm-crew-state`, `fm-home-seed`, `treehouse`, `tmux`, `git`, or `ps`.
- The worker S5 steps (commit, bundle, cut a fresh copy, carry the work over) were done with plain git commands, which is what a worker does.

Fixtures written by hand, and why:

- `mate2/state/holder.meta` and `mate2/state/other.meta`: records in a second registered local home, to drive the cross-home scans.
- `data/secondmates.md` lines for `mate2` and for a home that does not exist (`ghost`).
- One `pr=` line appended to and then removed from a live record, to drive the recorded-PR refusal.
- `state/.lock` and `state/.lock-session` set to another live harness and another session, then restored, to drive the non-owner refusal.
- One plain file at `state/terminal-outcomes`, to make a teardown step fail after the slot return. It was removed before the re-run.
- One `done:` line appended to `state/labsix.status`, which is what a worker does.

## Files, in the order they were produced

| File | What it shows |
| --- | --- |
| `01-spawn-labship.log` | Real spawn of ship `labship` into Treehouse pool slot 1. |
| `02-nested-s5-setup.log` | Worker S5 setup: nested fresh copy inside the slot (d3 GRE-1937 shape). |
| `03-refusals-labship.log` | Eight refusals, each with a before and after state fingerprint. |
| `04-nested-reassociate-result.log` | Record, brief, slot claim, anchor ref, old copy, and live worker after the move. |
| `05-spawn-gate-refuses-nested.log` | A new spawn refuses while the slot holds the live nested copy. |
| `06-teardown-unlanded-refuses.log` | Teardown refuses while the nested copy's work is not landed. |
| `07-merge-local.log` | `fm-merge-local.sh` lands the branch the record now names. |
| `08-teardown-unanchored-slot-refuses.log` | Teardown refuses a late slot commit that is neither landed nor anchored. |
| `09-teardown-force-does-not-waive-slot-proof.log` | `--force --drop-file` still refuses that slot. |
| `10-teardown-fails-after-slot-return.log` | Teardown removes the nested copy, returns the slot, then a later step fails. The record stays. |
| `11-slot-handed-to-another-task.log` | Treehouse hands the returned slot to a new task while the stale record still exists. |
| `12-plain-rerun-records-landed.log` | Plain re-run: ship recorded as landed (`local main`), no drop record, the other task's slot untouched. |
| `13-reverse-nested-setup.log` | Move in, then move back: current copy is the slot, prior copy nested inside it. |
| `14-reverse-nested-teardown.log` | Teardown removes the anchored nested prior copy and returns the slot. |
| `15-forward-nested-one-run-and-next-spawn.log` | One plain teardown of a nested task, then a new spawn takes the freed slot. |
| `16-disjoint-reassociate-and-move-back.log` | Move out of the pool (d1 shape): slot released and anchored. Move back undoes it. |
| `17-teardown-scout-keeps-prior-copy.log` | Teardown returns the slot and leaves the prior copy untouched and named. |
| `18-disjoint-teardown-leaves-copy.log` | Teardown of a task whose current copy is outside the pool leaves it in place. |
| `19-spawn-gate-cross-home.log` | Missing registered home: one warning, spawn proceeds. Readable home with a live nested copy: spawn refuses. |
| `20-refusals-cross-record.log` | Six more refusals, including another task's copy in another home, then a positive control. |
| `21-crew-state-follows-replacement-copy.log` | `fm-crew-state` says `worktree gone` before the move and reads the replacement copy after it. |
| `22-relaunch-after-reassociate.log` | FAIL on tmux: `fm-control relaunch` after a move stops the agent and then refuses to start one. |
| `23-secondmate-own-missing-home.log` | Retiring a real secondmate whose own home is gone succeeds; another missing home still refuses. |
| `24-cleanup-teardowns.log` | Teardown of the last two reassociated tasks. |
| `30-targeted-tests.log` | The change's own test files, run through `bin/fm-test-run.sh`. |

## Not driven live

- `fm-crew-state` reading the replacement copy's no-mistakes pipeline run. It needs a real no-mistakes run in the copy. This test phase must not start or control another pipeline. The live check in file 21 uses the status-log and worktree paths instead.
- A stale `index.lock` appearing between the slot detach and the Treehouse return. It needs a lock planted in the middle of teardown.
- `fm-control relaunch` after a move on the Herdr backend. Only tmux was driven.
- Retiring a secondmate with `--force` when its own home is gone. A recorded decision declined that finding.

## Mistakes in my own setup, kept for honesty

- The first "non-owner" attempt changed only `state/.lock`. `state/.lock-session` still named this test's own Claude session, and the lock library counts the same session as the owner. So that call was a valid move. It is the forward nested move in file 04. The true non-owner refusal is the last entry of file 03.
- The lab tmux server was reaped twice by the machine's test reaper, because I had not registered the tmux directory with `bin/fm-lab-home.sh tmux-dir`. After I registered it, the server stayed up. Files 19 and 21 were re-driven after each restart.
- In file 14 the first merge refused because `labtwo` branched from an older main. I rebased it as a worker would.
- In file 21 the first three reads are mixed up by timing (the worker was mid-turn). The clean before and after pair is the last block of that file.

## Left behind on the machine

- `bin/fm-spawn.sh` registers Claude workspace trust for each worker copy. Five entries for deleted lab paths under `~/tmp/fm-labw.vuezng/` remain in `~/.claude.json`. I did not edit that file.
