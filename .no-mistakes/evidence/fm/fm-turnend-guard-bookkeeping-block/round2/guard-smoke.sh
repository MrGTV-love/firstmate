#!/usr/bin/env bash
# Hook-level smoke: real bin/fm-turnend-guard.sh + bin/fm-guard.sh, plain-checkout
# trees of TARGET (and BASE for before/after) under a marked lab home, real
# bin/fm-watch-arm.sh watcher for the healthy state.
set -u
W=${WORKTREE:?}; E=${EVID:?}; TARGET=${TARGET:?}; BASE=${BASE:?}
cd "$W"
unset FM_GUARD_GRACE FM_ARM_CONFIRM_TIMEOUT
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
L=$FM_HOME
export FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100
mk_tree() { local rev=$1 d=$2; mkdir -p "$d"; git archive "$rev" | tar -x -C "$d"; git -C "$d" init -q; git -C "$d" -c user.name=lab -c user.email=lab@example.invalid add -A -f; git -C "$d" -c user.name=lab -c user.email=lab@example.invalid commit -qm tree --no-verify; }
C=$L/projects/primary; B=$L/projects/base
mk_tree "$TARGET" "$C"; mk_tree "$BASE" "$B"
echo "implementation_root=$W head=$TARGET"
echo "lab=$L plain_tree=$C tree=$(git -C "$C" rev-parse 'HEAD^{tree}') expected_tree=$(git rev-parse "$TARGET^{tree}")"
echo "base_tree=$(git -C "$B" rev-parse 'HEAD^{tree}') expected_base=$(git rev-parse "$BASE^{tree}")"
S=$L/state
WPIDS=()
clean() { chmod -R u+rwX "$S" 2>/dev/null; find "$S" -mindepth 1 -maxdepth 1 ! -name .fm-lab-tmux-dir -exec rm -rf {} + ; }
stop_w() {
  local p; p=$(cat "$S/.watch.lock/pid" 2>/dev/null || true)
  [ "$p" != "${SLEEP_PID:-}" ] || p=""
  for x in "${WPIDS[@]:-}" "$p"; do [ -n "$x" ] && kill "$x" 2>/dev/null; done
  sleep 0.3
  for x in "${WPIDS[@]:-}" "$p"; do [ -n "$x" ] && kill -9 "$x" 2>/dev/null; done
  WPIDS=(); return 0
}
trap 'stop_w; chmod -R u+rwX "$L" 2>/dev/null; "$W/bin/fm-lab-home.sh" teardown "$L" && rm -rf "$L"; [ -z "${SLEEP_PID:-}" ] || kill "$SLEEP_PID" 2>/dev/null' EXIT
start_w() { # <tree>
  local t=$1 i
  FM_HOME=$L nohup bash "$t/bin/fm-watch-arm.sh" >>"$E/guard-smoke-watcher.log" 2>&1 </dev/null &
  WPIDS+=($!); disown $! 2>/dev/null
  for i in $(seq 1 100); do
    if FM_HOME=$L FM_STATE_OVERRIDE= bash -c '. "$1/bin/fm-supervision-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-supervision-liveness-lib.sh"; fm_supervision_watcher_live "$2" "$1/bin/fm-watch.sh"' _ "$t" "$S" 2>/dev/null; then echo "   real watcher pid=$(cat "$S/.watch.lock/pid") tree=$t"; return 0; fi
    sleep 0.2
  done
  echo "   WATCHER DID NOT COME UP"; return 1
}
SID=sess-smoke
hook() { # <tree> [flag]; sets RC OUT
  local t=$1 fl=${2:-}
  OUT=$(printf '{"stop_hook_active":%s,"session_id":"%s"}' "${ACTIVE:-false}" "$SID" | FM_HOME=$L bash "$t/bin/fm-turnend-guard.sh" $fl 2>&1); RC=$?
}
evs() { jq -c '[.decision,.cleared_by]' "$S/guard-events.jsonl" 2>/dev/null | sort | uniq -c | tr '\n' ';' ; }
budget() { [ -f "$S/.turnend-claude-blocks" ] && tr '\n' ' ' <"$S/.turnend-claude-blocks" || { [ -e "$S/.turnend-claude-blocks" ] && echo "<non-file>" || echo "<absent>"; }; }
seq6() { # runs 6 Claude stops; prints rc list and repair counts
  local t=$1 i rcs="" rep="" blind=0 warn=0 down=0
  for i in 1 2 3 4 5 6; do
    hook "$t" --claude; rcs+="$RC "
    rep+="$(grep -o 'bin/fm-claude-stop-autoarm.sh' <<<"$OUT" | wc -l | tr -d ' ') "
    grep -q 'TURN WOULD END BLIND' <<<"$OUT" && blind=$((blind+1))
    grep -q 'cannot be locked or written' <<<"$OUT" && warn=$((warn+1))
    grep -q 'GENUINELY DOWN' <<<"$OUT" && down=$((down+1))
  done
  echo "   rc=[$rcs] repair_cmd_count=[$rep] block_banners=$blind unavailable_warnings=$warn exhausted_diagnostics=$down budget=$(budget)"
  echo "   events: $(evs)"
}
sleep 3000 & SLEEP_PID=$!
disown "$SLEEP_PID" 2>/dev/null
identity() { FM_STATE_OVERRIDE=$S bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$C" "$1"; }
seed_notice() { : >"$S/.claude-autoarm-failure-notified"; printf 'epoch=3 owner_pid=999 outcome=%s updated_at=1\n' "$1" >"$S/.claude-autoarm-epoch"; [ "${2:-old}" = fresh ] || touch -t 202001010000 "$S/.claude-autoarm-epoch"; }

echo; echo "=== S1 live watcher + failed episode bookkeeping (BASE vs TARGET) ==="
for tree in base target; do
  [ $tree = base ] && T=$B || T=$C
  for v in notice-dir budget-lock-live budget-dir state-readonly; do
    clean; : >"$S/task1.meta"; start_w "$T" >/dev/null
    printf 'session=%s\ncount=3\nepoch=2\n' "$SID" >"$S/.turnend-claude-blocks"
    case $v in
      notice-dir) mkdir "$S/.claude-autoarm-failure-notified" ;;
      budget-lock-live) mkdir "$S/.turnend-claude-blocks.lock"; echo "$SLEEP_PID" >"$S/.turnend-claude-blocks.lock/pid" ; : >"$S/.claude-autoarm-failure-notified" ;;
      budget-dir) rm -f "$S/.turnend-claude-blocks"; mkdir "$S/.turnend-claude-blocks" ;;
      state-readonly) : >"$S/.claude-autoarm-failure-notified"; touch "$S/.last-watcher-beat"; chmod 555 "$S" ;;
    esac
    hook "$T" --claude; chmod 755 "$S"
    echo "$tree/$v: exit=$RC blocked_banner=$(grep -c 'TURN WOULD END BLIND' <<<"$OUT") out_len=${#OUT} events=$(evs)"; [ -z "$OUT" ] || printf '   output: %s\n' "$OUT"
    stop_w
  done
