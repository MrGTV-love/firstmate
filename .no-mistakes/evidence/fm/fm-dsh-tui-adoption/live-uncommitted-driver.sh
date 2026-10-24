#!/usr/bin/env bash
# Disposable live driver (test-phase evidence, not a repo test), head 8af2496db.
# Real DeepSeek ships on dsh-tui in a named non-default Herdr lab. It drives the
# behavior this run's review fixes changed:
#  S-XDG       operator keeps git identity only in ~/.config/git/config (no
#              ~/.gitconfig, no GIT_CONFIG_GLOBAL): the worker's own Bash sees no
#              GIT_CONFIG_GLOBAL and `git config --global user.name` finds the XDG name
#  S-EXPLICIT  a pane that exports GIT_CONFIG_GLOBAL: the worker keeps that exact value
#  S-MALFORMED a committed non-session first line in a session log: relaunch refuses,
#              the binding generation and the depth-zero log stay byte-identical
#  S-UNCOMMITTED an uncommitted newer session.v5.jsonl header beside the live v4 log:
#              session-file/position still read v4, relaunch resumes the same session
#              in the same generation, and the worker recalls its earlier secret
set -eu
ROOT=$1; TASK=$2; OPH=$3; PROJECT=$4; COPY=$5
cd "$ROOT"
HELPER=$ROOT/bin/fm-herdr-lab.sh
ORIGINAL_PATH=$PATH
export FM_DSH_OPERATOR_HOME=$OPH
MODEL=deepseek/deepseek-v4-flash
mkdir -p "$TASK/bin" "$TASK/out"
export FM_HERDR_LAB_STATE_DIR="$TASK/herdr-safety"
SESSION=$("$HELPER" name dsh-uncommit)
echo "herdr lab session: $SESSION"
HOME_ROOT=$(mktemp -d /tmp/fm-dsh-uncommit.XXXXXX); HOME_ROOT=$(cd "$HOME_ROOT" && pwd -P)
. "$ROOT/tests/fm-dsh-live-cleanup.sh"
cleanup() {
  local rc=$?
  trap - EXIT
  fm_dsh_live_cleanup "$rc" "$SESSION" "$HELPER" "$ORIGINAL_PATH" "$HOME_ROOT" || rc=1
  left=$(find "$HOME_ROOT" -name '.credentials.yaml' 2>/dev/null | wc -l | tr -d ' ')
  echo "credential copies left under task home after scrub: $left"
  [ "$left" = 0 ] || rc=1
  printf 'lab_home=%s\nfinal_exit=%s\n' "$HOME_ROOT" "$rc"
  exit "$rc"
}
trap cleanup EXIT
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION GIT_CONFIG_GLOBAL XDG_CONFIG_HOME
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
"$ROOT/bin/fm-lab-home.sh" create "$HOME_ROOT" >/dev/null
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
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo 'lab guard refuses foreign Herdr call' >&2; exit 98; }
args=("\${args[@]:0:\$((n-2))}")
exec env PATH='$ORIGINAL_PATH' '$HELPER' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$TASK/bin/herdr"
printf '#!/bin/sh\necho "treehouse shim refused: lab never allocates real pool slots" >&2\nexit 97\n' > "$TASK/bin/treehouse"; chmod +x "$TASK/bin/treehouse"
"$HELPER" provision "$SESSION"
export PATH="$TASK/bin:$ORIGINAL_PATH"
lab() { PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/backends/herdr.sh"
spawn() { FM_HOME="$HOME_ROOT" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" "$@"; }
control() { FM_HOME="$HOME_ROOT" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 bash "$ROOT/bin/fm-control.sh" "$@"; }
dshpy() { python3 "$ROOT/bin/fm-dsh.py" "$@"; }
state() { dshpy state "$HOME_ROOT/state" "$ID"; }
root_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root"])' "$HOME_ROOT/state/$ID.dsh-session"; }
wait_state() {
  local want=$1 i s
  for i in $(seq 1 150); do
    s=$(state 2>/dev/null || true)
    [ "$s" = "$want" ] && { echo "observed $ID $want"; return 0; }
    sleep 1
  done
  lab pane read "$PANE" --source visible
  echo "dsh-tui never reached $want (last: $s)" >&2
  return 1
}
wait_file() { local f=$1 i; for i in $(seq 1 150); do [ -s "$f" ] && return 0; sleep 1; done; echo "never wrote $f" >&2; return 1; }
wait_rendered() {
  local text=$1 i screen
  for i in $(seq 1 150); do
    screen=$(lab pane read "$PANE" --source recent --lines 300 2>/dev/null || true)
    case "$screen" in *"$text"*) return 0 ;; esac
    sleep 1
  done
  return 1
}
new_ship() {  # <id> [workspace --env args...]
  ID=$1; shift
  mkdir -p "$HOME_ROOT/data/$ID"
  WS=$(lab workspace create --cwd "$COPY" --label "fm-$ID" --no-focus "$@")
  PANE=$(printf '%s' "$WS" | jq -er .result.root_pane.pane_id)
  sleep 3
  cat > "$HOME_ROOT/state/$ID.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$ID
worktree=$COPY
project=$PROJECT
harness=dsh
kind=ship
mode=local-only
yolo=off
branch=lab-copy
model=$MODEL
effort=high
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$(printf '%s' "$WS" | jq -er .result.workspace.workspace_id)
herdr_tab_id=$(printf '%s' "$WS" | jq -er .result.root_pane.tab_id)
herdr_pane_id=$PANE
EOF
}
brief() {  # <id> <outfile> <secret>
  cat > "$HOME_ROOT/data/$1/brief.md" <<EOF
# Task
## Captain's intent
Report the git identity this DeepSeek ship sees, without changing files.
## Firstmate spec
Remember this secret word for later questions: $3.
Use your Bash tool to run exactly this one command:
{ printf 'GIT_CONFIG_GLOBAL=[%s]\\n' "\${GIT_CONFIG_GLOBAL-<unset>}"; printf 'user.name=[%s]\\n' "\$(git config --global user.name)"; printf 'HOME=[%s]\\n' "\$HOME"; } > '$2'
Then reply exactly FMDSHGITDONE. Do not edit project files, publish, or run fleet commands.
EOF
}

cap() { lab pane read "$PANE" --source recent --lines 120 > "$TASK/out/$1.txt" 2>&1 || true; echo "--- pane after $1 (last 40 lines)"; tail -40 "$TASK/out/$1.txt"; }
SECRET=OSPREY$$
new_ship "dsh-unc-$$"
brief "$ID" "$TASK/out/unc.txt" "$SECRET"
spawn "$ID" --relaunch --model "$MODEL" --effort high
wait_file "$TASK/out/unc.txt"
wait_rendered FMDSHGITDONE || true
wait_state idle
control "$ID" exit
V4=$(dshpy session-file "$HOME_ROOT/state" "$ID"); GEN=$(root_of); SDIR=$(dirname "$V4")
echo "v4=$V4"; echo "gen=$GEN"
MODE=${UNC_MODE:-partial}
case "$MODE" in
  partial) printf '{"type":"session","id":"partial' > "$SDIR/session.v5.jsonl" ;;
  empty) : > "$SDIR/session.v5.jsonl" ;;
  none) ;;
