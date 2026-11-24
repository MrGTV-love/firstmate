# Live lab evidence: relaunch adopts the task's own slot manifest

Lab: `bin/fm-live-lab.sh up --harness claude --supervision-host none --expect-host no` (private tmux, TREEHOUSE_ROOT in the lab), at the target commit 5497d1084.
Worker: a real `bin/fm-spawn.sh` ship spawn on Claude (sonnet, low), governed by a lab create-only provisioner (`driver/provision_existing_slot.py`, stdlib, Vernant-style record store `<common>/vernant-worktree-lifecycle/<sha16>.json`, every real run appended to a sentinel).
Relaunches: real `bin/fm-control.sh <id> relaunch` in the lab's clean environment. Session-end: the real `fm_session_end_relaunch_scan` call of `bin/fm-watch.sh`, made from the sourced file and not from the running loop (the loop needs a primary to drain its wakes). Lab inputs: a `working` status line was appended so the lane is unpaused, and the 30-minute cap rows were removed before scans 2 and 3 so only the refusal memory decides.
A second lab (lab2-*) re-drove the custody refusals with a direct Claude pid read and drove the adopt route for an untracked recorded scope path.
Teardown: `bin/fm-live-lab.sh down` (lab-down.log); ~/.treehouse unchanged; no lab Claude trust entries left.

| File | Scenario |
|---|---|
| s0-fresh-spawn.log | fresh governed spawn: provisioner runs once, record gains slot_manifest/slot_base_sha/slot_owned_path |
| sA-own-manifest-relaunch-twice.log, sA2-second-relaunch.log | two own-manifest relaunches admitted; manifest inventory identical; 0 provisioner runs (relaunch 2 first hit a lab Claude MCP dialog, re-driven) |
| sB-own-out-of-scope-work.log | own out-of-scope commit + edit: admitted, paths printed, scope unchanged |
| sC-kept-settings-merge.log | kept settings: allow/deny reach the active file; defaultMode, disableAllHooks, env do not; kept copy byte-identical |
| sD-adversarial-not-own.log | lab 1: branch_mismatch and custody_other_record refused by name, record and manifest unchanged (its pid line read the treehouse wrapper, so it does not prove the agent kept running; see lab2) |
| sD3-adversarial-recheck-claude-pid.log | lab 1: lifecycle_state_mismatch refused by name; the real Claude pid 28924 kept running |
| lab2-sD-sG-claude-pid-and-adopt-untracked-scope.log | lab 2: branch_mismatch and custody_other_record leave the same Claude pid 25228 running; the adopt route admits a recorded scope path that is not tracked at the base (the d5 scope_not_tracked shape, lab input), 0 provisioner runs, manifest unchanged |
| sE1-session-end-scan1.log, sE2-session-end-no-retry-then-changed-cause.log | session-end: refusal reported once; unchanged cause not retried (cap rows removed to isolate); changed cause gets one attempt, relaunched, drift report in wake and state/<id>.relaunch-drift (one block) |
| sF1F2-..., sF3F4F5-... (F1/F2 agent survival: Claude pid 84525 read directly in F3/F4) | no-manifest route: dirty_worktree (+drift), scope_mismatch (+drift), scope_not_tracked, manifest_exists (names the file) refused before the stop; cleared collision: one provisioner run, admitted, manifest recorded |
| sBASE-base-commit-manifest-exists.log | baseline at 87836f79: same relaunch runs the provisioner, manifest_exists, agent stopped, no replacement |
| sR-recover-stuck-worker-after-base-refusal.log | back on the change: the dead worker is relaunched by adoption, 0 provisioner runs, manifest identical |
| suite-*.log | the four targeted suites (not live) |