done

echo; echo "=== S2 genuine absent supervision, normal writable budget, every exit path (6 stops) ==="
for v in absent clean-epoch stale-rewake failed-notice away-dead-daemon alarmed alarm-unwritable owner-lock-live observe-init-missing-budget observe-init-prev-session; do
  clean; : >"$S/task1.meta"
  case $v in
    clean-epoch) printf 'epoch=7 owner_pid=999 outcome=clean updated_at=1\n' >"$S/.claude-autoarm-epoch"; touch -t 202001010000 "$S/.claude-autoarm-epoch" ;;
    stale-rewake) printf 'epoch=7 owner_pid=999 outcome=rewake updated_at=1\n' >"$S/.claude-autoarm-epoch"; touch -t 202001010000 "$S/.claude-autoarm-epoch" ;;
    failed-notice) seed_notice failed-suppressed ;;
    away-dead-daemon) : >"$S/.afk"; mkdir "$S/.supervise-daemon.lock"; echo 999999 >"$S/.supervise-daemon.lock/pid"; echo x >"$S/.supervise-daemon.lock/pid-identity" ;;
    alarmed) : >"$S/.claude-autoarm-failure-alarmed" ;;
    alarm-unwritable) mkdir "$S/.claude-autoarm-failure-alarmed" ;;
    owner-lock-live) mkdir "$S/.claude-autoarm.lock"; echo "$SLEEP_PID" >"$S/.claude-autoarm.lock/pid" ;;
    observe-init-missing-budget) seed_notice failed-suppressed fresh ;;
    observe-init-prev-session) seed_notice failed-suppressed fresh; printf 'session=older\ncount=2\nepoch=1\n' >"$S/.turnend-claude-blocks" ;;
  esac
  echo "$v:"; seq6 "$C"
