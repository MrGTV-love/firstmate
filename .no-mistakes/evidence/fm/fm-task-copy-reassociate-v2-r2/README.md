# Live validation: `fm-control <task> reassociate` and its lifecycle

Branch `fm/fm-task-copy-reassociate-v2-r2`, target `e4a0d4ff`.

## How it was driven

- A disposable lab home made by `bin/fm-lab-home.sh create` (see `lab-env.sh`).
- A throwaway git project with a bare `origin`, outside every repository.
- The real `treehouse` binary, with its pool root pinned inside the throwaway directory.
- A private tmux server on socket `fm-lab` under the lab home.
- The lab home's session lock taken by `bin/fm-lock.sh` for the real Claude harness that ran this test step.
- Three real `bin/fm-spawn.sh` launches of real Claude workers (one ship, two scouts), each given a "do nothing, reply idle" brief.
- No stubs for `fm-control`, `fm-teardown`, `fm-spawn`, `fm-merge-local`, `treehouse`, `tmux`, `git`, or `ps`.
- The "worker" S5 steps (commit, bundle, cut a fresh copy, carry the work over) were done with plain git commands, which is what a worker does.

Fixtures written by hand, and why:

- `mate2/state/holder.meta` and `mate2/state/other.meta`: records in a second registered local home, to drive the cross-home scans.
- `data/secondmates.md`: the registry lines for that home and for a home that does not exist.
- One `pr=` line appended to and then removed from a live record, to drive the recorded-PR refusal.
- `state/.lock` set to another live harness pid and then restored, to drive the non-owner refusal.

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
| `09-teardown-force-does-not-waive-slot-proof.log` | `--force` and `--force --drop-file` still refuse that slot. |
| `10-teardown-nested-success.log` | Plain teardown removes the nested copy and returns the slot through real Treehouse. |
| `11-spawn-after-teardown-succeeds.log` | A new spawn succeeds and claims the freed slot. |
| `12-disjoint-reassociate-releases-slot.log` | Move out of the pool (d1 shape): slot released and anchored, worker untouched. |
| `13-move-back-undoes-hop.log` | Moving back undoes the hop and claims the slot again. |
| `14-teardown-scout-keeps-prior-copy.log` | Teardown returns the slot and leaves the prior copy untouched and named. |
| `15-spawn-gate-cross-home.log` | Missing registered home: one warning, spawn proceeds. Readable home with a live nested copy: spawn refuses. |
| `16-refusals-cross-record.log` | Seven more refusals, including another task's copy in another home. |
| `17-disjoint-teardown-leaves-copy.log` | Teardown of a task whose current copy is a non-pool copy leaves it in place. |
| `20-targeted-tests.log` | The change's own test files, run through `bin/fm-test-run.sh`. |

## Not driven live

- `fm-crew-state` reading the replacement copy's pipeline run. It needs a real no-mistakes run in the copy. This test phase must not start or control another pipeline.
- A teardown step failing after the slot return, then a plain re-run. It needs a fault inside teardown.
- A stale `index.lock` appearing between the slot detach and the Treehouse return. It needs a lock planted in the middle of teardown.

The change's own tests cover those three with stubs; see `20-targeted-tests.log`.

## A mistake in my own setup, kept for honesty

The first "non-owner" attempt ran from the lab tmux pane. That shell descends from the test's own Claude harness, so it did own the lock, and the call was a valid reassociation. It is the forward nested move recorded in `04-nested-reassociate-result.log`. The proper non-owner refusal is the last entry of `03-refusals-labship.log`.
