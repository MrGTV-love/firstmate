#!/usr/bin/env bash
# One suite, one fm-duration owner, serial. Usage: suite.sh <suite-name>
set -u
s=$1
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6JWCK13QKYX35VNMKYBVERE
N=/Users/charlesabrooker/.no-mistakes/evidence/01M6JWCK13QKYX35VNMKYBVERE
cd "$WT" || exit 1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
echo "SUITE_START $s $(date -u +%FT%TZ) head=$(git rev-parse --short HEAD) load=$(sysctl -n vm.loadavg) fmlab_procs=$(pgrep -f 'session fmlab' | wc -l | tr -d ' ')" >> "$N/suites-progress.txt"
FM_TEST_EVIDENCE=1 python3 bin/fm-duration.py run "test.tests/$s.test.sh" -- bash bin/fm-test-run.sh "tests/$s.test.sh" --json "$N/$s.json" > "$N/$s.log" 2>&1
rc=$?
echo "SUITE_END $s exit=$rc $(date -u +%FT%TZ) load=$(sysctl -n vm.loadavg)" >> "$N/suites-progress.txt"
grep -E '^not ok|FM_TEST_SUMMARY ' "$N/$s.log"
exit $rc
