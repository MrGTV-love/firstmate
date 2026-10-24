#!/usr/bin/env bash
# Live validation of `fm-control.sh <id> adopt` against a real Herdr lab session
# (guarded bin/fm-herdr-lab.sh, non-default fm-lab-* name) and real native omp
# processes restored with `omp --resume=<file>` (no FM_SPAWN_GEN in their
# environment), inside a disposable marked lab FM_HOME.
# Usage: adopt-live-lab.sh <firstmate-worktree> <evidence-dir>
set -uo pipefail
ROOT=$1
EVID=$2
HELPER="$ROOT/bin/fm-herdr-lab.sh"
REAL_PATH=$PATH
LOG="$EVID/adopt-live-transcript.log"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
FAILS=0
check() { # <name> <condition-status>
  if [ "$2" = 0 ]; then say "RESULT PASS: $1"; else say "RESULT FAIL: $1"; FAILS=$((FAILS + 1)); fi
}

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-adopt-fx.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab home create failed"; exit 1; }
SESSION=$("$HELPER" name adopt-live)
OWNED=0
NATIVE="$TMP/native-processes"; : > "$NATIVE"

cleanup() {
  local pid start
  if [ "$OWNED" = 1 ]; then
    PATH="$REAL_PATH" "$HELPER" teardown "$SESSION" >>"$LOG" 2>&1 && say "guarded teardown of $SESSION completed" \
      || say "TEARDOWN FAILED for $SESSION; retained $TMP $LAB"
  fi
  while IFS=$'\t' read -r pid start; do
    for _ in $(seq 1 100); do
      kill -0 "$pid" 2>/dev/null || break
      [ "$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null)" = "$start" ] || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && [ "$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null)" = "$start" ] \
      && say "native pid $pid still alive after teardown" || say "native pid $pid exit confirmed"
  done < "$NATIVE"
  chmod -R u+w "$TMP" "$LAB" 2>/dev/null
  rm -rf "$TMP" "$LAB" && say "removed private fixture trees"
}
trap cleanup EXIT

# Plain FM_HOME on a marked lab home; no override relocation.
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset FM_GATE_REFUSE_BYPASS FM_TASK_ID HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV TMUX TMUX_PANE FM_SPAWN_GEN
export FM_HOME="$LAB" HERDR_SESSION="$SESSION"
STATE="$LAB/state"
mkdir -p "$STATE" "$LAB/config" "$LAB/data" "$TMP/fakebin"
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'off\n' > "$LAB/config/herdr-presentation-spaces"

"$HELPER" prepare "$SESSION" >>"$LOG" 2>&1 || { say "prepare failed"; exit 1; }
OWNED=1
"$HELPER" provision "$SESSION" >>"$LOG" 2>&1 || { say "provision failed"; exit 1; }
say "lab session: $SESSION (non-default, guarded helper)"
run() { PATH="$REAL_PATH" "$HELPER" run "$SESSION" "$@"; }

NATIVE_HOME="$TMP/native-home"
mkdir -p "$NATIVE_HOME/.omp/agent" "$NATIVE_HOME/.config" \
  "$NATIVE_HOME/.local/share/omp" "$NATIVE_HOME/.local/state/omp" "$NATIVE_HOME/.cache/omp"
printf 'composer:\n  shape: box\n' > "$NATIVE_HOME/.omp/agent/config.yml"
NATIVE_ENV=("HOME=$NATIVE_HOME"
  "XDG_CONFIG_HOME=$NATIVE_HOME/.config" "XDG_DATA_HOME=$NATIVE_HOME/.local/share"
  "XDG_STATE_HOME=$NATIVE_HOME/.local/state" "XDG_CACHE_HOME=$NATIVE_HOME/.cache"
  PI_CONFIG_DIR=.omp "PI_CODING_AGENT_DIR=$NATIVE_HOME/.omp/agent"
  OMP_PROFILE=default PI_PROFILE=default OMP_SKIP_SETUP=1
  OPENAI_API_KEY=fm-non-submitting-fixture)
env "${NATIVE_ENV[@]}" PI_CODING_AGENT_DIR= PATH="$REAL_PATH" "$HELPER" run "$SESSION" integration install omp >>"$LOG" 2>&1

