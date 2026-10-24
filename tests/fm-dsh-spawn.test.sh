#!/usr/bin/env bash
# tests/fm-dsh-spawn.test.sh - the portable regression for firstmate's wiring of
# the dsh adapter (DeepSeek Harness through dsh-tui): process detection, the
# crew default route onto dsh, the launch environment a worker inherits, the
# session launch policy, and the busy and liveness verdicts.
#
# Real processes, a fake dsh-tui and dsh, and the fake tmux of the spawn suites
# stand in for the vendor runtime, so CI needs no DeepSeek install.
# FM_DSH_LIVE=1 tests/fm-dsh-live-e2e.test.sh is the live guard against vendor
# drift; tests/fm-dsh-harness.test.sh owns the adapter helper's own contract.
#
# The load-bearing contracts:
#   1. dsh publishes no marker of its own: the anchored process names dsh and
#      dsh-tui, or a node argv naming the dsh script, are the ancestry
#      evidence, and FM_DSH_HARNESS=dsh is a precedence override that needs one.
#   2. With no harness named, a crewmate or scout on a DeepSeek model becomes a
#      dsh launch; only the recorded model decides.
#   3. The launch clears foreign markers, selects the danger-full-access
#      permission mode, and runs the worker under a private HOME that still
#      names the operator's git config and no-mistakes home.
#   4. config/session-launch-policy=omp-or-tc admits the dsh-tui DeepSeek adapter.
#   5. The busy verdict follows the launch's own session log and the tmux
#      liveness probe counts dsh as an agent.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-session-launch-policy-lib.sh
. "$ROOT/bin/fm-session-launch-policy-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-dsh-spawn)
DSH_MODEL=deepseek/deepseek-v4-flash
KNOWN_EMAIL=operator-known@example.test

# --- 1. Detection -------------------------------------------------------------

# Processes whose kernel-recorded identity is a bare dsh name: symlinks to the
# system shell, never copies (a copied platform binary fails macOS code
# signing). A node-named symlink running a script inside a
# @deepseek-harness-tui/dsh-tui package directory proves the argv evidence a
# real node-hosted dsh-tui carries.
make_dsh_processes() {  # <dir> -> echoes <bindir>
  local dir=$1 name
  mkdir -p "$dir/node_modules/@deepseek-harness-tui/dsh-tui/bin" "$dir/node_modules/other" "$dir/node_modules/claude-tool"
  for name in dsh dsh-tui dshd node; do
    ln -sf /bin/bash "$dir/$name"
  done
  # shellcheck disable=SC2016 # the body expands inside the named shell
  printf '%s\n' 'export FM_ANCESTRY_FIXTURE_PID=$$' '"$1"' ':' > "$dir/node_modules/@deepseek-harness-tui/dsh-tui/bin/dsh-tui.js"
  # shellcheck disable=SC2016 # the body expands inside the named shell
  printf '%s\n' 'export FM_ANCESTRY_FIXTURE_PID=$$' '"$1"' ':' > "$dir/node_modules/other/unrelated.js"
  # shellcheck disable=SC2016 # the body expands inside the named shell
  printf '%s\n' 'export FM_ANCESTRY_FIXTURE_PID=$$' '"$1"' ':' > "$dir/node_modules/claude-tool/run.js"
  printf '%s' "$dir"
}

test_detection_anchored_names_argv_and_marker_precedence() {
  local bin out
  bin=$(make_dsh_processes "$TMP_ROOT/dsh-procs")
  # Bound the ancestry walk at this shell: a real dsh may be running this suite,
  # and every decoy would otherwise inherit it.
  local -x FM_TEST_DETECTION_BOUNDARY=$$ FM_TEST_REAL_PS
  FM_TEST_REAL_PS=$(command -v ps)
  local PATH="$bin:$PATH"
  cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "-o ppid= -p $FM_TEST_DETECTION_BOUNDARY" ]; then
  printf '1\n'
else
  exec "$FM_TEST_REAL_PS" "$@"
fi
SH
  chmod +x "$bin/ps"
  local -a clean=(env -u CLAUDECODE -u FM_OMP_HARNESS -u FM_DSH_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u GEMINI_CLI)
  for name in dsh dsh-tui; do
    # shellcheck disable=SC2016 # the quoted body expands inside the named shell
    out=$("${clean[@]}" PATH="$bin:$PATH" "$bin/$name" -c 'export FM_ANCESTRY_FIXTURE_PID=$$; "$1"; :' _ "$HARNESS")
    [ "$out" = dsh ] || fail "a process named $name must detect as dsh, got '$out'"
  done
  out=$("${clean[@]}" PATH="$bin:$PATH" "$bin/node" "$bin/node_modules/@deepseek-harness-tui/dsh-tui/bin/dsh-tui.js" "$HARNESS")
  [ "$out" = dsh ] || fail "a node argv naming the dsh script must detect as dsh, got '$out'"
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$("${clean[@]}" PATH="$bin:$PATH" "$bin/dshd" -c 'export FM_ANCESTRY_FIXTURE_PID=$$; "$1"; :' _ "$HARNESS")
  [ "$out" != dsh ] || fail "'dshd' merely contains dsh and must not detect as dsh"
  out=$("${clean[@]}" PATH="$bin:$PATH" "$bin/node" "$bin/node_modules/other/unrelated.js" "$HARNESS")
  [ "$out" != dsh ] || fail "a node argv that does not name the dsh script must not detect as dsh"
  # The marker beats an inherited CLAUDECODE only under a real dsh ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_DSH_HARNESS=dsh \
    PATH="$bin:$PATH" "$bin/dsh" -c 'export FM_ANCESTRY_FIXTURE_PID=$$; "$1"; :' _ "$HARNESS")
  [ "$out" = dsh ] || fail "FM_DSH_HARNESS under a dsh ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # A tool process under dsh whose script path merely names claude is the
  # nearest harness-shaped ancestor; the marker is what keeps it dsh.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u CLAUDECODE FM_DSH_HARNESS=dsh \
    PATH="$bin:$PATH" "$bin/dsh" -c '"$1" "$2" "$3"; :' _ "$bin/node" "$bin/node_modules/claude-tool/run.js" "$HARNESS")
  [ "$out" = dsh ] || fail "FM_DSH_HARNESS must keep a worker dsh when a nearer tool process only mentions claude in its script path, got '$out'"
  # ...and is inert when it leaks into a worker whose ancestry holds no dsh.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_DSH_HARNESS=dsh \
    PATH="$bin:$PATH" bash -c 'export FM_ANCESTRY_FIXTURE_PID=$$; "$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "a leaked FM_DSH_HARNESS without a dsh ancestor must not relabel a claude worker, got '$out'"
  cat > "$bin/deep-tool.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" -gt 0 ]; then
  bash "$0" "$(( $1 - 1 ))" "$2"
