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
SESSION=$("$HELPER" name dsh-route)
echo "herdr lab session: $SESSION"
HOME_ROOT=$(mktemp -d /tmp/fm-dsh-route.XXXXXX); HOME_ROOT=$(cd "$HOME_ROOT" && pwd -P)
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
printf 'omp\n' > "$HOME_ROOT/config/crew-harness"
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

echo "crew-harness config: $(cat "$HOME_ROOT/config/crew-harness")"
echo "== routing owner CLI (bin/fm-dsh.py route)"
for sel in 'deepseek/deepseek-v4-flash' ' DeepSeek/deepseek-v4-pro ' 'claude-opus-4-1' 'claude-sonnet-4' 'openai/gpt-5' 'moonshot/kimi-k2' 'deepseekish/model'; do printf '%-30s -> %s\n' "[$sel]" "$(dshpy route "$sel")"; done
printf '%-30s -> %s\n' "[v4-flash provider=deepseek]" "$(dshpy route deepseek-v4-flash deepseek)"
echo "== S-ROUTE-REFUSE: explicit --harness omp with a DeepSeek model"
new_ship "dsh-rref-$$"; sed -i '' 's/^harness=dsh/harness=omp/' "$HOME_ROOT/state/$ID.meta"
brief "$ID" "$TASK/out/rref.txt" UNUSED
set +e; out=$(spawn "$ID" --relaunch --harness omp --model "$MODEL" 2>&1); rc=$?; set -e
echo "$out" | grep -v '^notice\|^warning' | tail -4; echo "rc=$rc"
[ "$rc" -ne 0 ] || { echo "S-ROUTE-REFUSE FAIL: launched" >&2; exit 1; }
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" != alive ] || { echo "S-ROUTE-REFUSE FAIL: agent running" >&2; exit 1; }
[ ! -e "$HOME_ROOT/state/$ID.dsh-session" ] || { echo "S-ROUTE-REFUSE FAIL: dsh binding written" >&2; exit 1; }
grep -q '^harness=omp' "$HOME_ROOT/state/$ID.meta" && echo "meta still harness=omp; agent state=$(fm_backend_agent_state herdr "$SESSION:$PANE")"
echo "S-ROUTE-REFUSE pass"
echo "== S-ROUTE-IMPLICIT: omp-recorded ship relaunched with only a DeepSeek model"
set +e; out=$(spawn "$ID" --relaunch --model "$MODEL" 2>&1); rc=$?; set -e
echo "$out" | grep -v '^notice\|^warning' | tail -4; echo "rc=$rc"
if [ "$rc" -eq 0 ]; then
  echo "meta harness now: $(sed -n 's/^harness=//p' "$HOME_ROOT/state/$ID.meta") model: $(sed -n 's/^model=//p' "$HOME_ROOT/state/$ID.meta")"
  ps -ax -o command | grep -F "$HOME_ROOT/state/$ID.dsh" | grep -v grep | grep -o 'dsh-tui[^ ]*' | head -2
  wait_file "$TASK/out/rref.txt" && cat "$TASK/out/rref.txt"
  wait_state idle || true
  lab pane read "$PANE" --source visible > "$TASK/out/implicit-pane.txt" 2>&1 || true
  cp "$TASK/out/implicit-pane.txt" "${ROUTE_EVIDENCE:-/dev/null}" 2>/dev/null || true
  control "$ID" exit
fi
echo "== S-ROUTE-FRESH-SCOUT: fresh scout, only a DeepSeek model, crew-harness=omp"
set +e; out=$(FM_HOME="$HOME_ROOT" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" "dsh-rscout-$$" "$PROJECT" --scout --model "$MODEL" 2>&1); rc=$?; set -e
echo "$out" | grep -v '^notice\|^warning' | tail -6; echo "rc=$rc"
if [ "$rc" -eq 0 ]; then ID="dsh-rscout-$$"; echo "meta harness: $(sed -n 's/^harness=//p' "$HOME_ROOT/state/$ID.meta")"; PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_ROOT/state/$ID.meta"); wait_state busy || true; control "$ID" exit || true; fi
echo DONE
