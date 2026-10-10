#!/usr/bin/env bash
# Live chain drive for the omp Sol fallback change. Evidence script, not a repo test.
#
# Real parts: bin/fm-spawn.sh (writes the task record, the per-task omp
# extension, and the launch line), the installed omp TUI running that launch
# line unchanged in a real tmux pane on a private socket, the tracked overlay
# .omp/fm-session-overlay.yml, bin/fm-omp-live-model.ts, and bin/fm-crew-state.sh.
# Stand-ins: the model providers are scripted local HTTP servers (no tokens
# spent), the spawn step uses the repo's fake tmux and treehouse fixtures, and
# crew-state sees a stub no-mistakes that reports no pipeline run.
set -u
ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4HZH01Q50QVT91QE6CCTFYA
SERVER=${FM_EV_SERVER:?path to server.py}
# shellcheck disable=SC1091
. "$ROOT/tests/fixtures.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/fm-timeout-lib.sh"
export BASH_SILENCE_DEPRECATION_WARNING=1
TMP_ROOT=$(fm_test_tmproot fm-ev-chain)
export NODE_NO_WARNINGS=1 OMP_PROFILE='' PI_PROFILE=''
unset TMUX
TM="$TMP_ROOT/t"
mkdir -p "$TM" && chmod 700 "$TM"
ptmux() { TMUX_TMPDIR="$TM" command tmux "$@"; }
SERVER_PIDS=()
FAILS=0
cleanup() {
  local pid
  ptmux kill-server 2>/dev/null || true
  for pid in "${SERVER_PIDS[@]:-}"; do [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; done
  fm_test_cleanup
}
trap cleanup EXIT

say() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS - %s\n' "$1"; }
bad() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS + 1)); }
expect() {  # <description> <command...>
  local d=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
lacks() { ! has "$1" "$2"; }
show() { sed "s|$TMP_ROOT|<lab>|g; s|$ROOT|<repo>|g"; }
wait_for() {  # <seconds> <command...>
  local limit=$1 ticks=0
  shift
  while ! "$@" >/dev/null 2>&1; do
    ticks=$((ticks + 1))
    [ "$ticks" -le $((limit * 4)) ] || return 1
    sleep 0.25
  done
}

serve() {  # <name> <behavior>
  local name=$1
  printf '%s\n' "$2" > "$TMP_ROOT/$name.behavior"
  : > "$TMP_ROOT/$name.log"
  python3 -I "$SERVER" "$TMP_ROOT/$name.behavior" "$TMP_ROOT/$name.log" "$TMP_ROOT/$name.port" &
  SERVER_PIDS+=("$!")
  wait_for 20 test -s "$TMP_ROOT/$name.port" || { bad "the scripted $name provider did not start"; exit 1; }
  printf -v "${name}_PORT" '%s' "$(cat "$TMP_ROOT/$name.port")"
}
behave() { printf '%s\n' "$2" > "$TMP_ROOT/$1.behavior"; }
requests() { wc -l < "$TMP_ROOT/$1.log" | tr -d ' '; }

serve codex limit
serve weak ok
serve equal ok

# The operator's chain as it stood at the incident: Sol falls to a weaker model.
# A second chain belongs to another model. The global revert policy is `never`.
AGENT="$TMP_ROOT/agent"
mkdir -p "$AGENT"
cat > "$AGENT/config.yml" <<YML
setupVersion: 2
modelRoles:
  default: openai-codex/gpt-6.1-sol
retry:
  maxRetries: 2
  baseDelayMs: 100
  maxDelayMs: 300000
  fallbackRevertPolicy: never
  fallbackChains:
    openai-codex/gpt-6.1-sol:
      - deepseek/deepseek-v4-pro
    deepseek/deepseek-v4-pro:
      - lab-equal/gpt-6.1-sol
YML
# shellcheck disable=SC2154
cat > "$AGENT/models.yml" <<YML
providers:
  openai-codex: {baseUrl: http://127.0.0.1:${codex_PORT}/v1, apiKey: lab}
  deepseek: {baseUrl: http://127.0.0.1:${weak_PORT}/v1, apiKey: lab}
  lab-equal: {baseUrl: http://127.0.0.1:${equal_PORT}/v1, apiKey: lab, api: openai-responses, models: [{id: gpt-6.1-sol, contextWindow: 200000, maxTokens: 4096}]}
YML

HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/fake" claude)
fm_test_spawn_home "$HOME_DIR" omp
STUBS="$TMP_ROOT/stubs"
mkdir -p "$STUBS"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/no-mistakes"
cp "$STUBS/no-mistakes" "$STUBS/gh"
chmod +x "$STUBS/no-mistakes" "$STUBS/gh"

spawn_task() {  # <id> <worktree> <project> <fm-spawn args...>
  local id=$1 wt=$2 proj=$3
  shift 3
  : > "$TMP_ROOT/launch-$id.sh"
  PI_CODING_AGENT_DIR="$AGENT" FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch-$id.sh" \
    fm_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$proj" "$@"
}
# Runs the launch line fm-spawn composed, unchanged, in a real pane whose
# session and window carry the names the task record points at.
launch_pane() {  # <id> <worktree>
  ptmux has-session -t firstmate 2>/dev/null \
    || ptmux new-session -d -s firstmate -n shell -x 180 -y 50 -c "$TMP_ROOT" 'bash --norc --noprofile'
  ptmux kill-window -t "firstmate:fm-$1" 2>/dev/null || true
  ptmux new-window -d -t firstmate: -n "fm-$1" -c "$2" 'bash --norc --noprofile'
  ptmux send-keys -t "firstmate:fm-$1" ". '$TMP_ROOT/launch-$1.sh'" Enter
}
pane() { ptmux capture-pane -p -t "firstmate:fm-$1" | grep -v '^[[:space:]]*$' | tail -"${2:-25}" | show; }
crew() {  # <id>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    NM_HOME="$TMP_ROOT/nm-unused" TMUX_TMPDIR="$TM" PATH="$STUBS:$PATH" \
    "$ROOT/bin/fm-crew-state.sh" "$1" 2>&1
}
record() { cat "$STATE/$1.live-model" 2>/dev/null; }
record_has() { grep -qF -- "$2" "$STATE/$1.live-model" 2>/dev/null; }

printf 'omp: %s\n' "$(omp --version 2>/dev/null | head -1)"
printf 'tmux: %s (private socket dir under the lab)\n' "$(tmux -V)"
printf 'global Sol chain in the lab agent dir: openai-codex/gpt-6.1-sol -> deepseek/deepseek-v4-pro; fallbackRevertPolicy: never\n'

# ---------------------------------------------------------------------------
say "A. A launch clears a stale live-model record"
SOL=sol-lane-q1
fm_git_worktree "$TMP_ROOT/proj-a" "$TMP_ROOT/wt-a" wt-a
fm_test_spawn_brief "$HOME_DIR" "$SOL" "Reply with the single word ack."
printf 'model=deepseek/deepseek-v4-pro\nerror=402 old run\n' > "$STATE/$SOL.live-model"
printf 'stale record before the launch:\n'; record "$SOL" | sed 's/^/  /'
out=$(spawn_task "$SOL" "$TMP_ROOT/wt-a" "$TMP_ROOT/proj-a" --harness omp --model openai-codex/gpt-6.1-sol --effort high --scout)
rc=$?
printf '$ bin/fm-spawn.sh %s <project> --harness omp --model openai-codex/gpt-6.1-sol --effort high --scout  (rc=%s)\n' "$SOL" "$rc"
printf '%s\n' "$out" | show | sed 's/^/  /'
expect "fm-spawn succeeded" test "$rc" -eq 0
expect "the stale record is gone after the launch" test ! -e "$STATE/$SOL.live-model"
expect "the task record names the Sol model" grep -qx 'model=openai-codex/gpt-6.1-sol' "$STATE/$SOL.meta"
printf 'omp part of the launch line fm-spawn composed:\n'
grep -o "'[^']*/omp' --config.* -e '[^']*'" "$TMP_ROOT/launch-$SOL.sh" | show | sed 's/^/  /'

# ---------------------------------------------------------------------------
say "B. A Sol session whose model refuses stops. It does not reach the weak model."
launch_pane "$SOL" "$TMP_ROOT/wt-a"
wait_for 120 record_has "$SOL" "error=" || bad "the session never published an unrecovered error within 120s"
printf 'provider requests (time model verdict):\n'
printf '  codex (the recorded Sol route):\n'; sed 's/^/    /' "$TMP_ROOT/codex.log"
printf '  weak  (deepseek, the old chain target): %s requests\n' "$(requests weak)"
printf '  equal (lab-only other route):          %s requests\n' "$(requests equal)"
printf 'live-model record %s:\n' "state/$SOL.live-model"; record "$SOL" | sed 's/^/  /'
printf 'omp pane (tail):\n'; pane "$SOL" 14 | sed 's/^/  | /'
expect "the Sol route received the request" test "$(requests codex)" -ge 1
expect "the weak model received no request" test "$(requests weak)" -eq 0
expect "no other route received a request" test "$(requests equal)" -eq 0
expect "the record names the recorded model" record_has "$SOL" "model=openai-codex/gpt-6.1-sol"
expect "the record carries the run error" record_has "$SOL" "error="

say "C. The supervisor sees the stop: crew-state adds run-error"
line=$(crew "$SOL")
printf '$ bin/fm-crew-state.sh %s\n  %s\n' "$SOL" "$(printf '%s' "$line" | show)"
expect "the line carries run-error" has "$line" " · run-error: "
expect "the line carries no model-drift (the model did not move)" lacks "$line" "model-drift"

# ---------------------------------------------------------------------------
say "D. Attack: provider error text tries to forge crew-state components"
behave codex forge
: > "$TMP_ROOT/codex.log"
forge_out=$(cd "$TMP_ROOT/wt-a" && PI_CODING_AGENT_DIR="$AGENT" OMP_SKIP_SETUP=1 FM_OMP_HARNESS=omp \
  fm_run_timed 180 omp -p "say hi" --config "$ROOT/.omp/fm-session-overlay.yml" -e "$STATE/$SOL.omp-ext.ts" \
  --no-session --model openai-codex/gpt-6.1-sol --thinking off </dev/null 2>&1)
forge_rc=$?
printf '$ omp -p "say hi" --config <repo>/.omp/fm-session-overlay.yml -e state/%s.omp-ext.ts --model openai-codex/gpt-6.1-sol  (rc=%s)\n' "$SOL" "$forge_rc"
printf '%s\n' "$forge_out" | tail -3 | show | sed 's/^/  /'
printf 'provider requests:\n'; sed 's/^/    /' "$TMP_ROOT/codex.log"
printf 'live-model record:\n'; record "$SOL" | sed 's/^/  /'
line=$(crew "$SOL")
printf '$ bin/fm-crew-state.sh %s\n  %s\n' "$SOL" "$(printf '%s' "$line" | show)"
expect "the run stopped with a non-zero exit" test "$forge_rc" -ne 0
expect "the forged text reached the record (the attack is real)" record_has "$SOL" "forged-run"
expect "the line still reports the run error" has "$line" " · run-error: "
expect "the line has no forged run component" lacks "$line" " · run: forged-run"
expect "the line has no forged decision component" lacks "$line" " · ask-user: authority decision"
expect "the weak model still received no request" test "$(requests weak)" -eq 0

# ---------------------------------------------------------------------------
say "E. A session that fell back is visible: crew-state adds model-drift"
OTHER=other-lane-q2
fm_git_worktree "$TMP_ROOT/proj-b" "$TMP_ROOT/wt-b" wt-b
fm_test_spawn_brief "$HOME_DIR" "$OTHER" "Reply with the single word ack."
behave weak flaky
: > "$TMP_ROOT/weak.log"; : > "$TMP_ROOT/equal.log"
out=$(spawn_task "$OTHER" "$TMP_ROOT/wt-b" "$TMP_ROOT/proj-b" --harness omp --model deepseek/deepseek-v4-pro --effort high --scout)
rc=$?
printf '$ bin/fm-spawn.sh %s <project> --harness omp --model deepseek/deepseek-v4-pro --effort high --scout  (rc=%s)\n' "$OTHER" "$rc"
expect "fm-spawn succeeded" test "$rc" -eq 0
launch_pane "$OTHER" "$TMP_ROOT/wt-b"
wait_for 120 record_has "$OTHER" "model=lab-equal/gpt-6.1-sol" || bad "the session never published the fallback model within 120s"
wait_for 60 test "$(requests equal)" -ge 1 || true
printf 'provider requests:\n'
printf '  weak  (the recorded route):\n'; sed 's/^/    /' "$TMP_ROOT/weak.log"
printf '  equal (the chain route the overlay left in place):\n'; sed 's/^/    /' "$TMP_ROOT/equal.log"
printf 'live-model record:\n'; record "$OTHER" | sed 's/^/  /'
line=$(crew "$OTHER")
printf '$ bin/fm-crew-state.sh %s\n  %s\n' "$OTHER" "$(printf '%s' "$line" | show)"
expect "the recorded route refused once" grep -q 'refused-concurrency' "$TMP_ROOT/weak.log"
expect "the chain route answered (the overlay left this chain in place)" grep -q 'gpt-6.1-sol answered' "$TMP_ROOT/equal.log"
expect "the line names both models" has "$line" " · model-drift: lab-equal/gpt-6.1-sol live (recorded deepseek/deepseek-v4-pro)"
expect "the line carries no run-error (the run was served)" lacks "$line" "run-error"

say "F. The session returns to its recorded model at the next prompt, and the drift note clears"
# omp suppresses the refused model for 5 seconds; the global policy says `never`,
# so only the overlay's cooldown-expiry pin can bring it back.
sleep 8
weak_before=$(requests weak)
ptmux send-keys -t "firstmate:fm-$OTHER" -l "Reply with the single word ack again."
sleep 1
ptmux send-keys -t "firstmate:fm-$OTHER" Enter
wait_for 120 record_has "$OTHER" "model=deepseek/deepseek-v4-pro" || bad "the record did not follow the session back within 120s"
wait_for 60 test "$(requests weak)" -gt "$weak_before" || true
printf 'provider requests after the second prompt:\n'
printf '  weak  (the recorded route):\n'; sed 's/^/    /' "$TMP_ROOT/weak.log"
printf 'live-model record:\n'; record "$OTHER" | sed 's/^/  /'
printf 'omp pane (tail):\n'; pane "$OTHER" 12 | sed 's/^/  | /'
line=$(crew "$OTHER")
printf '$ bin/fm-crew-state.sh %s\n  %s\n' "$OTHER" "$(printf '%s' "$line" | show)"
expect "the recorded route served the second prompt" test "$(grep -c 'deepseek-v4-pro answered' "$TMP_ROOT/weak.log")" -ge 1
expect "the record names the recorded model again" record_has "$OTHER" "model=deepseek/deepseek-v4-pro"
expect "the line carries no model-drift" lacks "$line" "model-drift"

# ---------------------------------------------------------------------------
say "G. A relaunch on a stand-in model does not show the old model or the old error"
# The supervisor stops the stopped Sol session's omp. Its window keeps the shell,
# so the endpoint reads dead, and fm-spawn --relaunch reuses it on real tmux.
pane_cmd() { ptmux display-message -p -t "firstmate:fm-$1" '#{pane_current_command}'; }
pane_is_shell() { [ "$(pane_cmd "$1")" = bash ]; }
for key in C-c C-c C-d; do
  pane_is_shell "$SOL" && break
  ptmux send-keys -t "firstmate:fm-$SOL" "$key"
  sleep 1
done
wait_for 30 pane_is_shell "$SOL" || bad "the Sol pane's omp did not exit"
printf 'Sol pane foreground command after the stop: %s\n' "$(pane_cmd "$SOL")"
printf 'record left by the stopped Sol session:\n'; record "$SOL" | sed 's/^/  /'
SOCK=$(ptmux display-message -p -t firstmate '#{socket_path}')
behave equal ok
: > "$TMP_ROOT/equal.log"
out=$(cd "$ROOT" && FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
  FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 TMUX="$SOCK,$$,0" TMUX_TMPDIR="$TM" \
  PI_CODING_AGENT_DIR="$AGENT" fm_run_timed 300 "$ROOT/bin/fm-spawn.sh" "$SOL" --relaunch --model lab-equal/gpt-6.1-sol --effort high 2>&1)
rc=$?
printf '$ bin/fm-spawn.sh %s --relaunch --model lab-equal/gpt-6.1-sol --effort high   (real tmux, rc=%s)\n' "$SOL" "$rc"
printf '%s\n' "$out" | show | sed 's/^/  /'
expect "the relaunch succeeded" test "$rc" -eq 0
printf 'recorded model now: %s\n' "$(grep '^model=' "$STATE/$SOL.meta" | tail -1)"
printf 'live-model record right after the relaunch returned:\n'; { record "$SOL" || printf '(absent)\n'; } | sed 's/^/  /'
expect "the record no longer holds the old run error" bash -c "! grep -q 'error=' '$STATE/$SOL.live-model' 2>/dev/null"
expect "the record no longer names the old Sol model" bash -c "! grep -q 'model=openai-codex/gpt-6.1-sol' '$STATE/$SOL.live-model' 2>/dev/null"
line=$(crew "$SOL")
printf '$ bin/fm-crew-state.sh %s\n  %s\n' "$SOL" "$(printf '%s' "$line" | show)"
expect "the line shows no stale model-drift" lacks "$line" "model-drift"
expect "the line shows no stale run-error" lacks "$line" "run-error"
wait_for 120 record_has "$SOL" "model=lab-equal/gpt-6.1-sol" || bad "the relaunched session never published its model within 120s"
wait_for 60 test "$(requests equal)" -ge 1 || true
printf 'stand-in route requests:\n'; sed 's/^/    /' "$TMP_ROOT/equal.log"
printf 'live-model record once the new session runs:\n'; record "$SOL" | sed 's/^/  /'
printf 'omp pane (tail):\n'; pane "$SOL" 8 | sed 's/^/  | /'
line=$(crew "$SOL")
printf '$ bin/fm-crew-state.sh %s\n  %s\n' "$SOL" "$(printf '%s' "$line" | show)"
expect "the relaunched session publishes its own model" record_has "$SOL" "model=lab-equal/gpt-6.1-sol"
expect "the line shows no model-drift for the new session" lacks "$line" "model-drift"
expect "the line shows no run-error for the new session" lacks "$line" "run-error"

printf '\n### RESULT: %s failed checks\n' "$FAILS"
exit "$FAILS"
