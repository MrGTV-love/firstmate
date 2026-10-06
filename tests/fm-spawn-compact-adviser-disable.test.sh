#!/usr/bin/env bash
# tests/fm-spawn-compact-adviser-disable.test.sh - the default-off and opted-in
# automatic adviser policies must reach the actual launched process.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane actually received, under a synthetic pane environment, with
# the harness binary replaced by a probe that prints the environment it was
# started with. What the probe prints is what a real agent would have received.
#
# The remote second-mate route never reaches this path; its coverage lives in
# tests/fm-spawn-compact-adviser-disable-remote.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-compact-adviser)

# A synthetic pane value the launch must override rather than inherit: the
# switch is a floor, so a pane that already carries the wrong value still has to
# start its agent with 1.
CONTRARY=0

# make_case <name> <harness> <id>...
# Echoes "<case-dir>|<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog panelog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  panelog="$case_dir/pane.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$panelog"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# Replace the harness binary with a probe that reports the single environment
# fact under test, so executing the emitted launch answers "what would the agent
# have seen" rather than "what does the command text look like".
install_env_probe() {  # <fakebin> <harness>
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf '%s\n' "${COMPACT_ADVISER_DISABLE-unset}"
SH
  chmod +x "$1/$2"
}

install_launch_state_probe() {
  cat > "$1/$2" <<'SH'
#!/bin/sh
printf '%s|%s|%s|%s|%s\n' "${FM_TASK_ID-unset}" "${COMPACT_ADVISER_DISABLE-unset}" \
  "${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS-unset}" "${FM_COMPACT_ADVISER_HOOKS-unset}" \
  "${FM_COMPACT_ADVISER_DISABLE-unset}"
SH
  chmod +x "$1/$2"
}

# Run the emitted launch command in a synthetic pane shell. The pane carries the
# CONTRARY value, so a launch that merely forwarded the ambient environment
# would be caught here rather than reported as a pass.
#   emitted_launch_env <fakebin> <launch-log> <pane-log>
emitted_launch_env() {
  local fakebin=$1 launchlog=$2 panelog=$3 launch preamble
  launch=$(cat "$launchlog")
  # The pane exports run before the launch command in the real pane shell, so
  # replay them here in the same order: the filtered launch environment retains
  # what the pane holds, and dropping them would test a pane that never existed.
  preamble=$(grep '^export ' "$panelog")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
    TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" \
    /bin/sh -c "$preamble
$launch"
}


