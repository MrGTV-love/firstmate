# Test-phase evidence: fm-spawn --successor-of (target fd80ebc90, base d25e907c1)

## Live end to end (real bin/fm-spawn.sh + REAL Vernant provision_existing_slot.py + REAL R-13 hook)
Vernant: a throwaway clone of the local Vernant main at 8deb75e11 (contains the landed --supersedes verb, added in 06a185533).
Temp bare origin, temp CODEX_HOOK_STATE_DIR and WORKTREE_LIFECYCLE_STORE_DIR, disposable .venv with pydantic.
Backend (tmux, treehouse, agent) is the suite's fakebin stub. Round-1 driver: replaced in round 2 (see below).
- f6-e2e-with-flag.txt: spawn with --successor-of exits 0; the record holds successor_of=; Vernant's own writer put a
  schema 1.1.0 marker (carry_status resolved) in the temp worktree-supersedence dir; after carrying the predecessor
  commit, the real R-13 pre-push hook exits 0 (local origin/main fallback, since the temp origin is not GitHub).
- f6-e2e-without-flag-control.txt: same spawn without the flag: no successor_of, no marker, R-13 exits 1 (foreign commit).
- f2-e2e-moved-predecessor-refused.txt: predecessor copy left its recorded branch: spawn exits 1 with the branch error;
  home state/data unchanged, pool copy unmoved, lifecycle store empty, no marker.
- f2-e2e-primary-without-verb-refused.txt: primary checkout at 06a185533^ (no verb): spawn exits 1 naming the primary
  checkout and the Vernant verb; nothing changed, no marker. (Its "origin/main" label prints the reset primary sha.)
- l1-real-state-untouched.txt: the real default Vernant state dir has no e2e record; no real Vernant worktree added.

## Suite (stubbed provisioner, real fm-spawn.sh)
- suite-before-fix/: the 11 test_successor_of_* rows on target: 10 pass, test_successor_of_retained_retry fails.
  Cause: the merge of origin/main brought #427 (342ac52b2), so a relaunch of an admitted governed task now adopts its
  recorded manifest instead of calling the provisioner; the fixture manifest had no repo_root, so adoption refused.
- test-fix.diff: fixture manifest gains repo_root; the tail rows now assert the base behaviour: the admitted successor
  relaunch adopts (no new provisioner call, so no --supersedes, successor_of kept once) and a manifest that disagrees
  refuses as for any task (slot adoption refused: branch_mismatch, no provisioner call).
- head-fixed-*.txt: all 11 rows pass with the fix.

## Notes
- Vernant sha: 8deb75e11 is an ancestor of the local Vernant checkout's recorded origin/main (c9a3a86f8; 0 commits in
  main not in origin/main, 11 the other way), and 06a185533 (the verb) is an ancestor of it. So the run used a landed
  Vernant main commit that carries the verb, not the newest origin/main tip. The Vernant checkout was not fetched.
- R-13 ran on its documented fallback path (local origin/main plus base-equality), because the temp origin is not the
  canonical GitHub URL. The canonical-remote proof path was not driven.
- No real tmux or treehouse backend was driven; spawn ran with the suite's fakebin and FM_SPAWN_NO_GUARD=1.
- The round-1 driver could not be rerun (it sourced a defs.sh and /tmp/fm-e2e-path, deleted at teardown). Round 2
  overwrote f6-e2e-driver.sh with a self-contained driver; it produced only the round-2 f6 files below.

## Test round 2 (target f5c2c5563; product code identical to fd80ebc90, only the test file changed)
- successor-suite-head.txt: the 11 test_successor_of_* rows plus 4 no-flag governed spawn rows
  (test_freshness_introduces_slot_owner, test_freshness_absent_slot_owner_launches, test_local_only_source_binding,
  test_legacy_relaunch_scope_adoption) all pass at f5c2c5563. Provisioner and tmux/treehouse are stubs there.
- f6-e2e-head-f5c2c55.txt: real fm-spawn.sh + REAL Vernant provision_existing_slot.py + REAL R-13, Vernant pinned at
  c9a3a86f8 (the local Vernant checkout's recorded origin/main; not fetched; the verb landed in 06a185533, an ancestor).
  Control spawn without the flag: no marker, R-13 exit 1 listing the 2 predecessor commits as foreign.
  Successor spawn with --successor-of: successor_of= recorded, Vernant's writer put a schema 1.1.0 marker
  (carry_status resolved, predecessor_branch fm/<pred>, superseded_by_branch fm/<succ>) in the temp state dir;
  after a same-sha carry, R-13 exit 0 with no foreign commits.
  R-13 ran its PROVEN-remote path this time: harness change, CANONICAL_ORIGIN_URLS pointed at the temp origin URL
  (as Vernant's own _successor_decision test does); bypass env unset. All Vernant state stayed under the temp case dir.
- f6-e2e-unrelated-lane-not-laundered.txt: first attempt, where the control branch still held the same predecessor
  commits. R-13 kept blocking the successor and named the control branch as the foreign holder: the marker does not
  launder an unrelated lane. The driver then drops the control lane before the successor check.
- f6-e2e-driver.sh was rewritten in round 2 (the round-1 driver it replaced could not be rerun, as noted above).
  Python came from the operator Vernant checkout's .venv with PYTHONDONTWRITEBYTECODE=1. After the run: no file under
  that .venv is newer than successor-suite-head.txt, the checkout has no new worktree and no fm/f6* ref.
- f7-grep-head.txt: the change adds no line naming worktree-supersedence or CODEX_HOOK_STATE_DIR under bin/; the
  CODEX_HOOK_STATE_DIR reads that exist are pre-existing manifest-store reads, same count at base and head.
- /tmp/vernant-codex-hooks-501 (the real default Vernant state dir) is unchanged: last modified Nov 26, no
  worktree-supersedence directory.
