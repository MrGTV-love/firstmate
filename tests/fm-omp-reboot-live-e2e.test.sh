#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OMP_REBOOT_LIVE herdr omp jq python3
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$HELPER" name omp-reboot)
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

native_pid() {
  run pane process-info --pane "$PANE" | jq -er --arg ref "$REF" '
    [.result.process_info.foreground_processes[]
      | select(any(.argv[]?; . == $ref or . == ("--resume=" + $ref)))]
    | select(length == 1) | .[0].pid'
}

assert_native_unchanged() {
  [ "$(native_pid)" = "$PID" ] || fail 'inspection or refusal replaced the native live PID'
  [ "$(fm_launch_proof_herdr "$META")" = unmanaged ] || fail 'native launch acquired ownership'
  [ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = alive ] || fail 'native launch stopped'
  [ "$(fm_backend_composer_state herdr "$SESSION:$PANE" "fm-$TASK_ID")" = "$COMPOSER" ] \
    || fail 'inspection or refusal changed the composer state'
  [ "$(fm_backend_herdr_composer_content "$SESSION:$PANE" "$(fm_backend_herdr_composer_identity "$SESSION:$PANE")")" = "$DRAFT" ] \
    || fail 'inspection or refusal changed the composer content'
  run pane read "$PANE" --format text > "$TMP/after.screen"
  cmp -s "$TMP/before.screen" "$TMP/after.screen" || fail 'inspection or refusal altered the visible native screen'
  [ "$(cksum "${PRESERVED[@]}")" = "$SNAPSHOT" ] \
    || fail 'inspection or refusal changed metadata, busy state, instructions or dirty work'
  [ "$(git -C "$WT" rev-parse HEAD)" = "$BEFORE" ] \
    && [ "$(git -C "$WT" symbolic-ref HEAD)" = "$BRANCH" ] \
    || fail 'inspection or refusal changed HEAD or branch'
  [ "$(find "$FM_STATE_OVERRIDE" -type f -print | LC_ALL=C sort)" = "$STATE_FILES" ] \
    || fail 'inspection or refusal created lifecycle state'
  [ ! -e "$FM_STATE_OVERRIDE/$TASK_ID.control-relaunch" ] \
    && [ ! -e "$FM_STATE_OVERRIDE/$TASK_ID.control-exit" ] \
    || fail 'inspection or refusal began a lifecycle transaction'
}

exercise_native_refusals() {
  local action out
  for action in interrupt exit relaunch direct sweep; do
    case "$action" in
      interrupt|exit)
        if out=$("$ROOT/bin/fm-control.sh" "$TASK_ID" "$action" 2>&1); then
          fail "$action accepted an unmanaged native launch: $out"
        fi
        case "$out" in
          *'cannot positively attribute its live Herdr agent'*'refusing lifecycle input'*) ;;
          *) fail "$action did not refuse native ownership: $out" ;;
        esac
        ;;
      relaunch)
        if out=$("$ROOT/bin/fm-control.sh" "$TASK_ID" relaunch --note 'Must not reach native instructions.' 2>&1); then
          fail "ordinary relaunch accepted an unmanaged native launch: $out"
        fi
        case "$out" in
          *'cannot positively attribute its live Herdr agent'*'before checkpoint or lifecycle input'*) ;;
          *) fail "ordinary relaunch did not refuse before checkpoint: $out" ;;
        esac
        ;;
      direct)
        out=$("$ROOT/bin/fm-control.sh" "$TASK_ID" relaunch --recover-launch 2>&1) \
          || fail "direct native recovery inspection failed: $out"
        case "$out" in
          *"recovery-skipped $TASK_ID launch=unmanaged; no lifecycle action taken"*) ;;
          *) fail "direct recovery did not report the unmanaged no-op: $out" ;;
        esac
        ;;
      sweep)
        out=$("$ROOT/bin/fm-reboot-recover.sh" recover 2>&1) \
          || fail "native reboot inspection failed: $out"
        case "$out" in
          *"REBOOT_RECOVERY: $TASK_ID: live launch is unmanaged; no lifecycle action taken"*) ;;
          *) fail "reboot sweep did not alert without lifecycle action: $out" ;;
        esac
        ;;
    esac
    assert_native_unchanged
  done
}