test_ship_allowlist_absent() {
  local rec out status seen
  rec=$(make_case ship-open codex ship-open-a1)
  read_case "$rec"
  out=$(run_case_spawn ship-open-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn without an allowlist should succeed: $out"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "ship, allowlist absent: the emitted launch failed to run"
  assert_equals 1 "$seen" \
    "a ship worker launched with the ambient environment must start with the compact adviser disabled"
  pass "ship launch with no allowlist starts its agent with the compact-adviser switch on"
}

test_ship_allowlist_enabled() {
  local rec out status seen
  rec=$(make_case ship-filtered codex ship-filtered-a1)
  read_case "$rec"
  # An empty file is the strictest opt-in: the launch keeps Firstmate's own
  # operational floor and nothing else, so it is where a floor either holds or
  # is lost.
  : > "$HOME_DIR/config/launch-env-allowlist"
  out=$(run_case_spawn ship-filtered-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "ship spawn under an allowlist should succeed: $out"
  install_env_probe "$FAKEBIN_DIR" codex
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
    || fail "ship, allowlist enabled: the emitted launch failed to run"
  assert_equals 1 "$seen" \
    "a ship worker launched under the cleared allowlisted environment must still start with the compact adviser disabled"
  pass "ship launch under an enabled allowlist keeps the compact-adviser switch through the cleared environment"
}

# The floor must not depend on the pane export having landed: a pane whose
# export was lost still has to launch its agent with the switch on. Replaying
# the launch alone, with a contrary ambient value, is that case.
test_launch_command_carries_the_switch_without_the_pane_export() {
  local setting rec out status seen launch
  for setting in absent enabled; do
    rec=$(make_case "ship-nopane-$setting" codex "ship-nopane-$setting-a1")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_case_spawn "ship-nopane-$setting-a1" "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 0 "$status" "allowlist=$setting spawn should succeed: $out"
    install_env_probe "$FAKEBIN_DIR" codex
    launch=$(cat "$LAUNCH_LOG")
    seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
      TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" \
      /bin/sh -c "$launch") \
      || fail "allowlist=$setting: the emitted launch failed to run without the pane exports"
    assert_equals 1 "$seen" \
      "allowlist=$setting: the launch command alone must set the compact-adviser switch, overriding a contrary pane value"
  done
  pass "the launch command sets the switch on its own, whichever allowlist posture is in force"
}

test_secondmate_launch() {
  local setting rec sm out status seen
  for setting in absent enabled; do
    rec=$(make_case "secondmate-$setting" codex "sm-$setting")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    sm="$CASE_DIR/secondmate-home"
    mkdir -p "$sm/bin" "$sm/data"
    printf '# Firstmate\n' > "$sm/AGENTS.md"
    printf '%s\n' "sm-$setting" > "$sm/.fm-secondmate-home"
    printf 'charter for sm-%s\n' "$setting" > "$sm/data/charter.md"
    printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
    git -C "$sm" init -q -b main
    out=$(run_case_spawn "sm-$setting" "$sm" --secondmate)
    status=$?
    expect_code 0 "$status" "secondmate spawn with allowlist=$setting should succeed: $out"
    install_env_probe "$FAKEBIN_DIR" codex
    seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") \
      || fail "secondmate, allowlist $setting: the emitted launch failed to run"
    assert_equals 1 "$seen" \
      "a secondmate launched with allowlist=$setting must start with the compact adviser disabled"
  done
  pass "a secondmate launch carries the compact-adviser switch in both allowlist postures"
}

# --- relaunch ---------------------------------------------------------------
#
# Drive the replacement-launch boundary with an agent-free pane. Capture the
# staged command when the pane sources it, independently of the harness's
# initial-prompt carrier, then execute it to observe the replacement environment.
make_relaunch_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          printf '%s\n' "$payload" > "$D/launch"
          cat "$D/harness" > "$D/command"
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

test_relaunch_rebuilds_the_switch() {
  local setting dir home proj wt id out status seen launch preamble harness expected
  local driver=()
  for harness in codex claude omp; do
  for setting in absent enabled; do
    id="relaunch-$harness-$setting-a1"
    dir="$TMP_ROOT/relaunch-$harness-$setting"
    home="$dir/home"
    proj="$dir/proj"
    wt="$dir/wt"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$dir/fake"
    touch "$home/state/.last-watcher-beat"
    [ "$setting" = absent ] || : > "$home/config/launch-env-allowlist"
    expected=1
    printf '{"claude":"auto","omp":"auto"}\n' > "$home/config/compact-adviser"
    [ "$harness" = codex ] || expected=0
    make_relaunch_stub "$dir"
    install_env_probe "$dir/fakebin" "$harness"
    fm_git_worktree "$proj" "$wt" "wt-relaunch-$harness-$setting"
    fm_test_spawn_brief "$home" "$id"
    : > "$dir/fake/launch"
    : > "$dir/fake/keys"
    # --relaunch accepts the task id only and requires an agent-free endpoint.
    printf 'zsh' > "$dir/fake/command"
    printf '%s' "$harness" > "$dir/fake/harness"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$wt" > "$dir/fake/cwd"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$wt"
      echo "project=$proj"
      echo "harness=$harness"
      echo "kind=ship"
      echo "mode=no-mistakes"
      echo "yolo=off"
      echo "tasktmp=$dir/tasktmp"
      echo "model=default"
      echo "effort=default"
    } > "$home/state/$id.meta"

    mkdir -p "$dir/user-home"
    # Process-liveness classification belongs to fm-control's own tests.
    # Drive the actual replacement-launch boundary for every harness.
    driver=("$ROOT/bin/fm-spawn.sh" "$id" --relaunch)
    out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_FAKE_DIR="$dir/fake" \
      HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 COMPACT_ADVISER_DISABLE=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
      "${driver[@]}" 2>&1)
    status=$?
    expect_code 0 "$status" "relaunch with allowlist=$setting should succeed: $out"

    launch=$(cat "$dir/fake/launch")
    [ -n "$launch" ] || fail "$harness relaunch with allowlist=$setting sent no replacement launch command"
    install_env_probe "$dir/fakebin" "$harness"
    preamble=$(grep '^export ' "$dir/fake/keys")
    seen=$(env -i HOME="$dir/user-home" PATH="$dir/fakebin:$PATH" TERM=xterm \
      TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" \
      /bin/sh -c "$preamble
$launch") \
      || fail "relaunch with allowlist=$setting: the replacement launch failed to run"
    assert_equals "$expected" "$seen" \
      "a relaunched $harness agent must preserve its adviser policy with allowlist=$setting"
  done
  done
  pass "relaunch rebuilds default-off and automatic adviser policies in both allowlist postures"
}

# A command-prefix assignment only covers the first simple command. A raw
# compound launch such as `cd <dir> && <probe>` must still start the probe with
# the switch on, so this drives that escape hatch and executes the pane's
# launch under a contrary ambient value.
test_raw_compound_launch_command_carries_the_switch() {
  local rec out status seen launch probe_dir
  rec=$(make_case raw-compound claude raw-compound-a1)
  read_case "$rec"
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$HOME_DIR/config/crew-dispatch.json"

  probe_dir="$CASE_DIR/agent-cwd"
  mkdir -p "$probe_dir"
  cat > "$probe_dir/probe" <<'SH'
#!/bin/sh
printf '%s\n' "${COMPACT_ADVISER_DISABLE-unset}"
SH
  chmod +x "$probe_dir/probe"

  out=$(run_case_spawn raw-compound-a1 "$PROJ_DIR" --mode no-mistakes --yolo off \
    "cd $probe_dir && ./probe")
  status=$?
  expect_code 0 "$status" "raw compound launch spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  [ -n "$launch" ] || fail "raw compound launch spawn sent no launch command"
  seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" \
    /bin/sh -c "$launch") \
    || fail "raw compound launch: the emitted launch failed to run"
  assert_equals 1 "$seen" \
    "a raw compound launch must start its agent with the compact adviser disabled, even after cd"
  pass "a compound raw launch-command still starts its agent with the compact-adviser switch on"
}

# The spawning process carries the COMPACT_ADVISER_DISABLE=1 that a default-off
# secondmate's own launch exported, which must not defeat its children's policy.
test_auto_launch_policy() {
  local harness setting kind rec id out status seen expected launch sm
  for harness in claude omp; do
    for setting in absent enabled; do
      for kind in ship secondmate; do
        id="auto-$harness-$setting-$kind"
        rec=$(make_case "$id" "$harness" "$id")
        read_case "$rec"
        install_env_probe "$FAKEBIN_DIR" "$harness"
        printf '{"%s":"auto"}\n' "$harness" > "$HOME_DIR/config/compact-adviser"
        [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
        if [ "$kind" = secondmate ]; then
          sm="$CASE_DIR/secondmate-home"
          mkdir -p "$sm/bin" "$sm/data"
          printf '# Firstmate\n' > "$sm/AGENTS.md"
          printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
          printf 'charter\n' > "$sm/data/charter.md"
          printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
          git -C "$sm" init -q -b main
          out=$(COMPACT_ADVISER_DISABLE=1 run_case_spawn "$id" "$sm" --secondmate "$harness")
        else
          out=$(COMPACT_ADVISER_DISABLE=1 run_case_spawn "$id" "$PROJ_DIR" "$harness" --mode no-mistakes --yolo off)
        fi
        status=$?
        expect_code 0 "$status" "$id: automatic policy spawn should succeed: $out"
        cat > "$FAKEBIN_DIR/$harness" <<'SH'
#!/bin/sh
printf '%s|%s|%s\n' "${COMPACT_ADVISER_DISABLE-unset}" "${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS-unset}" \
  "${FM_COMPACT_ADVISER_HOOKS-unset}"
SH
        chmod +x "$FAKEBIN_DIR/$harness"
        expected='0|unset|unset'
        [ "$harness" != claude ] || expected='0|1|1'
        launch=$(cat "$LAUNCH_LOG")
        seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
          COMPACT_ADVISER_DISABLE=1 /bin/sh -c "$launch") || fail "$id: launch replay failed"
        assert_equals "$expected" "$seen" "$id: launch policy did not override a contrary pane value"
        seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") || fail "$id: pane replay failed"
        assert_equals "$expected" "$seen" "$id: automatic mode was lost through the pane"
        # A shell that already opted into function hooks keeps that opt-in whole,
        # except where the cleared environment drops the unlisted flag.
        [ "$setting" != absent ] || expected='0|1|unset'
        seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
          CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 /bin/sh -c "$launch") || fail "$id: opted-in replay failed"
        assert_equals "$expected" "$seen" "$id: a pre-existing function-hooks opt-in was not preserved"
        if [ "$kind" = secondmate ]; then
          cmp -s "$HOME_DIR/config/compact-adviser" "$sm/config/compact-adviser" \
            || fail "$id: secondmate workers did not inherit adviser policy"
        fi
      done
    done
  done
  pass "automatic policy reaches Claude and omp ships and secondmates without implicitly enabling Calm"
}

