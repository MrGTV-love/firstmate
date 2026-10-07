#!/usr/bin/env bash
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-shell)
SPAWN_TMP_DIRS=()
cleanup() {
  local dir
  for dir in ${SPAWN_TMP_DIRS[@]+"${SPAWN_TMP_DIRS[@]}"}; do rm -rf -- "$dir"; done
  fm_test_cleanup
}
trap cleanup EXIT
unset FM_SPAWN_GEN HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_TAB_ID
export HERDR_SESSION=fm-shell-test
BASH_BIN=$(command -v bash)
PYTHON_BIN=$(command -v python3)
ZSH_BIN=$(command -v zsh || true)

make_case() {
  local name=$1 kind=$2 task_tmp home_root home_hash launch_dir
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  ID="shell-$name-$$"
  task_tmp="/tmp/fm-$ID"
  if (umask 077 && mkdir "$task_tmp") 2>/dev/null; then
    SPAWN_TMP_DIRS+=("$task_tmp")
  else
    fail "refusing preexisting or unavailable task temp namespace $task_tmp"
  fi
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake" gh gh-axi)
  fm_test_spawn_home "$HOME_DIR" codex
  home_root=$(cd "$HOME_DIR" && pwd -P)
  home_hash=$(printf '%s' "$home_root" | shasum -a 256)
  home_hash=${home_hash%% *}
  launch_dir="/tmp/fm-$ID+$home_hash"
  if (umask 077 && mkdir "$launch_dir") 2>/dev/null; then
    SPAWN_TMP_DIRS+=("$launch_dir")
  else
    fail "refusing preexisting or unavailable launch namespace $launch_dir"
  fi
  printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "task-$name"
  fm_test_spawn_brief "$HOME_DIR" "$ID"
  if [ "$kind" = secondmate ]; then
    mkdir -p "$WT_DIR/bin" "$WT_DIR/data" "$WT_DIR/state" "$WT_DIR/config" "$WT_DIR/projects"
    printf '%s\n' "$ID" > "$WT_DIR/.fm-secondmate-home"
    printf '# Supervisor\n' > "$WT_DIR/AGENTS.md"
    printf '# Charter\nExercise the launch shell.\n' > "$WT_DIR/data/charter.md"
    ln -s "$ROOT/bin" "$PROJ_DIR/bin"
  fi
  WT_DIR=$(cd "$WT_DIR" && pwd -P)
  printf '%s\n' "$WT_DIR" > "$CASE_DIR/cwd"
  : > "$CASE_DIR/pane-input.sh"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
D=$FM_FAKE_DIR
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n' ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n' ;;
  'workspace create') printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"}}}\n' ;;
  'tab list') printf '{"result":{"tabs":[]}}\n' ;;
  'tab create') printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n' ;;
  'pane get') jq -nc --arg pane "${3:-}" --arg cwd "$(cat "$D/cwd")" '{result:{pane:{pane_id:$pane,foreground_cwd:$cwd}}}' ;;
  'agent get') printf '{"error":{"code":"agent_not_found"}}\n' ;;
  'pane process-info') printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%%9","shell_pid":4242,"foreground_processes":[]}}}\n' ;;
  'pane send-text')
    printf '%s\n' "${4:-}" >> "$D/pane-input.sh"
    case "${4:-}" in
      ". '"*"'")
        printf '%s\n' "${4:-}" >> "$D/source-lines" ;;
    esac ;;
  *) : ;;
esac
SH
  cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-axo pid=,ppid=,comm=') printf '4242 1 bash\n' ;;
  '-p 4242 -o args=') printf 'bash\n' ;;
  *) exec /bin/ps "$@" ;;
esac
SH
  cat > "$CASE_DIR/probe.py" <<'PY'
import json, os, sys
print(json.dumps({"argv": sys.argv[1:], "gen": os.environ.get("FM_SPAWN_GEN"),
                  "ambient": os.environ.get("PANE_AMBIENT"),
                  "listed": os.environ.get("PANE_LISTED"),
                  "compound": os.environ.get("COMPOUND_VALUE"),
                  "shell": os.environ.get("BOUNDARY_SHELL")}))
PY
  for harness in omp codex; do
    printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$PYTHON_BIN" "$CASE_DIR/probe.py" > "$FAKEBIN/$harness"
    chmod +x "$FAKEBIN/$harness"
  done
  chmod +x "$FAKEBIN/herdr" "$FAKEBIN/ps"
  export FM_HERDR_PS_BIN="$FAKEBIN/ps"
}

