#!/usr/bin/env bash
# Disposable live driver (test-phase evidence, not a repo test).
# One real DeepSeek ship in a named non-default Herdr lab:
#  S-REFUSE   explicit --harness omp with a DeepSeek model refuses before any launch
#  S-REROUTE  a ship recorded on omp, relaunched with --model DeepSeek/<id> and no
#             harness, launches dsh-tui and records harness=dsh, canonical model
#  S-GH       that worker's own Bash tool runs a read-only gh-axi call (exit 0)
#             through the linked operator CLI state; DSH preferences stay private
set -eu
ROOT=$1     # gate worktree
TASK=$2     # scratch dir for this run
OPH=$3      # disposable operator home (links real HOME entries, own .dsh-tui/model.json)
PROJECT=$4
COPY=$5
cd "$ROOT"
HELPER=$ROOT/bin/fm-herdr-lab.sh
ORIGINAL_PATH=$PATH
export FM_DSH_OPERATOR_HOME=$OPH
M=$(python3 "$ROOT/bin/fm-dsh.py" preferred-model "$OPH")
MIXED="DeepSeek/${M#deepseek/}"
echo "model resolved at run time: $M ; mixed spelling used: $MIXED"
mkdir -p "$TASK/bin"
export FM_HERDR_LAB_STATE_DIR="$TASK/herdr-safety"
SESSION=$("$HELPER" name dsh-reroute)
echo "herdr lab session: $SESSION"
HOME_ROOT=$(mktemp -d /tmp/fm-dsh-reroute.XXXXXX); HOME_ROOT=$(cd "$HOME_ROOT" && pwd -P)
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
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
"$ROOT/bin/fm-lab-home.sh" create "$HOME_ROOT" >/dev/null
printf 'manual\n' > "$HOME_ROOT/config/backlog-backend"
printf 'herdr\n' > "$HOME_ROOT/config/runtime-backend"
printf 'omp\n' > "$HOME_ROOT/config/crew-harness"
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
"$HELPER" provision "$SESSION"
export PATH="$TASK/bin:$ORIGINAL_PATH"
lab() { PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/backends/herdr.sh"
spawn() { FM_HOME="$HOME_ROOT" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" "$@"; }
control() { FM_HOME="$HOME_ROOT" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 bash "$ROOT/bin/fm-control.sh" "$@"; }
meta() { sed -n "s/^$1=//p" "$HOME_ROOT/state/$ID.meta"; }
ID=dsh-reroute-$$
mkdir -p "$HOME_ROOT/data/$ID"
cat > "$HOME_ROOT/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Prove a read-only GitHub request from this DeepSeek ship.
## Firstmate spec
Use your shell tool to run exactly this read-only command, saving stdout and stderr and its exit status:
gh-axi pr view 182 --repo MrGTV-love/firstmate > '$TASK/gh-pr.txt' 2>&1; result=\$?; printf '%s\\n' "\$result" > '$TASK/gh-pr.exit'
Then reply FMDSHGHREADCOMPLETE. Do not inspect credentials or print tokens. Do not edit project files, publish, start no-mistakes, or run fleet commands.
EOF
WS=$(lab workspace create --cwd "$COPY" --label "fm-$ID" --no-focus)
PANE=$(printf '%s' "$WS" | jq -er .result.root_pane.pane_id)
# The task is recorded as a former omp ship, exactly as fleet state looked
# before DeepSeek moved to dsh-tui.
cat > "$HOME_ROOT/state/$ID.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$ID
worktree=$COPY
project=$PROJECT
harness=omp
kind=ship
mode=local-only
yolo=off
branch=$(git -C "$COPY" symbolic-ref --short HEAD)
model=default
effort=high
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$(printf '%s' "$WS" | jq -er .result.workspace.workspace_id)
herdr_tab_id=$(printf '%s' "$WS" | jq -er .result.root_pane.tab_id)
herdr_pane_id=$PANE
EOF
cp "$HOME_ROOT/state/$ID.meta" "$TASK/meta-before.txt"

echo "=== S-REFUSE: fm-spawn $ID --relaunch --harness omp --model $M"
set +e; out=$(spawn "$ID" --relaunch --harness omp --model "$M" --effort high 2>&1); rc=$?; set -e
printf '%s\n' "$out" | sed 's/^/    | /'
echo "S-REFUSE exit=$rc"
[ "$rc" -ne 0 ] || { echo 'S-REFUSE FAIL: contradicting omp+DeepSeek profile launched' >&2; exit 1; }
case "$out" in *'DeepSeek runs through dsh-tui, not omp'*) ;; *) echo 'S-REFUSE FAIL: refusal text missing' >&2; exit 1 ;; esac
[ ! -e "$HOME_ROOT/state/$ID.dsh-session" ] || { echo 'S-REFUSE FAIL: a dsh binding was prepared' >&2; exit 1; }
cmp -s "$HOME_ROOT/state/$ID.meta" "$TASK/meta-before.txt" || { echo 'S-REFUSE FAIL: meta changed' >&2; exit 1; }
echo "S-REFUSE: pane agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE"); no dsh binding; meta unchanged"
echo "ok - S-REFUSE: explicit omp harness with a DeepSeek model refused before launch"