# The same pane shell sources an automatic launch, then an off and an
# emergency-off replacement. Only the automatic one may run with the flag
# Firstmate marked as adviser-only; a captain's unmarked opt-in stays whole. The
# backend never sees the operator's per-invocation override or that marker.
test_reused_endpoint_drops_adviser_hooks() {
  local setting rec id seen expected script kind pre launch out
  for setting in absent enabled; do
    rec=$(make_case "reuse-$setting" claude "reuse-$setting-auto" "reuse-$setting-off" "reuse-$setting-kill")
    read_case "$rec"
    [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-backend"
    cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${FM_COMPACT_ADVISER_DISABLE-unset}" "${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS-unset}" \
  "${FM_COMPACT_ADVISER_HOOKS-unset}" >> "$(dirname "$0")/backend-env"
exec "$(dirname "$0")/tmux-backend" "$@"
SH
    chmod +x "$FAKEBIN_DIR/tmux"
    script=
    for kind in auto off kill; do
      id="reuse-$setting-$kind"
      if [ "$kind" = off ]; then
        printf '{"claude":"off"}\n' > "$HOME_DIR/config/compact-adviser"
      else
        printf '{"claude":"auto"}\n' > "$HOME_DIR/config/compact-adviser"
      fi
      if [ "$kind" = kill ]; then
        : > "$FAKEBIN_DIR/backend-env"
        out=$(FM_COMPACT_ADVISER_DISABLE=1 CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 FM_COMPACT_ADVISER_HOOKS=1 \
          run_case_spawn "$id" "$PROJ_DIR" claude --mode no-mistakes --yolo off) \
          || fail "$id: spawn failed: $out"
        [ -s "$FAKEBIN_DIR/backend-env" ] || fail "$id: the backend was never invoked"
        [ "$(sort -u "$FAKEBIN_DIR/backend-env")" = 'unset|unset|unset' ] \
          || fail "$id: the backend inherited per-invocation adviser state: $(sort -u "$FAKEBIN_DIR/backend-env" | tr '\n' ' ')"
      else
        out=$(run_case_spawn "$id" "$PROJ_DIR" claude --mode no-mistakes --yolo off) \
          || fail "$id: spawn failed: $out"
      fi
      pre=$(grep '^export ' "$PANE_LOG")
      launch=$(cat "$LAUNCH_LOG")
      script="$script$pre
$launch
"
    done
    cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/bin/sh
printf '%s|%s|%s\n' "${COMPACT_ADVISER_DISABLE-unset}" "${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS-unset}" \
  "${FM_COMPACT_ADVISER_HOOKS-unset}"
SH
    chmod +x "$FAKEBIN_DIR/claude"
    seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane \
      /bin/sh -c "$script" | tr '\n' ' ') || fail "reuse, allowlist $setting: replay failed"
    assert_equals '0|1|1 1|unset|unset 1|unset|unset ' "$seen" \
      "reuse, allowlist $setting: an off or emergency-off relaunch kept the adviser-only hooks flag"
    expected='0|1|unset 1|1|unset 1|1|unset '
    [ "$setting" = absent ] || expected='0|1|1 1|unset|unset 1|unset|unset '
    seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm TMUX=synthetic-pane \
      CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 /bin/sh -c "$script" | tr '\n' ' ') \
      || fail "reuse, allowlist $setting: opted-in replay failed"
    assert_equals "$expected" "$seen" "reuse, allowlist $setting: a captain's own function-hooks opt-in was not preserved"
  done
  pass "a reused endpoint drops adviser-only hooks on off and emergency-off relaunches, and the backend never inherits the override"
}

