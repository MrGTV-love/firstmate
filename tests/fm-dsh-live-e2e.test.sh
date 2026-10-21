#!/usr/bin/env bash
# Credentialed real dsh-tui lifecycle guard. Preallocated project/copy required:
# FM_DSH_LAB_PROJECT and FM_DSH_LAB_COPY; never allocates or removes worktrees.
# Every Herdr operation routes through the guarded named-session lab helper.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
fm_live_gate opt-in FM_DSH_LIVE herdr jq dsh-tui
: "${FM_DSH_LAB_PROJECT:?supply a disposable preallocated project}"
: "${FM_DSH_LAB_COPY:?supply its separate preallocated linked copy}"
TASK=${FM_DSH_EVIDENCE_DIR:-$(mktemp -d)}
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
ORIGINAL_PATH=$PATH
SESSION=$("$HELPER" name dsh-live)
export FM_HERDR_LAB_STATE_DIR="$TASK/herdr-safety"
mkdir -p "$TASK"
# shellcheck source=tests/fm-dsh-live-cleanup.sh
. "$ROOT/tests/fm-dsh-live-cleanup.sh"
cleanup() {
  local rc=$?
  trap - EXIT
  fm_dsh_live_cleanup "$rc" "$SESSION" "$HELPER" "$ORIGINAL_PATH"
  exit $?
}
trap cleanup EXIT
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
PROJECT=$(cd "$FM_DSH_LAB_PROJECT" && pwd -P)
COPY=$(cd "$FM_DSH_LAB_COPY" && pwd -P)
[ "$PROJECT" != "$COPY" ] || { echo 'project and linked copy must differ' >&2; exit 1; }
[ "$(git -C "$COPY" rev-parse --show-toplevel)" = "$COPY" ]
[ "$(git -C "$COPY" rev-parse --path-format=absolute --git-common-dir)" = "$PROJECT/.git" ]
HOME_ROOT="$TASK/home-$(date +%s)"
mkdir -p "$HOME_ROOT/config" "$HOME_ROOT/state" "$HOME_ROOT/data" "$HOME_ROOT/projects" "$TASK/bin"
printf 'manual\n' > "$HOME_ROOT/config/backlog-backend"
printf 'herdr\n' > "$HOME_ROOT/config/runtime-backend"
printf 'dsh\n' > "$HOME_ROOT/config/crew-harness"
printf 'omp-or-tc\n' > "$HOME_ROOT/config/session-launch-policy"
printf '| Project | Path | Mode | Yolo |\n| --- | --- | --- | --- |\n| dsh-lab | %s | local-only | off |\n' "$PROJECT" > "$HOME_ROOT/data/projects.md"
cat > "$TASK/bin/herdr" <<EOF
#!/usr/bin/env bash
set -eu
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo 'lab guard refuses unsessioned or foreign Herdr call' >&2; exit 98; }
args=("\${args[@]:0:\$((n-2))}")
exec env PATH='$ORIGINAL_PATH' '$HELPER' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$TASK/bin/herdr"
"$HELPER" provision "$SESSION"
export PATH="$TASK/bin:$ORIGINAL_PATH"
lab() { PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
control() { FM_HOME="$HOME_ROOT" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 bash "$ROOT/bin/fm-control.sh" "$@"; }
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
state() { python3 "$ROOT/bin/fm-dsh.py" state "$HOME_ROOT/state" "$ID"; }
wait_state() {
  local want=$1 i s
  for i in $(seq 1 120); do
    s=$(state)
    [ "$s" = "$want" ] && { echo "observed $ID $want"; return 0; }
    sleep 1
  done
  lab pane read "$PANE" --source visible
  echo "dsh-tui 0.16.1 never reached $want" >&2
  return 1
}
wait_rendered() {
  local text=$1 i screen
  for i in $(seq 1 120); do
    screen=$(lab pane read "$PANE" --source recent --lines 250 2>/dev/null || true)
    case "$screen" in *"$text"*) return 0 ;; esac
    sleep 1
  done
  return 1
}
for KIND in ship scout; do
  ID="dsh-$KIND-$$"
  mkdir -p "$HOME_ROOT/data/$ID"
  cat > "$HOME_ROOT/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Prove a tiny interactive DeepSeek $KIND lifecycle without changing files.
