#!/usr/bin/env bash
# incident-logs-left-in-place.sh <repo>
# Three sparse status logs at the exact incident sizes (140 GB, 265 GB, 122 GB; a few KB of real blocks)
# are left in a marked lab home. The REAL watcher, wake drain, fleet snapshot, crew-state, captain-hold
# diverged and the status append helper each run against them under a timeout. Nothing may be read whole,
# deleted, truncated or rewritten; every reader must finish promptly with a small resident set.
set -u
R=$1
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
: > "$LAB/config/supervision-host-off"
trap 'kill "${WP:-0}" 2>/dev/null; rm -rf "$LAB"' EXIT
mkdir -p "$LAB/state" "$LAB/data"
mk() { perl -e 'open(my $f, ">", $ARGV[0]) or die; print $f "working [at=1792400000]: lane start\n"; close $f; truncate($ARGV[0], $ARGV[1]) or die' "$LAB/state/$1.status" "$2"; }
mk lane-a 140000000001; mk lane-b 265000000001; mk lane-c 122000000001
sig() { for l in a b c; do f="$LAB/state/lane-$l.status"; printf '%s size=%s inode=%s mtime=%s head4k=%s\n' "lane-$l" "$(stat -f %z "$f")" "$(stat -f %i "$f")" "$(stat -f %m "$f")" "$(head -c 4096 "$f" | shasum | cut -c1-12)"; done; }
echo "head=$(git -C "$R" rev-parse --short HEAD)  real blocks used by the three logs: $(du -sk "$LAB/state" | cut -f1) KiB"
echo "--- before"; sig > "$LAB/before.sig"; cat "$LAB/before.sig"
envc() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
run() { # <label> <timeout> cmd...
  local label=$1 to=$2; shift 2
  local t0 t1 rc
  t0=$(now)
  ( cd "$R" && envc perl -e 'alarm shift; exec @ARGV' "$to" /usr/bin/time -l "$@" > "$LAB/o.out" 2> "$LAB/o.err" ); rc=$?
  t1=$(now)
  echo "[$label] rc=$rc secs=$(perl -e "printf '%.1f', $t1-$t0") (alarm ${to}s; rc 142 = killed by the alarm)  max_rss_MB=$(awk '/maximum resident set size/{printf "%.0f", $1/1048576}' "$LAB/o.err")  stdout_bytes=$(wc -c < "$LAB/o.out" | tr -d ' ')"
  grep -v 'real\|user\|sys\|resident\|page\|swap\|block\|messages\|signals\|context\|fault\|reclaim\|instructions\|cycles\|peak\|voluntary' "$LAB/o.err" | sed "s#$LAB#<lab>#g" | cut -c1-330 | head -6 | sed 's/^/    stderr: /'
}
echo "--- 1. the REAL watcher (poll 1 s, default 32 MiB cap) with the three logs already in place"
envc FM_POLL=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  "$R/bin/fm-watch.sh" > "$LAB/watch.out" 2> "$LAB/watch.err" &
WP=$!
t0=$(now); peak=0
while kill -0 "$WP" 2>/dev/null; do
  rss=$(ps -p "$WP" -o rss= 2>/dev/null | tr -d ' '); [ -n "$rss" ] && [ "$rss" -gt "$peak" ] && peak=$rss
  [ "$(perl -e "print(($(now)-$t0) > 120 ? 1 : 0)")" = 1 ] && break
  sleep 0.5
done
alive=no; kill -0 "$WP" 2>/dev/null && alive=yes
echo "[watcher] still_running=$alive secs=$(perl -e "printf '%.1f', $(now)-$t0") peak_rss_KB=$peak (a wake exits the watcher; running after 120 s would mean it hung)"
sed "s#$LAB#<lab>#g" "$LAB/watch.out" | cut -c1-700
echo "    watcher stderr: $(sed "s#$LAB#<lab>#g" "$LAB/watch.err" | head -c 400)"
kill "$WP" 2>/dev/null
echo "--- 2. the REAL wake drain"
run drain 120 bin/fm-wake-drain.sh
echo "    drain stdout kinds: $(grep -c . "$LAB/o.out") lines; annotation lines: $(grep -c 'wake annotation' "$LAB/o.out")"
echo "--- 3. fleet snapshot"
run fleet-snapshot 120 bin/fm-fleet-snapshot.sh --json
echo "--- 4. crew-state on a lane"
run crew-state 120 bin/fm-crew-state.sh lane-a
cat "$LAB/o.out" | cut -c1-300 | sed 's/^/    stdout: /'
echo "--- 5. captain-hold diverged (r4-1 reader)"
run captain-hold-diverged 120 bin/fm-captain-hold.sh diverged
echo "--- 6. sanctioned append helper (done: line, the most privileged kind) on each log"
for l in a b c; do
  ( cd "$R" && envc bin/fm-status-append.sh "$LAB/state/lane-$l.status" "done [at=1792458000]: finished" 2> "$LAB/o.err" ); rc=$?
  echo "[append lane-$l] rc=$rc (75 = refused)  $(sed "s#$LAB#<lab>#g" "$LAB/o.err" | cut -c1-260)"
done
echo "--- after"; sig > "$LAB/after.sig"; cat "$LAB/after.sig"
if cmp -s "$LAB/before.sig" "$LAB/after.sig"; then echo "IDENTICAL: size, inode, mtime and first 4 KiB of all three logs unchanged"; else echo "CHANGED!"; diff "$LAB/before.sig" "$LAB/after.sig"; fi
echo "files over 1 MB created in state/ besides the logs: $(find "$LAB/state" -type f -size +1048576c ! -name '*.status' | wc -l | tr -d ' ')"