done
clean; : >"$S/task1.meta"; seed_notice failed-suppressed; echo "BASE failed-notice with notice removed mid-episode (uncapped-path comparison):"
for i in 1 2 3 4 5 6; do hook "$B" --claude; printf '%s ' "$RC"; rm -f "$S/.claude-autoarm-failure-notified"; done; echo "budget=$(budget)"
clean; : >"$S/task1.meta"; seed_notice failed-suppressed; echo "TARGET failed-notice with notice removed mid-episode:"
for i in 1 2 3 4 5 6; do hook "$C" --claude; printf '%s ' "$RC"; rm -f "$S/.claude-autoarm-failure-notified"; done; echo "budget=$(budget)"

echo; echo "=== S3 budget cannot be locked or written, no supervision (6 stops each) ==="
for tree in base target; do
  [ $tree = base ] && T=$B || T=$C
  for v in budget-dir budget-symlink-to-dir budget-lock-live state-readonly-log-writable state-readonly-no-log; do
    clean; : >"$S/task1.meta"
    case $v in
      budget-dir) mkdir "$S/.turnend-claude-blocks" ;;
      budget-symlink-to-dir) mkdir "$L/data/bd"; ln -s "$L/data/bd" "$S/.turnend-claude-blocks" ;;
      budget-lock-live) mkdir "$S/.turnend-claude-blocks.lock"; echo "$SLEEP_PID" >"$S/.turnend-claude-blocks.lock/pid" ;;
      state-readonly-log-writable) : >"$S/guard-events.jsonl"; chmod 555 "$S" ;;
      state-readonly-no-log) chmod 555 "$S" ;;
    esac
    echo "$tree/$v:"; t0=$(date +%s); seq6 "$T"; echo "   elapsed=$(( $(date +%s)-t0 ))s"
    rm -rf "$L/data/bd"
    chmod 755 "$S"
  done
done

echo; echo "=== S4 recovery: exhausted episode, real watcher returns, next outage gets a fresh budget ==="
clean; : >"$S/task1.meta"; seed_notice failed-suppressed
seq6 "$C"
echo "   before recovery: budget=$(budget) notice=$([ -e "$S/.claude-autoarm-failure-notified" ] && echo present || echo absent) alarm=$([ -e "$S/.claude-autoarm-failure-alarmed" ] && echo present || echo absent)"
start_w "$C"
hook "$C" --claude; echo "   with real watcher: exit=$RC out_len=${#OUT} budget=$(budget) notice=$([ -e "$S/.claude-autoarm-failure-notified" ] && echo present || echo absent) alarm=$([ -e "$S/.claude-autoarm-failure-alarmed" ] && echo present || echo absent)"
stop_w
rm -rf "$S/.watch.lock"
echo "   next outage:"; seq6 "$C"

echo; echo "=== S5 idle stops: episode kept with notice, block budget cleared without notice ==="
clean; printf 'session=%s\ncount=4\nepoch=2\n' "$SID" >"$S/.turnend-claude-blocks"; : >"$S/.claude-autoarm-failure-notified"
hook "$C" --claude; echo "no need + notice: exit=$RC budget=$(budget) notice=$([ -e "$S/.claude-autoarm-failure-notified" ] && echo present || echo absent)"
clean; printf 'session=%s\ncount=4\nepoch=2\n' "$SID" >"$S/.turnend-claude-blocks"
hook "$C" --claude; echo "no need + no notice: exit=$RC budget=$(budget)"