else
  "$2"
fi
:
SH
  # The native session-start transport nests real bounded shell helpers;
  # its structural DSH marker proof must survive that depth.
  # shellcheck disable=SC2016 # this body expands in the dsh-named shell
  out=$("${clean[@]}" FM_DSH_HARNESS=dsh PATH="$bin:$PATH" \
    "$bin/dsh" -c 'bash "$1" 9 "$2"; :' _ "$bin/deep-tool.sh" "$HARNESS")
  [ "$out" = dsh ] || fail "nested native startup must still detect dsh, got '$out'"
  pass "fm-harness: dsh detects by anchored name or script argv, including nested native startup; its marker needs real dsh ancestry"
}

test_lock_identity_and_tmux_liveness_name_dsh() {
  fm_harness_process_matches dsh '' || fail "session-lock identity must accept the exact dsh name"
  fm_harness_process_matches dsh-tui '' || fail "session-lock identity must accept the exact dsh-tui name"
  fm_harness_process_matches /opt/nvm/bin/dsh-tui '' || fail "session-lock identity must accept a dsh-tui path"
  fm_harness_process_matches node 'node /opt/homebrew/bin/dsh-tui --patch launch.yml -- brief' \
    || fail "session-lock identity must accept the Homebrew dsh-tui launcher argv"
  fm_harness_process_matches node 'node /opt/lib/node_modules/@deepseek-harness-tui/dsh-tui/bin/dsh-tui.js --patch launch.yml' \
    || fail "session-lock identity must accept a node argv running a dsh-tui package script"
  ! fm_harness_process_matches dshd '' || fail "session-lock identity must not accept dshd"
  ! fm_harness_process_matches node 'node /tmp/unrelated.js' || fail "session-lock identity must not accept an unrelated node argv"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  [ "$(fm_agent_process_classify_name dsh)" = agent ] || fail "tmux liveness must classify dsh as an agent"
  [ "$(fm_agent_process_classify_name /opt/nvm/bin/dsh-tui)" = agent ] || fail "tmux liveness must classify a dsh-tui path as an agent"
  [ "$(fm_agent_process_classify_name dshd)" != agent ] || fail "tmux liveness must not classify dshd as an agent"
  [ "$(fm_agent_process_classify node '' 'node /opt/homebrew/bin/dsh-tui --patch launch.yml')" = agent ] \
    || fail "shared process classification must accept the Homebrew dsh-tui launcher argv"
  pass "session lock and process classification: dsh is anchored, decoys stay out"
}

# A tmux pane whose foreground group is one node process: tmux reports a tty,
# and the fake ps lists that one process with the command line under test.
make_node_pane() {  # <dir> <args> -> echoes <fakebin>
  local dir=$1 args=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_tty*) printf '/dev/ttyfake\n'; exit 0 ;;
        *pane_current_command*) printf 'node\n'; exit 0 ;;
      esac
    done
    exit 0 ;;
  list-windows) printf 'win\n'; exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"-t ttyfake"*) printf '4242 4242 4242 node\n' ;;
  *"-p 4242 -o args="*) printf '%s\n' '$args' ;;
  *) exec /bin/ps "\$@" ;;
esac
SH
  chmod +x "$fakebin/tmux" "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_tmux_agent_state_names_dsh() {
  local base=/usr/bin:/bin:/usr/sbin:/sbin fb out
  for comm in dsh dsh-tui; do
    fb=$(fm_fakebin "$TMP_ROOT/tmux-$comm")
    cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\\n' '$comm'; exit 0 ;; esac; done
    exit 0 ;;
  list-windows) printf 'win\\n'; exit 0 ;;
