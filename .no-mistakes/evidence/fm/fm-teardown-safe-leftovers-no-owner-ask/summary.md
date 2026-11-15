# Test step summary (head 49ded5b4a, base 9d516486d)
Host rule (Main 1783, 1288/1292): full teardown suites and bin/fm-teardown.sh must not run on this host
(fm_run_timed new process group, leaked-process kill path). Only library-level test_r5_* cases, run by name.
Ran all 16 test_r5_* cases of tests/fm-teardown-cleanup.test.sh one by one: 16/16 exit 0. Log: r5-cases.log
End-to-end bin/fm-teardown.sh scenarios (dead-launcher release, squash landing, bundle close, live-launcher refusal)
were not run here by owner rule; CI runs the full suites on the pushed head.
