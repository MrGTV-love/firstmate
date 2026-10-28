# Live device-remount harness, test round (HEAD 4efe85770 vs base 1f843933b) (disposable). Usage: . harness.sh
# Real APFS disk image, real stat, real bin/fm-watch.sh / fm-wake-drain.sh.
# lab-head runs HEAD (the run worktree); lab-base runs base 1f843933b (git archive copy).
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M60Q9NTSDEB99J8Q1NC7JYGW
S=$(cat /Users/charlesabrooker/.no-mistakes/evidence/01M60Q9NTSDEB99J8Q1NC7JYGW/live/scratch.path)
LH=$S/mnt/lab-head
LB=$S/mnt/lab-base
STALE=${STALE:-6}   # FM_WATCHER_STALE_GRACE for the lab: tighter than the 300 s default
N=${N:-14}   # status logs per lab
codebin() { case "$1" in head) printf '%s/bin' "$W" ;; base) printf '%s/base/bin' "$S" ;; esac; }
labof() { case "$1" in head) printf '%s' "$LH" ;; base) printf '%s' "$LB" ;; esac; }
mtime() { stat -f '%m' "$1" 2>/dev/null; }
# beacon sampler: one "epoch age" line per 0.5 s while the watcher pid lives
sample_beacon() {  # <code> <pid> <out>
  local lab pid=$2 m now
  lab=$(labof "$1")
  while kill -0 "$pid" 2>/dev/null; do
    m=$(mtime "$lab/state/.last-watcher-beat"); now=$(date +%s)
    [ -n "$m" ] && printf '%s %s %s\n' "$now" "$((now - m))" "$(ps -A -o pid=,ppid=,command= | awk -v p="$pid" '
      { par[$1]=$2; c=$3; if (c ~ /bash$/ && $4 != "") c=$4; sub(".*/", "", c); cmd[$1]=c }
      END { for (k in par) { q=par[k]; d=0; while (q != "" && q != 1 && d < 6) { if (q == p) { printf "%s,", cmd[k]; break } q=par[q]; d++ } } }')" >> "$3"
    sleep 0.5
  done
}
# capture sampler: every 0.5 s, the owned-capture and span-scratch files alive in state/
sample_captures() {  # <code> <pid> <out>
  local st; st="$(labof "$1")/state"
  while kill -0 "$2" 2>/dev/null; do
    printf '%s %s\n' "$(date +%s)" "$(cd "$st" && ls -a 2>/dev/null | grep -E '^\.fm-check-output\.|\.span\.' | tr '\n' ' ')" >> "$3"
    sleep 0.5
  done
}
# capture_spans <code> <from> <to>: first/last epoch each span scratch name was seen
capture_spans() {
  awk -v a="$2" -v b="$3" '$1 >= a && $1 <= b { for (i = 2; i <= NF; i++) if ($i ~ /\.span/) { if (!($i in f)) f[$i]=$1; l[$i]=$1 } }
    END { for (k in f) printf "    %s alive %ss (%s..%s)\n", k, l[k]-f[k], f[k], l[k] }' "$(labof "$1")/captures.samples" | sort
}
# run_watch <code> <seconds> [extra env...] -> "exited rc=N" (watcher queued a wake) or "alive..."
run_watch() {
  local code=$1 secs=$2 bin lab pid i=0 spid; shift 2
  bin=$(codebin "$code"); lab=$(labof "$code")
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    TMUX_TMPDIR="$(cat "$S/tmux-$code.path")" FM_HOME="$lab" FM_POLL=1 FM_SIGNAL_GRACE=${GRACE:-1} \
    FM_WATCHER_STALE_GRACE="$STALE" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 "$@" \
    bash "$bin/fm-watch.sh" >> "$lab/watch.out" 2>> "$lab/watch.err" &
  pid=$!
  echo "$pid" > "$S/watch-$code.pid"
  echo "START $(date +%s) $pid" >> "$lab/beacon.samples"
  sample_beacon "$code" "$pid" "$lab/beacon.samples" &
  spid=$!
  sample_captures "$code" "$pid" "$lab/captures.samples" &
  while [ "$i" -lt "$((secs * 10))" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; local rc=$?; wait "$spid" 2>/dev/null; echo "exited rc=$rc after ~$((i / 10))s"; return 0; }
    sleep 0.1; i=$((i + 1))
  done
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; wait "$spid" 2>/dev/null
  echo "alive-after-${secs}s (no wake; stopped by harness)"
}
# ack_all <code>: drain the queue like a supervisor would, then ack it
ack_all() {
  local code=$1 bin lab err seq gen id
  bin=$(codebin "$code"); lab=$(labof "$code"); err="$lab/drain.err"
  FM_HOME="$lab" "$bin/fm-wake-drain.sh" > "$lab/drain.out" 2> "$err" || return 1
  { echo "=== drain $(date +%T)"; cat "$lab/drain.out" "$err"; } >> "$lab/drain.history"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || { echo "no ack line"; cat "$err"; return 1; }
  for id in $(FM_HOME="$lab" "$bin/fm-open-loops.sh" --report | sed -n 's/^  "\([^"]*\)",.*/\1/p'); do
    FM_HOME="$lab" "$bin/fm-open-loops.sh" action "$id" escalated --evidence 'live lab supervisor escalated' >/dev/null || return 1
  done
  FM_HOME="$lab" "$bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
signals() { awk -F '\t' '$3=="signal"{n++} END{print n+0}' "$(labof "$1")/state/.wake-queue" 2>/dev/null || echo 0; }
signal_names() { awk -F '\t' '$3=="signal"{print $4}' "$(labof "$1")/state/.wake-queue" 2>/dev/null | sort | tr '\n' ' '; }
qlen() { local q; q="$(labof "$1")/state/.wake-queue"; [ -s "$q" ] && wc -l < "$q" | tr -d ' ' || echo 0; }
devof() { stat -f '%d' "$1"; }
# remount until the volume's device number differs (a fresh dummy per attempt holds the freed number)
remount_new_dev() {
  local before after k
  before=$(devof "$S/mnt")
  for _ in 1 2 3 4 5; do
    k=$(( $(cat "$S/dummy.n" 2>/dev/null || echo 10) + 1 )); echo "$k" > "$S/dummy.n"
    local t=0; until hdiutil detach -quiet "$S/mnt"; do t=$((t + 1)); [ "$t" -lt 15 ] || return 1; echo "  detach busy (try $t): $(lsof +D "$S/mnt" 2>/dev/null | awk 'NR>1{print $1"/"$2}' | sort -u | tr '\n' ' ')"; sleep 2; done
    hdiutil create -size 10m -fs APFS -volname fmdd$k -quiet "$S/dummy$k.dmg" || return 1
    mkdir -p "$S/dmnt$k"; hdiutil attach -nobrowse -mountpoint "$S/dmnt$k" "$S/dummy$k.dmg" >/dev/null 2>&1 || return 1
    hdiutil attach -nobrowse -owners on -mountpoint "$S/mnt" "$S/vol.dmg" >/dev/null 2>&1 || return 1
    after=$(devof "$S/mnt")
    [ "$after" != "$before" ] && { echo "remounted: device $before -> $after"; return 0; }
  done
  echo "device did not change"; return 1
}
# round <code> <max-passes> [pass-seconds]: run watcher passes, ack between, stop after 2 quiet passes
round() {
  local c=$1 max=$2 secs=${3:-15} p=1 r total=0 n quiet=0 names
  while [ "$p" -le "$max" ]; do
    r=$(run_watch "$c" "$secs")
    n=$(signals "$c"); total=$((total + n)); names=$(signal_names "$c")
    echo "  $c pass $p: $r ; signal rows queued=$n ; distinct row keys=$(printf "%s" "$names" | tr " " "\n" | sort -u | grep -c .) ; all queued rows=$(qlen "$c")${names:+ ; names: $names}"
    [ "$(qlen "$c")" = 0 ] || cp "$(labof "$c")/state/.wake-queue" "$(labof "$c")/queue-$(date +%H%M%S)-pass$p"
    [ "$(qlen "$c")" = 0 ] || ack_all "$c" || echo "  ack failed"
    case "$r:$n" in alive*:0) quiet=$((quiet + 1)) ;; *) quiet=0 ;; esac
    [ "$quiet" -ge 2 ] && break
    p=$((p + 1))
  done
  echo "  $c TOTAL signal wakes this round: $total"
}
classified() { cut -f3 "$1" 2>/dev/null; }
reported() { cut -f2 "$1" 2>/dev/null; }
# count seen / hb markers whose classified identity names <dev>
marker_devices() {  # <code> <dev>
  local st; st="$(labof "$1")/state"
  printf "seen=%s/$N hb=%s/$N" \
    "$(for m in "$st"/.seen-task*_status; do classified "$m"; echo; done | grep -c "@strong:$2:")" \
    "$(for m in "$st"/.hb-surfaced-task*; do classified "$m"; echo; done | grep -c "@strong:$2:")"
}
# current observed signature of a log, through HEAD's own owner
observed_sig() { FM_STATE_OVERRIDE="$LH/state" bash -c '. "$1/bin/fm-status-wake-lib.sh"; status_observed_signature "$2"' _ "$W" "$1"; }
# summarize beacon ages in a window [from,to] of epoch seconds
beacon_max() {  # <code> <from> <to>: max beacon age per window, after each watcher's first own beat
  awk -v a="$2" -v b="$3" '
    $1 == "START" { if ($2 >= a && $2 <= b) { skip=1; st=$2; passes++ } next }
    $1 < a || $1 > b { next }
    skip && $2 <= 1 { skip=0; fb=$1-st; if (fb > mfb) mfb=fb }
    skip { pre++; next }
    { n++; if ($2 > m) { m=$2; mt=$1; mc=$3 } }
    END { printf "passes=%d samples=%d max_age=%ds (at %s; running: %s) ; startup samples before first beat=%d (max %ds to first beat)\n", passes, n, m+0, mt, mc, pre, mfb }' "$(labof "$1")/beacon.samples"
}
# count markers whose reported signature equals the log's current observed signature
markers_current() {  # <code>
  local st f t sig s=0 h=0; st="$(labof "$1")/state"
  for f in "$st"/task*.status; do
    t=${f##*/}; t=${t%.status}; sig=$(observed_sig "$f")
    [ "$(reported "$st/.seen-${t}_status")" = "$sig" ] && s=$((s + 1))
    [ "$(reported "$st/.hb-surfaced-$t")" = "$sig" ] && h=$((h + 1))
  done
  printf "seen-reported-current=%s/$N hb-reported-current=%s/$N" "$s" "$h"
}