test_invalid_policy_refuses_before_launch() {
  local policy rec out status
  rec=$(make_case invalid-policy codex invalid-policy-a1)
  read_case "$rec"
  for policy in '{"codex":"auto"}' '{"grok":"auto"}' '{"claude":"hint"}' \
    '{"cluade":"auto"}' '{"codex":"off"}' '{"claude":"auto","grok":"off"}' \
    '[]' '{} {}' '{bad json'; do
    printf '%s\n' "$policy" > "$HOME_DIR/config/compact-adviser"
    out=$(run_case_spawn invalid-policy-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
    status=$?
    expect_code 1 "$status" "unsupported adviser policy must refuse: $out"
    assert_contains "$out" 'config/compact-adviser' "policy refusal should identify the setting"
    [ ! -s "$LAUNCH_LOG" ] || fail "invalid policy launched a worker"
    [ ! -f "$HOME_DIR/state/invalid-policy-a1.meta" ] || fail "invalid policy published a task"
  done
  pass "malformed policy and keys other than claude or omp refuse before launch"
}

test_auto_emergency_override() {
  local rec out status seen
  rec=$(make_case auto-kill claude auto-kill-a1)
  read_case "$rec"
  printf '{"claude":"auto"}\n' > "$HOME_DIR/config/compact-adviser"
  out=$(FM_COMPACT_ADVISER_DISABLE=' YES ' COMPACT_ADVISER_DISABLE=0 \
    run_case_spawn auto-kill-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "emergency-disabled launch should still succeed: $out"
  install_env_probe "$FAKEBIN_DIR" claude
  seen=$(emitted_launch_env "$FAKEBIN_DIR" "$LAUNCH_LOG" "$PANE_LOG") || fail "emergency launch replay failed"
  assert_equals 1 "$seen" "the operator's emergency switch must defeat automatic policy"
  pass "the operator's emergency kill switch overrides opted-in auto"
}

test_batch_launch_policy_survives_reexec() {
  local harness setting kind policy rec name id1 id2 out status expected switch hooks marker
  local launchlog panelog seen rows
  local args=()
  for harness in claude omp; do
    for setting in absent enabled; do
      for kind in ship scout; do
        for policy in auto emergency; do
          name="batch-$harness-$setting-$kind-$policy"
          id1="$name-a"
          id2="$name-b"
          rec=$(make_case "$name" "$harness" "$id1" "$id2")
          read_case "$rec"
          printf '{"%s":"auto"}\n' "$harness" > "$HOME_DIR/config/compact-adviser"
          [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
          install_launch_state_probe "$FAKEBIN_DIR" "$harness"
          mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-backend"
          mkdir -p "$FAKEBIN_DIR/children"
          cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
dir=$(dirname "$0")
printf '%s\n' "${FM_COMPACT_ADVISER_DISABLE-unset}" >> "$dir/backend-env"
if [ "${1:-}" = send-keys ]; then
  prev=
  for arg in "$@"; do
    if [ "$prev" = -t ]; then
      export FM_FAKE_LAUNCH_LOG="$dir/children/$arg.launch"
      export FM_FAKE_PANE_LOG="$dir/children/$arg.pane"
      break
    fi
    prev=$arg
  done
fi
exec "$dir/tmux-backend" "$@"
SH
          chmod +x "$FAKEBIN_DIR/tmux"
          args=("$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness "$harness")
          if [ "$kind" = scout ]; then
            args+=(--scout)
          else
            args+=(--mode no-mistakes --yolo off)
          fi
          if [ "$policy" = emergency ]; then
            out=$(FM_COMPACT_ADVISER_DISABLE=' YES ' run_case_spawn "${args[@]}")
          else
            out=$(run_case_spawn "${args[@]}")
          fi
          status=$?
          expect_code 0 "$status" "$name: batch spawn should succeed: $out"
          [ -s "$FAKEBIN_DIR/backend-env" ] || fail "$name: the backend was never invoked"
          assert_equals unset "$(sort -u "$FAKEBIN_DIR/backend-env")" \
            "$name: the backend inherited the per-invocation emergency override"
          switch=0
          hooks=unset
          marker=unset
          if [ "$policy" = emergency ]; then
            switch=1
          elif [ "$harness" = claude ]; then
            hooks=1
            marker=1
          fi
          rows=
          for launchlog in "$FAKEBIN_DIR"/children/*.launch; do
            [ -f "$launchlog" ] || fail "$name: no child launch was captured"
            panelog="${launchlog%.launch}.pane"
            seen=$(emitted_launch_env "$FAKEBIN_DIR" "$launchlog" "$panelog") \
              || fail "$name: a captured child launch failed to execute"
            rows="$rows$seen
"
          done
          expected=$(printf '%s\n' "$id1|$switch|$hooks|$marker|unset" "$id2|$switch|$hooks|$marker|unset" | sort)
          seen=$(printf '%s' "$rows" | sort)
          assert_equals "$expected" "$seen" \
            "$name: each distinct batch child must receive its own identity, adviser policy, and no raw emergency override"
        done
      done
    done
  done
  pass "ship and scout batch reexecs preserve emergency-off and ordinary auto for every Claude and omp child"
}

test_raw_function_hooks_assignment_is_operator_owned() {
  local setting policy variant rec id raw hook switch out status launch seen expected prior
  for setting in absent enabled; do
    for policy in auto off emergency; do
      for variant in plain quoted other repeated zero; do
        id="raw-hooks-$setting-$policy-$variant"
        rec=$(make_case "$id" claude "$id")
        read_case "$rec"
        [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
        if [ "$policy" = off ]; then
          printf '{"claude":"off"}\n' > "$HOME_DIR/config/compact-adviser"
        else
          printf '{"claude":"auto"}\n' > "$HOME_DIR/config/compact-adviser"
        fi
        install_launch_state_probe "$FAKEBIN_DIR" claude
        hook=1
        case "$variant" in
          plain) raw='CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude' ;;
          quoted) raw="CLAUDE_CODE_ENABLE_FUNCTION_HOOKS='1' claude" ;;
          other) raw='FM_RAW_ASSIGNMENT=owned CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude' ;;
          repeated) raw='CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0 CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude' ;;
          zero) raw='CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0 claude'; hook=0 ;;
        esac
        if [ "$policy" = emergency ]; then
          out=$(FM_COMPACT_ADVISER_DISABLE=1 run_case_spawn "$id" "$PROJ_DIR" \
            --mode no-mistakes --yolo off "$raw")
        else
          out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$raw")
        fi
        status=$?
        expect_code 0 "$status" "$id: raw-assignment spawn should succeed: $out"
        launch="$(grep '^export ' "$PANE_LOG")
$(cat "$LAUNCH_LOG")"
        switch=1
        [ "$policy" != auto ] || switch=0
        expected="$id|$switch|$hook|unset|unset"
        for prior in clean marked; do
          if [ "$prior" = marked ]; then
            seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
              TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" \
              CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 FM_COMPACT_ADVISER_HOOKS=1 \
              /bin/sh -c "$launch") \
              || fail "$id: launch replay in a previously marked pane failed"
          else
            seen=$(env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
              TMUX=synthetic-pane COMPACT_ADVISER_DISABLE="$CONTRARY" /bin/sh -c "$launch") \
              || fail "$id: launch replay in a clean pane failed"
          fi
          assert_equals "$expected" "$seen" \
            "$id ($prior pane): the raw hook assignment must keep its shell value without an adviser marker"
        done
      done
    done
  done
  pass "raw leading hook assignments remain operator-owned in auto, off, and emergency launches, including reused panes"
}

test_auto_launch_policy
test_reused_endpoint_drops_adviser_hooks
test_invalid_policy_refuses_before_launch
test_auto_emergency_override
test_batch_launch_policy_survives_reexec
test_raw_function_hooks_assignment_is_operator_owned
test_ship_allowlist_absent
test_ship_allowlist_enabled
test_launch_command_carries_the_switch_without_the_pane_export
test_secondmate_launch
test_relaunch_rebuilds_the_switch
test_raw_compound_launch_command_carries_the_switch