exercise_native_pane() {
  local proof composer live environment launch start screen previous='' stable=0
  printf -v launch '%q ' env "${NATIVE_ENV[@]}" omp "--resume=$REF"
  printf '#!/usr/bin/env bash\nexec %s\n' "$launch" > "$TMP/native-launch.sh"
  printf -v launch '%q ' bash "$TMP/native-launch.sh"
  run pane send-text "$PANE" "$launch"
  NATIVE_LAUNCH_PENDING=1
  run pane send-keys "$PANE" Enter
  for _ in $(seq 1 60); do
    proof=$(fm_launch_proof_herdr "$META")
    composer=$(fm_backend_composer_state herdr "$SESSION:$PANE" "fm-$TASK_ID")
    live=$(fm_backend_agent_state herdr "$SESSION:$PANE")
    [ "$proof" != unmanaged ] || [ "$composer" != empty ] || [ "$live" != alive ] || break
    sleep 0.2
  done
  [ "$proof" = unmanaged ] && [ "$composer" = empty ] && [ "$live" = alive ] \
    || fail "native omp: bare resume did not reach a live unmanaged empty composer ($proof/$composer/$live)"
  PID=$(native_pid) || fail 'native omp live PID could not be identified'
  start=$(LC_ALL=C ps -p "$PID" -o lstart=) \
    && [ -n "$start" ] || fail 'native omp process start identity could not be captured'
  printf '%s\t%s\n' "$PID" "$start" >> "$NATIVE_PROCESSES"
  NATIVE_LAUNCH_PENDING=0
  printf 'native child captured: pid=%s start=%s\n' "$PID" "$start"
  environment=$(fm_remote_herdr_process_env "$PID") || fail 'native omp live environment could not be read'
  printf '%s\n' "$environment" | grep -Eq '^(PATH|HOME)=' \
    || fail 'native omp live environment was not positively readable'
  if printf '%s\n' "$environment" | grep -q '^FM_SPAWN_GEN='; then
    fail 'native omp unexpectedly inherited a Firstmate spawn pin'
  fi
  python3 - "$NATIVE_HOME" "$environment" <<'PY'
import sys
home = sys.argv[1]
environment = dict(line.split("=", 1) for line in sys.argv[2].splitlines())
expected = {
    "HOME": home,
    "XDG_CONFIG_HOME": home + "/.config",
    "XDG_DATA_HOME": home + "/.local/share",
    "XDG_STATE_HOME": home + "/.local/state",
    "XDG_CACHE_HOME": home + "/.cache",
    "PI_CONFIG_DIR": ".omp",
    "PI_CODING_AGENT_DIR": home + "/.omp/agent",
    "OMP_PROFILE": "default",
    "PI_PROFILE": "default",
    "OPENAI_API_KEY": "fm-non-submitting-fixture",
}
for key, value in expected.items():
    assert environment.get(key) == value, (key, environment.get(key), value)
PY
  # Opt-in cleanup smoke uses both real native launches but skips the unchanged
  # lifecycle matrix below; its proof is emitted by the shared EXIT cleanup.
  [ "${FM_OMP_REBOOT_CLEANUP_SMOKE:-0}" != 1 ] || return 0
  # The composer can become idle before omp finishes replaying the resumed
  # transcript. Snapshot only after that real UI has rendered and settled.
  for _ in $(seq 1 60); do
    screen=$(run pane read "$PANE" --format text) || fail 'native screen could not be read'
    case "$screen" in
      *'FIRSTMATE_OP: v1 launch-brief:'*)
        if [ "$screen" = "$previous" ]; then
          stable=$((stable + 1))
        else
          stable=0
        fi
        [ "$stable" -lt 5 ] || break
        ;;
    esac
    previous=$screen
    sleep 0.2
  done
  [ "$stable" -ge 5 ] || fail 'native resumed transcript did not settle before preservation checks'
  RETAINED_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$FM_STATE_OVERRIDE" "$TASK_ID" \
    --state busy --source omp-ext --event agent_start)
  printf 'busy_gen=%s\n' "$RETAINED_GEN" >> "$META"
  PRESERVED+=("$META" "$FM_STATE_OVERRIDE/$TASK_ID.busy-gen" "$FM_STATE_OVERRIDE/$TASK_ID.busy-state" "$REF")
  BEFORE=$(git -C "$WT" rev-parse HEAD)
  BRANCH=$(git -C "$WT" symbolic-ref HEAD)
  SNAPSHOT=$(cksum "${PRESERVED[@]}")
  STATE_FILES=$(find "$FM_STATE_OVERRIDE" -type f -print | LC_ALL=C sort)
  for DRAFT in '' 'preserve draft' '!git diff' '$ print(1)'; do
    COMPOSER=empty
    if [ -n "$DRAFT" ]; then
      run pane send-text "$PANE" "$DRAFT"
      COMPOSER=pending
    fi
    for _ in $(seq 1 30); do
      [ "$(fm_backend_herdr_composer_content "$SESSION:$PANE" "$(fm_backend_herdr_composer_identity "$SESSION:$PANE")")" != "$DRAFT" ] || break
      sleep 0.1
    done
    [ "$(fm_backend_composer_state herdr "$SESSION:$PANE" "fm-$TASK_ID")" = "$COMPOSER" ] \
      || fail 'native fixture composer did not settle'
    run pane read "$PANE" --format text > "$TMP/before.screen"
    exercise_native_refusals
    if [ -n "$DRAFT" ]; then
      run pane send-keys "$PANE" ctrl+u
      for _ in $(seq 1 30); do
        [ "$(fm_backend_composer_state herdr "$SESSION:$PANE" "fm-$TASK_ID")" != empty ] || break
        sleep 0.1
      done
      [ "$(fm_backend_composer_state herdr "$SESSION:$PANE" "fm-$TASK_ID")" = empty ] \
        || fail 'explicit fixture draft cleanup did not clear the composer'
    fi
  done
}

