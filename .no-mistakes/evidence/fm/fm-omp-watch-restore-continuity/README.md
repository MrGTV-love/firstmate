# Test evidence: fm-omp-watch-restore-continuity (head 5d960771, base 99f53265)

## Controlled fixture (tests/fm-omp-harness.test.sh, test_watch_extension_restores_while_delivery_pending)
Runs used `env -i`, a fresh empty HOME and TMPDIR under /tmp/fmnm-*, OMP selectors unset, OMP_API_BILLING unset.

- `regression-fixed-head.log`: all five rows (pending, rejected, replay, foreign-late, foreign-never) pass at 5d960771.
- `regression-unfixed-head.log`: the same test file against the base extension fails on the first row:
  "second actionable close has no extension-started successor while first delivery is pending".
- `regression-per-case-both-heads.log`: each row alone on both heads.
  Base: pending, replay, foreign-late, foreign-never FAIL (missing successor); rejected PASS (delivery-error behavior unchanged).
  Head: all PASS.
- `lifecycle/<ref>-<case>.log`: the extension's own lifecycle.log per row and head, plus the arm chain and send counts.
  The `control` row (scratch-only: sendUserMessage always returns undefined) passes on both heads, so the fixture does not fail by construction.

## Live omp 18.11.2 primary in a disposable lab home (bin/fm-lab-home.sh env, tmux -L fm-lab)
- `live-omp/run1-*`: first boot. Two real startup check closes 1 s apart. The second close logged
  `restore-skipped reason=restoring`, then `restore-unchanged reason=owned-child`; the extension-started arm 47134 / watcher 47195 stayed live with a fresh beacon.
- `live-omp/run2-*`: restart with FM_CHECK_INTERVAL=5 and a lab-only registered check (`livep.check.sh.txt`).
  fire-1, fire-2, fire-3 were fired while the model turn was busy. Each close logged `actionable-close` -> `restore-start` and a new extension-started arm:
  13027 -> 33241 -> 53418 -> 72279; then `/new` and fire-4: 72279 -> 22922. No repair call.
  `watch-cycle-exits-full.log` shows `successor=started:<pid>` for each of these closes.
  Each lab wake text appears once in the pane capture.
- Observation: in this live omp 18.11.2 run, `wake-delivery-start` -> `wake-delivery-settled` took about 150 ms while the model turn ran for tens of seconds.
The lab home and its tmux socket directory were removed after the run.
