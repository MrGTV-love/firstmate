Round 2 test evidence for commit 7ed7798107ff38296f4f6bf12c904a79671834ea (omp `adopt`).
Every command ran under `nice -n 20 timeout 600`. Fake Herdr backend only; no live Herdr server or pane input.

relaunch-test_omp_adoption_*.log   one log per adoption test function (all ok)
relaunch-test_gate_other_pin_adopt_then_interrupt.log   round-1 failing case re-driven: pin=other now refused, record unchanged, 0 sends
relaunch-test_gate_real_kernel_cwd.log                 real owned process + real lsof cwd: adopt inside worktree, refuse outside
relaunch-test_gate_idempotent_and_harness_scope.log    repeat adopt byte-identical; claude harness, missing record, missing gen refused
before-fix-test_omp_adoption_other_generation_pin.log  same new regression run against the previous bin/fm-launch-proof-lib.sh: FAILS (unsafe adoption succeeded)
launch-proof.log, reassociate.log                      neighbouring suites (exit 0)
omp-harness-task-session-proof.log                     extension "must remain unproven" test (exit 0)
omp-harness.log                                        full suite hit the 600 s cap (exit 124): 48 ok, 0 not ok before the cap
ALL-SUMMARY.txt                                        exit codes per stream
