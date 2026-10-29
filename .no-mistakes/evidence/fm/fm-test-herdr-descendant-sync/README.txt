Evidence for fm/fm-test-herdr-descendant-sync (tests/fm-backend-herdr.test.sh: wait for the `pi` child instead of `sleep 0.3`).
driver/old.defs.sh, driver/new.defs.sh : the test file at base e27bbad9b and at 9a688b721, with the bare case calls removed so only the two changed cases run.
driver/run.sh <old|new> [delay] : runs the two changed cases; a delay puts driver/slowsh/sh first on PATH, which waits <delay> s and then execs /bin/sh (same pid), the way a saturated runner starts the shell late.
01-normal-start.txt     : both versions pass on an idle start.
02-slow-shell-start.txt : 1 s late shell. Old fails with the CI message "got 'stale-agent dead refused'"; new passes both cases.
03-shell-dies-early.txt : the agent binary is missing, so the shell exits with no child. New fails at once with "the shell died before its agent-named child appeared" (no hang).
04-real-cpu-saturation.txt : 54 busy loops on 18 cores. Old passed 10/10, so plain load on this host does not reproduce; run stopped early to spare the shared host.