esac
echo "mode=$MODE; session-file now: $(dshpy session-file "$HOME_ROOT/state" "$ID")"
b0=$(wc -c < "$V4")
( while :; do lab pane read "$PANE" --source recent --lines 120 > "$TASK/out/poll.tmp" 2>/dev/null && grep -q . "$TASK/out/poll.tmp" && ! grep -q pane_not_found "$TASK/out/poll.tmp" && cp "$TASK/out/poll.tmp" "$TASK/out/last-live-pane.txt"; sleep 1; done ) &
POLL=$!
set +e
control "$ID" relaunch --note "Without running any tool, reply with the text SECRETIS immediately followed by the secret word you were asked to remember, with no space."
rc=$?
set -e
echo "control relaunch rc=$rc"
echo "binding root after: $(root_of) (same=$([ "$(root_of)" = "$GEN" ] && echo yes || echo no))"
if wait_rendered "SECRETIS$SECRET"; then echo "RECALLED secret after relaunch"; else echo "NO RECALL"; fi
kill $POLL 2>/dev/null || true; wait $POLL 2>/dev/null || true
echo "--- last live pane during relaunch:"; cat "$TASK/out/last-live-pane.txt" 2>/dev/null | tail -60
ls -la "$SDIR"; echo "v4 bytes before=$b0 after=$(wc -c < "$V4")"
[ -f "$SDIR/session.v5.jsonl" ] && { echo "v5 head:"; head -c 300 "$SDIR/session.v5.jsonl"; echo; }
ps -ax -o pid,command | grep -F "$GEN" | grep -v grep | head -3 || true
if [ "${UNC_RECOVER:-0}" = 1 ]; then
  echo "== recovery: remove the foreign v5 file, relaunch the same task again"
  rm -f "$SDIR/session.v5.jsonl"
  # the failed relaunch closed the pane; give the task a fresh pane in the lab
  WS=$(lab workspace create --cwd "$COPY" --label "fm-$ID-r" --no-focus); PANE=$(printf '%s' "$WS" | jq -er .result.root_pane.pane_id); sleep 3
  sed -i '' -e "s/^window=.*/window=$SESSION:$PANE/" -e "s/^herdr_pane_id=.*/herdr_pane_id=$PANE/" -e "s/^herdr_workspace_id=.*/herdr_workspace_id=$(printf '%s' "$WS" | jq -er .result.workspace.workspace_id)/" -e "s/^herdr_tab_id=.*/herdr_tab_id=$(printf '%s' "$WS" | jq -er .result.root_pane.tab_id)/" "$HOME_ROOT/state/$ID.meta"
  b1=$(wc -c < "$V4")
  control "$ID" relaunch --note "Without running any tool, reply with the text RECALLIS immediately followed by the secret word you were asked to remember, with no space."
  echo "binding root after recovery: $(root_of) (same=$([ "$(root_of)" = "$GEN" ] && echo yes || echo no))"
  echo "session-file after recovery: $(dshpy session-file "$HOME_ROOT/state" "$ID")"
  wait_rendered "RECALLIS$SECRET" && echo "RECOVERY RECALLED secret $SECRET" || { echo "RECOVERY NO RECALL"; exit 1; }
  echo "v4 bytes before=$b1 after=$(wc -c < "$V4")"
  grep -q "RECALLIS$SECRET" "$V4" && echo "answer recorded in the same v4 log"
  lab pane read "$PANE" --source visible > "$TASK/out/recovery-pane.txt" 2>&1 || true
  cp "$TASK/out/recovery-pane.txt" "${UNC_EVIDENCE:-/dev/null}" 2>/dev/null || true
fi
control "$ID" exit || true
echo DONE
