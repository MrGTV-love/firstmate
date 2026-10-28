# Test step: b576c5b9 metadata-capture candidate (local Darwin, bounded)

Inputs
- B tree = b576c5b9 tree a9e46242a123be9b8d320e78a26ee14d1a9db329 (git archive).
- A tree = 737f390b tree 554f78869110a6990b00814718119137a03d655e (git archive). `diff -r A B` = only bin/fm-teardown.sh lines 1697 and 1701 (the two capture expressions).
- Bash 5.2.37 built from ftp.gnu.org bash-5.2.37.tar.gz (sha256 9599b22e...a621ff) into a scratch prefix; binary sha256 e523ba46f00448a6f0eb8c2b1a785c9d9eac4fde3aaa307c0c7fa0ba7e9d85a7. Stock /bin/bash 3.2.57 also used for metadata checks.
- Darwin 27.0.0 arm64, Python 3.13.6. Not CI, not Linux.

1. Counterbalanced A/B measurement (ab-run.sh): STOPPED after run 1 (p1-A).
   - Both selected cases printed ok; target_exit returncode 1; stderr: rm ... fm-teardown-tests.SmEjt4: Directory not empty.
   - Residue: docker-failure-volume-rm/state recreated after EXIT cleanup (known late-writer race). Retained at /Users/charlesabrooker/tmp/nm-ab-p1-A.9mA12V. Not retried, not deleted.
   - Single A sample only: 15 product invocations, backend.end->safety.start 5.55 CPU s / 6.83 wall s (p1-A/presafety.txt). No B sample, so no delta. Performance acceptance: INCONCLUSIVE.
2. Metadata semantics differential (meta-diff-driver.sh; real fm-teardown.sh CLI, 12 meta variants):
   - A vs B identical exit, stdout, stderr and resulting state under bash 5.2 and bash 3.2 (meta-A-vs-B-*.semantic.diff empty).
   - Covers exact, last-match-wins, last-bogus-wins (stale refusal exit 1), empty->sidecar fallback, empty/absent without sidecar, absent->sidecar fallback, CR kept literal (invalid --gen refusal), equals+backslash kept literal (refusal), unterminated final line, orca_worktree_id on non-orca backend.
   - Late writer .home-summary-refresh.log ("summary producer returned a malformed ledger document") appeared after cleanup in meta-B-bash5, meta-A-bash5, meta-A-bash32 (both trees). Retained under /Users/charlesabrooker/tmp/nm-meta-{B-bash5,A-bash5,A-bash32}.*.
3. Orca path (existing cases, real CLI): A and B both ok, exit 0, owned tmp empty and removed.

# Round 2 (same gate run, target b576c5b9 unchanged; no source change after round 1)

Inputs
- A = git archive 737f390b (tree 554f7886...), B = git archive HEAD b576c5b9 (tree a9e46242...). `diff -r A B` = only bin/fm-teardown.sh lines 1697 and 1701.
- Bash 5.2.37 rebuilt from the same tarball (sha256 9599b22e...a621ff); new binary sha256 b81c5bed5a789336b3f9479f20de43446c6ac57bd652f77451ad6b89a724a401 (build not byte-reproducible vs round 1). Darwin 27.0.0 arm64.

1. Counterbalanced A/B, fresh attempt r2-p1-A (baseline A first): STOPPED again.
   - Both selected cases ok; suite_exit=1; stderr: rm ... fm-teardown-tests.CsOcpD: Directory not empty.
   - Residue: docker-failure-volume-rm/state (empty dir) recreated after EXIT cleanup, still present after 15 s.
     Retained, not deleted: /Users/charlesabrooker/tmp/nm-ab-r2-p1-A.DRcLsA.
   - A sample: 15 invocations, backend.end->safety.start 4.72 CPU s / 5.70 wall s (r2-p1-A/presafety.txt).
     Round-1 A sample was 5.55 CPU s / 6.83 wall s on the same tree: run-to-run spread ~0.8 s.
   - No B sample. No delta. Performance acceptance: INCONCLUSIVE. Not retried further (intent stop rule).