echo; echo "=== S6 one predicate: pull warning vs turn-end, same state (BASE vs TARGET) ==="
pi_marks() { # <tree> <session pid>
  local t=$1 pid=$2 v
  for pair in fm-primary-pi-watch.ts:.pi-watch-extension-loaded:w fm-primary-turnend-guard.ts:.pi-turnend-extension-loaded:t; do
    v=$(FM_STATE_OVERRIDE=$S bash -c '. "$1"; fm_pi_extension_version "$2"' _ "$t/bin/fm-wake-lib.sh" "$t/.pi/extensions/${pair%%:*}")
    m=${pair#*:}; m=${m%%:*}
    if [ "${pair##*:}" = w ]; then printf '%s\n%s\ngeneration=1 phase=active\n' "$v" "$pid" >"$S/$m"; else printf '%s\n%s\n' "$v" "$pid" >"$S/$m"; fi
  done
  echo "$pid" >"$S/.lock"
}
printf '%-8s %-11s %-22s %-14s %-14s %s\n' tree model state pull-warning turnend-exit agree
for tree in base target; do
  [ $tree = base ] && T=$B || T=$C
  for model in persistent autoarm extension; do
    for st in healthy claude-rewake-handoff pi-extension-handoff missing-lock stale-beacon wrong-identity away-live-daemon away-dead-daemon idle; do
      clean
      [ "$st" = idle ] || : >"$S/task1.meta"
      touch "$S/.last-watcher-beat"
      case $st in
        healthy) start_w "$T" >/dev/null ;;
        claude-rewake-handoff)
          echo "$SLEEP_PID" >"$S/.lock"
          printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=g\n' "$SLEEP_PID" >"$S/.claude-autoarm-epoch"
          printf 'acked:handling:g\n' >"$S/.watcher-down"
          touch -t 201901010000 "$S/.last-watcher-beat"; touch -t 202001010000 "$S/.claude-autoarm-epoch" ;;
        pi-extension-handoff) pi_marks "$T" "$SLEEP_PID" ;;
        stale-beacon|wrong-identity)
          mkdir "$S/.watch.lock"; echo "$SLEEP_PID" >"$S/.watch.lock/pid"; echo "$L" >"$S/.watch.lock/fm-home"; echo "$T/bin/fm-watch.sh" >"$S/.watch.lock/watcher-path"; identity "$SLEEP_PID" >"$S/.watch.lock/pid-identity"
          [ $st = stale-beacon ] && touch -t 202001010000 "$S/.last-watcher-beat"
          [ $st = wrong-identity ] && echo wrong >"$S/.watch.lock/pid-identity" ;;
        away-live-daemon) : >"$S/.afk"; mkdir "$S/.supervise-daemon.lock"; echo "$SLEEP_PID" >"$S/.supervise-daemon.lock/pid"; identity "$SLEEP_PID" >"$S/.supervise-daemon.lock/pid-identity" ;;
        away-dead-daemon) : >"$S/.afk"; mkdir "$S/.supervise-daemon.lock"; echo 999999 >"$S/.supervise-daemon.lock/pid"; echo x >"$S/.supervise-daemon.lock/pid-identity" ;;
      esac
      g=$(FM_HOME=$L FM_SUPERVISION_MODEL=$model bash "$T/bin/fm-guard.sh" 2>&1); grc=$?
      w=silent; grep -q 'WATCHER DOWN - SUPERVISION IS OFF' <<<"$g" && w=WARN
      grc2=$grc
      FM_SUPERVISION_MODEL=$model hook "$T"
      ag=no; { [ $w = WARN ] && [ "$RC" = 2 ]; } && ag=yes; { [ $w = silent ] && [ "$RC" = 0 ]; } && ag=yes
      printf '%-8s %-11s %-22s %-14s %-14s %s (guard_exit=%s)\n' $tree $model $st $w "$RC" $ag $grc2
      stop_w
      kill -0 "$SLEEP_PID" 2>/dev/null || { echo "HELPER DIED: table invalid"; exit 9; }
    done
  done
done

echo; echo "=== S7 non-Claude path keeps per-turn loop guard and ignores the Claude budget ==="
clean; : >"$S/task1.meta"; mkdir "$S/.turnend-claude-blocks"; mkdir "$S/.turnend-claude-blocks.lock"; echo "$SLEEP_PID" >"$S/.turnend-claude-blocks.lock/pid"
ACTIVE=false hook "$C"; echo "no flag, first stop: exit=$RC banner=$(grep -c 'TURN WOULD END BLIND' <<<"$OUT") events=$(evs)"
ACTIVE=true hook "$C"; echo "no flag, stop_hook_active: exit=$RC out_len=${#OUT}"
echo; echo "smoke complete"
