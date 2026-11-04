# Live validation: fm-spawn --successor-of (head e2b25eab5)

Lab: a marked fm-lab home (`bin/fm-lab-home.sh env`), a real tmux server on the
lab's private socket (`tmux -L fm-lab`), a real treehouse pool under a lab
`TREEHOUSE_ROOT`, and a lab clone of Vernant whose origin is a lab bare repo
holding Vernant main `06a1855330d36d23d236f4ee2a62710b04ed4bae` (PR 3607, the
landed `--supersedes` verb). The provisioner and the R-13 hook are Vernant's
REAL scripts at that commit, run with the Vernant venv, with
`CODEX_HOOK_STATE_DIR` and `WORKTREE_LIFECYCLE_STORE_DIR` pointed into the lab.
The worker agent is an inert raw launch command (`sleep 86400`); this change
never touches the agent path. Every spawn ran from a shell inside the lab
tmux server. The lab was torn down after the run; `~/.treehouse` is unchanged
(treehouse-before.txt / treehouse-after.txt).

Helpers: lab-lib.sh (spawn/relaunch/refusal/snapshot), lab-run.sh, r13.sh,
steps/*.sh (the exact commands of later steps). Snapshots exclude
state/guard-events.jsonl and state/.guard-watcher-stale-banner, the two entry
telemetry files every fm-spawn call touches before its own checks (the lab
runs no watcher).

| File | What it shows |
|---|---|
| 01-pred1-spawn.txt | real predecessor spawn, no flag (real pool, tmux, Vernant PASS) |
| 02-pred1-commit.txt | predecessor carries one commit 3f1c0151d |
| 03-advertise-refusal.txt | primary checkout at pre-verb 1cf0e36: refusal names the checkout and says to update it; nothing changed |
| 04-pred2-spawn.txt | primary fast-forwarded to 06a185533; second predecessor |
| 05-predecessor-refusals.txt | unsafe id, itself, no record, other branch, detached HEAD: refused, nothing changed. Its last row was a quoting slip on my side (copy not removed), so the spawn found a LIVE predecessor and was admitted: labsucc2, successor_of=labpred2, marker written by Vernant |
| 06-gone-refusal.txt | predecessor copy removed: refused, nothing changed |
| 07-scope-refusals.txt | --scout, --secondmate, --relaunch, id=repo batch, flag twice: refused, nothing changed |
| 08-positive-successor.txt, 08-marker-labsucc1.json | labsucc1 --successor-of labpred1 admitted; successor_of=labpred1; Vernant marker (unmerged_count 1) |
| 09-control-no-flag.txt | labsucc0 without the flag: no successor_of, no marker |
| 10-r13.txt | real R-13: labsucc1 carrying 3f1c0151d accepts (exit 0); labsucc0 carrying it blocks (exit 1) |
| 11-provisioner-refusal.txt | real Vernant refusal (supersedes_state_dir_refused): recovery=slot-provision-refused plus successor_of kept, no agent, task stays Queued |
| 12-respawn-drop-guard.txt | window closed; fresh spawn without the flag, or naming another predecessor, refuses and points to --relaunch; record byte-identical |
| 13-relaunch-retry.txt / 13a | on tmux with the window gone, --relaunch refuses (pre-existing proven-gone tmux endpoint policy) |
| 14-same-flag-respawn.txt | fresh spawn naming the SAME predecessor recovers it: admitted on the same copy, successor_of kept, marker re-recorded (Vernant keys markers by predecessor path, so it replaced labsucc1's) |
| 15..17 | labsucc4: refused (window kept); --relaunch with the predecessor detached refuses naming it and keeps the record; --relaunch while Vernant still refuses carries --supersedes (supersedes-only reason); --relaunch after the fix is admitted and Vernant writes the marker owner=labsucc4 |
| 18-later-relaunch-and-r13.txt | later relaunch of admitted labsucc4 with the predecessor detached reaches the provisioner (no successor checks, marker unchanged); Vernant refuses manifest_exists. Its R-13 block is from my earlier rows leaving other branches on the commit |
| 19-control-relaunch-no-successor.txt | the same manifest_exists refusal for a NON-successor relaunch: Vernant behaviour, same for any task |
| 20-r13-retried-successor.txt | after resetting those extra branches, real R-13 accepts labsucc4 (exit 0) |
| 21-successor-suite.txt | the ten test_successor_of_* rows of tests/fm-spawn-pool-base-freshen.test.sh (stub provisioner; not live) |
| final-state/ | task records, markers and backlog before teardown |

Named limits (not driven live): the handover window (the pane runner can wait
up to SPAWN_ACQUIRE_STALL=600 s before the provisioner reads the branch); the
copy-base case (the advertise probe reads the primary checkout's script; a copy
whose base lacks the verb makes the provisioner refuse on every retry).
