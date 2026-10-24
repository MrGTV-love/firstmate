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
SESSION=$("$HELPER" name dsh-fixes)
echo "herdr lab session: $SESSION"
HOME_ROOT=$(mktemp -d /tmp/fm-dsh-fixes.XXXXXX); HOME_ROOT=$(cd "$HOME_ROOT" && pwd -P)
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

# ---------- S-EXPLICIT: pane shell exports GIT_CONFIG_GLOBAL ----------
echo "== S-EXPLICIT"
new_ship "dsh-explicit-$$" --env "GIT_CONFIG_GLOBAL=$TASK/explicit.gitconfig"
printf '[user]\n\tname = FmExplicitLabUser\n\temail = explicit@lab.invalid\n' > "$TASK/explicit.gitconfig"
brief "$ID" "$TASK/out/explicit.txt" UNUSED
spawn "$ID" --relaunch --model "$MODEL" --effort high
wait_file "$TASK/out/explicit.txt"; sleep 1
cat "$TASK/out/explicit.txt"
grep -qx "GIT_CONFIG_GLOBAL=\[$TASK/explicit.gitconfig\]" "$TASK/out/explicit.txt" || { echo "S-EXPLICIT FAIL: exported GIT_CONFIG_GLOBAL not kept" >&2; exit 1; }
grep -qx 'user.name=\[FmExplicitLabUser\]' "$TASK/out/explicit.txt" || { echo "S-EXPLICIT FAIL: explicit global config not read" >&2; exit 1; }
echo "S-EXPLICIT pass"
wait_state idle || true
control "$ID" exit

# ---------- S-XDG ----------
echo "== S-XDG"
SECRET=PELICAN$$
new_ship "dsh-xdg-$$"
brief "$ID" "$TASK/out/xdg.txt" "$SECRET"
spawn "$ID" --relaunch --model "$MODEL" --effort high
wait_file "$TASK/out/xdg.txt"; sleep 1
cat "$TASK/out/xdg.txt"
grep -qx 'GIT_CONFIG_GLOBAL=\[<unset>\]' "$TASK/out/xdg.txt" || { echo "S-XDG FAIL: GIT_CONFIG_GLOBAL was forced" >&2; exit 1; }
grep -qx 'user.name=\[FmXdgLabUser\]' "$TASK/out/xdg.txt" || { echo "S-XDG FAIL: XDG-only git identity lost" >&2; exit 1; }
echo "S-XDG pass"
wait_rendered FMDSHGITDONE || true
wait_state idle
control "$ID" exit
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = dead ] || { echo "exit did not stop $ID" >&2; exit 1; }
V4=$(dshpy session-file "$HOME_ROOT/state" "$ID")
GEN=$(root_of)
echo "depth-zero log: $V4"; echo "generation: $GEN"
SDIR=$(dirname "$V4"); SESSIONS=$(dirname "$SDIR")

# ---------- S-MALFORMED ----------
echo "== S-MALFORMED"
BAD="$SESSIONS/00000000-0000-0000-0000-badbadbadbad"
mkdir -p "$BAD"; printf '{"type":"not-a-session"}\n' > "$BAD/session.v4.jsonl"
sum_before=$(shasum "$V4" | cut -d' ' -f1)
set +e; out=$(spawn "$ID" --relaunch --model "$MODEL" --effort high 2>&1); rc=$?; set -e
echo "$out" | tail -5; echo "relaunch rc=$rc"
[ "$rc" -ne 0 ] || { echo "S-MALFORMED FAIL: relaunch did not refuse" >&2; exit 1; }
case "$out" in *"does not open with a session header"*) ;; *) echo "S-MALFORMED FAIL: unexpected refusal text" >&2; exit 1 ;; esac
[ "$(root_of)" = "$GEN" ] && [ -d "$GEN" ] || { echo "S-MALFORMED FAIL: generation replaced or removed" >&2; exit 1; }
[ "$(shasum "$V4" | cut -d' ' -f1)" = "$sum_before" ] || { echo "S-MALFORMED FAIL: conversation log changed" >&2; exit 1; }
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = dead ] || { echo "S-MALFORMED FAIL: an agent started" >&2; exit 1; }
echo "S-MALFORMED pass: refused, generation and v4 log intact"
rm -rf "$BAD"

# ---------- S-UNCOMMITTED ----------
echo "== S-UNCOMMITTED"
printf '{"type":"session","id":"partial' > "$SDIR/session.v5.jsonl"
echo "session-file with partial v5: $(dshpy session-file "$HOME_ROOT/state" "$ID")"
echo "position with partial v5: $(dshpy position "$HOME_ROOT/state" "$ID")"
echo "state with partial v5: $(state)"
[ "$(dshpy session-file "$HOME_ROOT/state" "$ID")" = "$V4" ] || { echo "S-UNCOMMITTED FAIL: v4 not the live log" >&2; exit 1; }
before_bytes=$(wc -c < "$V4")
spawn "$ID" --relaunch --model "$MODEL" --effort high
[ "$(root_of)" = "$GEN" ] || { echo "S-UNCOMMITTED FAIL: relaunch prepared a new generation (conversation discarded)" >&2; exit 1; }
[ -f "$V4" ] || { echo "S-UNCOMMITTED FAIL: v4 log gone" >&2; exit 1; }
sleep 8
FM_HOME="$HOME_ROOT" bash "$ROOT/bin/fm-send.sh" "$ID" "Without running any tool, reply with the text SECRETIS immediately followed by the secret word you were asked to remember, with no space."
wait_rendered "SECRETIS$SECRET" || { lab pane read "$PANE" --source visible; echo "S-UNCOMMITTED FAIL: resumed worker did not recall its secret" >&2; exit 1; }
[ "$(wc -c < "$V4")" -gt "$before_bytes" ] || ls -la "$SDIR"
grep -q "SECRETIS$SECRET" "$SDIR"/session.v*.jsonl || { echo "S-UNCOMMITTED FAIL: answer not in the bound session dir" >&2; exit 1; }
echo "after relaunch session dir:"; ls -la "$SDIR"
echo "S-UNCOMMITTED pass: same generation $GEN, same session dir, secret recalled"
wait_state idle || true
lab pane read "$PANE" --source visible > "$TASK/out/uncommitted-pane.txt" 2>&1 || true
control "$ID" exit
echo "ALL PASS"