## Firstmate spec
Run sleep 40 using Bash, then reply exactly FMDSHBRIEF$KIND.
Do not edit any file or run any fleet command.
Follow subsequent supervisor instructions, but never write task status yourself.
EOF
  WS=$(lab workspace create --cwd "$COPY" --label "fm-$ID" --no-focus)
  PANE=$(printf '%s' "$WS" | jq -er .result.root_pane.pane_id)
  cat > "$HOME_ROOT/state/$ID.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$ID
worktree=$COPY
project=$PROJECT
harness=dsh
kind=$KIND
mode=local-only
yolo=off
branch=$(git -C "$COPY" symbolic-ref --short HEAD)
model=deepseek/deepseek-v4-flash
effort=high
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$(printf '%s' "$WS" | jq -er .result.workspace.workspace_id)
herdr_tab_id=$(printf '%s' "$WS" | jq -er .result.root_pane.tab_id)
herdr_pane_id=$PANE
EOF
  FM_HOME="$HOME_ROOT" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch --model deepseek/deepseek-v4-flash --effort high
  wait_state busy
  first_session=$(python3 "$ROOT/bin/fm-dsh.py" session-file "$HOME_ROOT/state" "$ID")
  [ -n "$first_session" ] || { echo "no readable dsh session after launch" >&2; exit 1; }
  echo "first session=$first_session"
  composer=unknown
  for _ in $(seq 1 60); do
    composer=$(fm_backend_herdr_composer_state "$SESSION:$PANE")
    [ "$composer" = unknown ] || break
    sleep 1
  done
  echo "busy composer=$composer"
  [ "$composer" = empty ] || { lab pane read "$PANE" --source visible; echo "expected an empty busy composer, got $composer" >&2; exit 1; }
  FM_HOME="$HOME_ROOT" bash "$ROOT/bin/fm-send.sh" "$ID" "After the current instructions finish, reply exactly FMDSHSTEER$KIND and nothing else."
  wait_rendered "FMDSHSTEER$KIND" || { lab pane read "$PANE" --source visible; echo "$ID never consumed its mid-task steer" >&2; exit 1; }
  echo "steer acknowledged by $ID"
  wait_state idle
  FM_HOME="$HOME_ROOT" bash "$ROOT/bin/fm-send.sh" "$ID" "Run sleep 60 with Bash, then reply exactly FMDSHINTERRUPT$KIND."
  wait_state busy
  control "$ID" interrupt
  control "$ID" exit
  [ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = dead ] || { echo "exit did not stop $ID" >&2; exit 1; }
  # A resumed dsh session appends to the same log. Growth after the relaunch,
  # plus an acknowledgement, is the local proof; the secret-word probe and the
  # resumed-recall assertion cover the conversation itself.
  before_bytes=$(wc -c < "$first_session")
  control "$ID" relaunch --note "Reply exactly FMDSHRELAUNCH$KIND. Do not run sleep or edit files."
  wait_rendered "FMDSHRELAUNCH$KIND" || { lab pane read "$PANE" --source visible; echo "relaunched $ID never read its instructions" >&2; exit 1; }
  second_session=$(python3 "$ROOT/bin/fm-dsh.py" session-file "$HOME_ROOT/state" "$ID")
  [ "$second_session" = "$first_session" ] || { echo "relaunch did not continue the bound session" >&2; exit 1; }
  after_bytes=$(wc -c < "$second_session")
  [ "$after_bytes" -gt "$before_bytes" ] || { echo "the resumed session recorded no new turn" >&2; exit 1; }
  grep -q "FMDSHSTEER$KIND" "$second_session" \
    || { echo "the resumed session lost its earlier conversation" >&2; exit 1; }
  echo "resumed the earlier conversation in place"
  for _ in $(seq 1 60); do
    [ "$(fm_backend_herdr_composer_state "$SESSION:$PANE")" = empty ] && break
    sleep 1
  done
  control "$ID" exit
  [ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = dead ] || { echo "final exit did not stop $ID" >&2; exit 1; }
  printf 'ok - live dsh-tui 0.16.1 %s brief, busy composer, mid-task steer, interrupt, exit, resumed conversation, final exit\n' "$KIND"
done
printf 'lab_project=%s\nlab_copy=%s\nlab_home=%s\n' "$PROJECT" "$COPY" "$HOME_ROOT"
