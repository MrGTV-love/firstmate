#!/usr/bin/env bash
# One suite, one fm-duration owner, serial. Usage: suite-c2be9593.sh <suite-name>; writes <suite>.c2be9593.{log,json} and refuses any other head
set -u
s=$1
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6KS2CS6GX0GDVNTT34X3QMC
N=/Users/charlesabrooker/.no-mistakes/evidence/01M6KS2CS6GX0GDVNTT34X3QMC
cd "$WT" || exit 1
[ "$(git rev-parse HEAD)" = c2be9593474c6e561bbae42ca343e23fceef7a38 ] && [ -z "$(git status --short)" ] || { echo "not exact clean head"; exit 2; }
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
echo "SUITE_START $s $(date -u +%FT%TZ) head=$(git rev-parse --short HEAD) load=$(sysctl -n vm.loadavg) fmlab_procs=$(pgrep -f 'session fmlab' | wc -l | tr -d ' ')" >> "$N/suites-progress.txt"
FM_TEST_EVIDENCE=1 python3 bin/fm-duration.py run "test.tests/$s.test.sh" -- bash bin/fm-test-run.sh "tests/$s.test.sh" --json "$N/$s.c2be9593.json" > "$N/$s.c2be9593.log" 2>&1
rc=$?
echo "SUITE_END $s exit=$rc $(date -u +%FT%TZ) load=$(sysctl -n vm.loadavg)" >> "$N/suites-progress.txt"
grep -E "^not ok|FM_TEST_SUMMARY " "$N/$s.c2be9593.log"
exit $rc