esac
exit 0
SH
    chmod +x "$fb/tmux"
    out=$(PATH="$fb:$base" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
    [ "$out" = alive ] || fail "a live $comm foreground process should classify as alive, got '$out'"
  done
  fb=$(make_node_pane "$TMP_ROOT/tmux-dsh-argv" 'node /opt/homebrew/bin/dsh-tui --patch launch.yml -- brief')
  out=$(PATH="$fb:$base" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" = alive ] || fail "a node foreground process running the dsh-tui launcher should classify as alive, got '$out'"
  fb=$(make_node_pane "$TMP_ROOT/tmux-node-other" 'node /opt/lib/node_modules/other/unrelated.js')
  out=$(PATH="$fb:$base" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" != alive ] || fail "a node foreground process running another script must not classify as alive"
  pass "fm_backend_tmux_agent_state: dsh is alive by name and by script argv, an unrelated node is not"
}

# --- 2. Busy state ------------------------------------------------------------

test_busy_classify_follows_the_launch_session_log() {
  local state="$TMP_ROOT/busy/state" root="$TMP_ROOT/busy/launch" cwd="$TMP_ROOT/busy/cwd" store header log
  mkdir -p "$state" "$cwd"
  store="$root/dsh/sessions/workspace/session"
  mkdir -p "$store"
  log="$store/session.v4.jsonl"
  header=$(printf '{"type":"session","version":4,"id":"11111111-1111-4111-8111-111111111111","cwd":"%s","delegationDepth":0}' "$cwd")
  [ "$(fm_busy_classify tmux fake:w dsh dsh-busy "$state")" = 'unknown dsh-session-log' ] \
    || fail "a launch with no binding must read unknown from the session log"
  printf '{"root":"%s","cwd":"%s","generation":"g1","model":"v4","effort":""}\n' "$root" "$cwd" > "$state/dsh-busy.dsh-session"
  [ "$(fm_busy_classify tmux fake:w dsh dsh-busy "$state")" = 'unknown dsh-session-log' ] \
    || fail "a bound launch with no log yet must read unknown"
  printf '%s\n{"type":"turn/start","seq":1}\n' "$header" > "$log"
  [ "$(fm_busy_classify tmux fake:w dsh dsh-busy "$state")" = 'busy dsh-session-log' ] \
    || fail "a durable turn/start must read busy"
  printf '%s\n{"type":"turn/start","seq":1}\n{"type":"turn/end","seq":2}\n' "$header" > "$log"
  [ "$(fm_busy_classify tmux fake:w dsh dsh-busy "$state")" = 'idle dsh-session-log' ] \
    || fail "a durable turn/end must read idle"
  printf '%s\n{"type":"turn/start","seq":1}\n{"type":"turn/end","seq":2}\n{"type":"turn/start","seq":3}\n' "$header" > "$log"
  [ "$(fm_busy_classify tmux fake:w dsh dsh-busy "$state")" = 'busy dsh-session-log' ] \
    || fail "a later turn/start must read busy again"
  pass "fm_busy_classify: dsh follows the launch's own durable session log"
}

# --- 3. Spawn -----------------------------------------------------------------

# A fake dsh-tui whose successful version probe advertises a different release
# and, when launched, records the environment, arguments, and git
# identity the worker would see. A fake dsh answers the CLI version.
make_fake_dsh() {  # <fakebin>
  cat > "$1/dsh-tui" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = version ]; then
  printf '@deepseek-harness-tui/dsh-tui 99.1.0 (launcher)\nprofile: 99.1.0  fake\n'
  exit 0
fi
# Like the real launcher, require its CLI through the worker's search path.
dsh --version >/dev/null || exit 1
log=${FM_FAKE_DSH_ENV_LOG:-/dev/null}
env > "$log"
printf '%s\n' "$@" > "$log.args"
if [ -n "${FM_FAKE_DSH_REPO:-}" ]; then
  git -C "$FM_FAKE_DSH_REPO" commit --allow-empty -q --no-verify -m probe
  git -C "$FM_FAKE_DSH_REPO" log -1 --format=%ae > "$log.author"
  git -C "$FM_FAKE_DSH_REPO" config --get core.hooksPath > "$log.hooks"
fi
exit 0
SH
  cat > "$1/dsh" <<'SH'
#!/usr/bin/env bash
printf '99.2.0\n'
SH
  chmod +x "$1/dsh-tui" "$1/dsh"
}

# A session-log writer standing in for the TUI: once the launch command has been
# sent it records the opening turn in the bound launch store, which is the
# start proof the spawn waits for.
cat > "$TMP_ROOT/dsh-session-writer.py" <<'PY'
import json
import os
import sys
import time
import uuid
from pathlib import Path

state, task, launch = sys.argv[1:]
binding = Path(state) / f"{task}.dsh-session"
deadline = time.time() + 120
while time.time() < deadline:
    if binding.exists() and os.path.exists(launch) and os.path.getsize(launch) > 0:
        break
    time.sleep(0.02)
else:
    sys.exit(1)
bound = json.loads(binding.read_text())
store = Path(bound["root"]) / "dsh" / "sessions" / "workspace" / "session"
store.mkdir(parents=True, exist_ok=True)
header = {"type": "session", "version": 4, "id": str(uuid.uuid4()), "cwd": bound["cwd"], "delegationDepth": 0}
(store / "session.v4.jsonl").write_text(json.dumps(header) + "\n" + json.dumps({"type": "turn/start", "seq": 1}) + "\n")
PY

make_dsh_case() {  # <name> <id> [crew-harness]
  local name=$1 id=$2 crew=${3-omp}
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake" claude omp)
  make_fake_dsh "$FAKEBIN_DIR"
  fm_test_spawn_home "$HOME_DIR" "$crew"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$LAUNCH_LOG"
  printf '%s\n' '  ╭──────────────────────────────╮' '  ⌸ ❯                          ⛶' '  ╰──────────────────────────────╯' > "$CASE_DIR/screen"
  # The installed profile prepare reads, and the credentials it copies.
  local installed="$HOME_DIR/user-home/.dsh"
  mkdir -p "$installed/profiles/dsh-tui/node_modules/@deepseek-harness-tui/dsh-tui"
  printf '{}\n' > "$installed/profiles/dsh-tui/package.json"
  printf '{"version":"99.1.0"}\n' > "$installed/profiles/dsh-tui/node_modules/@deepseek-harness-tui/dsh-tui/package.json"
  printf 'secret\n' > "$installed/.credentials.yaml"
  mkdir -p "$HOME_DIR/user-home/.config/gh"
  printf 'github.com:\n    user: fixture-operator\n' > "$HOME_DIR/user-home/.config/gh/hosts.yml"
}

# Spawn on the current case with the session writer running; echoes the output.
run_dsh_spawn() {  # <id> <spawn-args...>
  local id=$1 writer status out
  shift
  python3 "$TMP_ROOT/dsh-session-writer.py" "$HOME_DIR/state" "$id" "$LAUNCH_LOG" &
  writer=$!
  out=$(DSH_HOME='' FM_DSH_SOURCE_HOME='' FM_BACKEND=tmux FM_DSH_START_POLL_INTERVAL=0.05 FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_CAPTURE_FILE="${FM_FAKE_CAPTURE_FILE:-$CASE_DIR/screen}" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" "$@")
  status=$?
  kill "$writer" 2>/dev/null
  wait "$writer" 2>/dev/null
  printf '%s' "$out"
  return "$status"
}

test_deepseek_model_without_a_harness_routes_to_dsh() {
  local id out status kind
  for kind in ship scout; do
    id="dsh-route-$kind"
    make_dsh_case "route-$kind" "$id"
    if [ "$kind" = scout ]; then
      out=$(run_dsh_spawn "$id" --model "$DSH_MODEL" --scout)
    else
      out=$(run_dsh_spawn "$id" --model "$DSH_MODEL" --mode local-only --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "a $kind on a DeepSeek model with no harness must launch on dsh: $out"
    assert_contains "$out" "spawned $id harness=dsh" "the $kind spawn must report the dsh harness"
    assert_grep "harness=dsh" "$HOME_DIR/state/$id.meta" "the $kind meta must record dsh, not the crew default"
    assert_grep "model=$DSH_MODEL" "$HOME_DIR/state/$id.meta" "the $kind meta must record the DeepSeek model"
    assert_present "$HOME_DIR/state/$id.dsh-session" "the $kind spawn must bind its launch store"
    assert_contains "$(cat "$LAUNCH_LOG")" "FM_DSH_HARNESS=dsh" "the $kind launch must be the dsh template"
    python3 - "$HOME_DIR/state/$id.dsh-session" "$HOME_DIR/user-home" "$kind" <<'PY' || fail "$kind cannot use the linked operator gh configuration"
import json
from pathlib import Path
import sys
binding, operator, kind = map(Path, sys.argv[1:])
home = Path(json.loads(binding.read_text())['root']) / 'home'
gh_config = home / '.config/gh/hosts.yml'
assert gh_config.resolve() == (operator / '.config/gh/hosts.yml').resolve(), f'{kind} must link the operator gh configuration'
assert gh_config.read_text() == 'github.com:\n    user: fixture-operator\n', f'{kind} must read the operator gh configuration'
assert not (home / '.dsh-tui').is_symlink(), f'{kind} DSH preferences must remain launch-local'
PY
  done
  pass "fm-spawn: a ship and a scout on a DeepSeek model with no harness launch on dsh instead of the crew default"
}

test_deepseek_spelling_without_a_harness_routes_to_dsh() {
  local id out status spelling
  for spelling in 'DeepSeek/deepseek-v4-flash' ' DeepSeek / deepseek-v4-flash '; do
    id="dsh-spelled-${#spelling}"
    make_dsh_case "spelled-${#spelling}" "$id"
    out=$(run_dsh_spawn "$id" --model "$spelling" --scout 2>&1)
    status=$?
    expect_code 0 "$status" "'$spelling' with no harness must launch on dsh, not be refused: $out"
    assert_contains "$out" "spawned $id harness=dsh" "'$spelling' must report the dsh harness"
    assert_grep "harness=dsh" "$HOME_DIR/state/$id.meta" "'$spelling' meta must record dsh, not the crew default"
    assert_equals "$DSH_MODEL" "$(sed -n 's/^model=//p' "$HOME_DIR/state/$id.meta")" \
      "'$spelling' meta must record the canonical DeepSeek model"
    [ "$(jq -r .model "$HOME_DIR/state/$id.dsh-session")" = deepseek-v4-flash ] \
      || fail "'$spelling' must bind the bare DeepSeek id"
  done
  pass "fm-spawn: DeepSeek spellings omp would resolve to the deepseek provider route to dsh with no harness"
}

test_explicit_harness_is_not_rerouted() {
  local id=dsh-explicit out status
  make_dsh_case explicit "$id" claude
  out=$(run_dsh_spawn "$id" --harness dsh --model "$DSH_MODEL" --scout)
  status=$?
  expect_code 0 "$status" "an explicit dsh harness must launch: $out"
  assert_grep "harness=dsh" "$HOME_DIR/state/$id.meta" "an explicit dsh pin must be recorded"
  out=$(run_dsh_spawn "$id-bad" --harness dsh --scout 2>&1)
  status=$?
  expect_code 1 "$status" "a dsh launch with no DeepSeek model must be refused: $out"
  assert_contains "$out" "dsh requires an explicit DeepSeek model id" "the refusal must name the missing model"
  assert_absent "$HOME_DIR/state/$id-bad.meta" "a refused dsh launch must publish no metadata"
  pass "fm-spawn: an explicit dsh pin is honored and a dsh launch without a DeepSeek model is refused"
}

# Runs the recorded launch command as a pane would: in a clean environment that
# still carries foreign harness markers, under a fake operator HOME. The fake
# dsh-tui records what it was given; extra arguments are further pane variables.
run_recorded_launch() {  # <out-log> <pane-vars...>
  local log=$1 launch real_home="$CASE_DIR/operator-home" probe="$CASE_DIR/probe-repo"
  shift
  mkdir -p "$real_home"
  printf '[user]\n\tname = Known Operator\n\temail = %s\n' "$KNOWN_EMAIL" > "$real_home/.gitconfig"
  [ -d "$probe/.git" ] || fm_git_init_commit "$probe"
  launch=$(cat "$LAUNCH_LOG")
  : > "$log"
  env -i HOME="$real_home" PATH=/usr/bin:/bin \
    CLAUDECODE=1 FM_OMP_HARNESS=omp PI_CODING_AGENT=true GROK_AGENT=1 CURSOR_AGENT=1 \
    FM_FAKE_DSH_ENV_LOG="$log" FM_FAKE_DSH_REPO="$probe" "$@" \
    /bin/sh -c "$launch" </dev/null >/dev/null 2>&1 || return 1
}

test_launch_environment() {
  local id=dsh-env log launch_env state_home real_home out
  make_dsh_case env "$id"
  real_home="$CASE_DIR/operator-home"
  out=$(run_dsh_spawn "$id" --model "$DSH_MODEL" --scout) || fail "dsh scout spawn failed: $out"
  log="$CASE_DIR/dsh-env.log"
  run_recorded_launch "$log" || fail "the recorded dsh launch command failed: $(cat "$LAUNCH_LOG")"
  launch_env=$(cat "$log")
  assert_contains "$launch_env" "FM_DSH_HARNESS=dsh" "the launch must establish its own marker"
  assert_contains "$launch_env" "DSH_PERMISSION_MODE=danger-full-access" "the launch must select the full-access permission mode"
  for foreign in CLAUDECODE FM_OMP_HARNESS PI_CODING_AGENT GROK_AGENT CURSOR_AGENT; do
    case "$launch_env" in
      *"
$foreign="*|"$foreign="*) fail "the launch must clear the inherited $foreign" ;;
    esac
  done
  state_home=$(sed -n 's/^HOME=//p' "$log")
  case "$state_home" in
    "$HOME_DIR/state/$id.dsh/"*"/home") ;;
    *) fail "the worker's HOME must be the task's private dsh home, got '$state_home'" ;;
  esac
  assert_present "$state_home/.dsh-tui/model.json" "the private HOME must carry the launch-local model preference"
  assert_contains "$(cat "$log.args")" "--patch" "the launch must hand dsh-tui its launch patch"
  assert_contains "$(cat "$log.args")" "brief for $id" "the brief must reach dsh-tui as the opening prompt"
  assert_equals "$KNOWN_EMAIL" "$(cat "$log.author")" \
    "a commit under the private HOME must keep the operator's configured git author"
  assert_contains "$(cat "$log.hooks")" "$id.git-hooks" \
    "the GIT_CONFIG core.hooksPath guard must survive beside GIT_CONFIG_GLOBAL"
  assert_equals "$real_home/.gitconfig" "$(sed -n 's/^GIT_CONFIG_GLOBAL=//p' "$log")" \
    "the worker must read the operator's own git config file"
  assert_equals "$real_home/.no-mistakes" "$(sed -n 's/^NM_HOME=//p' "$log")" \
    "with no NM_HOME exported the worker must still reach the operator's no-mistakes home"
  run_recorded_launch "$log" NM_HOME=/shared/nm GIT_CONFIG_GLOBAL=/shared/gitconfig || fail "the launch with exported paths failed"
  assert_equals /shared/nm "$(sed -n 's/^NM_HOME=//p' "$log")" "an exported NM_HOME must be carried unchanged"
  assert_equals /shared/gitconfig "$(sed -n 's/^GIT_CONFIG_GLOBAL=//p' "$log")" "an exported GIT_CONFIG_GLOBAL must be carried unchanged"
  run_recorded_launch "$log" NM_HOME= || fail "the launch with an empty NM_HOME failed"
  assert_equals "$real_home/.no-mistakes" "$(sed -n 's/^NM_HOME=//p' "$log")" "an empty NM_HOME must select the operator's default home"
  pass "fm-spawn: the dsh launch clears foreign markers, selects full access, and keeps the operator's git config and no-mistakes home under a private HOME"
}

# A crew harness mirrored from a DSH primary with no model carries that
# session's bound model and stages from the operator's install, not from the
# primary's private runtime copy; without a live record it refuses.
mirror_spawn() {  # <dsh-home> <id> -> spawn output
  local writer status out
  python3 "$TMP_ROOT/dsh-session-writer.py" "$HOME_DIR/state" "$2" "$LAUNCH_LOG" &
  writer=$!
  # shellcheck disable=SC2016 # the body expands inside the dsh-named shell
  out=$(export -f fm_test_run_spawn; ROOT="$ROOT" FM_DSH_HARNESS=dsh DSH_HOME="$1" FM_DSH_SOURCE_HOME="$HOME_DIR/user-home/.dsh" \
    FM_BACKEND=tmux FM_DSH_START_POLL_INTERVAL=0.05 FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_CAPTURE_FILE="$CASE_DIR/screen" \
    "$CASE_DIR/ancestor/dsh" -c 'fm_test_run_spawn "$@"; exit "$?"' _ "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$2" "$PROJ_DIR" --scout)
  status=$?
  kill "$writer" 2>/dev/null
  wait "$writer" 2>/dev/null
  printf '%s' "$out"
  return "$status"
}

test_mirrored_dsh_primary_carries_its_bound_model() {
  local id=dsh-mirror primary out status
  make_dsh_case mirror "$id" ''
  mkdir -p "$CASE_DIR/ancestor" "$CASE_DIR/primary-state" "$CASE_DIR/operator-home"
  ln -sf /bin/bash "$CASE_DIR/ancestor/dsh"
  primary=$(FM_DSH_OPERATOR_HOME="$CASE_DIR/operator-home" python3 "$ROOT/bin/fm-dsh.py" prepare-primary \
    "$CASE_DIR/primary-state" dsh-primary g1 "$HOME_DIR/user-home/.dsh" deepseek/deepseek-v4-pro max "$HOME_DIR" "$ROOT") \
    || fail "the primary runtime fixture could not be prepared"
  printf 'stale\n' > "$primary/dsh/.credentials.yaml"
  out=$(mirror_spawn "$primary/dsh" "$id")
  status=$?
  expect_code 0 "$status" "a mirrored dsh crew harness with no model must carry the primary's model: $out"
  assert_grep "harness=dsh" "$HOME_DIR/state/$id.meta" "the mirrored crew harness must stay dsh"
  assert_grep "model=deepseek/deepseek-v4-pro" "$HOME_DIR/state/$id.meta" "the worker must carry the DSH primary's bound model"
  assert_equals secret "$(cat "$HOME_DIR/state/$id.dsh/"*/dsh/.credentials.yaml)" \
    "the worker must stage credentials from the operator's DSH install, not the primary's runtime copy"
  out=$(mirror_spawn "$CASE_DIR/unbound/dsh" "$id-unbound" 2>&1)
  status=$?
  expect_code 1 "$status" "a mirrored dsh harness without a live session record must refuse: $out"
  assert_contains "$out" "has no configured model" "the refusal must name the missing model configuration"
  assert_absent "$HOME_DIR/state/$id-unbound.meta" "a refused mirror must publish no task"
  pass "fm-spawn: a dsh crew harness mirrored from a DSH primary carries its bound model and the operator's install, and refuses without a live record"
}

# Spawn a dsh secondmate of the current case into its own seeded home.
secondmate_spawn() {  # <id> [spawn-args...] -> spawn output
  local sm="$CASE_DIR/sm-$1" writer status out
  mkdir -p "$sm/bin" "$sm/data" "$sm/state" "$sm/config" "$sm/projects"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$sm/bin/fm-turnend-guard.sh"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$1" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  fm_git_init_commit "$sm"
  : > "$LAUNCH_LOG"
  python3 "$TMP_ROOT/dsh-session-writer.py" "$HOME_DIR/state" "$1" "$LAUNCH_LOG" &
  writer=$!
  out=$(DSH_HOME='' FM_DSH_SOURCE_HOME='' FM_DSH_OPERATOR_HOME="$CASE_DIR/spawner-operator" FM_BACKEND=tmux FM_DSH_START_POLL_INTERVAL=0.05 \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_CAPTURE_FILE="$CASE_DIR/screen" \
    fm_test_run_spawn "$HOME_DIR" "$sm" "$FAKEBIN_DIR" "$1" "$sm" dsh --secondmate --model "$DSH_MODEL" "${@:2}")
  status=$?
  kill "$writer" 2>/dev/null
  wait "$writer" 2>/dev/null
  printf '%s' "$out"
  return "$status"
}

test_secondmate_launch_carries_brief_and_operator_home() {
  local id=dsh-sm out status log
  make_dsh_case secondmate "$id" claude
  mkdir -p "$CASE_DIR/spawner-operator/.config"
  out=$(secondmate_spawn "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "a dsh secondmate must spawn: $out"
  assert_grep "harness=dsh" "$HOME_DIR/state/$id.meta" "the secondmate must launch on dsh"
  assert_equals "$CASE_DIR/spawner-operator/.config" "$(readlink "$HOME_DIR/state/$id.dsh/"*/home/.config)" \
    "the secondmate's private HOME must link the spawner's operator home"
  log="$CASE_DIR/sm-env.log"
  run_recorded_launch "$log" || fail "the recorded dsh secondmate launch failed: $(cat "$LAUNCH_LOG")"
  assert_equals "$CASE_DIR/spawner-operator" "$(sed -n 's/^FM_DSH_OPERATOR_HOME=//p' "$log")" \
    "nested spawns inside the secondmate must link the same operator home"
  assert_equals "$HOME_DIR/user-home/.dsh" "$(sed -n 's/^FM_DSH_SOURCE_HOME=//p' "$log")" \
    "nested spawns inside the secondmate must stage from the operator's DSH install"
  assert_equals -- "$(sed -n 3p "$log.args")" "the brief must reach dsh-tui as its positional opening prompt"
  [ -n "$(sed -n 4p "$log.args")" ] || fail "the secondmate brief must not be empty: $(cat "$log.args")"
  pass "fm-spawn: a dsh secondmate starts on its positional brief and carries the operator's DSH install and home to nested spawns"
}

# A plain relaunch of a dsh secondmate keeps its recorded model and effort even
# when the calling DSH primary is bound to another model, so it resumes the
# same generation's conversation instead of replacing it.
test_secondmate_plain_relaunch_resumes_its_recorded_dsh_profile() {
  local id=dsh-sm-resume sm primary binding generation session out status bin writer seq args
  make_dsh_case secondmate-resume "$id" claude
  mkdir -p "$CASE_DIR/spawner-operator" "$CASE_DIR/sentinel-source/profiles/dsh-tui/node_modules"
  printf '{}\n' > "$CASE_DIR/sentinel-source/profiles/dsh-tui/package.json"
  printf 'sentinel-inherited-source\n' > "$CASE_DIR/sentinel-source/.credentials.yaml"
  printf 'dsh\n' > "$HOME_DIR/config/secondmate-harness"
  out=$(FM_DSH_SOURCE_HOME="$CASE_DIR/sentinel-source" secondmate_spawn "$id" --effort high 2>&1)
  status=$?
  expect_code 0 "$status" "a dsh secondmate must spawn: $out"
  sm="$CASE_DIR/sm-$id"
  binding="$HOME_DIR/state/$id.dsh-session"
  generation=$(jq -r .root "$binding")
  assert_equals secret "$(cat "$generation/dsh/.credentials.yaml")" \
    "the spawn helper must stage from the fixture install, not an inherited FM_DSH_SOURCE_HOME"
  session=$(head -n 1 "$generation/dsh/sessions/workspace/session/session.v4.jsonl" | jq -r .id)
  primary=$(FM_DSH_OPERATOR_HOME="$CASE_DIR/spawner-operator" python3 "$ROOT/bin/fm-dsh.py" prepare-primary \
    "$CASE_DIR/primary-state" dsh-primary g1 "$HOME_DIR/user-home/.dsh" deepseek/deepseek-v4-pro max "$HOME_DIR" "$ROOT") \
    || fail "the DSH primary runtime fixture could not be prepared"
  bin="$CASE_DIR/relaunch-shell"
  mkdir -p "$bin"
  cat > "$bin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *pane_current_command*) printf 'zsh\\n'; exit 0 ;;
esac
exec "$FAKEBIN_DIR/tmux" "\$@"
SH
  chmod +x "$bin/tmux"
  # A plain relaunch, an explicit bound model in any DeepSeek spelling without
  # --effort, and the exact profile bin/fm-control.sh hands over each resume the
  # same conversation.
  printf '{"version":1,"roles":{"bound":{"dsh":{"model":"%s"}}},"retired":[]}\n' "$DSH_MODEL" > "$HOME_DIR/config/model-index.json"
  seq=2
  for args in '' "--model $DSH_MODEL" "--model DeepSeek/${DSH_MODEL#deepseek/}" "--model role:bound" "--harness dsh --model $DSH_MODEL --effort high"; do
    : > "$LAUNCH_LOG"
    python3 - "$generation/dsh/sessions/workspace/session/session.v4.jsonl" "$LAUNCH_LOG" "$seq" <<'PY' &
import json, os, sys, time
log, launch, seq = sys.argv[1], sys.argv[2], int(sys.argv[3])
deadline = time.time() + 120
while time.time() < deadline and not (os.path.exists(launch) and os.path.getsize(launch) > 0):
    time.sleep(0.02)
with open(log, "a") as stream:
    stream.write(json.dumps({"type": "turn/end", "seq": seq}) + "\n" + json.dumps({"type": "turn/start", "seq": seq + 1}) + "\n")
PY
    writer=$!
    # shellcheck disable=SC2086 # each case is a deliberate word list of flags
    out=$(DSH_HOME="$primary/dsh" FM_DSH_SOURCE_HOME='' FM_DSH_OPERATOR_HOME="$CASE_DIR/spawner-operator" FM_BACKEND=tmux \
      FM_DSH_START_POLL_INTERVAL=0.05 FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_CAPTURE_FILE="$CASE_DIR/screen" \
      FM_FAKE_DUPLICATE_WINDOW="$(sed -n 's/^window=[^:]*://p' "$HOME_DIR/state/$id.meta")" \
      fm_test_run_spawn "$HOME_DIR" "$sm" "$bin:$FAKEBIN_DIR" "$id" --relaunch $args 2>&1)
    status=$?
    kill "$writer" 2>/dev/null
    wait "$writer" 2>/dev/null
    seq=$((seq + 2))
    expect_code 0 "$status" "a dsh secondmate relaunch '$args' must resume it: $out"
    assert_grep "model=$DSH_MODEL" "$HOME_DIR/state/$id.meta" "relaunch '$args' must keep the recorded model, not the primary's"
    assert_grep "effort=high" "$HOME_DIR/state/$id.meta" "relaunch '$args' must keep the recorded effort"
    assert_equals "$generation" "$(jq -r .root "$binding")" "relaunch '$args' must resume the bound generation"
    assert_equals "$(basename "$generation")" "$(ls "$HOME_DIR/state/$id.dsh")" "relaunch '$args' must neither delete nor add a generation"
    assert_equals "$session" "$(jq -r '.[0].config.sessionId' "$generation/launch.yml")" \
      "relaunch '$args' must resume the recorded conversation"
  done
  cp "$generation/dsh/sessions/workspace/session/session.v4.jsonl" "$CASE_DIR/session.before"
  out=$(DSH_HOME="$primary/dsh" FM_DSH_SOURCE_HOME='' FM_DSH_OPERATOR_HOME="$CASE_DIR/spawner-operator" FM_BACKEND=tmux \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_CAPTURE_FILE="$CASE_DIR/screen" \
    FM_FAKE_DUPLICATE_WINDOW="$(sed -n 's/^window=[^:]*://p' "$HOME_DIR/state/$id.meta")" \
    fm_test_run_spawn "$HOME_DIR" "$sm" "$bin:$FAKEBIN_DIR" "$id" --relaunch --model role:absent 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a relaunch onto a missing role must refuse: $out"
  assert_contains "$out" "absent" "the refusal must name the missing role"
  assert_equals "$generation" "$(jq -r .root "$binding")" "a missing role must keep the bound generation"
  cmp -s "$CASE_DIR/session.before" "$generation/dsh/sessions/workspace/session/session.v4.jsonl" \
    || fail "a missing role must leave the bound conversation log untouched"
  rm -f "$HOME_DIR/config/model-index.json"
  pass "fm-spawn: a plain, same-model or same-model role dsh secondmate relaunch keeps its recorded model and effort and resumes the same generation"
}

test_launch_policy_admits_dsh() {
  local id=dsh-policy out status config
  make_dsh_case policy "$id"
  config="$HOME_DIR/config"
  printf 'omp-or-tc\n' > "$config/session-launch-policy"
  out=$(run_dsh_spawn "$id" --harness dsh --model "$DSH_MODEL" --scout 2>&1)
  status=$?
  expect_code 0 "$status" "the enabled policy must admit the dsh-tui DeepSeek adapter: $out"
  assert_grep "harness=dsh" "$HOME_DIR/state/$id.meta" "the policy must not put DeepSeek back on omp"
  assert_contains "$(cat "$LAUNCH_LOG")" "FM_DSH_HARNESS=dsh" "policy admission must launch dsh-tui"
  fm_session_launch_policy_check "$config" omp 0 || fail "the policy must keep admitting omp"
  ! fm_session_launch_policy_check "$config" dsh 1 2>/dev/null || fail "raw launches must stay refused"
  ! fm_session_launch_policy_check "$config" claude 0 2>/dev/null || fail "the unrelated Claude policy must not change"
  pass "fm-spawn: the restricted session policy admits canonical dsh-tui DeepSeek launches"
}

test_deepseek_cannot_launch_on_omp() {
  local id=dsh-not-omp out status route
  for route in explicit raw indexed; do
    make_dsh_case "not-omp-$route" "$id"
    case "$route" in
      explicit) out=$(run_dsh_spawn "$id" --harness omp --model "$DSH_MODEL" --scout 2>&1) ;;
      raw) out=$(run_dsh_spawn "$id" "omp --model $DSH_MODEL" --scout 2>&1) ;;
      indexed)
        printf '%s\n' '{"version":1,"roles":{"legacy":{"omp":{"model":"deepseek/deepseek-v4-flash"}}},"retired":[]}' > "$HOME_DIR/config/model-index.json"
        out=$(run_dsh_spawn "$id" --harness omp --model role:legacy --scout 2>&1)
        ;;
    esac
    status=$?
    expect_code 1 "$status" "$route DeepSeek-through-omp must refuse: $out"
    assert_contains "$out" "DeepSeek runs through dsh-tui, not omp" "refusal must name dsh-tui"
    [ ! -s "$LAUNCH_LOG" ] || fail "a contradictory route must launch nothing"
    assert_absent "$HOME_DIR/state/$id.meta" "a contradictory route must publish no task"
  done
  pass "fm-spawn: explicit, raw, and indexed DeepSeek-through-omp routes refuse before launch"
}

