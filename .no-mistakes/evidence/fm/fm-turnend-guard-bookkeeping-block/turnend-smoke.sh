#!/usr/bin/env bash
# Live smoke of bin/fm-turnend-guard.sh and bin/fm-guard.sh, driven through the
# real hook entry point (Stop payload on stdin) against a disposable lab
# FM_HOME minted by bin/fm-lab-home.sh, with a REAL bin/fm-watch.sh process as
# the live supervisor where a scenario needs one.
# Usage: turnend-smoke.sh <impl-root> <lab-fm-home>
# The impl root must be in primary scope (plain checkout or marked home).
set -u
ROOT=$1
export FM_HOME=$2
S=$FM_HOME/state
EV=$S/guard-events.jsonl
PAYLOAD='{"session_id":"lab-smoke-sess","stop_hook_active":false,"hook_event_name":"Stop"}'
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE
export CLAUDECODE=1
WATCH_PID=
HOLDER_PID=

hr() { printf '\n=== %s ===\n' "$*"; }
stop() {  # <label> [--claude] ; prints exit + stdout + stderr
  local label=$1; shift
  local out err rc
  out=$(mktemp); err=$(mktemp)
  printf '%s' "$PAYLOAD" | bash "$ROOT/bin/fm-turnend-guard.sh" "$@" >"$out" 2>"$err"; rc=$?
  printf -- '--- %s: exit=%s\n' "$label" "$rc"
  [ -s "$out" ] && { printf 'stdout: '; cat "$out"; }
  [ -s "$err" ] && { printf 'stderr:\n'; sed 's/^/  /' "$err"; }
  [ -f "$S/.turnend-claude-blocks" ] && printf 'budget-file: %s\n' "$(tr '\n' ' ' < "$S/.turnend-claude-blocks")"
  rm -f "$out" "$err"
  LAST_RC=$rc
}
events_since() {  # <line-count-before>
  tail -n +"$(( $1 + 1 ))" "$EV" 2>/dev/null | jq -c '{guard,decision,cleared_by,repeat,source_ok}' 2>/dev/null
}
evcount() { [ -f "$EV" ] && wc -l < "$EV" | tr -d ' ' || echo 0; }
start_watcher() {
  ( cd "$ROOT" && nohup bash bin/fm-watch.sh > "$FM_HOME/data/watch.out" 2>&1 & echo $! > "$FM_HOME/data/watch.pid" )
  WATCH_PID=$(cat "$FM_HOME/data/watch.pid")
  for _ in $(seq 1 50); do
    [ -e "$S/.watch.lock/pid" ] && [ -e "$S/.last-watcher-beat" ] && break
    sleep 0.2
  done
  WATCH_PID=$(cat "$S/.watch.lock/pid" 2>/dev/null || echo "$WATCH_PID")
  printf 'real watcher lock-pid=%s cmd=%s watcher-path=%s\n' "$WATCH_PID" "$(ps -o command= -p "$WATCH_PID")" "$(cat "$S/.watch.lock/watcher-path" 2>/dev/null)"
}
stop_watcher() {
  [ -n "$WATCH_PID" ] || return 0
  kill -CONT "$WATCH_PID" 2>/dev/null; kill "$WATCH_PID" 2>/dev/null
  for _ in $(seq 1 50); do kill -0 "$WATCH_PID" 2>/dev/null || break; sleep 0.2; done
  WATCH_PID=
}
reset_bookkeeping() {
  rm -rf "$S/.turnend-claude-blocks" "$S/.turnend-claude-blocks.lock" "$S/.claude-autoarm-failure-notified" \
    "$S/.claude-autoarm-failure-alarmed" "$S/.claude-autoarm-epoch" "$S/.claude-autoarm.lock" "$S"/.guard-watcher-stale-banner*
}
pull_guard() {  # <label>
  local out
  out=$(cd "$ROOT" && bash bin/fm-guard.sh 2>&1)
  printf -- '--- pull %s: ' "$1"
  if printf '%s' "$out" | grep -q 'WATCHER DOWN\|watcher is down\|supervision is DOWN\|SUPERVISION'; then
    printf 'WARNS\n'; printf '%s\n' "$out" | grep -v '^\s*$' | sed 's/^/  /' | head -8
  else
    printf 'silent\n'
  fi
}
liveness() {  # print the shared verdict
  ( cd "$ROOT" && STATE=$S bash -c '. bin/fm-supervision-lib.sh; . bin/fm-wake-lib.sh; . bin/fm-supervision-liveness-lib.sh; fm_supervision_liveness "$1" 300 "$2/bin/fm-watch.sh" "$FM_HOME"; printf "shared-verdict: live=%s reason=%s\n" "$FM_SUP_LIVE" "$FM_SUP_REASON"' _ "$S" "$ROOT" )
}
cleanup() {
  stop_watcher
  [ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null
  chmod -R u+w "$S" 2>/dev/null
}
trap cleanup EXIT

echo "impl-root=$ROOT"
echo "impl-head=$(git -C "$ROOT" rev-parse HEAD)"
echo "FM_HOME=$FM_HOME"
date -u
printf 'window=fm-lab:smoke\nharness=claude\n' > "$S/smoke.meta"   # one task in flight => supervision needed

hr "S1 supervised turn + episode bookkeeping cannot be reset (failure notice is a directory)"
reset_bookkeeping; start_watcher; liveness
mkdir "$S/.claude-autoarm-failure-notified"
stop "S1 --claude stop" --claude
[ -d "$S/.claude-autoarm-failure-notified" ] && echo "bookkeeping left intact (reset failed as designed)"
S1=$LAST_RC

hr "S1b supervised turn + episode reset lock held by another live process"
rm -rf "$S/.claude-autoarm-failure-notified"; : > "$S/.claude-autoarm-failure-notified"
mkdir -p "$S/.turnend-claude-blocks.lock"; sleep 600 & HOLDER_PID=$!
printf '%s\n' "$HOLDER_PID" > "$S/.turnend-claude-blocks.lock/pid"
kill -0 "$WATCH_PID" 2>/dev/null || { rm -rf "$S"/.watch.lock*; start_watcher; }
liveness
stop "S1b --claude stop" --claude
[ -e "$S/.claude-autoarm-failure-notified" ] && echo "bookkeeping left intact (reset lock contended)"
S1B=$LAST_RC
kill "$HOLDER_PID"; HOLDER_PID=; rm -rf "$S/.turnend-claude-blocks.lock"

hr "S5 shared liveness: fm-guard (pull) vs turn-end guard on the same states"
reset_bookkeeping
kill -0 "$WATCH_PID" 2>/dev/null || { rm -rf "$S"/.watch.lock*; start_watcher; }
echo "[state healthy: real watcher + fresh beacon]"; liveness; pull_guard healthy; FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 stop "turnend healthy" --claude; H_TE=$LAST_RC
stop_watcher; rm -rf "$S"/.watch.lock*; touch "$S/.last-watcher-beat"
echo "[state hand-off: fresh beacon, no watcher lock/process]"; liveness; pull_guard handoff; FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 stop "turnend handoff" --claude; HO_TE=$LAST_RC
reset_bookkeeping; rm -f "$S/.last-watcher-beat"
echo "[state missing lock + no beacon]"; liveness; pull_guard missing; FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 stop "turnend missing" --claude; MI_TE=$LAST_RC
reset_bookkeeping; start_watcher; kill -STOP "$WATCH_PID"; touch -t 202001010000 "$S/.last-watcher-beat"
echo "[state stale beacon with live identity-matched watcher (paused)]"; liveness; pull_guard stale; FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 stop "turnend stale" --claude; ST_TE=$LAST_RC
kill -CONT "$WATCH_PID"; stop_watcher; rm -rf "$S"/.watch.lock*

hr "S2 genuinely absent supervision, writable budget: 3 charged blocks then loud allow (default 12s auto-arm wait)"
reset_bookkeeping; touch -t 202001010000 "$S/.last-watcher-beat"; liveness
n0=$(evcount); S2=""
for i in 1 2 3 4 5; do stop "S2 --claude stop $i" --claude; S2="$S2 $LAST_RC"; done
echo "S2 exits:$S2"; echo "S2 guard events:"; events_since "$n0"

hr "S3 fresh failed-suppressed epoch + notice + budget from previous session / missing: exactly 3 blocks then loud allow"
for budget in previous-session missing; do
  reset_bookkeeping; : > "$S/.claude-autoarm-failure-notified"
  [ "$budget" = missing ] || printf 'session=sess-previous\ncount=2\nepoch=4\n' > "$S/.turnend-claude-blocks"
  r=""
  for i in 1 2 3 4; do
    printf 'epoch=4 owner_pid=999 outcome=failed-suppressed updated_at=%s\n' "$(date +%s)" > "$S/.claude-autoarm-epoch"
    FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 stop "S3[$budget] stop $i" --claude; r="$r $LAST_RC"
  done
  echo "S3[$budget] exits:$r"; eval "S3_${budget//-/_}=\"\$r\""
done

hr "S4 budget cannot be written: allow with one repair warning + warn event, never block"
for kind in budget-is-directory budget-lock-held state-readonly; do
  reset_bookkeeping; touch -t 202001010000 "$S/.last-watcher-beat"
  case $kind in
    budget-is-directory) mkdir "$S/.turnend-claude-blocks" ;;
    budget-lock-held) mkdir -p "$S/.turnend-claude-blocks.lock"; sleep 600 & HOLDER_PID=$!; printf '%s\n' "$HOLDER_PID" > "$S/.turnend-claude-blocks.lock/pid" ;;
    state-readonly) export FM_GUARD_EVENT_LOG="$FM_HOME/data/guard-events-ro.jsonl"; chmod a-w "$S" ;;
  esac
  [ "$kind" = state-readonly ] && EVF=$FM_GUARD_EVENT_LOG || EVF=$EV
  n0=$( [ -f "$EVF" ] && wc -l < "$EVF" | tr -d ' ' || echo 0 ); r=""
  for i in 1 2 3 4; do FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 stop "S4[$kind] stop $i" --claude; r="$r $LAST_RC"; done
  echo "S4[$kind] exits:$r"; echo "S4[$kind] events:"; tail -n +"$(( n0 + 1 ))" "$EVF" 2>/dev/null | jq -c '{guard,decision,cleared_by}'
  eval "S4_${kind//-/_}=\"\$r\""
  case $kind in
    budget-lock-held) kill "$HOLDER_PID"; HOLDER_PID= ;;
    state-readonly) chmod u+w "$S"; unset FM_GUARD_EVENT_LOG ;;
  esac