2. Existing behavioral cases on B (r2-B-semantic): cleanup test_teardown_missing_busy_sidecar_completes,
   test_forced_orca_children_clean_docker_before_worktree_removal; endpoint-safety test_orca_composite_worktree_id_validates,
   test_absent_orca_descendant_preserves_backend_copy, test_orca_close_failure_refuses_even_under_force.
   All ok, both exits 0, owned tmp empty after 10 s and removed.
3. Round-1 metadata differential (12 variants, Bash 5.2 + 3.2) and Orca A/B evidence still apply: target commit unchanged.

# Round 3 (same gate run, target b576c5b9 unchanged; no source change after round 2)

Inputs (r3/inputs.txt): A = git archive 737f390b (tree 554f7886...), B = git archive b576c5b9 (tree a9e46242...),
in scratch /Users/charlesabrooker/tmp/nm-r3-trees.wDxfgK (removed after run). `diff -r A B` = only bin/fm-teardown.sh 1697/1701.
Stock /bin/bash 3.2.57 (sha256 d59c6f23...004e). Darwin 27.0.0 arm64. Scratch Bash 5.2 not rebuilt this round.

1. Counterbalanced A/B measurement: NOT re-run. Rounds 1 and 2 both stopped on baseline A with the
   docker-failure-volume-rm/state late-writer residue. A third identical attempt would be a blind retry,
   which the intent's stop rule forbids. Both residues are still present and retained:
   /Users/charlesabrooker/tmp/nm-ab-p1-A.9mA12V, /Users/charlesabrooker/tmp/nm-ab-r2-p1-A.DRcLsA.
   Performance acceptance stays INCONCLUSIVE (A samples only: 5.55 s and 4.72 s pre-safety CPU; no B sample).
2. Real-CLI metadata differential, 12 variants, A vs B under bash 3.2 (r3/meta-r3-{A,B}-bash32):
   all exits, refusals, stdout and resulting state identical. Same exit pattern as round 1.
   One stderr-only difference (r3/meta-r3-A-vs-B-bash32.semantic.diff): on baseline A, variant empty-no-sidecar,
   the detached worker bin/fm-home-summary-refresh.sh printed "child setpgid (...): Operation not permitted".
   It is on the unchanged A tree, from the detached summary lifecycle, absent in the other 5 runs. Not caused by B.
   Both owned temp roots were empty after 10 s and removed.
   (A first attempt had a setup error, driver path missing, exit 127; retained under r3/setup-error-127.)
3. Existing behavioral cases on B (r3/r3-B-semantic): same 5 cleanup/endpoint-safety cases as round 2.
   All ok, both exits 0, owned temp root empty after 10 s and removed.

# Round 4 (human decision: fix fixture lifetime first, then re-measure)