test_omp_default_cannot_hide_a_deepseek_route() {
  local model id out status config
  for model in deepseek/deepseek-v4-flash lab/native-model; do
    id="default-${model%%/*}"
    make_dsh_case "$id" "$id"
    config="$CASE_DIR/omp-config"
    mkdir -p "$config"
    printf 'modelRoles:\n  default: %s:high\n' "$model" > "$config/config.yml"
    cat > "$FAKEBIN_DIR/omp" <<'SH'
#!/bin/sh
case "$1" in
  --version) printf 'omp/18.1.20\n' ;;
  models) printf '{"models":[{"provider":"deepseek","id":"deepseek-v4-flash","selector":"deepseek/deepseek-v4-flash"},{"provider":"lab","id":"native-model","selector":"lab/native-model"}]}\n' ;;
  *) exit 0 ;;
esac
SH
    chmod +x "$FAKEBIN_DIR/omp"
    out=$(PI_CODING_AGENT_DIR="$config" OMP_PROFILE='' PI_PROFILE='' FM_BACKEND=tmux FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --harness omp --scout)
    status=$?
    if [ "${model%%/*}" = deepseek ]; then
      expect_code 1 "$status" "a catalog-listed DeepSeek default without --model must refuse: $out"
      assert_contains "$out" 'DeepSeek runs through dsh-tui, not omp' 'the inherited default must obey the same family route'
      assert_absent "$HOME_DIR/state/$id.meta" 'a contradictory inherited default must publish no task'
      [ ! -s "$LAUNCH_LOG" ] || fail 'a contradictory inherited default must launch nothing'
    else
      expect_code 0 "$status" "a non-DeepSeek default must retain its original route: $out"
      assert_grep 'harness=omp' "$HOME_DIR/state/$id.meta" 'a non-DeepSeek inherited default must remain omp'
    fi
  done
  pass 'fm-spawn: catalog-listed DeepSeek defaults refuse without --model; non-DeepSeek defaults retain omp'
}

