#!/usr/bin/env bash
# Scenario 5 at exact head: run the registered readiness case through the public test runner entry
# (tests/fm-control-relaunch.test.sh <case>), then two disposable mutant copies of the helper:
#  M1 liveness by kill -0 instead of running owned job (accepts a live unowned PID)
#  M2 marker checked before producer ownership (accepts a supplied marker from an unowned PID)
# Each mutant must make the case fail; the head must pass.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6JWCK13QKYX35VNMKYBVERE
cd "$WT" || exit 1; echo "head=$(git rev-parse HEAD) dirty=$(git status --short | wc -l | tr -d ' ')"
c=test_relaunch_trace_prepare_rejects_failed_setup
run() { (cd "$1" && FM_TEST_EVIDENCE=1 bash tests/fm-control-relaunch.test.sh "$c" 2>&1); echo "case exit=$?"; }
echo "== head"; run "$WT"
mk() { local d; d=$(mktemp -d /tmp/fm-nm-s5.XXXXXX); git archive HEAD | tar -x -C "$d"; git -C "$d" init -q; git -C "$d" add -A; git -C "$d" -c user.name=lab -c user.email=lab@example.invalid commit -qm copy; echo "$d"; }
m1=$(mk); python3 - "$m1/tests/fm-control-relaunch.test.sh" <<'PY'
import sys;p=sys.argv[1];s=open(p).read()
old='    for running_pid in $(jobs -pr); do\n      [ "$running_pid" != "$producer_pid" ] || owned_running=1\n    done\n'
assert s.count(old)==1; s=s.replace(old,'    kill -0 "$producer_pid" 2>/dev/null && owned_running=1\n'); open(p,'w').write(s)
PY
(cd "$m1" && git diff --stat); echo "== M1 mutant: kill -0 liveness"; run "$m1"
m2=$(mk); python3 - "$m2/tests/fm-control-relaunch.test.sh" <<'PY'
import sys;p=sys.argv[1];s=open(p).read()
old='  while :; do\n    owned_running=0\n'
assert s.count(old)==1; s=s.replace(old,'  while :; do\n    [ ! -e "$marker" ] || return 0\n    owned_running=0\n'); open(p,'w').write(s)
PY
(cd "$m2" && git diff --stat); echo "== M2 mutant: marker before ownership"; run "$m2"
rm -rf "$m1" "$m2"; echo "left: $(ls -d "$m1" "$m2" 2>/dev/null || echo none)"
echo "worktree dirty=$(git -C "$WT" status --short | wc -l | tr -d ' ')"
