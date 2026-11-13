#!/usr/bin/env bash
# Live drive of the real bin/fm-spawn.sh spawn path on a REAL tmux server (private
# fm-lab socket) with a marked disposable lab home (bin/fm-lab-home.sh env).
# The pane's own shell is polluted (tmux set-environment -g plus the pane rc):
# VIRTUAL_ENV -> decoy venv, PATH led by the decoy bin and the clone .venv/bin,
# PYTHONPATH/PYTHONHOME/... set. The nested project clone has a marker .venv; the
# copy has its own real venv that alone can import the fixture module.
# `treehouse get` in the pane is a shell function that cds into the scratch copy
# (the real treehouse and its pools are never touched).
# Usage: live-real-tmux-spawn.sh <firstmate-root> <scratch-dir> <out-dir>
set -u
ROOT=$1 SCR=$2 OUT=$3
mkdir -p "$SCR" "$OUT"
# shellcheck disable=SC1091
. "$ROOT/tests/fixtures.sh"
. "$ROOT/tests/fm-slot-env-helpers.sh"
TMP_ROOT=$SCR
slot_env_setup_base_python
dir=$(slot_env_make_world tmuxlab copies)
slot_env_add_clone_venv "$dir"
slot_env_add_decoy_venv "$dir"
slot_env_snapshot_decoy "$dir" before
ID=tmuxlab-$$

eval "$("$ROOT/bin/fm-lab-home.sh" env 2>"$OUT/lab-home.stderr")"
echo "lab FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR"
fm_test_spawn_home "$FM_HOME" codex
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
fm_test_spawn_brief "$FM_HOME" "$ID"

fakebin=$dir/fakebin; mkdir -p "$fakebin"
fm_fake_exit0 "$fakebin" treehouse
fm_test_fake_no_mistakes "$fakebin"; fm_test_fake_gh "$fakebin"; fm_test_fake_gh_axi "$fakebin"
cat > "$fakebin/codex" <<SH
#!/bin/sh
printf 'fake codex launched: %s\n' "\$*" >> "$dir/launch.log"
exec sleep 600
SH
chmod +x "$fakebin/codex"

rc=$dir/pane-rc.sh
{
  printf 'export PATH=%q\n' "$dir/decoy/bin:$dir/project/.venv/bin:$dir/stubs:$dir/pybin:$fakebin:/opt/homebrew/bin:/usr/bin:/bin"
  printf 'export FM_STUB_LOG=%q FM_TEST_ENV_RECORD=%q FM_TEST_SLOT_RECORD=%q\n' "$dir/stub-calls.log" "$dir/env-record.json" "$dir/slot-record.json"
  printf 'export FM_TEST_TOOL_NAME=fm-env-tool FM_TEST_TOOL_LOG=%q FM_SENTINEL=sentinel\n' "$dir/tool.log"
  printf 'export CODEX_HOOK_STATE_DIR=%q WORKTREE_LIFECYCLE_STORE_DIR=%q\n' "$dir/codex-hooks" "$dir/lifecycle"
  printf 'treehouse() { [ "${1:-}" = get ] && cd %q && return 0; command treehouse "$@"; }\n' "$dir/copy"
  printf 'PS1="lab$ "\n'
} > "$rc"

T() { tmux -L fm-lab -f /dev/null "$@"; }
T new-session -d -s firstmate -x 200 -y 50 -c "$dir/project" "bash --noprofile --rcfile $rc -i"
T set -g default-command "bash --noprofile --rcfile $rc -i"
T set-environment -g VIRTUAL_ENV "$dir/decoy"
for a in "${SLOT_ENV_POLLUTION[@]}"; do T set-environment -g "${a%%=*}" "${a#*=}"; done
sock=$(T display-message -p '#{socket_path}'); spid=$(T display-message -p '#{pid}')
echo "real tmux server: socket=$sock pid=$spid"
echo "--- pane environment as tmux will give new windows:"; T show-environment -g | grep -E '^(VIRTUAL_ENV|PYTHON|UV_|CONDA|__PYVENV)'

spawn_home=$dir/user-home; mkdir -p "$spawn_home"
(
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$FM_HOME" HOME="$spawn_home" CLAUDE_CONFIG_DIR= TMUX="$sock,$spid,0" TMUX_TMPDIR="$TMUX_TMPDIR" \
    FM_SPAWN_NO_GUARD=1 PATH="$dir/stubs:$dir/pybin:$fakebin:/opt/homebrew/bin:/usr/bin:/bin" \
    "$ROOT/bin/fm-spawn.sh" "$ID" "$dir/project" --backend tmux --mode local-only --yolo off --owned-path scripts
) > "$OUT/spawn.out" 2>&1 &
spawn_pid=$!
( sleep 300; kill "$spawn_pid" 2>/dev/null ) & dog=$!
wait "$spawn_pid"; spawn_rc=$?
kill "$dog" 2>/dev/null
echo "fm-spawn.sh exit=$spawn_rc"
echo "--- spawn output (tail):"; tail -n 25 "$OUT/spawn.out"
echo "--- tmux windows:"; T list-windows -a -F '#{session_name}:#{window_name} #{pane_current_path}'
for w in $(T list-windows -a -F '#{session_name}:#{window_index}'); do echo "--- pane $w:"; T capture-pane -p -t "$w" | grep -v '^$' | tail -n 15; done
echo "--- provisioner env record:"; cat "$dir/env-record.json" 2>/dev/null || echo NONE; echo
echo "--- borrowed interpreter log:"; cat "$dir/borrowed.log"
echo "--- foreign-only tool found:"; cat "$dir/tool.log"
echo "--- pip/uv/venv stub calls:"; cat "$dir/stub-calls.log"
slot_env_snapshot_decoy "$dir" after
echo "--- decoy unchanged: $(cmp -s "$dir/decoy-before.txt" "$dir/decoy-after.txt" && echo yes || echo NO)"
echo "--- slot record:"; cat "$dir/slot-record.json" 2>/dev/null || echo NONE; echo
echo "--- copy branch: $(git -C "$dir/copy" branch --show-current)"
echo "WORLD=$dir"
T kill-server
"$ROOT/bin/fm-lab-home.sh" teardown "$FM_HOME" && rm -rf "$FM_HOME"
echo "lab torn down: $( [ -e "$FM_HOME" ] && echo NO || echo yes)"
