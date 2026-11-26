#!/usr/bin/env bash
# Live Herdr-lab proof for the omp-promax Bun runtime adoption fix.
# Real pieces: a named fm-lab-* Herdr session (bin/fm-herdr-lab.sh), the INSTALLED
# omp-promax launcher (Bun runtime + installed cli.ts) resumed natively in a lab pane
# with no prompt submitted, a marked lab FM_HOME (bin/fm-lab-home.sh), and the real
# bin/fm-control.sh at the gate head. The base revision's bin/ is extracted to scratch
# for the red leg. No real worker, no real FM_HOME, no default Herdr session is touched.
# Usage: herdr-lab-bun-omp-adopt.sh <worktree-root> <base-commit>
set -u
ROOT=$1 BASE=$2
HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAUNCHER="$HOME/.local/share/omp-promax-fix/omp-promax"
REAL_PATH=$PATH
say() { printf '\n=== %s\n' "$*"; }
SESSION=$("$HELPER" name bunadopt) || exit 1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-bunadopt.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
eval "$("$ROOT/bin/fm-lab-home.sh" env 2>"$TMP/lab-env.err")" || { cat "$TMP/lab-env.err"; exit 1; }
LAB_TEARDOWN=$(grep -o "[^ ]*fm-lab-home.sh teardown .*" "$TMP/lab-env.err" | head -1)
OWNED=0 PIDS=()
cleanup() {
  say "teardown"
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  if [ "$OWNED" = 1 ]; then PATH="$REAL_PATH" "$HELPER" teardown "$SESSION" && echo "herdr lab $SESSION torn down"; fi
  sleep 1
  pgrep -fl "$TMP" || echo "no lab process left under $TMP"
  if [ -n "$LAB_TEARDOWN" ]; then eval "$LAB_TEARDOWN" && echo "lab home removed"; fi
  chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP" && echo "scratch removed"
}
trap cleanup EXIT
unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV TMUX TMUX_PANE FM_SPAWN_GEN FM_TASK_ID
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE
export HERDR_SESSION=$SESSION
echo "lab FM_HOME=$FM_HOME herdr session=$SESSION head=$(git -C "$ROOT" rev-parse HEAD) base=$BASE"
"$HELPER" prepare "$SESSION" || exit 1; OWNED=1
"$HELPER" provision "$SESSION" || exit 1
run() { PATH="$REAL_PATH" "$HELPER" run "$SESSION" "$@"; }

# Base revision bin/ for the red leg.
mkdir -p "$TMP/base"; git -C "$ROOT" archive "$BASE" bin .omp | tar -x -C "$TMP/base"

# Isolated omp home: no operator key, settings or agent dir; Herdr's omp integration only.
NH="$TMP/native-home"
mkdir -p "$NH/.omp/agent" "$NH/.config" "$NH/.local/share/omp" "$NH/.local/state/omp" "$NH/.cache/omp"
printf 'composer:\n  shape: box\n' > "$NH/.omp/agent/config.yml"
NENV=("HOME=$NH" "XDG_CONFIG_HOME=$NH/.config" "XDG_DATA_HOME=$NH/.local/share" "XDG_STATE_HOME=$NH/.local/state"
  "XDG_CACHE_HOME=$NH/.cache" PI_CONFIG_DIR=.omp "PI_CODING_AGENT_DIR=$NH/.omp/agent" OMP_PROFILE=default
  PI_PROFILE=default OMP_SKIP_SETUP=1 OPENAI_API_KEY=fm-non-submitting-fixture)
env "${NENV[@]}" PI_CODING_AGENT_DIR= PATH="$REAL_PATH" "$HELPER" run "$SESSION" integration install omp >/dev/null || echo "integration install failed"
echo "integration files: $(cd "$NH" && find . -type f | tr '\n' ' ')"

