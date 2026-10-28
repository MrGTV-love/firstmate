#!/usr/bin/env bash
# Live drive of the status readers on a sparse 2 GiB status log inside a disposable lab
# FM_HOME (bin/fm-lab-home.sh). Run from the gate worktree.
# Readers: the wake drain (cold and warm cursor), the open-decisions fold, the latest
# line and declared wait (status-event library), the fleet snapshot, and a drain killed
# mid-run. Expected: each finishes inside 60 s, names the log it refuses, leaves no
# non-status file over 1 MB, and never changes the log.
set -u
REPO=$PWD
eval "$("$REPO/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
trap '"$REPO/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"; echo "lab removed: $LAB"' EXIT
: > "$LAB/config/supervision-host-off"
printf '## In flight\n- [ ] huge - Huge log (repo: alpha) (kind: ship) (since 2026-10-01)\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
S="$LAB/state"; F="$S/huge.status"; mkdir -p "$LAB/wt"
printf '%s\n' "window=firstmate:fm-huge" "worktree=$LAB/wt" "project=alpha" "harness=claude" "kind=ship" "mode=ship" "yolo=off" > "$S/huge.meta"
perl -e '
  my ($path) = @ARGV; open my $f, ">", $path or die;
  for my $i (1 .. 3000) { print $f "working [at=$i]: distinct event number $i\n"; }
  print $f "needs-decision [key=old-question]: an early question that is still open\n";
  my $tail = ("REPOST REQUIRED corr=6be04311231638c7 reply on the parent status channel padding\n") x 60000;
  seek($f, 2 * 1024 * 1024 * 1024 - length($tail), 0) or die; print $f $tail; close $f or die;' "$F"
SIZE=$(stat -f %z "$F"); echo "lab FM_HOME=$LAB ; huge.status apparent size $SIZE bytes; on-disk $(du -k "$F" | cut -f1) KiB"
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
row() {  # <label> <cmd...>
  local t0 t1 rc
  t0=$(now); "${@:2}" > "$LAB/out.txt" 2> "$LAB/err.txt"; rc=$?; t1=$(now)
  printf '| %s | %.2f s | exit %s | %s |\n' "$1" "$(echo "$t1 - $t0" | bc)" "$rc" "$(grep -m1 -i 'refus\|limit' "$LAB/err.txt" | cut -c1-200)"
}
echo "| reader | wall time | exit | stderr naming the refusal |"
echo "| --- | --- | --- | --- |"
row "wake drain (cold cursor)" timeout 120 env FM_HOME="$LAB" "$REPO/bin/fm-wake-drain.sh"
row "wake drain (warm cursor)" timeout 120 env FM_HOME="$LAB" "$REPO/bin/fm-wake-drain.sh"
row "open-decisions fold" timeout 120 bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$REPO" "$F"
row "last_status_line" timeout 120 bash -c '. "$1/bin/fm-classify-lib.sh"; last_status_line "$2"' _ "$REPO" "$F"
echo "   last_status_line printed: $(cut -c1-80 "$LAB/out.txt")"
row "status_declared_wait_line" timeout 120 bash -c '. "$1/bin/fm-classify-lib.sh"; status_declared_wait_line "$2"' _ "$REPO" "$F"
row "fleet snapshot --secondmate-home-summary" timeout 120 env FM_HOME="$LAB" FM_SNAPSHOT_NOW=2026-10-28T12:00:00Z FM_CONTRIBUTIONS_NOW=2026-10-28T12:00:00Z "$REPO/bin/fm-fleet-snapshot.sh" --secondmate-home-summary
echo "   snapshot: $(jq -c '{schema, counts}' "$LAB/out.txt" 2>/dev/null | cut -c1-200)"
grep -m2 'huge.status' "$LAB/err.txt" | cut -c1-250 | sed 's/^/   snapshot stderr: /'
echo "-- killed drain --"
rm -f "$S"/.*cursor* 2>/dev/null
FM_HOME="$LAB" "$REPO/bin/fm-wake-drain.sh" > /dev/null 2>&1 & dp=$!
sleep 0.5; kill -9 $dp 2>/dev/null; wait $dp 2>/dev/null
echo "drain killed after 0.5 s"
big=$(find "$LAB" -type f -size +1048576c ! -name '*.status')
echo "non-status files over 1 MB anywhere in the lab: ${big:-none}"
echo "largest non-status files in state/: $(find "$S" -type f ! -name '*.status' -exec stat -f '%z %N' {} + | sort -rn | head -3 | sed "s|$S/||" | tr '\n' ';')"
echo "huge.status size after all readers: $(stat -f %z "$F") (unchanged: $([ "$(stat -f %z "$F")" = "$SIZE" ] && echo yes || echo NO))"