test_unrecognized_dsh_screen_refuses_launch() {
  local id=dsh-unknown-screen out status
  make_dsh_case unknown-screen "$id"
  printf '%s\n' 'An incompatible frontend without a composer' > "$CASE_DIR/screen"
  out=$(FM_DSH_START_POLLS=10 run_dsh_spawn "$id" --model "$DSH_MODEL" --scout 2>&1)
  status=$?
  expect_code 1 "$status" "an unrecognized dsh frontend must refuse: $out"
  assert_contains "$out" 'could not parse the composer frame or its input content' "the refusal must name the unreadable screen shape"
  pass "fm-spawn: a successful version probe and durable turn cannot admit an unrecognized dsh screen"
}

test_exhausted_omp_replaces_deepseek_harness() {
  local id=dsh-replacement out status
  make_dsh_case replacement "$id"
  printf 'omp-or-tc\n' > "$HOME_DIR/config/session-launch-policy"
  printf '%s\n' '{"rules":[{"when":"work","use":{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"},"fallback":[{"harness":"dsh","model":"deepseek/deepseek-v4-flash","effort":"high"}]}]}' > "$HOME_DIR/config/crew-dispatch.json"
  cat > "$FAKEBIN_DIR/omp" <<'SH'
#!/bin/sh
case "$1" in
  usage) printf '{"reports":[{"provider":"openai-codex","fetchedAt":%s000,"metadata":{"meterStates":{"chat":{"allowed":false,"limitReached":true}}}}]}\n' "$(date +%s)" ;;
  --version) printf 'omp/18.1.20\n' ;;
  models) printf '{"models":[{"selector":"openai-codex/gpt-6.1-sol"}]}\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/omp"
  out=$(run_dsh_spawn "$id" --harness omp --model openai-codex/gpt-6.1-sol --effort high --dispatch-rule rule_1 --scout 2>&1)
  status=$?
  expect_code 0 "$status" "the declared DeepSeek stand-in must replace omp with dsh: $out"
  assert_grep "harness=dsh" "$HOME_DIR/state/$id.meta" "the replacement must record dsh"
  assert_grep "model=$DSH_MODEL" "$HOME_DIR/state/$id.meta" "the replacement must record DeepSeek"
  assert_contains "$(cat "$LAUNCH_LOG")" "FM_DSH_HARNESS=dsh" "the replacement must launch dsh-tui"
  assert_absent "$HOME_DIR/state/$id.omp-fallback.yml" "the dsh replacement must not receive an omp native fallback chain"
  pass "fm-spawn: exhausted omp replaces its declared DeepSeek stand-in with dsh-tui under the session policy"
}