# Every adapter herdr call is forced through the guarded lab helper.
export FM_LAB_REAL_PATH="$PATH" FM_LAB_HELPER="$HELPER" FM_LAB_SESSION="$SESSION"
cat > "$TMP/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "${2:-}" = "$FM_LAB_SESSION" ] || exit 91; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
PATH="$FM_LAB_REAL_PATH" "$FM_LAB_HELPER" run "$FM_LAB_SESSION" "${args[@]}"
SH
chmod +x "$TMP/fakebin/herdr"
export PATH="$TMP/fakebin:$PATH"

git_project() { # <proj> <wt> <branch>
  git init -q -b main "$1" && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    && git -C "$1" worktree add -q -b "$3" "$2"
}
seed_session() { # <file> <cwd>
  python3 - "$1" "$2" <<'PY'
import datetime, json, sys, uuid
now = datetime.datetime.now(datetime.timezone.utc)
with open(sys.argv[1], 'w') as f:
    slot = {'type':'title','v':1,'title':'','updatedAt':now.isoformat(),'pad':''}
    slot['pad'] = ' ' * (255 - len(json.dumps(slot, separators=(',', ':')).encode('utf-8')))
    f.write(json.dumps(slot, separators=(',', ':')) + '\n')
    f.write(json.dumps({'type':'session','version':3,'id':str(uuid.uuid4()),
                       'timestamp':now.isoformat(),'cwd':sys.argv[2]}) + '\n')
    mid = uuid.uuid4().hex[:8]
    f.write(json.dumps({'type':'model_change','id':mid,'parentId':None,
                       'timestamp':now.isoformat(),'model':'openai/gpt-4.1'}) + '\n')
    f.write(json.dumps({'type':'message','id':uuid.uuid4().hex[:8],'parentId':mid,
                       'timestamp':now.isoformat(),'message':{'role':'user','content':[{
                       'type':'text','text':'Isolated lifecycle fixture. Stay idle.'}],
                       'timestamp':int(now.timestamp()*1000)}}) + '\n')
PY
}
# new_task <id> <cwd-inside-wt-relative> -> sets WS PANE TAB WT for the task
new_task() {
  local id=$1
  git_project "$TMP/proj-$id" "$TMP/wt-$id" "$id" || { say "git setup failed for $id"; exit 1; }
  WT=$(cd "$TMP/wt-$id" && pwd -P)
  WS=$(run workspace create --cwd "$WT" --label "fm-$id" | jq -r '.result.workspace.workspace_id')
  PANE=$(run pane list --workspace "$WS" | jq -r '.result.panes[0].pane_id')
  TAB=$(run pane get "$PANE" | jq -r '.result.pane.tab_id')
  cat > "$STATE/$id.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$id
worktree=$WT
project=$TMP/proj-$id
harness=omp
kind=ship
mode=no-mistakes
spawn_gen=gen-$id
launch_proof=env-v1
yolo=off
model=openai-codex/gpt-6.1-sol
effort=low
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF
}
launch_in_pane() { # <pane> <script-body>
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$TMP/launch-$1.sh"
  run pane send-text "$1" "bash $(printf %q "$TMP/launch-$1.sh")" >/dev/null
  run pane send-keys "$1" Enter >/dev/null
}
fg_pid_for() { # <pane> <argv-needle>
  run pane process-info --pane "$1" | jq -er --arg n "$2" '
    [.result.process_info.foreground_processes[] | select(any(.argv[]?; contains($n)))]
    | select(length == 1) | .[0].pid'
}
wait_omp() { # <pane> <ref> -> PID
  local pid
  for _ in $(seq 1 100); do
    pid=$(fg_pid_for "$1" "$2" 2>/dev/null) && \
      [ "$(run agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_session.value // empty')" != "" ] && break
    pid=; sleep 0.2
  done
  [ -n "$pid" ] || return 1
  printf '%s\t%s\n' "$pid" "$(LC_ALL=C ps -p "$pid" -o lstart=)" >> "$NATIVE"
  printf '%s' "$pid"
}
dead_pid() { sh -c 'exit 0' & local p=$!; wait "$p"; kill -0 "$p" 2>/dev/null && return 1; printf '%s' "$p"; }
write_record() { # <id> <json>
  printf '%s\n' "$2" > "$STATE/$1.omp-session.json"
}
ctl() { # <id> <verb> [env...] -> sets OUT RC
  OUT=$(nice -n 20 timeout 600 "$ROOT/bin/fm-control.sh" "$1" "$2" 2>&1); RC=$?
  say "\$ fm-control.sh $1 $2   (exit $RC)"; printf '%s\n' "$OUT" | sed 's/^/    /' | tee -a "$LOG" >/dev/null
  printf '%s\n' "$OUT" | sed 's/^/    /'
}
sum() { cksum "$STATE/$1.omp-session.json" 2>/dev/null; }

