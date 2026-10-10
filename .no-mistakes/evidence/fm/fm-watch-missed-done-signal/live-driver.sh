#!/usr/bin/env bash
# Live driver: run the real firstmate watcher (bin/fm-watch-arm.sh -> fm-watch.sh)
# and the real Main drain (bin/fm-wake-drain.sh) against a disposable lab home.
# Usage: driver.sh <code-dir> <scenario>
set -u
CODE=$1 SCEN=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$CODE/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 \
  || /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4H906AJDNT83YE1DPHM1VRK/bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
ST="$LAB/state"
mkdir -p "$LAB/projects/demo" "$LAB/drv"
CLEAN_ENV=(env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999)
ts() { date +%H:%M:%S; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }
task() { printf 'project=%s/projects/demo\nkind=%s\n' "$LAB" "$2" > "$ST/$1.meta"; printf 'working: setup\n' > "$ST/$1.status"; }
arm_fg() {  # <label> [env...]
  local label=$1; shift
  (cd "$CODE" && "${CLEAN_ENV[@]}" "$@" timeout 90 bin/fm-watch-arm.sh) > "$LAB/drv/$label.out" 2>&1
  log "$label exit=$? output:"; sed 's/^/    /' "$LAB/drv/$label.out"
}
arm_bg() {  # <label> [env...]
  local label=$1; shift
  (cd "$CODE" && "${CLEAN_ENV[@]}" "$@" timeout 90 bin/fm-watch-arm.sh) > "$LAB/drv/$label.out" 2>&1 &
  ARM_PID=$!
}
drain() {  # <label> : Main's real drain + acknowledgement
  local label=$1 seq gen
  "${CLEAN_ENV[@]}" "$CODE/bin/fm-wake-drain.sh" > "$LAB/drv/$label.drain" 2> "$LAB/drv/$label.drain.err"
  log "$label Main drain (stdout):"; sed 's/^/    /' "$LAB/drv/$label.drain"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$LAB/drv/$label.drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$LAB/drv/$label.drain.err")
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    "${CLEAN_ENV[@]}" "$CODE/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
    log "$label acked through seq $seq"
  fi
}
settle() {  # consume the one-time first open-loop-ledger wake so later cycles reach the step under test
  log "settle: let Main consume the first open-loop-ledger wake"
  arm_fg settle "$@"; drain settle >/dev/null
}
queue() { log "wake queue rows:"; cut -f2- "$ST/.wake-queue" 2>/dev/null | sed 's/^/    /'; }
register_check() {  # check driven by $LAB/drv/check-mode
  cat > "$ST/slow.check.sh" <<SH
#!/usr/bin/env bash
mode=\$(cat "$LAB/drv/check-mode" 2>/dev/null)
case "\$mode" in
  slow-quiet) touch "$LAB/drv/check-started"; sleep 6 ;;
  slow-loud) touch "$LAB/drv/check-started"; sleep 6; echo 'slow: upstream PR merged'; echo off > "$LAB/drv/check-mode" ;;
  loud) echo 'slow: upstream PR merged' ;;
esac
exit 0
SH
  chmod 0700 "$ST/slow.check.sh"
  "${CLEAN_ENV[@]}" "$CODE/bin/fm-check-register.sh" slow || log "check registration FAILED"
}

