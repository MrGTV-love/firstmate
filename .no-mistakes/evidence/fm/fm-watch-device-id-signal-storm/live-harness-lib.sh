# Live harness helpers. Usage: . lib.sh ; all paths are disposable.
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5K1HBHPZ710YK5KWPVX15NA
S=$(cat /tmp/fmdev.path)
codebin() { case "$1" in head) printf '%s/bin' "$W" ;; base) printf '%s/base/bin' "$S" ;; esac; }
# run_watch <code> <lab> <seconds> [extra env...] -> prints "exited rc" or "alive"
run_watch() {
  local code=$1 lab=$2 secs=$3 bin pid i=0; shift 3
  bin=$(codebin "$code")
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    TMUX_TMPDIR="$lab/tmux" FM_HOME="$lab" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_IDLE_REAP_INTERVAL=0 \
    FM_TYPESAFE_HEALTH_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 "$@" \
    bash "$bin/fm-watch.sh" >> "$lab/watch.out" 2>> "$lab/watch.err" &
  pid=$!
  while [ "$i" -lt "$((secs * 10))" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; echo "exited rc=$?"; return 0; }
    sleep 0.1; i=$((i + 1))
  done
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo "alive-after-${secs}s (no actionable wake; stopped by harness)"
}
ack_all() {  # <code> <lab>
  local bin lab=$2 err seq gen id
  bin=$(codebin "$1"); err="$lab/drain.err"
  FM_HOME="$lab" "$bin/fm-wake-drain.sh" > "$lab/drain.out" 2> "$err" || return 1; { echo "=== drain $(date +%T)"; cat "$lab/drain.out" "$err"; } >> "$lab/drain.history"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || { echo "no ack line"; cat "$err"; return 1; }
  for id in $(FM_HOME="$lab" "$bin/fm-open-loops.sh" --report | sed -n 's/^  "\([^"]*\)",.*/\1/p'); do
    FM_HOME="$lab" "$bin/fm-open-loops.sh" action "$id" escalated --evidence 'live lab supervisor escalated' >/dev/null || return 1
  done
  FM_HOME="$lab" "$bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
signals() { awk -F '\t' '$3=="signal"{n++} END{print n+0}' "$1/state/.wake-queue" 2>/dev/null || echo 0; }
signal_files() { awk -F '\t' '$3=="signal"{for(i=4;i<=NF;i++) print $i}' "$1/state/.wake-queue" 2>/dev/null | tr ' ' '\n' | grep -c . ; }
qlen() { [ -s "$1/state/.wake-queue" ] && wc -l < "$1/state/.wake-queue" | tr -d ' ' || echo 0; }
devof() { stat -f '%d' "$1"; }
remount() {  # detach vol, attach dummy (holds the freed disk number), reattach vol
  hdiutil detach -quiet "$S/mnt" || return 1
  hdiutil detach -quiet "$S/dmnt" 2>/dev/null
  hdiutil attach -nobrowse -mountpoint "$S/dmnt" "$S/dummy.dmg" >/dev/null 2>&1 || return 1
  hdiutil attach -nobrowse -owners on -mountpoint "$S/mnt" "$S/vol.dmg" >/dev/null 2>&1
}
# remount until the volume's device number differs (extra dummies hold freed numbers)
remount_new_dev() {
  local before after k=0
  before=$(devof "$S/mnt")
  while [ "$k" -lt 4 ]; do
    k=$((k + 1))
    hdiutil detach -quiet "$S/mnt" || return 1
    [ -e "$S/dummy$k.dmg" ] || hdiutil create -size 20m -fs APFS -volname fmdd$k -quiet "$S/dummy$k.dmg" || return 1
    mkdir -p "$S/dmnt$k"
    mount | grep -q " on $S/dmnt$k " || mount | grep -q " on /private$S/dmnt$k " \
      || hdiutil attach -nobrowse -mountpoint "$S/dmnt$k" "$S/dummy$k.dmg" >/dev/null 2>&1 || return 1
    hdiutil attach -nobrowse -owners on -mountpoint "$S/mnt" "$S/vol.dmg" >/dev/null 2>&1 || return 1
    after=$(devof "$S/mnt")
    [ "$after" != "$before" ] && { echo "remounted: device $before -> $after (attempts $k)"; return 0; }
  done
  echo "device did not change"; return 1
}
# round <code> <lab> <max-passes>: run watcher passes, ack between, report
round() {
  local c=$1 lab=$2 max=$3 p=1 r total=0 n quiet=0
  while [ "$p" -le "$max" ]; do
    r=$(run_watch "$c" "$lab" 15)
    n=$(signals "$lab"); total=$((total + n))
    echo "  $c pass $p: $r ; signal rows queued=$n ; all queued rows=$(qlen "$lab") ; last line: $(tail -1 "$lab/watch.out" | cut -c1-90)"
    [ "$(qlen "$lab")" = 0 ] || ack_all "$c" "$lab" || echo "  ack failed"
    case "$r:$n" in alive*:0) quiet=$((quiet + 1)) ;; *) quiet=0 ;; esac
    [ "$quiet" -ge 2 ] && break
    p=$((p + 1))
  done
  echo "  $c TOTAL signal wakes this round: $total"
}
remount_new_dev() {  # override: a fresh dummy per attempt holds the freed number
  local before after k
  before=$(devof "$S/mnt")
  for _ in 1 2 3 4; do
    k=$(( $(cat "$S/dummy.n" 2>/dev/null || echo 10) + 1 )); echo "$k" > "$S/dummy.n"
    hdiutil detach -quiet "$S/mnt" || return 1
    hdiutil create -size 10m -fs APFS -volname fmdd$k -quiet "$S/dummy$k.dmg" || return 1
    mkdir -p "$S/dmnt$k"; hdiutil attach -nobrowse -mountpoint "$S/dmnt$k" "$S/dummy$k.dmg" >/dev/null 2>&1 || return 1
    hdiutil attach -nobrowse -owners on -mountpoint "$S/mnt" "$S/vol.dmg" >/dev/null 2>&1 || return 1
    after=$(devof "$S/mnt")
    [ "$after" != "$before" ] && { echo "remounted: device $before -> $after"; return 0; }
  done
  echo "device did not change"; return 1
}