# ---------------- task A: real native resumed omp (the stuck-task shape) -----
A=adopt-a
new_task "$A"; A_WT=$WT; A_PANE=$PANE
mkdir -p "$A_WT/sub/inner"
REF_A="$TMP/omp-session-a.jsonl"; seed_session "$REF_A" "$A_WT/sub/inner"
printf -v L '%q ' env "${NATIVE_ENV[@]}" omp "--resume=$REF_A"
launch_in_pane "$A_PANE" "cd $(printf %q "$A_WT/sub/inner") && exec $L"
A_PID=$(wait_omp "$A_PANE" "$REF_A") || { say "native omp A did not start/register"; run pane read "$A_PANE" --format text >>"$LOG"; exit 1; }
say "task A: native omp pid=$A_PID pane=$A_PANE cwd=$(lsof -a -p "$A_PID" -d cwd -Fn | sed -n 's/^n//p')"
say "task A: live environment FM_SPAWN_GEN present? $(ps eww -p "$A_PID" | grep -c 'FM_SPAWN_GEN=' )"
say "task A: herdr registration: $(run agent get "$A_PANE" | jq -c '.result.agent | {agent, agent_session}')"
sleep 3
DEAD=$(dead_pid)
STUCK=$(jq -nc --arg g "gen-$A" --argjson p "$DEAD" --arg t "$REF_A" \
  '{version:1, spawn_gen:$g, pid:$p, task_session_file:$t, current_session_file:""}')
write_record "$A" "$STUCK"
say "task A stuck record (dead pid $DEAD, empty current): $(cat "$STATE/$A.omp-session.json")"

say "=== S0 baseline: interrupt on the stuck restored omp is refused ==="
ctl "$A" interrupt; [ "$RC" != 0 ] && grep -q 'cannot positively attribute' <<<"$OUT"; check "S0 interrupt refused before adopt" $?

say "=== S7a worker refusal ==="
B=$(sum "$A"); OUT=$(FM_TASK_ID=someworker nice -n 20 timeout 600 "$ROOT/bin/fm-control.sh" "$A" adopt 2>&1); RC=$?
say "\$ FM_TASK_ID=someworker fm-control.sh $A adopt (exit $RC)"; say "    $OUT"
[ "$RC" != 0 ] && grep -q 'workers cannot adopt' <<<"$OUT" && [ "$(sum "$A")" = "$B" ]; check "S7a worker adopt refused, record unchanged" $?

say "=== S7b session without the home lock ==="
ctl "$A" adopt; [ "$RC" != 0 ] && grep -q 'lock-owning main' <<<"$OUT" && [ "$(sum "$A")" = "$B" ]; check "S7b no-lock adopt refused, record unchanged" $?

# Take the lab home lock the real way, from this Claude harness ancestry.
nice -n 20 timeout 600 "$ROOT/bin/fm-lock.sh" >>"$LOG" 2>&1; say "fm-lock.sh acquire exit $?; $("$ROOT/bin/fm-lock.sh" status)"

say "=== S5 record spawn_gen differs from metadata ==="
write_record "$A" "$(jq -c '.spawn_gen="gen-someone-else"' <<<"$STUCK")"; B=$(sum "$A")
ctl "$A" adopt; [ "$RC" != 0 ] && grep -q 'generation proof' <<<"$OUT" && [ "$(sum "$A")" = "$B" ] \
  && [ "$(jq -r .spawn_gen "$STATE/$A.omp-session.json")" = gen-someone-else ]; check "S5 generation mismatch refused, no generation fabricated" $?