run_spawn() {
  local kind=$1 raw=$2 out status=0
  shift 2
  if [ "$kind" = secondmate ]; then
    mkdir -p "$HOME_DIR/user-home"
    out=$(FM_FAKE_DIR="$CASE_DIR" FM_ROOT_OVERRIDE="$PROJ_DIR" \
      FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_SPAWN_NO_GUARD=1 \
      PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-spawn.sh" "$ID" "$WT_DIR" \
      --secondmate --backend herdr --harness "$raw" "$@" 2>&1) || status=$?
  elif [ "$kind" = relaunch ]; then
    out=$(FM_FAKE_DIR="$CASE_DIR" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" \
      "$ID" --relaunch --harness "$raw" "$@") || status=$?
  elif [ "$kind" = scout ]; then
    out=$(FM_FAKE_DIR="$CASE_DIR" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" \
      "$ID" "$PROJ_DIR" --scout --backend herdr --harness "$raw" "$@") || status=$?
  else
    out=$(FM_FAKE_DIR="$CASE_DIR" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" \
      "$ID" "$PROJ_DIR" --mode local-only --yolo off --backend herdr --harness "$raw" "$@") || status=$?
  fi
  expect_code 0 "$status" "$kind spawn should succeed: $out"
  [ -s "$CASE_DIR/source-lines" ] || fail "$kind must deliver a staged source line"
}

execute_pane() {
  local shell=$1 filtered=$2 harness=$3 expected_config=$4 compound=$5 gen
  gen=$(grep '^spawn_gen=' "$HOME_DIR/state/$ID.meta" | cut -d= -f2-)
  [ -n "$gen" ] || fail 'spawn record must contain an incarnation'
  cat > "$CASE_DIR/after-launch.sh" <<'SH'
printf 'shell-gen=%s\n' "${FM_SPAWN_GEN-unset}"
printf 'shell-compound=%s\n' "${COMPOUND_VALUE-unset}"
omp --resume=bare-session
SH
  mkdir -p "$CASE_DIR/pane-home"
  local shell_args=(-f)
  [ "$shell" != "$BASH_BIN" ] || shell_args=(--noprofile --norc)
  # shellcheck disable=SC2016 # The destination shell must expand this code.
  env -i HOME="$CASE_DIR/pane-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    TMPDIR="${TMPDIR:-$TMP_ROOT}" PANE_AMBIENT=ambient PANE_LISTED=listed \
    "$shell" "${shell_args[@]}" -c '
      unset FM_SPAWN_GEN
      BOUNDARY_SHELL=${ZSH_VERSION:+zsh}
      BOUNDARY_SHELL=${BOUNDARY_SHELL:-bash}
      export BOUNDARY_SHELL
      . "$1"
      . "$2"
    ' pane "$CASE_DIR/pane-input.sh" "$CASE_DIR/after-launch.sh" \
    > "$CASE_DIR/probe-output" 2> "$CASE_DIR/probe-error" \
    || fail "destination shell failed: $(cat "$CASE_DIR/probe-error")"
  "$PYTHON_BIN" - "$CASE_DIR/probe-output" "$gen" "$filtered" "$expected_config" "$compound" <<'PY'
import json, pathlib, sys
path, gen, filtered, config, compound = sys.argv[1:]
lines = pathlib.Path(path).read_text().splitlines()
children = [json.loads(line) for line in lines if line.startswith('{')]
assert len(children) == 2, lines
child, resume = children
assert child['gen'] == gen, child
assert 'shell-gen=unset' in lines, lines
assert resume['gen'] is None, resume
assert 'shell-compound=unset' in lines, lines
assert resume['argv'] == ['--resume=bare-session'], resume
assert child['argv'] == ['--config', config], child
assert child['compound'] == (compound or None), child
assert child['ambient'] == (None if filtered == 'yes' else 'ambient'), child
assert child['listed'] == 'listed', child
if filtered == 'yes':
    assert child['shell'] is None, child
else:
    assert child['shell'] in ('zsh', 'bash'), child
PY
  pass "$harness destination-shell launch matches record without contaminating shell or bare resume"
}

if [ -n "$ZSH_BIN" ]; then
  make_case zsh-ship ship
  # shellcheck disable=SC2016 # The destination zsh must expand this launch command.
  run_spawn ship 'omp --config "${${HOME}:A}/worker.yml"'
  execute_pane "$ZSH_BIN" no omp "$CASE_DIR/pane-home/worker.yml" ''

  make_case zsh-scout scout
  # shellcheck disable=SC2016 # The destination zsh must expand this launch command.
  run_spawn scout 'omp --config "${${HOME}:A}/worker.yml"; export COMPOUND_VALUE=compound'
  execute_pane "$ZSH_BIN" no omp "$CASE_DIR/pane-home/worker.yml" ''
  [ ! -s "$CASE_DIR/probe-error" ] || fail 'compound zsh launch must not emit errors'
else
  printf 'ok - zsh destination-shell cases # SKIP zsh is unavailable\n'
fi

make_case bash-generic ship
# shellcheck disable=SC2016 # The destination shell must expand this launch command.
run_spawn ship 'codex --config "${HOME}/worker.yml"'
execute_pane "$BASH_BIN" no codex "$CASE_DIR/pane-home/worker.yml" ''

: > "$CASE_DIR/pane-input.sh"
: > "$CASE_DIR/source-lines"
old_gen=$(grep '^spawn_gen=' "$HOME_DIR/state/$ID.meta" | cut -d= -f2-)
# shellcheck disable=SC2016 # The destination shell must expand this launch command.
run_spawn relaunch 'codex --config "${HOME}/replacement.yml"'
execute_pane "$BASH_BIN" no codex "$CASE_DIR/pane-home/replacement.yml" ''
new_gen=$(grep '^spawn_gen=' "$HOME_DIR/state/$ID.meta" | cut -d= -f2-)
[ "$old_gen" != "$new_gen" ] || fail 'relaunch must record a new incarnation'

make_case bash-secondmate secondmate
# shellcheck disable=SC2016 # The destination shell must expand this launch command.
run_spawn secondmate 'codex --config "${HOME}/supervisor.yml"'
execute_pane "$BASH_BIN" no codex "$CASE_DIR/pane-home/supervisor.yml" ''

for shell in "$BASH_BIN" ${ZSH_BIN:+"$ZSH_BIN"}; do
  name=bash
  [ "$shell" != "$ZSH_BIN" ] || name=zsh
  make_case "$name-filtered" scout
  printf 'PANE_LISTED\n' > "$HOME_DIR/config/launch-env-allowlist"
  # shellcheck disable=SC2016 # The destination shell must expand this launch command.
  run_spawn scout 'COMPOUND_VALUE=posix; export COMPOUND_VALUE; omp --config "${ZSH_VERSION-posix}/worker.yml"'
  execute_pane "$shell" yes omp 'posix/worker.yml' posix
done
