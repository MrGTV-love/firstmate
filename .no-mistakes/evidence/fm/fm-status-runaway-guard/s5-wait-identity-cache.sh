#!/usr/bin/env bash
# Live drive of the watcher's declared-wait identity and its cache (state/.<id>.wait-identity)
# inside a disposable lab FM_HOME (bin/fm-lab-home.sh). Run from the gate worktree.
# The functions are the watcher's own: bin/fm-watch.sh is sourced (its runtime does not
# start when sourced), so status_declared_wait_identity runs in watcher tail mode and
# declared_wait_scope is the consumer the paused/stale handlers call each poll.
# Usage: s5-wait-identity-cache.sh big|small
#   big:   one paused wait restated with a distinct stamp on every 100-byte line until the
#          log is at the read limit (cap plus reserve); time the first and later polls.
#   small: ~9 MiB of distinct restatements (more than two 4 MiB tail windows); window slide,
#          corrupt cache, truncated log, replaced log.
set -u
MODE=${1:?big|small}
REPO=$PWD
eval "$("$REPO/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
trap '"$REPO/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"; echo "lab removed: $LAB"' EXIT
F="$LAB/state/lane.status"; C="$LAB/state/.lane.wait-identity"
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
whole() { FM_STATUS_EVENT_SCAN_TAIL=0 bash -c '. "$1/bin/fm-classify-lib.sh"; status_declared_wait_identity "$2"' _ "$REPO" "$F"; }
poll() {  # the watcher's identity and scope for the lane, as one poll computes them
  FM_HOME="$LAB" bash -c '. "$1/bin/fm-watch.sh"; printf "identity=%s\n" "$(status_declared_wait_identity "$2")"; printf "scope=%s\n" "$(declared_wait_scope "$2")"' _ "$REPO" "$F" 2>&1
}
timed_poll() {  # <label>
  local t0 t1 out
  t0=$(now); out=$(poll); t1=$(now)
  printf '%s: %.2f s | %s | cache=%s\n' "$1" "$(echo "$t1 - $t0" | bc)" "$(printf '%s' "$out" | tr '\n' ' ')" "$( [ -s "$C" ] && echo present || echo absent)"
  LAST=$(printf '%s\n' "$out" | sed -n 's/^identity=//p')
}
restate() {  # <from> <count>  distinct-stamp 100-byte restatements (99 chars + newline)
  perl -e 'my ($from, $n) = @ARGV; for my $i ($from .. $from + $n - 1) { my $l = "paused [key=deploy] [at=$i]: waiting for the deploy window"; print $l, " " x (99 - length $l), "\n" }' "$1" "$2"
}
echo "lab FM_HOME=$LAB mode=$MODE host=$(hostname) date=$(date -u +%FT%TZ)"
if [ "$MODE" = big ]; then
  limit=$((33554432 + 1048576))
  n=$(( (limit - 25 - 200) / 100 ))
  { printf 'working: before the wait\n'; restate 0 "$n"; } > "$F"
  echo "log: $(stat -f %z "$F") bytes, $(wc -l < "$F" | tr -d ' ') lines, read limit $limit"
  t0=$(now); REF=$(whole); t1=$(now); printf 'whole-log identity (reference): %s in %.2f s\n' "$REF" "$(echo "$t1 - $t0" | bc)"
  timed_poll "poll 1 (cold, exact walk)"; [ "$LAST" = "$REF" ] && echo "  equal to whole-log identity: yes" || echo "  equal: NO"
  timed_poll "poll 2 (no change)"; [ "$LAST" = "$REF" ] && echo "  equal: yes" || echo "  equal: NO"
  "$REPO/bin/fm-status-append.sh" "$F" "paused [key=deploy] [at=$n]: waiting for the deploy window"; echo "sanctioned append of one restatement exit=$?"
  timed_poll "poll 3 (one appended restatement)"; [ "$LAST" = "$REF" ] && echo "  equal: yes" || echo "  equal: NO"
  "$REPO/bin/fm-status-append.sh" "$F" "resolved [key=deploy]: window opened"; echo "resolved append exit=$?"
  timed_poll "poll 4 (wait resolved)"; echo "  identity after resolve: '${LAST}' (empty = no declared wait)"
else
  { printf 'working: before the wait\n'; restate 0 94000; } > "$F"
  echo "log: $(stat -f %z "$F") bytes (> 2 x 4 MiB window)"
  REF=$(whole); echo "whole-log identity: $REF"
  timed_poll "poll 1 (cold)"; [ "$LAST" = "$REF" ] && echo "  equal: yes" || echo "  equal: NO"
  restate 94000 45000 >> "$F"; echo "appended 45000 restatements (4.5 MB: the tail window slides past the old window)"
  timed_poll "poll 2 (window slid)"; [ "$LAST" = "$REF" ] && echo "  equal: yes" || echo "  equal: NO"
  echo "  whole-log identity now: $(whole)"
  printf 'garbage\tnot\ta\tcache\n' > "$C"; echo "cache corrupted"
  timed_poll "poll 3 (corrupt cache)"; [ "$LAST" = "$REF" ] && echo "  equal: yes (fell back to the exact walk)" || echo "  equal: NO"
  awk -F '\t' -v OFS='\t' '{ $3 = $3 + 100; print }' "$C" > "$C.n" && mv -f "$C.n" "$C"; echo "cache opener offset altered (+100, checksum now wrong)"
  timed_poll "poll 4 (altered cache)"; [ "$LAST" = "$REF" ] && echo "  equal: yes" || echo "  equal: NO"
  { printf 'working: new run\n'; printf 'paused [key=deploy]: reopened after rotation\n'; restate 0 10; } > "$F.new"; mv -f "$F.new" "$F"; echo "log replaced by a new file (rotation)"
  timed_poll "poll 5 (rotated)"; echo "  whole-log identity of new file: $(whole)"; [ "$LAST" = "$(whole)" ] && echo "  equal: yes" || echo "  equal: NO"
  { printf 'paused [key=deploy] [at=1]: waiting for the deploy window\n'; } > "$F"; echo "log truncated in place to one line"
  timed_poll "poll 6 (truncated)"; [ "$LAST" = "$(whole)" ] && echo "  equal to whole-log identity $(whole): yes" || echo "  equal: NO"
fi