write_record "$A" "$STUCK"

say "=== S4 two metas claim one pane ==="
sed "s/^endpoint_task_id=.*/endpoint_task_id=adopt-dup/; s#^worktree=.*#worktree=$TMP/elsewhere#" "$STATE/$A.meta" > "$STATE/adopt-dup.meta"
mkdir -p "$TMP/elsewhere"; B=$(sum "$A")
ctl "$A" adopt; [ "$RC" != 0 ] && grep -q 'unique-claim proof' <<<"$OUT" && [ "$(sum "$A")" = "$B" ]; check "S4 duplicate pane claim refused" $?
rm -f "$STATE/adopt-dup.meta"

say "=== S3a another task owns a deeper worktree around the cwd ==="
printf 'window=%s:p-none\nworktree=%s\nbackend=herdr\nharness=omp\nherdr_session=%s\nherdr_pane_id=p-none\n' \
  "$SESSION" "$A_WT/sub" "$SESSION" > "$STATE/adopt-nested.meta"; B=$(sum "$A")
ctl "$A" adopt; [ "$RC" != 0 ] && grep -q 'workspace proof' <<<"$OUT" && grep -q 'adopt-nested' <<<"$OUT" && [ "$(sum "$A")" = "$B" ]; check "S3a deeper nested worktree of another task refused" $?
say "=== S3b another task records the same worktree (tie) ==="
printf 'window=%s:p-none\nworktree=%s\nbackend=herdr\nharness=omp\nherdr_session=%s\nherdr_pane_id=p-none\n' \
  "$SESSION" "$A_WT" "$SESSION" > "$STATE/adopt-nested.meta"
ctl "$A" adopt; [ "$RC" != 0 ] && grep -q 'unique deepest match' <<<"$OUT" && [ "$(sum "$A")" = "$B" ]; check "S3b same-depth worktree tie refused" $?
rm -f "$STATE/adopt-nested.meta"

say "=== S6 same live PID with the extension's empty unproven mark ==="
write_record "$A" "$(jq -c --argjson p "$A_PID" '.pid=$p' <<<"$STUCK")"; B=$(sum "$A")
ctl "$A" adopt; [ "$RC" != 0 ] && grep -q 'live PID is empty or invalid' <<<"$OUT" && [ "$(sum "$A")" = "$B" ]; check "S6a adopt refused for live-PID empty mark, unchanged" $?
ctl "$A" interrupt; [ "$RC" != 0 ] && [ "$(sum "$A")" = "$B" ]; check "S6b interrupt still refused on live-PID empty mark" $?
write_record "$A" "$STUCK"

say "=== S1 happy path: adopt the stuck restored omp, then interrupt with no keystroke ==="
run pane read "$A_PANE" --format text > "$EVID/pane-A-before-interrupt.txt"
ctl "$A" adopt; ADOPT_RC=$RC; ADOPT_OUT=$OUT
say "record after adopt: $(cat "$STATE/$A.omp-session.json")"
jq -e --argjson p "$A_PID" --arg g "gen-$A" --arg t "$REF_A" '
  (keys == ["current_session_file","pid","spawn_gen","task_session_file","version"])
  and .version == 1 and .spawn_gen == $g and .pid == $p and .task_session_file == $t
  and (.current_session_file | type == "string" and startswith("/"))' "$STATE/$A.omp-session.json" >/dev/null
REC_OK=$?
[ "$(stat -f %i "$(jq -r .current_session_file "$STATE/$A.omp-session.json")")" = "$(stat -f %i "$REF_A")" ]; SAME=$?
[ "$ADOPT_RC" = 0 ] && grep -qx "adopted: $A" <<<"$ADOPT_OUT" && [ "$REC_OK" = 0 ] && [ "$SAME" = 0 ]
check "S1a adopt writes version=1, same spawn_gen, live pid, preserved task file, live current file" $?
ls -la "$STATE" | grep -E 'adopt|omp-session' | tee -a "$LOG" >/dev/null
[ -z "$(find "$STATE" -name ".$A.omp-session.adopt.*")" ]; check "S1b no staged/capture leftovers" $?
[ "$(fg_pid_for "$A_PANE" "$REF_A")" = "$A_PID" ]; check "S1c adopt did not restart or replace the agent" $?
ctl "$A" interrupt; INT_RC=$RC
run pane read "$A_PANE" --format text > "$EVID/pane-A-after-interrupt.txt"
[ "$INT_RC" = 0 ]; check "S1d interrupt succeeds after adopt (no human keystroke)" $?
[ "$(fg_pid_for "$A_PANE" "$REF_A")" = "$A_PID" ]; check "S1e agent survives interrupt (same PID)" $?

