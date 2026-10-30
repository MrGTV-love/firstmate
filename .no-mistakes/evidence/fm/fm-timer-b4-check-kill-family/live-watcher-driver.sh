#!/usr/bin/env bash
# Live driver: runs the real bin/fm-watch.sh (from a given checkout) against a
# disposable marked lab home, with real custom checks. Usage:
#   live-watcher-driver.sh <checkout-root> <scenario> <lab-home>
# Scenarios: slow45, cpu, hung, sigkill, term
set -u
ROOT=$1 SCEN=$2 LAB=$3
STATE="$LAB/state"
WATCH="$ROOT/bin/fm-watch.sh"
REG="$ROOT/bin/fm-check-register.sh"
UNREG="$ROOT/bin/fm-check-unregister.sh"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
live() { kill -0 "$1" 2>/dev/null && ! ps -o stat= -p "$1" 2>/dev/null | grep -q Z; }

reset_state() {
  local f id
  for f in "$STATE"/*.check.sh; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .check.sh)
    FM_HOME="$LAB" bash "$UNREG" "$id" >/dev/null 2>&1 || rm -f "$f" "$STATE/$id.check-trust"
  done
  rm -f "$STATE"/.last-check "$STATE"/*.check-stopped "$STATE"/check-* "$STATE"/*.pid
  : > "$STATE/.wake-queue"
  : > "$STATE/.watch-triage.log" 2>/dev/null || true
}

arm() {  # <id> <body>
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$STATE/$1.check.sh"
  chmod 0700 "$STATE/$1.check.sh"
  FM_HOME="$LAB" bash "$REG" "$1" || { log "register $1 failed"; exit 1; }
}

start_watch() {  # extra env assignments...
  rm -f "$STATE/.watcher-down" "$STATE/open-loops.json" "$STATE/.open-loops-surfaced"
  env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
    FM_HOME="$LAB" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" \
    bash "$WATCH" > "$LAB/watch.out" 2> "$LAB/watch.err" &
  WPID=$!
  log "watcher pid $WPID started ($*)"
}

wait_sweep() {  # <max-seconds>
  local i
  for ((i = 0; i < $1 * 10; i++)); do
    [ -e "$STATE/.last-check" ] && return 0
    live "$WPID" || return 0
    sleep 0.1
  done
  return 1
}

stop_watch() {
  kill -TERM "$WPID" 2>/dev/null
  wait "$WPID" 2>/dev/null
  log "watcher exited rc=$?"
}

show() {
  log "--- watch.out"; cat "$LAB/watch.out"
  log "--- watch.err (tail)"; tail -5 "$LAB/watch.err"
  log "--- wake queue rows (check rows)"; grep -F 'check' "$STATE/.wake-queue" | cut -f4- || true
  log "--- triage log (check lines)"; grep -F 'check ' "$STATE/.watch-triage.log" 2>/dev/null || true
}

reset_state
case "$SCEN" in
  slow45)
    # Healthy check that progresses on stderr for ~45 s: longer than the old 30 s wall kill.
    arm slow 'for i in $(seq 1 15); do echo "step $i" >&2; sleep 3; done; touch "$FM_HOME/state/check-finished"; echo slow-check-completed'
    t0=$SECONDS; start_watch
    wait_sweep 120 || log "sweep did not finish in 120s"
    log "sweep took $((SECONDS - t0))s"
    stop_watch; show
    [ -e "$STATE/check-finished" ] && log "RESULT: check ran to completion" || log "RESULT: check was killed before it finished"
    grep -qF 'slow-check-completed' "$STATE/.wake-queue" && log "RESULT: completion wake queued" || log "RESULT: no completion wake"
    ;;
  cpu)
    # No output at all for ~15 s, only process-tree CPU, inactivity minimum 3 s.
    arm cpu 'end=$((SECONDS+15)); while [ $SECONDS -lt $end ]; do :; done; touch "$FM_HOME/state/check-finished"; echo cpu-check-completed'
    t0=$SECONDS; start_watch FM_CHECK_TIMEOUT=3
    wait_sweep 120 || log "sweep did not finish in 120s"
    log "sweep took $((SECONDS - t0))s"
    stop_watch; show
    [ -e "$STATE/check-finished" ] && log "RESULT: CPU-only check ran to completion" || log "RESULT: CPU-only check was stopped"
    ;;
  hung)
    # Silent, CPU-idle check plus a later check in the same sweep; inactivity minimum 3 s.
    arm a-hung 'echo $$ > "$FM_HOME/state/check-hung.pid"; [ -e "$FM_HOME/state/check-heal" ] && { echo healed; exit 0; }; sleep 600 & echo $! > "$FM_HOME/state/check-sleep.pid"; wait'
    arm b-after 'echo after-ran'
    for pass in 1 2 3; do
      rm -f "$STATE/.last-check"; : > "$STATE/.wake-queue"
      [ "$pass" = 3 ] && touch "$STATE/check-heal"
      log "=== pass $pass"
      t0=$SECONDS; start_watch FM_CHECK_TIMEOUT=3 FM_WATCH_HANDLING_SUCCESSOR=$([ $pass = 1 ] && echo 0 || echo 1)
      wait_sweep 120 || log "sweep did not finish in 120s"
      log "sweep took $((SECONDS - t0))s"
      stop_watch; show
      for p in check-hung.pid check-sleep.pid; do
        [ -s "$STATE/$p" ] || continue
        q=$(cat "$STATE/$p")
        live "$q" && log "RESULT: $p ($q) STILL ALIVE" || log "RESULT: $p ($q) gone"
      done
      log "unknown wakes this pass: $(grep -c 'result unknown, retry next pass' "$STATE/.wake-queue")"
      log "episode marker: $([ -e "$STATE/a-hung.check-stopped" ] && echo present || echo absent)"
    done
    ;;
  sigkill|term)
    # Progressing, TERM-resistant check with a descendant; then the watcher dies.
    arm owner 'trap "" TERM; sleep 600 & echo $! > "$FM_HOME/state/check-desc.pid"; echo $PPID > "$FM_HOME/state/check-launcher.pid"; echo $$ > "$FM_HOME/state/check-main.pid"; while :; do echo working >&2; sleep 0.2; done'
    start_watch FM_CHECK_TIMEOUT=3
    for ((i = 0; i < 300; i++)); do [ -s "$STATE/check-main.pid" ] && break; sleep 0.1; done
    main=$(cat "$STATE/check-main.pid"); desc=$(cat "$STATE/check-desc.pid"); launcher=$(cat "$STATE/check-launcher.pid")
    log "check main=$main desc=$desc launcher=$launcher"
    sleep 5
    live "$main" && log "after 5s with inactivity minimum 3s, progressing check still alive (expected)"
    if [ "$SCEN" = sigkill ]; then kill -KILL "$WPID"; log "sent SIGKILL to watcher"; else kill -TERM "$WPID"; log "sent TERM to watcher"; fi
    wait "$WPID" 2>/dev/null; log "watcher exited rc=$?"
    for ((i = 0; i < 300; i++)); do live "$launcher" || break; sleep 0.1; done
    log "launcher $(live "$launcher" && echo STILL ALIVE || echo exited)"
    for p in "$main" "$desc"; do live "$p" && { log "RESULT: pid $p STILL ALIVE (leak)"; kill -KILL "$p"; } || log "RESULT: pid $p gone"; done
    ;;
esac
reset_state
