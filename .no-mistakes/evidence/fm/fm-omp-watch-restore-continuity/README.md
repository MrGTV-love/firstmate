# Test-phase evidence: fm-omp-watch-restore-continuity

Target head: 00c19d7eeebde38f5343ea5896648c434fcddd2a. Base: 5abdbbbb163f6b44c6871582d16ca7dec4113df8.
OMP_API_BILLING: unset in every run. The omp status bar showed `(sub)`, so it was not an API-billed route.

## Fixture runs (real extension in Node with a fake omp host; not live)
- fixed-head-tests.log: `FM_TEST_ONLY=<case> bash tests/fm-omp-harness.test.sh` under `env -i`, fresh HOME and TMPDIR in /tmp.
  - pending, rejected, replay, foreign-late and foreign-never rows pass.
  - The other, missing and exhausted lock-reason rows pass.
- base-extension-tests.log: the same tests, but the scratch copy uses the base extension.
  - The pending row fails with "second actionable close has no extension-started successor while first delivery is pending".
  - The lock-reason row fails because the base has no restore-failed event.
- fixed-head-adjacent-watch-tests.log: 4 nearby watch-extension cases pass (exit=0).
  - 8 cases exit 2 because they are defined after the file's `fm_test_only` call, so they cannot be picked alone. CI runs them.

## Live run: real omp 18.11.2 primary, disposable lab home from bin/fm-lab-home.sh, tmux -L fm-lab
- live-lifecycle.log and live-watch-cycle-exits.log are the lab's extension lifecycle log and watcher ledger.
- Close A (predecessor 74273) at 23:18:01Z: restore-start, then the ledger shows successor=started:37875.
- Close B (predecessor 37586) at 23:18:22Z: the model was in its `sleep 60` wake turn (see live-pane-during-closeB.txt).
  - The log shows restore-start at the same millisecond as the close.
  - The ledger shows successor=started:68202.
- The model made 2 fm_watch_arm_omp calls in total: one refused before the lock existed, then the initial arm. It made no repair calls. All successors came from the extension.
- Both wakes (lab-a, lab-b) were drained and acknowledged once (live-pane-scrollback.txt). No handoff file was left behind.
- Lock loss: state/.lock was set to pid 1, then close C (predecessor 68064).
  - The log shows restore-failed reason=lock-lost at the same millisecond. There were no retry launches.
  - The ledger shows successor=none.
- Observation: in this omp TUI, wake delivery settled 0.3-0.5 s after the start (wake-delivery-start then wake-delivery-settled). The model turn ran about 60 s.
  - So in this omp version, sendUserMessage did not hold until the turn ended.
  - The pending-promise branch is proved only by the fixture, not by this live omp.
- The lab was torn down with `bin/fm-lab-home.sh teardown <lab> && rm -rf <lab>`.