REF="$TMP/native-worker-session.jsonl"
PRESERVED=("$FM_DATA_OVERRIDE/$TASK_ID/brief.md" "$WT/unlanded.txt")
exercise_native_pane

TASK_ID="$TASK_ID-secondmate"
mkdir -p "$WT/state" "$WT/data"
printf '%s\n' "$TASK_ID" > "$WT/.fm-secondmate-home"
printf '# Isolated lifecycle fixture\n' > "$WT/AGENTS.md"
printf 'Leave this native secondmate lifecycle fixture idle.\n' > "$WT/data/charter.md"
printf 'window=child:child-pane\n' > "$WT/state/child.meta"
printf 'claude opus high\n' > "$FM_CONFIG_OVERRIDE/secondmate-harness"
WS=$(run workspace create --cwd "$WT" --label "fm-$TASK_ID" | jq -r '.result.workspace.workspace_id')
PANE=$(run pane list --workspace "$WS" | jq -r '.result.panes[0].pane_id')
TAB=$(run pane get "$PANE" | jq -r '.result.pane.tab_id')
META="$FM_STATE_OVERRIDE/$TASK_ID.meta"
cat > "$META" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$TASK_ID
worktree=$WT
project=$TMP/proj
home=$WT
harness=omp
kind=secondmate
mode=secondmate
yolo=off
model=openai-codex/gpt-6.1-sol
effort=low
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF
REF="$TMP/native-secondmate-session.jsonl"
seed_native_resume "$REF" "$WT/data/charter.md"
PRESERVED+=("$WT/.fm-secondmate-home" "$WT/AGENTS.md" "$WT/data/charter.md" "$WT/state/child.meta" \
  "$FM_CONFIG_OVERRIDE/secondmate-harness")
exercise_native_pane
printf 'Herdr lab runtime: '
run status --json
if [ "${FM_OMP_REBOOT_CLEANUP_SMOKE:-0}" = 1 ]; then
  pass "native omp cleanup smoke: task and local secondmate reached live unmanaged composers in isolated homes"
else
  pass "native omp: task and local secondmate remain unmanaged and unchanged for empty/pending interrupt, exit, relaunch, direct recovery and reboot sweep"
fi
