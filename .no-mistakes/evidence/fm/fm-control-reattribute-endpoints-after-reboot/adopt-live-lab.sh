#!/usr/bin/env bash
# Live validation driver for `fm-control.sh <task> adopt` (not part of the repo).
# Derived from tests/fm-omp-reboot-live-e2e.test.sh: real Herdr in a named
# fm-lab-* session (bin/fm-herdr-lab.sh), real omp worker panes resumed with no
# FM_SPAWN_GEN pin (as after a Herdr restore), and a real omp PRIMARY pane that
# hosts the lock-owning main Firstmate's shell commands via omp's "!" bash mode.
set -euo pipefail
. /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5F7QXCMDY8X746T2JDG381G/tests/lib.sh
fm_live_gate opt-in FM_OMP_ADOPT_LIVE herdr omp jq python3
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$HELPER" name omp-adopt)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-reboot.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
TASK_ID="reboot-${TMP##*/}"
REAL_PATH=$PATH
OWNED_SESSION=0
NATIVE_LAUNCH_PENDING=0
NATIVE_PROCESSES="$TMP/native-processes"
: > "$NATIVE_PROCESSES"

# Session deletion can return before a native omp finishes its exit writes.
# Keep its private dependencies until each captured PID/start pair is gone;
# neither a timeout nor an unreadable launch authorizes deleting the tree.
wait_native_exit() {
  local pid expected_start current_start deadline=$((SECONDS + 10))
  [ "$NATIVE_LAUNCH_PENDING" = 0 ] || {
    printf 'native launch identity was not captured; refusing private tree removal\n' >&2
    return 1
  }
  while IFS=$'\t' read -r pid expected_start; do
    while kill -0 "$pid" 2>/dev/null; do
      current_start=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || current_start=
      if [ -n "$current_start" ] && [ "$current_start" != "$expected_start" ]; then
        break # The original child exited and this PID was reused; never signal it.
      fi
      if [ "$SECONDS" -ge "$deadline" ]; then
        printf 'native child exit not confirmed within 10s: pid=%s start=%s current=%s\n' \
          "$pid" "$expected_start" "${current_start:-<unreadable>}" >&2
        return 1
      fi
      sleep 0.1
    done
    printf 'native child exit confirmed: pid=%s start=%s\n' "$pid" "$expected_start"
  done < "$NATIVE_PROCESSES"
}

