#!/usr/bin/env bash
# Red-first: run the new regression tests against the BASE fm-home-summary-refresh.sh
# (541b9ff6c) with the target's tests, in a throwaway copy. Then stop only the
# refresh workers this run left behind (all of them live under this run's own TMPDIR).
set -u
WT=$1; WHICH=$2
RED=$(mktemp -d "${TMPDIR:-/tmp}/fm-red.XXXXXX")
mkdir -p "$RED/src" "$RED/tmp"
git -C "$WT" archive ef9316c90 | tar -x -C "$RED/src"
git -C "$WT" show 541b9ff6c:bin/fm-home-summary-refresh.sh > "$RED/src/bin/fm-home-summary-refresh.sh"
chmod +x "$RED/src/bin/fm-home-summary-refresh.sh"
echo "red copy: $RED/src (base refresh script sha $(git -C "$WT" rev-parse 541b9ff6c:bin/fm-home-summary-refresh.sh))"
cd "$RED/src"
case $WHICH in
  teardown) TMPDIR=$RED/tmp bash tests/fm-teardown-cleanup.test.sh test_fixture_cleanup_leaves_no_home_summary_refresh_worker; rc=$? ;;
  refresh)  TMPDIR=$RED/tmp bash tests/fm-home-summary-refresh.test.sh; rc=$? ;;
esac
echo "test rc=$rc"
left=$(pgrep -f -- "$RED/tmp/.*fm-home-summary-refresh" 2>/dev/null | tr '\n' ' ')
echo "refresh processes this red run left behind: ${left:-none}"
for p in $left; do ps -o pid=,ppid=,stat=,etime=,command= -p "$p"; done
for p in $left; do kill -KILL "$p" 2>/dev/null; done
sleep 1
echo "after cleanup: $(pgrep -f -- "$RED/tmp/.*fm-home-summary-refresh" 2>/dev/null | tr '\n' ' ' || true)"
rm -rf "$RED"
exit 0
