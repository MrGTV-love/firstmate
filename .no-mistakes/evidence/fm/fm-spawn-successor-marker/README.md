# fm-spawn --successor-of: test-phase evidence

Head: 0152bd20fb9b (branch fm/fm-spawn-successor-marker). Base: 012b72f34a60.

## Automated (stub provisioner; not live)
- successor-tests-head.txt: the 5 new rows of tests/fm-spawn-pool-base-freshen.test.sh pass on head.
- successor-tests-base-plus-test-only.txt: base code plus the head test file. test_successor_of_reaches_the_provisioner fails ("unknown harness '--successor-of'").
- pool-base-freshen-full-head.txt: a run of the whole changed file. The 50-minute background limit stopped it with 20 ok and 0 not ok. This run is reduced: rows after the equal-retry group (legacy relaunch scope, origin early/late/freshness, copy and primary missing, and the freshness rows that had not printed) did not run here. Remote CI owns them.

## Live lab (real fm-spawn.sh, real tmux on a private socket, real treehouse with TREEHOUSE_ROOT in the sandbox)
- The project is a disposable repo holding Vernant's scripts/ and src/core/contracts from **unmerged** Vernant PR #3604 head c28a44a66825. Its provisioner is the real `--supersedes` verb. Vernant main 1cf0e36bbb does not have the verb yet, so F6 against landed main stays **Blocked**.
- Vernant stores point at temp: CODEX_HOOK_STATE_DIR and WORKTREE_LIFECYCLE_STORE_DIR were set in the lab tmux server environment. The real /tmp/vernant-codex-hooks-501 listing and ~/.treehouse did not change.
- Workers use a raw `sleep 86400` launch. Relaunches use `--harness claude`, because a raw launch command cannot be relaunched.
- A `gh` stub that prints `[]` sits in the project venv, so the provisioner and R-13 never call GitHub.

Transcript: live-e2e-transcript.txt. Per-step logs and drivers: live-lab/.
1. pred is spawned with no flag and gets 2 commits. The control ctl (no flag) carries them, and R-13 BLOCKs the push.
2. succ is spawned with `--successor-of pred`. The real verb PASSes and writes the marker 1.1.0 resolved fm/pred -> fm/succ. The meta gets successor_of=pred. The succ push with the carried commits is accepted by the real R-13.
3. ctl carries the same commits while the marker exists. It is still BLOCKed.
4. Refusals: detached, other branch, copy gone, no record, --scout, --relaunch, --secondmate, and a project running Vernant main's provisioner (not advertised). Each one exits 1 with one error line and adds nothing to state, windows or the pool. Two rows log `state+windows+pool_unchanged=no` and `RESULT=no`: "no predecessor record" (rows2.log) and "not advertised" (adv2.log). Their diffs hold only removals (`<` lines) of transient files that existed before the row: a stale .control-adv.lock left by my killed job, and home-summary and lock temp files.
5. The real verb refuses (marker store blocked) and gives recovery=slot-provision-refused plus successor_of=pred. A retry with the predecessor detached refuses and names pred. The supported retry `--relaunch` PASSes. The marker is re-recorded for fm/retry, which proves `--supersedes` was sent.
6. A later relaunch of an admitted successor (succ4, predecessor detached) does not need the predecessor. It sends no `--supersedes`, and the marker stays byte-identical. The real Vernant verb then refuses `manifest_exists`. The plain no-flag task ctl gets the same refusal (ctlr2.log), so this is not caused by this change.