# The opted-in live guard must fail, not pass, when a required lab input is
# missing. Stubbed tools record any call, so the refusal is proven to come
# before any herdr or dsh-tui action.
test_live_guard_refuses_missing_lab_inputs() {
  local dir="$TMP_ROOT/live-inputs" guard="$ROOT/tests/fm-dsh-live-e2e.test.sh" tool label out status
  local -a supplied
  mkdir -p "$dir/bin"
  for tool in herdr dsh-tui jq; do
    cat > "$dir/bin/$tool" <<SH
#!/bin/sh
printf '%s\\n' "$tool \$*" >> "$dir/calls"
exit 97
SH
    chmod +x "$dir/bin/$tool"
  done
  for label in both project copy; do
    case "$label" in
      both) supplied=() ;;
      project) supplied=(FM_DSH_LAB_COPY="$dir/copy") ;;
      copy) supplied=(FM_DSH_LAB_PROJECT="$dir/project") ;;
    esac
    out=$(env -u FM_LIVE -u FM_DSH_LAB_PROJECT -u FM_DSH_LAB_COPY PATH="$dir/bin:$PATH" \
      FM_DSH_LIVE=1 "${supplied[@]+"${supplied[@]}"}" bash "$guard" 2>&1)
    status=$?
    expect_code 1 "$status" "the live guard must fail when $label input is missing: $out"
    case "$label" in
      both|project) assert_contains "$out" 'FM_DSH_LAB_PROJECT is missing' "the refusal must name the missing project ($label)" ;;
      *) assert_not_contains "$out" 'FM_DSH_LAB_PROJECT is missing' "a supplied project must not be reported missing" ;;
    esac
    case "$label" in
      both|copy) assert_contains "$out" 'FM_DSH_LAB_COPY is missing' "the refusal must name the missing copy ($label)" ;;
      *) assert_not_contains "$out" 'FM_DSH_LAB_COPY is missing' "a supplied copy must not be reported missing" ;;
    esac
  done
  mkdir -p "$dir/no-model" "$dir/primary-bin"
  out=$(env -u FM_LIVE PATH="$dir/bin:$PATH" FM_DSH_LIVE=1 FM_DSH_LAB_PROJECT="$dir/project" FM_DSH_LAB_COPY="$dir/copy" \
    FM_DSH_OPERATOR_HOME="$dir/no-model" bash "$guard" 2>&1)
  status=$?
  expect_code 1 "$status" "the live guard must fail when no DeepSeek model preference resolves: $out"
  assert_contains "$out" 'choose one with /model in dsh-tui' "the refusal must name how to set the model preference"
  for tool in herdr jq dsh-tui dsh node; do
    cat > "$dir/primary-bin/$tool" <<SH