done

hr "S6 non-Claude (codex-style) turn-end with absent supervision still blocks"
reset_bookkeeping; touch -t 202001010000 "$S/.last-watcher-beat"
stop "S6 default-mode stop"; S6=$LAST_RC

hr "SUMMARY"
printf 'S1  supervised+notice-dir reset fail      exit=%s (want 0)\n' "$S1"
printf 'S1b supervised+reset lock held            exit=%s (want 0)\n' "$S1B"
printf 'S5  turnend healthy/handoff/missing/stale  %s/%s/%s/%s (want 0/2/2/2)\n' "$H_TE" "$HO_TE" "$MI_TE" "$ST_TE"
printf 'S2  absent, writable budget                %s (want 2 2 2 0 0)\n' "$S2"
printf 'S3  failed-suppressed previous-session     %s (want 2 2 2 0)\n' "$S3_previous_session"
printf 'S3  failed-suppressed missing budget       %s (want 2 2 2 0)\n' "$S3_missing"
printf 'S4  budget dir                             %s (want 0 0 0 0)\n' "$S4_budget_is_directory"
printf 'S4  budget lock held                       %s (want 0 0 0 0)\n' "$S4_budget_lock_held"
printf 'S4  state read-only                        %s (want 0 0 0 0)\n' "$S4_state_readonly"
printf 'S6  default mode absent                    exit=%s (want 2)\n' "$S6"