# Task fixture in the lab home.
ID=bunadopt-task
STATE="$FM_HOME/state"; mkdir -p "$STATE" "$FM_HOME/data/$ID" "$FM_HOME/config" "$FM_HOME/projects" "$TMP/fakebin"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"; printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
git init -q -b main "$TMP/proj"; git -C "$TMP/proj" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$TMP/proj" worktree add -q -b "fm/$ID" "$TMP/wt"; WT=$(cd "$TMP/wt" && pwd -P)
printf '# Task\n## Captain'"'"'s intent\nIsolated lab fixture; stay idle.\n' > "$FM_HOME/data/$ID/brief.md"
REF="$TMP/task-session.jsonl"
python3 -I - "$REF" "$WT" <<'PY'
import datetime, json, sys, uuid
now = datetime.datetime.now(datetime.timezone.utc)
with open(sys.argv[1], 'w') as f:
    slot = {'type':'title','v':1,'title':'','updatedAt':now.isoformat(),'pad':''}
    slot['pad'] = ' ' * (255 - len(json.dumps(slot, separators=(',', ':')).encode()))
    f.write(json.dumps(slot, separators=(',', ':')) + '\n')
    f.write(json.dumps({'type':'session','version':3,'id':str(uuid.uuid4()),'timestamp':now.isoformat(),'cwd':sys.argv[2]}) + '\n')
    mid = uuid.uuid4().hex[:8]
    f.write(json.dumps({'type':'model_change','id':mid,'parentId':None,'timestamp':now.isoformat(),'model':'openai/gpt-4.1'}) + '\n')
    f.write(json.dumps({'type':'message','id':uuid.uuid4().hex[:8],'parentId':mid,'timestamp':now.isoformat(),
        'message':{'role':'user','content':[{'type':'text','text':'Stay idle. This is a lab fixture.'}],'timestamp':int(now.timestamp()*1000)}}) + '\n')
PY
WS=$(run workspace create --cwd "$WT" --label "fm-$ID" | jq -r '.result.workspace.workspace_id')
PANE=$(run pane list --workspace "$WS" | jq -r '.result.panes[0].pane_id')
TAB=$(run pane get "$PANE" | jq -r '.result.pane.tab_id')
META="$STATE/$ID.meta"
cat > "$META" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$ID
worktree=$WT
project=$TMP/proj
harness=omp
kind=ship
mode=no-mistakes
spawn_gen=gen-before-reboot
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
# The pre-reboot record: same generation, the task's session, a PID that is gone.
jq -nc --arg task "$REF" '{version:1,spawn_gen:"gen-before-reboot",pid:2000000001,task_session_file:$task,current_session_file:""}' > "$STATE/$ID.omp-session.json"
# Every Herdr call from production code is forced through the lab helper.
export FM_LAB_REAL_PATH="$REAL_PATH" FM_LAB_HELPER="$HELPER" FM_LAB_SESSION="$SESSION" FM_LAB_REG_DIR="$TMP/reg"; mkdir -p "$TMP/reg"
cat > "$TMP/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in --session) [ "${2:-}" = "$FM_LAB_SESSION" ] || exit 91; shift 2 ;; *) args+=("$1"); shift ;; esac
done
# STAND-IN (labelled): Herdr 0.9.5 keeps no session path for a Bun-named foreground in this lab, so for a pane
# listed in $FM_LAB_REG_DIR the real `agent get` answer gets the restored registration (kind path, task session).
if [ "${args[0]:-}" = agent ] && [ "${args[1]:-}" = get ] && [ -f "$FM_LAB_REG_DIR/${args[2]:-none}" ]; then
  out=$(PATH="$FM_LAB_REAL_PATH" "$FM_LAB_HELPER" run "$FM_LAB_SESSION" "${args[@]}") || { printf '%s\n' "$out"; exit 1; }
  printf '%s' "$out" | jq -c --arg ref "$(cat "$FM_LAB_REG_DIR/${args[2]}")" '.result.agent.agent_session = {kind:"path", value:$ref}'
  exit 0
fi
PATH="$FM_LAB_REAL_PATH" "$FM_LAB_HELPER" run "$FM_LAB_SESSION" "${args[@]}"
SH
chmod +x "$TMP/fakebin/herdr"; export PATH="$TMP/fakebin:$REAL_PATH"
say "session lock: this shell's harness takes the lab home lock (the lock-owning main Firstmate)"
"$ROOT/bin/fm-lock.sh" && echo "lock acquired in lab home"

say "launch: natively resume the installed omp-promax Bun runtime in the lab pane (no prompt is submitted)"
printf -v L '%q ' env "${NENV[@]}" "$LAUNCHER" "--resume=$REF"
printf '#!/usr/bin/env bash\nexec %s\n' "$L" > "$TMP/launch.sh"
run pane send-text "$PANE" "bash $TMP/launch.sh" >/dev/null; run pane send-keys "$PANE" Enter >/dev/null
PID=
for _ in $(seq 1 100); do
  PID=$(run pane process-info --pane "$PANE" | jq -er '[.result.process_info.foreground_processes[] | select(.name=="bun" or (.argv0//""|endswith("/bun")))] | select(length==1) | .[0].pid' 2>/dev/null) && break
  sleep 0.2