#!/bin/sh
case "\$*" in version|--version) printf 'fake\\n'; exit 0 ;; esac
printf '%s\\n' "$tool \$*" >> "$dir/primary-calls"
exit 97
SH
    chmod +x "$dir/primary-bin/$tool"
  done
  out=$(env -u FM_LIVE PATH="$dir/primary-bin:$PATH" FM_DSH_PRIMARY_LIVE=1 FM_DSH_OPERATOR_HOME="$dir/no-model" \
    bash "$ROOT/tests/fm-dsh-primary-live-e2e.test.sh" 2>&1)
  status=$?
  expect_code 1 "$status" "the live primary guard must fail when no DeepSeek model preference resolves: $out"
  assert_contains "$out" 'choose one with /model in dsh-tui' "the primary refusal must name how to set the model preference"
  assert_absent "$dir/primary-calls" "a missing-model refusal must precede every lab action: $(cat "$dir/primary-calls" 2>/dev/null)"
  out=$(env -u FM_LIVE -u FM_DSH_LAB_PROJECT -u FM_DSH_LAB_COPY PATH="$dir/bin:$PATH" \
    FM_DSH_LIVE=1 FM_DURATION_FILE="$dir/durations.jsonl" "$ROOT/bin/fm-test-run.sh" "$guard" 2>&1)
  status=$?
  expect_code 1 "$status" "fm-test-run must fail an opted-in guard with no lab inputs: $out"
  assert_contains "$out" 'exit=1 ' "fm-test-run must record the guard's nonzero exit"
  assert_contains "$out" 'FM_TEST_SUMMARY total=1 failed=1 skipped_gate=0' "fm-test-run must count the guard as failed, not passed or skipped"
  out=$(env -u FM_LIVE -u FM_DSH_LIVE -u FM_DSH_LAB_PROJECT -u FM_DSH_LAB_COPY PATH="$dir/bin:$PATH" bash "$guard" 2>&1)
  status=$?
  expect_code 0 "$status" "the guard without its opt-in must stay an ordinary skip: $out"
  assert_contains "$out" 'skip: live: opt-in; set FM_DSH_LIVE=1 to run' "the opt-out skip must be unchanged"
  assert_absent "$dir/calls" "a missing-input refusal must not reach herdr, dsh-tui or jq: $(cat "$dir/calls" 2>/dev/null)"
  pass "live guards: an opted-in run with a missing lab input or no DeepSeek model preference fails before any lab action; the opt-out still skips"
}

test_detection_anchored_names_argv_and_marker_precedence
test_lock_identity_and_tmux_liveness_name_dsh
test_tmux_agent_state_names_dsh
test_busy_classify_follows_the_launch_session_log
test_deepseek_model_without_a_harness_routes_to_dsh
test_deepseek_spelling_without_a_harness_routes_to_dsh
test_explicit_harness_is_not_rerouted
test_launch_environment
test_mirrored_dsh_primary_carries_its_bound_model
test_secondmate_launch_carries_brief_and_operator_home
test_secondmate_plain_relaunch_resumes_its_recorded_dsh_profile
test_launch_policy_admits_dsh
test_deepseek_cannot_launch_on_omp
test_omp_default_cannot_hide_a_deepseek_route
test_unrecognized_dsh_screen_refuses_launch
test_exhausted_omp_replaces_deepseek_harness
test_live_guard_refuses_missing_lab_inputs