say "=== S2 repeat adopt is refused and leaves the record byte-identical ==="
B=$(sum "$A"); ctl "$A" adopt
[ "$RC" != 0 ] && grep -q 'live process' <<<"$OUT" && [ "$(sum "$A")" = "$B" ]; check "S2 repeat adopt refused, record byte-identical" $?

# ---------------- task E: native omp pinned to another launch generation -----
E=adopt-e
new_task "$E"; E_PANE=$PANE
REF_E="$TMP/omp-session-e.jsonl"; seed_session "$REF_E" "$WT"
printf -v L '%q ' env "${NATIVE_ENV[@]}" FM_SPAWN_GEN=gen-another-launch omp "--resume=$REF_E"
launch_in_pane "$E_PANE" "exec $L"
E_PID=$(wait_omp "$E_PANE" "$REF_E") || { say "native omp E did not start"; }
say "task E: native omp pid=$E_PID pinned FM_SPAWN_GEN=gen-another-launch"
sleep 3
write_record "$E" "$(jq -nc --arg g "gen-$E" --argjson p "$(dead_pid)" --arg t "$REF_E" \
  '{version:1, spawn_gen:$g, pid:$p, task_session_file:$t, current_session_file:""}')"; B=$(sum "$E")
say "=== S8 process pinned to another generation ==="
ctl "$E" adopt; [ "$RC" != 0 ] && grep -q 'pinned to another launch generation' <<<"$OUT" && [ "$(sum "$E")" = "$B" ]; check "S8a pinned-elsewhere adopt refused, record unchanged" $?
ctl "$E" interrupt; [ "$RC" != 0 ] && [ "$(sum "$E")" = "$B" ]; check "S8b interrupt still refused for pinned-elsewhere" $?

# ---------------- task D: ambiguous foreground (two non-shell processes) ------
D=adopt-d
new_task "$D"; D_PANE=$PANE
launch_in_pane "$D_PANE" "sleep 601 & sleep 602; wait"
sleep 2
say "task D foreground: $(run pane process-info --pane "$D_PANE" | jq -c '[.result.process_info.foreground_processes[] | {pid,name}]')"
write_record "$D" "$(jq -nc --arg g "gen-$D" --argjson p "$(dead_pid)" --arg t "$REF_A" \
  '{version:1, spawn_gen:$g, pid:$p, task_session_file:$t, current_session_file:""}')"; B=$(sum "$D")
say "=== S9 ambiguous foreground ==="
ctl "$D" adopt; [ "$RC" != 0 ] && grep -q 'foreground proof' <<<"$OUT" && [ "$(sum "$D")" = "$B" ]; check "S9 ambiguous foreground refused" $?

# ---------------- task F: single non-agent foreground process ----------------
F=adopt-f
new_task "$F"; F_PANE=$PANE
launch_in_pane "$F_PANE" "exec sleep 603"
sleep 2
write_record "$F" "$(jq -nc --arg g "gen-$F" --argjson p "$(dead_pid)" --arg t "$REF_A" \
  '{version:1, spawn_gen:$g, pid:$p, task_session_file:$t, current_session_file:""}')"; B=$(sum "$F")
say "=== S10 non-agent foreground process ==="
ctl "$F" adopt; [ "$RC" != 0 ] && grep -q 'process proof' <<<"$OUT" && [ "$(sum "$F")" = "$B" ]; check "S10 non-agent foreground refused" $?

say "Herdr lab runtime: $(run status --json | jq -c '{server: .server.running, session: .session.name?}' 2>/dev/null)"
say "TOTAL FAILS: $FAILS"
exit "$FAILS"