done
[ -n "$PID" ] || { echo "FAIL: no bun foreground"; run pane process-info --pane "$PANE"; exit 1; }
PIDS+=("$PID")
sleep 4
say "Herdr pane process-info (real Herdr, real installed omp; environment not read)"
run pane process-info --pane "$PANE" | jq -c '.result.process_info | {shell_pid, foreground_processes:[.foreground_processes[]|{pid,name,argv0,argv}]}'
echo "ps comm: $(ps -o comm= -p "$PID")"
for _ in $(seq 1 50); do run agent get "$PANE" 2>/dev/null | jq -e '.result.agent.agent_session.value' >/dev/null 2>&1 && break; sleep 0.2; done
say "Herdr agent registration for the pane (native, before any stand-in)"
run agent get "$PANE" 2>&1 | jq -c '.result.agent | {agent, agent_session}' 2>/dev/null || run agent get "$PANE" 2>&1 | head -3
run agent explain "$PANE" 2>&1 | head -12
if ! run agent get "$PANE" 2>/dev/null | jq -e '.result.agent.agent_session.value' >/dev/null 2>&1; then
  say "STAND-IN: report the restored registration Herdr kept for the task (omp, task session path), as Herdr's native restore leaves it"
  run pane report-agent --source fm-lab-restore-standin --agent omp --state idle "$PANE" >/dev/null
  printf '%s' "$REF" > "$TMP/reg/$PANE"
  echo "real Herdr: $(run agent get "$PANE" 2>&1 | jq -c '.result.agent | {agent, agent_session}')"
  echo "through the wrapper production uses: $(herdr --session "$SESSION" agent get "$PANE" 2>&1 | jq -c '.result.agent | {agent, agent_session}')"
fi

say "identity predicate on the live PID: BASE vs HEAD fm_launch_proof_pid_is_omp"
( . "$TMP/base/bin/fm-backend.sh"; fm_backend_source herdr; . "$TMP/base/bin/fm-launch-proof-lib.sh"
  if fm_launch_proof_pid_is_omp "$PID"; then echo "BASE: is_omp=yes"; else echo "BASE: is_omp=no"; fi )
( . "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr; . "$ROOT/bin/fm-launch-proof-lib.sh"
  if fm_launch_proof_pid_is_omp "$PID"; then echo "HEAD: is_omp=yes"; else echo "HEAD: is_omp=no"; fi )
echo "HEAD fm-omp-identity.py interactive: $(python3 -I "$ROOT/bin/fm-omp-identity.py" interactive "$PID" 2>&1; echo " exit=$?")"
echo "HEAD fm-omp-identity.py writer:      $(python3 -I "$ROOT/bin/fm-omp-identity.py" writer "$PID" 2>&1; echo " exit=$?")"
echo "HEAD fm-omp-identity.py holds task session: $(python3 -I "$ROOT/bin/fm-omp-identity.py" holds "$PID" "$REF" 2>&1; echo " exit=$?")"

say "incident symptom at HEAD before adopt: interrupt (relaunch is not run: a successful relaunch would start a real omp)"
"$ROOT/bin/fm-control.sh" "$ID" interrupt 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}"

if ! python3 -I "$ROOT/bin/fm-omp-identity.py" holds "$PID" "$REF" >/dev/null 2>&1; then
  say "the idle resumed omp holds no session file; type a titled /rename into the LAB omp (no model call) so it writes its session"
  run pane send-text "$PANE" "/rename lab-title" >/dev/null; run pane send-keys "$PANE" Enter >/dev/null
  for _ in $(seq 1 50); do python3 -I "$ROOT/bin/fm-omp-identity.py" holds "$PID" "$REF" >/dev/null 2>&1 && break; sleep 0.2; done
  echo "holds task session after rename: $(python3 -I "$ROOT/bin/fm-omp-identity.py" holds "$PID" "$REF" 2>&1; echo " exit=$?")"
  echo "open session files: $(lsof -p "$PID" 2>/dev/null | grep -c jsonl)"
fi
snap() { shasum -a 256 "$META" "$STATE/$ID.omp-session.json" | awk '{print $1}' | tr '\n' ' '; }
say "BASE adopt (expected red: process proof refusal)"
B=$(snap); "$TMP/base/bin/fm-control.sh" "$ID" adopt 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}"
[ "$B" = "$(snap)" ] && echo "record and meta unchanged by base adopt"