echo "=== S-REROUTE: fm-spawn $ID --relaunch --model '$MIXED' --effort high (no harness; crew-harness=omp; recorded harness=omp)"
spawn "$ID" --relaunch --model "$MIXED" --effort high
echo "meta after: harness=$(meta harness) model=$(meta model) effort=$(meta effort)"
[ "$(meta harness)" = dsh ] && [ "$(meta model)" = "$M" ] && [ "$(meta effort)" = high ] \
  || { echo 'S-REROUTE FAIL: meta does not record dsh with the canonical model' >&2; exit 1; }
[ -s "$HOME_ROOT/state/$ID.dsh-session" ] || { echo 'S-REROUTE FAIL: no dsh binding' >&2; exit 1; }
echo "binding: $(cat "$HOME_ROOT/state/$ID.dsh-session")"
for _ in $(seq 1 60); do [ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" != dead ] && break; sleep 1; done
echo "pane agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE")"

echo "=== S-GH: wait for the worker's own Bash tool to finish gh-axi"
for _ in $(seq 1 180); do
  if [ -f "$TASK/gh-pr.exit" ] && [ "$(python3 "$ROOT/bin/fm-dsh.py" state "$HOME_ROOT/state" "$ID")" = idle ]; then break; fi
  sleep 1
done
lab pane read "$PANE" --source recent --lines 120 > "$TASK/pane.txt" || true
grep -q 'FMDSHGHREADCOMPLETE' "$TASK/pane.txt" && echo 'pane shows FMDSHGHREADCOMPLETE'
[ -f "$TASK/gh-pr.exit" ] || { echo 'S-GH FAIL: worker never ran the GitHub command' >&2; exit 1; }
echo "gh-axi exit recorded by the worker: $(cat "$TASK/gh-pr.exit")"
[ "$(cat "$TASK/gh-pr.exit")" = 0 ] || { cat "$TASK/gh-pr.txt"; exit 1; }
python3 - "$TASK/gh-pr.txt" "$HOME_ROOT/state/$ID.dsh-session" "$OPH" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1]).read_text()
assert 'number: 182' in out, out
runtime = Path(json.loads(Path(sys.argv[2]).read_text())['root'])
config = runtime / 'home/.config'
assert config.is_symlink(), 'worker .config must be linked, not copied'
assert config.resolve() == (Path(sys.argv[3]) / '.config').resolve()
assert not (runtime / 'home/.dsh-tui').is_symlink(), 'DSH preferences must stay private'
assert (runtime / 'home/.dsh').resolve() == (runtime / 'dsh').resolve(), '.dsh must point at the launch-local root'
print('ok - S-GH: real dsh-tui ship ran gh-axi pr view 182 via its Bash tool, exit=0; worker .config linked to operator home; .dsh/.dsh-tui private')
PY
control "$ID" exit
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = dead ] || { echo 'exit did not stop the ship' >&2; exit 1; }
echo 'ok - control exit stopped the rerouted ship'