log "code=$CODE scenario=$SCEN lab=$LAB"
case "$SCEN" in
  between)
    task scout-a scout
    arm_fg arm1-baseline; drain arm1
    log "no watcher running: scout appends done line"
    printf 'done [at=%s]: backlog triage finished\n' "$(date +%s)" >> "$ST/scout-a.status"
    arm_fg arm2; queue; drain arm2
    ;;
  keyed)
    task vernant-d2 ship; task vernant-d3 ship
    arm_fg arm1-baseline; drain arm1
    log "no watcher running: lanes append keyed needs-decision and blocked lines"
    printf 'needs-decision [key=main996-preservation-diagnosis] [at=%s]: preserve or drop?\n' "$(date +%s)" >> "$ST/vernant-d2.status"
    printf 'blocked [key=analytics-gre1948-native-validation]: need native validation access\n' >> "$ST/vernant-d3.status"
    arm_fg arm2; queue; drain arm2
    ;;
  incycle-quiet|incycle-loud)
    task scout-a scout; register_check; echo off > "$LAB/drv/check-mode"
    arm_fg arm1-baseline FM_CHECK_INTERVAL=1; drain arm1
    settle FM_CHECK_INTERVAL=1
    echo "slow-${SCEN#incycle-}" > "$LAB/drv/check-mode"; rm -f "$LAB/drv/check-started"; sleep 2
    arm_bg arm2 FM_CHECK_INTERVAL=1
    i=0; while [ ! -e "$LAB/drv/check-started" ] && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
    sleep 1
    log "watcher running a slow check: scout appends done line"
    printf 'done [at=%s]: backlog triage finished\n' "$(date +%s)" >> "$ST/scout-a.status"
    wait "$ARM_PID"; log "arm2 exit=$? output:"; sed 's/^/    /' "$LAB/drv/arm2.out"
    queue; drain arm2
    log "next arm after Main handled the batch:"
    arm_fg arm3 FM_CHECK_INTERVAL=1
    ;;
  chatty)
    task scout-a scout; register_check; echo off > "$LAB/drv/check-mode"
    arm_fg arm0-baseline FM_CHECK_INTERVAL=1; drain arm0
    settle FM_CHECK_INTERVAL=1
    echo loud > "$LAB/drv/check-mode"
    for r in 1 2 3 4 5 6; do
      sleep 2
      printf 'blocked [key=k%s]: round %s\n' "$r" "$r" >> "$ST/scout-a.status"
      log "round $r: fleet appended a status line; a due check also reports every round"
      arm_fg "arm$r" FM_CHECK_INTERVAL=1; drain "arm$r" >/dev/null
    done
    ;;
  lockgrace)
    task scout-a scout
    arm_fg arm1-baseline; drain arm1
    settle
    mkdir -p "$LAB/drv/shim"; real_mv=$(command -v mv)
    cat > "$LAB/drv/shim/mv" <<SH
#!/usr/bin/env bash
dest=\${!#}
"$real_mv" "\$@" || exit
if [ "\$dest" = "$ST/.prelude-progress" ] && [ ! -e "$LAB/drv/injected" ] && [ "\$(cat "\$dest")" = 7 ]; then
  printf 'done: finished beside process-event delivery\n' >> "$ST/scout-a.status"; touch "$LAB/drv/injected"
fi
SH
    chmod +x "$LAB/drv/shim/mv"
    "${CLEAN_ENV[@]}" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append check procevent:live-lab:1 "check: process-event fixture"' _ "$CODE"
    log "queued one process-event result; arming with a 6s signal grace"
    arm_bg arm2 PATH="$LAB/drv/shim:$PATH" FM_SIGNAL_GRACE=6
    i=0; while [ ! -e "$LAB/drv/injected" ] && [ $i -lt 600 ]; do sleep 0.1; i=$((i+1)); done
    log "status line landed in the step-6..7 race window (injected=$([ -e "$LAB/drv/injected" ] && echo yes || echo no))"
    ( while kill -0 "$ARM_PID" 2>/dev/null; do
        if [ -e "$ST/.wake-queue.lock" ]; then hp=$(cat "$ST/.wake-queue.lock/pid" 2>/dev/null)
          printf '%s holder=%s %s\n' "$(perl -MTime::HiRes=time -e 'printf "%.1f", time')" "$hp" "$(ps -o command= -p "$hp" 2>/dev/null | cut -c1-80)"; fi
        sleep 0.2; done ) > "$LAB/drv/holders" 2>&1 &
    max=0 n=0
    while kill -0 "$ARM_PID" 2>/dev/null && [ $n -lt 400 ]; do
      n=$((n+1)); t0=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
      "${CLEAN_ENV[@]}" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append check "queue-writer:$2" "check: concurrent queue writer"' _ "$CODE" "$n"
      t1=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000'); w=$((t1-t0)); [ $w -le $max ] || max=$w; [ $w -lt 2000 ] || log "slow append #$n waited ${w}ms ending $(perl -MTime::HiRes=time -e 'printf "%.1f", time')"
      sleep 0.05
    done
    wait "$ARM_PID"; log "arm2 exit=$? output:"; sed 's/^/    /' "$LAB/drv/arm2.out"
    log "concurrent queue writer: $n appends, max lock wait ${max}ms (signal grace = 6000ms)"
    if [ "$max" -ge 2000 ]; then log "lock holder samples:"; sed 's/^/    /' "$LAB/drv/holders"; fi
    awk -F '\t' '$3=="signal"{print "    signal row queued: " $4}' "$ST/.wake-queue"
    arm_fg arm3
    ;;
esac
(cd "$CODE" && "${CLEAN_ENV[@]}" bin/fm-watch-arm.sh --stop >/dev/null 2>&1)
rm -rf "$LAB"
log "lab removed"