say "HEAD adopt"
B=$(snap); "$ROOT/bin/fm-control.sh" "$ID" adopt 2>&1 | tail -4; RC=${PIPESTATUS[0]}; echo "exit=$RC"
echo "record now: $(cat "$STATE/$ID.omp-session.json")"
[ "$B" = "$(snap)" ] && echo "record and meta unchanged"
if [ "$RC" = 0 ]; then
  echo "record pid matches live PID $PID: $(jq -e --argjson p "$PID" '.pid==$p' "$STATE/$ID.omp-session.json")"
  say "HEAD after adopt: launch-proof verdict and lifecycle interrupt"
  ( . "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr; . "$ROOT/bin/fm-launch-proof-lib.sh"; echo "verdict: $(fm_launch_proof_herdr "$META")" )
  "$ROOT/bin/fm-control.sh" "$ID" interrupt 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}"
  say "HEAD second adopt on the same process (expected same-PID refusal)"
  "$ROOT/bin/fm-control.sh" "$ID" adopt 2>&1 | tail -3; echo "exit=${PIPESTATUS[0]}"
fi
foreign_case() { # <label> <command...>
  local id=bunadopt-$1 ws pane tab meta fpid; shift
  ws=$(run workspace create --cwd "$WT" --label "fm-$id" | jq -r '.result.workspace.workspace_id')
  pane=$(run pane list --workspace "$ws" | jq -r '.result.panes[0].pane_id'); tab=$(run pane get "$pane" | jq -r '.result.pane.tab_id')
  meta="$STATE/$id.meta"; sed -e "s#^window=.*#window=$SESSION:$pane#" -e "s#^endpoint_task_id=.*#endpoint_task_id=$id#" \
    -e "s#^herdr_workspace_id=.*#herdr_workspace_id=$ws#" -e "s#^herdr_tab_id=.*#herdr_tab_id=$tab#" -e "s#^herdr_pane_id=.*#herdr_pane_id=$pane#" \
    -e "s#^spawn_gen=.*#spawn_gen=gen-before-reboot#" "$META" > "$meta"
  mkdir -p "$FM_HOME/data/$id"; cp "$FM_HOME/data/$ID/brief.md" "$FM_HOME/data/$id/"
  jq -nc --arg task "$REF" '{version:1,spawn_gen:"gen-before-reboot",pid:2000000001,task_session_file:$task,current_session_file:""}' > "$STATE/$id.omp-session.json"
  local q; printf -v q '%q ' env "${NENV[@]}" "$@"; printf '#!/usr/bin/env bash\nexec %s\n' "$q" > "$TMP/launch-$id.sh"
  run pane send-text "$pane" "bash $TMP/launch-$id.sh" >/dev/null; run pane send-keys "$pane" Enter >/dev/null
  for _ in $(seq 1 100); do fpid=$(run pane process-info --pane "$pane" | jq -er '.result.process_info.foreground_processes | select(length==1) | .[0] | select(.name=="bun") | .pid' 2>/dev/null) && break; sleep 0.2; done
  PIDS+=("$fpid")
  run pane report-agent --source fm-lab-restore-standin --agent omp --state idle "$pane" >/dev/null
  printf '%s' "$REF" > "$TMP/reg/$pane"
  say "FOREIGN $id: foreground $(run pane process-info --pane "$pane" | jq -c '.result.process_info.foreground_processes[0] | {pid,name,argv}')"
  echo "HEAD interactive: $(python3 -I "$ROOT/bin/fm-omp-identity.py" interactive "$fpid" 2>&1; echo " exit=$?")"
  echo "HEAD writer: $(python3 -I "$ROOT/bin/fm-omp-identity.py" writer "$fpid" 2>&1; echo " exit=$?")"
  local b; b=$(shasum -a 256 "$meta" "$STATE/$id.omp-session.json")
  "$ROOT/bin/fm-control.sh" "$id" adopt 2>&1 | tail -2; echo "HEAD adopt exit=${PIPESTATUS[0]}"
  [ "$b" = "$(shasum -a 256 "$meta" "$STATE/$id.omp-session.json")" ] && echo "record and meta unchanged"
}
mkdir -p "$TMP/other/src"; printf 'setInterval(() => {}, 1 << 30);\n' > "$TMP/other/server.ts"; cp "$TMP/other/server.ts" "$TMP/other/src/cli.ts"
foreign_case other-script "$HOME/.bun/bin/bun" "$TMP/other/server.ts"
foreign_case runtime-other-cli "$HOME/.local/share/omp-promax-fix/runtime/node_modules/@oven/bun-darwin-aarch64/bin/bun" "$TMP/other/src/cli.ts"
say "screen tail"
run pane read "$PANE" --format text 2>/dev/null | tail -8
