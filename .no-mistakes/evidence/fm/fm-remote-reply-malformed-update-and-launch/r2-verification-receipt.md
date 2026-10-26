# Test round 2 verification receipt (head 7c449eb97)
No live endpoint was called. No new call to gtt-cb. All runs used bin/fm-proc-budget.sh.
Fixtures tests/fixtures/gtt-cb-fm-mini-scratch-update.reply and gtt-cb-r2-route.reply are byte-identical (sha1) to the captured
fm-mini-scratch-update.stdout and vernant-r2-review-route.stdout in the task data directory.

| Scenario | Result | Evidence |
|---|---|---|
| fm-update accepts captured gtt-cb fm-mini `current:` reply, keeps restart | pass (fake ssh, real fm-update.sh) | r2-new-fm-update.log T3e |
| fm-update malformed reply shows line count + bounded last line | pass (fake ssh) | r2-new-fm-update.log T3e |
| fm-spawn --secondmate replays captured r2 route (omp, no launch=): no "malformed", records omp, "running", replacement not confirmed | pass (fake ssh) | r2-new-fm-remote-secondmate-trace-context.log |
| launch=spawned with other harness refused, parent record unchanged | pass (fake ssh) | same log |
| reused/unconfirmed routes: no ledger dispatch, offset kept; fresh spawn writes one | pass (fake ssh) | same log |
| parent fm-control stay delegates exact argv, relays output + rc; interrupt/exit/relaunch/non-secondmate refused before transport | pass (fake ssh) | r2-new-fm-control.log |
| host-local stay: ownership gate, exactly one id, no pane input when refused | pass (fixture herdr) | r2-new-lifecycle-e2e.log line 17; suite rc=0, 34 ok |
| Live: real Claude 2.1.310 on picker in isolated fm-lab Herdr session released by parent stay; same PID acknowledges steering | pass, live in lab | r2-live-stay-teamclaude.log rc=0 |
| DoD M2: new tests fail on old code (base 9068220) | pass (fail-before shown) | r2-old-fm-update.log, r2-old-fm-control.log, r2-old-trace-context.log |

Live test note: run from a scratch copy of tests/fm-remote-secondmate-stay-live-e2e.test.sh with Claude launched through
bin/fm-teamclaude-launch.sh (TeamClaude) instead of bare `claude`; `fm-teamclaude-launch.sh --check` rc=0 first. Lab torn down by helper.
Old-code results: fm-update fails at malformed diagnostic (captured fm-mini reply passes on old code too: update incident not reproduced);
fm-control fails "a remote stay that the host accepted should succeed"; trace-context fails on reuse with
"error: remote launch returned malformed route metadata" (the r2 incident message; old code required harness equality).
Old suites stop at first failure, so later cases in those suites were not run on old code.
Real gtt-cb endpoints and post-merge vernant-mini-build acknowledgement: not exercised (forbidden here).
