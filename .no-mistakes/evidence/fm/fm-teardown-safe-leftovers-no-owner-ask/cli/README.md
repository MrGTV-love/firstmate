# Test round 2 (Main 3893): CLI scenario runs, head 762cd358f. Partial, stopped.

Authority: Main 3893 is the later ruling. It permits real bin/fm-teardown.sh runs in a
scratch FM_HOME. The rest of Main 1850 was kept: one run at a time, under
bin/fm-proc-budget.sh --own-procs 128. Host load average was about 100.
One teardown took about 6 to 8 minutes.

Ran:
1. test_dead_launcher_lock_is_released_when_the_driver_is_unavailable.txt: S1 (own nested,
   driver unavailable, dead launcher) through the real CLI. Result: ok, rc=0, 461s.
2. scenario-r6r8-foreign-release.txt: FAIL, caused by a fixture mistake, not a product defect.
   The foreign copy held ignored .cache and notes files that exist nowhere else. The existing
   held-copy rule (bin/fm-teardown.sh:408-426) held the copy and leased the slot, so the
   direct release never ran. Teardown printed the held-copy notices, which is base behaviour.
   To reach the foreign direct release, a fixture must hold only .claude/.opencode ignored
   files. The R8-1 top-level .cache case is held at the CLI before the release, so only the
   library reaches it.

Not run (stopped when the phase returned): r6-own-release, r7-own-late-claude,
r8-foreign-late-change, live-launcher, s2-open-file-holder, s3-*, s4-*, s5-*, s6-*,
and the library R6-2 and regression cases. None of these is marked passed.
Driver: cli-scenario.sh (one scenario per process); batch.sh; run-case.sh.

Note: scenario-r6-own-release.txt is empty. It was stopped partway through and has no result.