Repair (r4/lifetime-repair.patch, sha256 7a243462...4b241d; 3 files):
- bin/fm-home-summary-refresh.sh: when FM_TEST_PROCESS_REGISTRY is set, the refresh parent and the --_worker
  publish their own pid + lstart (pidfile `<registry>.<pid>`, then a `<pidfile>\tfm-home-summary-refresh.sh\twait`
  line) before any state write (before fm-wake-lib.sh's source-time mkdir). One that cannot publish exits 1 and
  starts no work. --detach returns only after its parent's entry exists, or reports exit 1 if the parent exits
  without one. Unset = no change.
- tests/lib.sh: exports the existing FM_TEST_PROCESS_REGISTRY; fm_test_reap_processes skips `wait` entries;
  new fm_test_wait_processes rereads the registry until each entry's exact identity is gone and the group that
  pid leads is empty (signal 0 probe only), bound FM_TEST_PROCESS_WAIT_SECONDS (default 150). At the bound it
  names the live identities, keeps registry + pidfiles + all roots, and fm_test_cleanup exits 1.
- tests/fm-home-summary-refresh.test.sh: 4 new checks (held writer: cleanup keeps root and fails at 1 s bound,
  then drains to real publication and exact-identity/group absence; 4 concurrent detaches; fast completion with
  lock held; registration failure for --detach and --_worker starts no work, no state dir).

Regression proof:
- r4/home-summary-refresh.out: whole owner file on the repaired worktree, exit 0, all ok.
- r4/prefix-run.out: same new test file + new lib.sh on OLD product script: fails at
  "cleanup under a running writer exited 0, expected 1". Old code then recreated the deleted root:
  /Users/charlesabrooker/tmp/fm-lifetime-child.DeT2bV/home/state/.home-summary-refresh.log (r4/prefix-residue.txt).
  Retained.
- r4/fm-home-summary-refresh-ownership.out and r4/fm-test-fixture-cleanup.out: exit 0.

Counterbalanced A/B (r4/ab-inputs.txt, r4/ab-run.sh; scratch Bash 5.2.37, same tarball sha256 9599b22e...a621ff,
binary sha256 06b7bab1...444db3de; Darwin 27.0.0 arm64; Python 3.13.6):
- A = archive 737f390b + patch, B = archive b576c5b9 + patch; diff -r A B = only bin/fm-teardown.sh 1697/1701.
- Order p1-A, p1-B, p2-B, p2-A. All 4: both cases ok, target_exit 0, suite_exit 0, owned TMPDIR empty right
  after exit and after 15 s, rmdir ok. No lifecycle failure recurred.
- r4/comparison.txt:
    p1-A presafety 5.59 s, p1-B 5.52 s, p2-B 5.51 s, p2-A 5.99 s (15 invocations each).
    pair1 A-B: presafety +0.07 s, ordinary case -0.15 s, docker case -0.17 s, CLI -0.29 s.
    pair2 A-B: presafety +0.48 s, ordinary case +0.17 s, docker case +1.40 s, CLI +1.47 s.
- Verdict: savings are inconsistent in sign across pairs for case/CLI totals and within run-to-run spread
  (A alone: 5.59 vs 5.99; earlier rounds 5.55, 4.72). Performance claim REJECTED as noisy / sub-resolution.

Unresolved invariants (not claimed closed):
- Only the summary refresh parent and its worker are registered. Groups made inside the worker's subtree by
  fm_run_timed (timeout/gtimeout/perl/bash) or by nested fm_run_progress (crew_state_json in
  fm-fleet-snapshot.sh, start_new_session) are waited for only through their synchronous launchers; a
  descendant that leaves the worker's group and outlives its launcher is not covered.
- --_release-lock/--_log-failure/--_note-failure children are covered only while the registered parent waits
  for them.
- Group probe can be held open by a reused pgid (conservative: wait longer, then fail at the bound).
- Other detached launch paths across the 189 cases, and external writers, are not claimed closed.
- Historical PID 45450 stays unattributed; the baseline-only setpgid EPERM cause stays unestablished.

# Round 5 (test step on committed target c1361cda, tree 7d367b73e03ec2abd9f05b0cc286727a74b5ae16)

Inputs
- `git diff b576c5b9 c1361cda` sha256 = 7a243462...4b241d = r4/lifetime-repair.patch. Committed head equals the r4 B tree.
- A = git archive c1361cda with bin/fm-teardown.sh = 737f390b blob 1011cf96...; B = git archive c1361cda (blob 16de7621...).
  `diff -r A B` = only bin/fm-teardown.sh 1697/1701 (r5/ab-inputs.txt).
- Scratch Bash 5.2.37 rebuilt from the same tarball (sha256 9599b22e...a621ff); binary sha256 6a7ede04...e767.
  Stock /bin/bash 3.2.57. Darwin 27.0.0 arm64, Python 3.13.6. Scratch build and trees removed after use.

1. Lifecycle owner tests/fm-home-summary-refresh.test.sh (bash 3.2): exit 0, 175 s, all ok incl. the 4 new
   lifetime checks; owned TMPDIR empty right after exit and after 15 s, rmdir ok (r5/home-summary-refresh.*).
2. Live real refresh CLI (r5/default-vs-registry.txt):
   - registry unset: --detach exit 0 in 0.29 s, real summary published, lock released, no failure log, no registry files.
   - registry set: --detach exit 0 in 0.47 s; parent entry present at return; worker entry added; fm_test_wait_processes rc 0, registry and pidfiles removed.
   - registry path missing (adversarial): --detach exit 1 with "did not register" message; no state dir, no registry created.
3. Counterbalanced A/B (r5/ab-run.sh, r5/ab-sequence.txt, r5/comparison.txt): order p1-A, p1-B, p2-B, p2-A.
   All 4: both cases ok, target_exit 0, suite_exit 0, empty stderr, owned TMPDIR empty after exit and after 15 s.
   presafety CPU: A 5.77 / 5.53, B 5.57 / 5.96 (15 invocations each).
   pair1 A-B +0.20 s, pair2 A-B -0.43 s. Docker case and CLI deltas also flip sign (+1.78/-2.29, +1.36/-2.26).
   With r4 (A 5.59, 5.99; B 5.52, 5.51): A mean 5.72 s, B mean 5.64 s, difference 0.08 s vs ~0.45 s spread.
   Verdict: no consistent saving; performance claim stays REJECTED as noisy / sub-resolution.
4. Real-CLI metadata differential, 12 variants, A vs B, bash 5.2 and 3.2 (r5/meta-*): semantic diffs empty
   (raw od dumps differ only by random temp-dir names). Same exit pattern as earlier rounds. Driver stderr empty;
   all 4 owned roots empty after 10 s. The .home-summary-refresh.log late writer seen in rounds 1 and 3 did not recur.
5. tests/fm-test-fixture-cleanup.test.sh and tests/fm-home-summary-refresh-ownership.test.sh: exit 0, owned root empty.

Not covered here: full 189-case run, Linux/CI, other detached launch paths (see round-4 unresolved invariants).

# Round 6 (test step re-run on unchanged target c1361cda, tree 7d367b73e03ec2abd9f05b0cc286727a74b5ae16)

Inputs (r6/ab-inputs.txt): B = git archive c1361cda; A = same with bin/fm-teardown.sh = 737f390b blob 1011cf96...
`diff -r A B` = only bin/fm-teardown.sh 1697/1701. Scratch Bash 5.2.37 rebuilt from the same tarball (sha256 9599b22e...a621ff),
binary sha256 fbbfd46d...6894. Stock /bin/bash 3.2.57. Darwin 27.0.0 arm64, Python 3.13.6. Trees and build removed after use.

1. Counterbalanced A/B (r6/ab-seq.sh, r6/ab-sequence.txt, r6/comparison.txt): p1-A, p1-B, p2-B, p2-A run alone, sequentially.
   All 4: both cases ok, target_exit 0, suite_exit 0, empty stderr, owned TMPDIR empty after exit and after 15 s.
   presafety CPU: A 5.73 / 5.46, B 5.70 / 5.21. pair1 A-B +0.03 s, pair2 A-B +0.25 s.
   Docker-case and CLI deltas flip sign again (-0.22/+1.16, -0.06/+1.18).
   Pooled r4+r5+r6 (r6/pooled.txt, 6 pairs, lifecycle repair in both trees): mean A-B +0.10 s, sd 0.30, t=0.80.
   Not distinguishable from zero. Performance claim stays REJECTED as noisy / sub-resolution.
2. Live refresh CLI on B (r6/default-vs-registry.txt):
   - registry unset: --detach exit 0 in 0.26 s; summary published; no registry files.
   - registry set: --detach exit 0; parent entry present at return; worker entry added; summary published;
     fm_test_wait_processes rc 0; registry and pidfiles removed.
   - summary contents unset vs set: only generated/generated_epoch differ.
   - adversarial missing registry: --detach exit 1 "did not register", no state dir; --_worker exit 1, no state entries.
   - First attempt had a script bug (wrong summary file name), retained as default-vs-registry.setup-error-wrong-summary-name.txt.
3. tests/fm-home-summary-refresh.test.sh (bash 3.2):
   - attempt 1 FAILED (r6/hsr-attempt1-concurrent): "best-effort failure reporting was not fully bounded" (21 s python bound
     exceeded). It ran at the same time as my 4 metadata-differential runs. Owned root was empty. Retained.
   - attempt 2, run alone: exit 0, 173 s, all ok incl. the 4 lifetime checks; owned root empty after 15 s.
   - Load-sensitive timing of an existing check. Cause (load only vs. added registration work) not established.
4. Real-CLI metadata differential, 12 variants, A vs B, bash 5.2 and 3.2 (r6/meta-*): exits, state, stdout identical.
   bash 5.2 semantic diff empty. bash 3.2: one stderr-only line on B, variant empty-no-sidecar:
   "fm-home-summary-refresh.sh: child setpgid (...): Operation not permitted". Round 3 saw the same line on A, same variant.
   So it is not caused by the 2-line change. Cause unestablished. Raw od diffs differ only by random temp names.
5. tests/fm-test-fixture-cleanup.test.sh and tests/fm-home-summary-refresh-ownership.test.sh: exit 0, owned root empty.

Not covered: full 189-case run, Linux/CI, other detached launch paths (see round-4 unresolved invariants).

# Round 8 (test step on committed target 1e980ec8, tree 5f04843ea1069883a340735445ba19973fbd3278)

Stock /bin/bash 3.2.57, Darwin 27.0.0 arm64. No A/B run (candidate dropped by human decision). No Bash 5 rebuild.

1. Metadata candidate dropped: bin/fm-teardown.sh at HEAD = blob 1011cf96 = 737f390b blob (r8/teardown-restore.txt).
2. tests/fm-home-summary-refresh.test.sh run alone: exit 0, 190 s, 38 ok, owned TMPDIR empty after 15 s (r8/hsr.*).
3. Fail-before / pass-after: committed lifetime block (r8/lifetime-block-head.sh) with each tree's own lib and product
   (r8/lifetime-harness.sh, r8/harness/): c1361 nested-bash/nested-default/held-worker/escape all rc=1;
   HEAD all rc=0. All 8 owned roots empty.
4. Live CLI (r8/live-cli.txt): unset registry --detach exit 0, summary published, no records; set registry: record
   filled at return, fm_run_progress + fm_run_timed records added, wait rc 0, all records removed; missing registry:
   exit 1, no home; keep-going --record writes "<pid>\n" equal to child pgid; pending-empty and partial-no-newline
   (dead prefix of a live pid) records stay pending, wait fails at bound, registry kept; live full record waits;
   exact kill then drains; non-numeric record is "unreadable" and kept.
5. Selected cleanup cases (2 phase-eligible + busy-sidecar + Orca): exit 0, target_exit returncode 0, 4 ok,
   owned root empty (r8/cleanup-selected.*). Bash 3.2 has no BASHPID, so no phase CPU numbers; not a measurement.
6. Related files (r8/receipts.txt): timeout-lib 24 ok, fixture-cleanup 7, hsr-ownership 3, endpoint-safety Orca 3,
   work-progress 26, nm-read-cache 17, duration 12; all exit 0.
   fm-duration.test.sh leaves 2 python temp dirs in TMPDIR on HEAD and on base 7c204105 alike (pre-existing);
   both scratch roots removed after listing.
Not covered: full 189-case run, Linux/CI, CPU delta. Watcher-launched summary path (bin/fm-watch.sh best-effort &)
and nonwriting watchdog groups stay disclosed limits, not closed.