cleanup() {
  local status=$?
  if [ "$OWNED_SESSION" = 1 ] && ! PATH="$REAL_PATH" "$HELPER" teardown "$SESSION"; then
    printf "guarded teardown failed for session '%s'; retained private tree for manual cleanup: %s\n" \
      "$SESSION" "$TMP" >&2
    exit 1
  fi
  if [ "$OWNED_SESSION" = 1 ]; then
    printf "guarded teardown completed for session '%s'; waiting for native child exit\n" "$SESSION"
  fi
  if ! wait_native_exit; then
    printf "native cleanup refused for session '%s'; retained private tree for manual cleanup: %s\n" \
      "$SESSION" "$TMP" >&2
    exit 1
  fi
  chmod -R u+w "$TMP" || status=1
  if rm -rf "$TMP"; then
    printf 'private fixture tree removed: %s\n' "$TMP"
  else
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
export FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$SESSION"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data"
export FM_CONFIG_OVERRIDE="$FM_HOME/config" FM_PROJECTS_OVERRIDE="$FM_HOME/projects"
export FM_SPAWN_NO_GUARD=1
unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV TMUX TMUX_PANE FM_SPAWN_GEN
"$HELPER" prepare "$SESSION"
OWNED_SESSION=1
mkdir -p "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE/$TASK_ID" "$FM_CONFIG_OVERRIDE" \
  "$FM_PROJECTS_OVERRIDE" "$TMP/fakebin"
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
META="$FM_STATE_OVERRIDE/$TASK_ID.meta"
"$HELPER" provision "$SESSION"
run() { PATH="$REAL_PATH" "$HELPER" run "$SESSION" "$@"; }
env "${NATIVE_ENV[@]}" PI_CODING_AGENT_DIR= PATH="$REAL_PATH" "$HELPER" run "$SESSION" integration install omp
printf 'manual\n' > "$FM_CONFIG_OVERRIDE/backlog-backend"
printf 'off\n' > "$FM_CONFIG_OVERRIDE/herdr-presentation-spaces"
fm_git_worktree "$TMP/proj" "$TMP/wt" "$TASK_ID"
WT=$(cd "$TMP/wt" && pwd -P)
printf 'preserve this dirty file\n' > "$WT/unlanded.txt"
cat > "$FM_DATA_OVERRIDE/$TASK_ID/brief.md" <<'EOF'
# Task
## Captain's intent
This is an isolated lifecycle verification, not a project implementation.
Leave this isolated lifecycle fixture idle; no implementation is requested.

## Firstmate spec
Do not inspect or modify files, delegate, supervise, or run any tools.
EOF
WS=$(run workspace create --cwd "$WT" --label "fm-$TASK_ID" | jq -r '.result.workspace.workspace_id')
PANE=$(run pane list --workspace "$WS" | jq -r '.result.panes[0].pane_id')
TAB=$(run pane get "$PANE" | jq -r '.result.pane.tab_id')
cat > "$META" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$TASK_ID
worktree=$WT
project=$TMP/proj
harness=omp
kind=ship
mode=no-mistakes
spawn_gen=reboot-native
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
# Every command issued by production adapters is also forced through the lab
# helper. The real binary remains on the helper's original PATH, avoiding a
# recursive wrapper while rejecting any attempt to leave this named session.
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
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
. "$ROOT/bin/fm-launch-proof-lib.sh"
seed_native_resume() { # <session-path> <launch-body-path>
  local ref=$1 body=$2 message
  message=$("$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$body") \
    || fail 'could not encode the native fixture launch brief'
  printf '%s' "$message" > "$TMP/native-launch-input"
  python3 - "$ref" "$WT" "$TMP/native-launch-input" <<'PY'
import datetime, json, pathlib, sys, uuid
now = datetime.datetime.now(datetime.timezone.utc)
with open(sys.argv[1], 'w') as f:
    slot = {'type':'title','v':1,'title':'','updatedAt':now.isoformat(),'pad':''}
    slot['pad'] = ' ' * (255 - len(json.dumps(slot, separators=(',', ':')).encode('utf-8')))
    f.write(json.dumps(slot, separators=(',', ':')) + '\n')
    f.write(json.dumps({'type':'session','version':3,'id':str(uuid.uuid4()),
                       'timestamp':now.isoformat(),'cwd':sys.argv[2]}) + '\n')
    model_id = uuid.uuid4().hex[:8]
    f.write(json.dumps({'type':'model_change','id':model_id,'parentId':None,
                       'timestamp':now.isoformat(),'model':'openai/gpt-4.1'}) + '\n')
    f.write(json.dumps({'type':'message','id':uuid.uuid4().hex[:8],'parentId':model_id,
                       'timestamp':now.isoformat(),
                       'message':{'role':'user','content':[{
                           'type':'text','text':pathlib.Path(sys.argv[3]).read_text()}],
                           'timestamp':int(now.timestamp() * 1000)}}) + '\n')
PY
}
seed_native_resume "$TMP/native-worker-session.jsonl" "$FM_DATA_OVERRIDE/$TASK_ID/brief.md"

# ---------------------------------------------------------------- scenarios --
EVDIR=${EV_DIR:?set EV_DIR to the evidence directory}
RESULTS=$EVDIR/live-results.txt
: > "$RESULTS"
FAILED=0
ok()  { printf 'PASS  %s\n' "$1" | tee -a "$RESULTS"; }
bad() { printf 'FAIL  %s :: %s\n' "$1" "$2" | tee -a "$RESULTS"; FAILED=1; }
note() { printf 'NOTE  %s\n' "$1" | tee -a "$RESULTS"; }

STATE=$FM_STATE_OVERRIDE
REF="$TMP/native-worker-session.jsonl"
DEAD_PID=2000000001
MAIN_ID=$TASK_ID
MAIN_PANE=$PANE
MAIN_WT=$WT

native_pid_in() { # <pane> <ref>
  run pane process-info --pane "$1" | jq -er --arg ref "$2" '
    [.result.process_info.foreground_processes[]
      | select(any(.argv[]?; . == $ref or . == ("--resume=" + $ref)))]
    | select(length == 1) | .[0].pid'
}

launch_worker() { # <name> <pane> <ref> <pin-or-empty> -> LIVE_PID
  local name=$1 pane=$2 ref=$3 pin=$4 launch start n
  local -a pinenv=()
  [ -z "$pin" ] || pinenv=("FM_SPAWN_GEN=$pin")
  printf -v launch '%q ' env "${NATIVE_ENV[@]}" ${pinenv[@]+"${pinenv[@]}"} omp "--resume=$ref"
  printf '#!/usr/bin/env bash\nexec %s\n' "$launch" > "$TMP/$name-launch.sh"
  NATIVE_LAUNCH_PENDING=1
  run pane send-text "$pane" "bash $TMP/$name-launch.sh" >/dev/null
  run pane send-keys "$pane" Enter >/dev/null
  LIVE_PID=
  for n in $(seq 1 200); do
    LIVE_PID=$(native_pid_in "$pane" "$ref" 2>/dev/null) && break
    LIVE_PID=
    sleep 0.2
  done
  [ -n "$LIVE_PID" ] || { run pane read "$pane" --format text >&2 || true; fail "$name: omp did not become the unique foreground process"; }
  start=$(LC_ALL=C ps -p "$LIVE_PID" -o lstart=)
  printf '%s\t%s\n' "$LIVE_PID" "$start" >> "$NATIVE_PROCESSES"
  NATIVE_LAUNCH_PENDING=0
  # Wait for the real Herdr omp registration of the session file.
  SESSION_REF=
  for n in $(seq 1 200); do
    SESSION_REF=$(fm_backend_herdr_pane_agent_session_ref "$SESSION" "$pane" 2>/dev/null) && [ -n "$SESSION_REF" ] && break
    SESSION_REF=
    sleep 0.2
  done
  note "$name: live pid $LIVE_PID, Herdr registration for pane $pane = ${SESSION_REF:-<none after 40s>}"
}

make_worker_task() { # <id> <ref> <spawn-gen> -> W_WT W_PANE
  local id=$1 ref=$2 gen=$3 ws tab
  git -C "$TMP/proj" worktree add --quiet -b "$id" "$TMP/wt-$id"
  W_WT=$(cd "$TMP/wt-$id" && pwd -P)
  ws=$(run workspace create --cwd "$W_WT" --label "fm-$id" | jq -r '.result.workspace.workspace_id')
  W_PANE=$(run pane list --workspace "$ws" | jq -r '.result.panes[0].pane_id')
  tab=$(run pane get "$W_PANE" | jq -r '.result.pane.tab_id')
  cat > "$STATE/$id.meta" <<EOF
window=$SESSION:$W_PANE
endpoint_task_id=$id
worktree=$W_WT
project=$TMP/proj
harness=omp
kind=ship
mode=no-mistakes
spawn_gen=$gen
launch_proof=env-v1
yolo=off
model=openai-codex/gpt-6.1-sol
effort=low
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$W_PANE
EOF
  # omp --resume restores the session header cwd, so seed it with this task's worktree.
  ( WT=$W_WT; seed_native_resume "$ref" "$FM_DATA_OVERRIDE/$MAIN_ID/brief.md" )
  mkdir -p "$FM_DATA_OVERRIDE/$id"
  cp "$FM_DATA_OVERRIDE/$MAIN_ID/brief.md" "$FM_DATA_OVERRIDE/$id/brief.md"
}

write_stale_record() { # <id> <ref> <gen>  -- the post-restart shape: dead pid, empty current
  jq -nc --arg gen "$3" --arg task "$2" --argjson pid "$DEAD_PID" \
    '{version:1,spawn_gen:$gen,pid:$pid,task_session_file:$task,current_session_file:""}' \
    > "$STATE/$1.omp-session.json"
}

rec_sum() { cksum "$STATE/$1.omp-session.json" "$STATE/$1.meta"; }

fm_ctl() { # direct (non-primary) call of the real script from this shell
  env -u FM_TASK_ID "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- real omp primary pane: hosts the lock-owning main Firstmate's commands ---
PRIMARY_CWD="$TMP/primary-cwd"; mkdir -p "$PRIMARY_CWD"
PWS=$(run workspace create --cwd "$PRIMARY_CWD" --label primary | jq -r '.result.workspace.workspace_id')
PRIMARY_PANE=$(run pane list --workspace "$PWS" | jq -r '.result.panes[0].pane_id')
printf -v launch '%q ' env "${NATIVE_ENV[@]}" omp
printf '#!/usr/bin/env bash\nexec %s\n' "$launch" > "$TMP/primary-launch.sh"
NATIVE_LAUNCH_PENDING=1
run pane send-text "$PRIMARY_PANE" "bash $TMP/primary-launch.sh" >/dev/null
run pane send-keys "$PRIMARY_PANE" Enter >/dev/null
PRIMARY_PID=
for n in $(seq 1 200); do
  PRIMARY_PID=$(run pane process-info --pane "$PRIMARY_PANE" 2>/dev/null | jq -er '
    [.result.process_info.foreground_processes[] | select(any(.argv[]?; test("(^|/)omp$")))]
    | select(length == 1) | .[0].pid' 2>/dev/null) && break
  PRIMARY_PID=
  sleep 0.2
done
[ -n "$PRIMARY_PID" ] || { run pane read "$PRIMARY_PANE" --format text >&2 || true; fail 'primary omp did not start'; }
printf '%s\t%s\n' "$PRIMARY_PID" "$(LC_ALL=C ps -p "$PRIMARY_PID" -o lstart=)" >> "$NATIVE_PROCESSES"
NATIVE_LAUNCH_PENDING=0
sleep 3
note "primary omp pid $PRIMARY_PID comm=$(ps -p "$PRIMARY_PID" -o comm=) in pane $PRIMARY_PANE"
printf '%s\n' "$PRIMARY_PID" > "$STATE/.lock"

cat > "$TMP/ctl.sh" <<EOF
#!/usr/bin/env bash
export FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$SESSION"
export FM_STATE_OVERRIDE="$FM_STATE_OVERRIDE" FM_DATA_OVERRIDE="$FM_DATA_OVERRIDE"
export FM_CONFIG_OVERRIDE="$FM_CONFIG_OVERRIDE" FM_PROJECTS_OVERRIDE="$FM_PROJECTS_OVERRIDE"
export FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1
export PATH="$TMP/fakebin:$REAL_PATH"
export FM_LAB_REAL_PATH="$REAL_PATH" FM_LAB_HELPER="$HELPER" FM_LAB_SESSION="$SESSION"
# The primary omp carries the fixture HOME/XDG roots; the Firstmate scripts and
# the real herdr client must resolve the lab session under the real HOME.
export HOME="$HOME"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME PI_CONFIG_DIR PI_CODING_AGENT_DIR OMP_PROFILE PI_PROFILE OMP_SKIP_SETUP OPENAI_API_KEY
unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV TMUX TMUX_PANE FM_SPAWN_GEN FM_TASK_ID
rm -f "$TMP/ctl.rc"
"$ROOT/bin/fm-control.sh" "\$@" > "$TMP/ctl.out" 2>&1
echo \$? > "$TMP/ctl.rc"
EOF
chmod +x "$TMP/ctl.sh"

ctl_primary() { # <fm-control args...> -> CTL_RC CTL_OUT ; typed into the real primary omp as a "!" command
  local n
  rm -f "$TMP/ctl.rc" "$TMP/ctl.out"
  run pane send-text "$PRIMARY_PANE" "!bash $TMP/ctl.sh $*" >/dev/null
  run pane send-keys "$PRIMARY_PANE" Enter >/dev/null
  for n in $(seq 1 300); do [ -s "$TMP/ctl.rc" ] && break; sleep 0.2; done
  [ -s "$TMP/ctl.rc" ] || { run pane read "$PRIMARY_PANE" --format text >&2 || true; fail "primary did not run: fm-control $*"; }
  CTL_RC=$(cat "$TMP/ctl.rc"); CTL_OUT=$(cat "$TMP/ctl.out")
}

# =========================================================== main worker task
note "== main worker task: restored omp, no launch pin, dead-pid stale record =="
launch_worker main "$MAIN_PANE" "$REF" ''
MAIN_LIVE_PID=$LIVE_PID
write_stale_record "$MAIN_ID" "$REF" reboot-native
cp "$STATE/$MAIN_ID.omp-session.json" "$EVDIR/live-main-record-before.json"
run pane read "$MAIN_PANE" --format text > "$TMP/main-before.screen"
SESSION_SUM_BEFORE=$(cksum < "$REF")
BEFORE_SUM=$(rec_sum "$MAIN_ID")
export HERDR_SESSION  # already exported by head

# S1: pre-adopt, interrupt is refused (the reported stuck state)
out=$(fm_ctl "$MAIN_ID" interrupt) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'cannot positively attribute its live Herdr agent'; then
  ok "S1 before adopt: interrupt on the restored, record-stale omp task is refused (rc=$rc)"
else bad "S1 before adopt interrupt refused" "rc=$rc out=$out"; fi

# S2: caller gates on the real script
out=$(fm_ctl "$MAIN_ID" adopt) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'requires the actual lock-owning main Firstmate' && [ "$BEFORE_SUM" = "$(rec_sum "$MAIN_ID")" ]; then
  ok "S2a adopt from a shell that is not the lock-owning primary is refused; record unchanged"
else bad "S2a non-owner adopt refused" "rc=$rc out=$out"; fi
out=$(env FM_TASK_ID=some-worker "$ROOT/bin/fm-control.sh" "$MAIN_ID" adopt 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'workers cannot adopt' && [ "$BEFORE_SUM" = "$(rec_sum "$MAIN_ID")" ]; then
  ok "S2b adopt with FM_TASK_ID set (a worker) is refused; record unchanged"
else bad "S2b worker adopt refused" "rc=$rc out=$out"; fi

# S3: adversarial claims, run by the real primary
printf 'window=%s\nworktree=%s/elsewhere\nremote_host=\n' "$SESSION:$MAIN_PANE" "$TMP" > "$STATE/dup-claimant.meta"
ctl_primary "$MAIN_ID" adopt
if [ "$CTL_RC" -ne 0 ] && printf '%s' "$CTL_OUT" | grep -q 'unique-claim proof' && [ "$BEFORE_SUM" = "$(rec_sum "$MAIN_ID")" ]; then
  ok "S3a second task claiming the same pane: adopt refused naming the unique-claim proof; record unchanged"
else bad "S3a duplicate pane refused" "rc=$CTL_RC out=$CTL_OUT"; fi
rm -f "$STATE/dup-claimant.meta"
printf 'window=%s:p-other\nworktree=%s\nremote_host=\n' "$SESSION" "$MAIN_WT" > "$STATE/same-worktree.meta"
ctl_primary "$MAIN_ID" adopt
if [ "$CTL_RC" -ne 0 ] && printf '%s' "$CTL_OUT" | grep -q 'unique deepest match' && [ "$BEFORE_SUM" = "$(rec_sum "$MAIN_ID")" ]; then
  ok "S3b another task recording the same worktree: adopt refused naming the unique-deepest-match proof; record unchanged"
else bad "S3b shared worktree refused" "rc=$CTL_RC out=$CTL_OUT"; fi
rm -f "$STATE/same-worktree.meta"
# generation mismatch
jq '.spawn_gen="other-generation"' "$STATE/$MAIN_ID.omp-session.json" > "$STATE/$MAIN_ID.omp-session.json.new" \
  && mv "$STATE/$MAIN_ID.omp-session.json.new" "$STATE/$MAIN_ID.omp-session.json"
MIS_SUM=$(rec_sum "$MAIN_ID")
ctl_primary "$MAIN_ID" adopt
if [ "$CTL_RC" -ne 0 ] && printf '%s' "$CTL_OUT" | grep -q 'spawn_gen' && [ "$MIS_SUM" = "$(rec_sum "$MAIN_ID")" ]; then
  ok "S3c record spawn_gen differs from metadata: adopt refused naming the generation proof; nothing fabricated"
else bad "S3c generation mismatch refused" "rc=$CTL_RC out=$CTL_OUT"; fi
write_stale_record "$MAIN_ID" "$REF" reboot-native
[ "$BEFORE_SUM" = "$(rec_sum "$MAIN_ID")" ] || note "record restored by fixture (cksum differs only by fixture rewrite)"
BEFORE_SUM=$(rec_sum "$MAIN_ID")

# S4: real pinned workers must be refused before any capture
note "== pinned workers (adversarial) =="
PINB_ID="${MAIN_ID}-pinned"; PINB_REF="$TMP/native-pinned-session.jsonl"
make_worker_task "$PINB_ID" "$PINB_REF" reboot-pinned
launch_worker pinned "$W_PANE" "$PINB_REF" reboot-pinned
write_stale_record "$PINB_ID" "$PINB_REF" reboot-pinned
PB_SUM=$(rec_sum "$PINB_ID")
ctl_primary "$PINB_ID" adopt
if [ "$CTL_RC" -ne 0 ] && printf '%s' "$CTL_OUT" | grep -q 'launch-pin proof' && [ "$PB_SUM" = "$(rec_sum "$PINB_ID")" ] \
   && [ -z "$(find "$STATE" -name ".$PINB_ID.omp-session*" 2>/dev/null)" ]; then
  ok "S4a real omp carrying the MATCHING launch pin: adopt refused before capture (launch-pin proof); no staged/captured file; record unchanged"
else bad "S4a matching pin refused" "rc=$CTL_RC out=$CTL_OUT"; fi

OTHC_ID="${MAIN_ID}-otherpin"; OTHC_REF="$TMP/native-otherpin-session.jsonl"
make_worker_task "$OTHC_ID" "$OTHC_REF" reboot-c
launch_worker otherpin "$W_PANE" "$OTHC_REF" some-other-generation
write_stale_record "$OTHC_ID" "$OTHC_REF" reboot-c
PC_SUM=$(rec_sum "$OTHC_ID")
ctl_primary "$OTHC_ID" adopt
if [ "$CTL_RC" -ne 0 ] && printf '%s' "$CTL_OUT" | grep -q 'generation proof' && [ "$PC_SUM" = "$(rec_sum "$OTHC_ID")" ]; then
  ok "S4b real omp pinned to ANOTHER generation: adopt refused naming the generation proof; record unchanged"
else bad "S4b other-generation pin refused" "rc=$CTL_RC out=$CTL_OUT"; fi

# S5: the happy path by the real primary on the main task
note "== happy path on the main task =="
ctl_primary "$MAIN_ID" adopt
note "adopt output: rc=$CTL_RC $CTL_OUT"
run pane read "$MAIN_PANE" --format text > "$TMP/main-after-adopt.screen"
rec="$STATE/$MAIN_ID.omp-session.json"
cp "$rec" "$EVDIR/live-main-record-after.json" 2>/dev/null || true
if [ "$CTL_RC" -eq 0 ] && printf '%s' "$CTL_OUT" | grep -q "adopted: $MAIN_ID" \
   && jq -e --arg ref "$REF" --argjson pid "$MAIN_LIVE_PID" \
        '. == {version:1,spawn_gen:"reboot-native",pid:$pid,task_session_file:$ref,current_session_file:$ref}' "$rec" >/dev/null; then
  ok "S5 adopt by the real lock-owning primary rewrote the record to the live pid $MAIN_LIVE_PID and live session file, same spawn_gen"
else bad "S5 adopt succeeds with the live values" "rc=$CTL_RC out=$CTL_OUT record=$(cat "$rec" 2>/dev/null)"; fi
# omp renders its own asynchronous "Update Available" banner; it is not input from adopt.
norm_screen() { grep -v -E 'Update Available|New version .* is available' "$1" | grep -v -E '^[─[:space:]]*$' || true; }
norm_screen "$TMP/main-before.screen" > "$TMP/main-before.norm"; norm_screen "$TMP/main-after-adopt.screen" > "$TMP/main-after.norm"
if cmp -s "$TMP/main-before.norm" "$TMP/main-after.norm" && [ "$SESSION_SUM_BEFORE" = "$(cksum < "$REF")" ]; then
  ok "S5b adopt sent no input to the worker pane (screen identical apart from omp's own update banner; session file unchanged)"
else bad "S5b adopt sends no input" "worker screen changed"; diff "$TMP/main-before.norm" "$TMP/main-after.norm" | head -20 | tee -a "$RESULTS" || true; fi
if [ -z "$(find "$STATE" -name ".$MAIN_ID.omp-session*" 2>/dev/null)" ] && [ ! -e "$STATE/$MAIN_ID.omp-session.json.prior" ]; then
  ok "S5c no staged or captured record files left behind"
else bad "S5c no leftovers" "$(find "$STATE" -name '.*omp-session*')"; fi

# S6: lifecycle control now works with no keystroke from a human
verdict=$(fm_launch_proof_herdr "$META" 2>/dev/null || true)
META="$STATE/$MAIN_ID.meta"; verdict=$(fm_launch_proof_herdr "$META" 2>/dev/null || true)
if [ "$verdict" = managed ]; then ok "S6a launch-proof verdict for the repaired task is managed (was unmanaged before)"
else bad "S6a verdict managed" "verdict=$verdict"; fi
out=$(FM_CONTROL_SETTLE_WAIT=1 fm_ctl "$MAIN_ID" interrupt) && rc=0 || rc=$?
printf '%s\n' "$out" > "$EVDIR/live-interrupt-after-adopt.txt"
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "interrupt-delivered $MAIN_ID"; then
  ok "S6b fm-control interrupt on the previously refused omp task is delivered after adopt, no human keystroke: $out"
else bad "S6b interrupt delivered" "rc=$rc out=$out"; fi
[ "$(fm_backend_agent_state herdr "$SESSION:$MAIN_PANE")" = alive ] \
  && ok "S6c the worker omp is still alive after interrupt (adopt/interrupt never exit it)" \
  || bad "S6c worker alive" "state=$(fm_backend_agent_state herdr "$SESSION:$MAIN_PANE")"

# S7: repeat adopt is refused because the recorded PID is now live (extension owns it)
R_SUM=$(rec_sum "$MAIN_ID")
ctl_primary "$MAIN_ID" adopt
if [ "$CTL_RC" -ne 0 ] && printf '%s' "$CTL_OUT" | grep -q 'recorded PID to be gone' && [ "$R_SUM" = "$(rec_sum "$MAIN_ID")" ]; then
  ok "S7 repeat adopt on the repaired record is refused (recorded PID is live); record byte-identical"
else bad "S7 repeat adopt refused" "rc=$CTL_RC out=$CTL_OUT"; fi

# S8: ongoing authorization: workspace loses ownership -> repaired record stops licensing input
printf 'window=%s:p-newowner\nworktree=%s\nremote_host=\n' "$SESSION" "$MAIN_WT" > "$STATE/new-owner.meta"
out=$(FM_CONTROL_SETTLE_WAIT=1 fm_ctl "$MAIN_ID" interrupt) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q "interrupt-delivered"; then
  ok "S8 after another task records the same worktree, the repaired record no longer authorizes interrupt (rc=$rc)"
else bad "S8 ownership loss withdraws authorization" "rc=$rc out=$out"; fi
rm -f "$STATE/new-owner.meta"

# S9: the pinned/other-pin workers still unauthorized by adopt (never repaired) ; lifecycle refused for them
for t in "$PINB_ID" "$OTHC_ID"; do
  out=$(FM_CONTROL_SETTLE_WAIT=1 fm_ctl "$t" interrupt) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q 'interrupt-delivered'; then ok "S9 $t (stale record, pinned worker, not adopted) stays refused for interrupt"
  else note "S9 $t interrupt rc=$rc out=$out"; fi
done

run pane read "$MAIN_PANE" --format text > "$EVDIR/live-main-worker-screen.txt" || true
run pane read "$PRIMARY_PANE" --format text > "$EVDIR/live-primary-screen.txt" || true
printf 'Herdr lab runtime: '; run status --json
if [ "$FAILED" = 0 ]; then pass "live adopt scenarios all passed"; else fail "live adopt scenarios had failures (see $RESULTS)"; fi
