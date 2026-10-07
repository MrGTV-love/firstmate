#!/usr/bin/env bash
# tests/fm-spawn-claude-api-key-guard.test.sh - every claude worker this fleet
# launches must be refused when ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN would
# reach it, unless --allow-api-key opts in or the worker-account pin shed strips
# the variable from the launch environment. On the tmux backend the check also
# covers the tmux session and global environment a new worker window inherits.
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then check the exit
# code and error message for refusal or success.
#
# The remote second-mate route cannot set these variables in its pane and is
# covered by a different test surface.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-api-key-guard)

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
  install_tmux_environment_stub "$fakebin"
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

# install_signed_in_pin: pin the current case's claude workers to a throwaway
# root that a fake claude reports as signed in.
install_signed_in_pin() {
  cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/bin/sh
case "${1:-}" in
auth) printf '{\n  "status": "signed_in"\n}\n' && exit 0 ;;
*)   exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/claude"
  mkdir -p "$CASE_DIR/auth-pin"
  printf '%s\n' "$CASE_DIR/auth-pin" > "$HOME_DIR/config/claude-account"
}

install_tmux_environment_stub() {
  local fakebin=$1
  cp "$fakebin/tmux" "$fakebin/tmux-base"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
server=${FM_TEST_TMUX_SERVER:-fresh}
state=${FM_TEST_TMUX_STATE:?}
if [ -f "$state.server" ]; then
  server=created
  for name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    export "FM_FAKE_TMUX_GLOBAL_ENV_$name=${!name:-}"
  done
fi
case "${1:-}" in
  show-options)
    [ "$server" != fresh ] || exit 1
    [ "${2:-}" = -gv ] && [ "${3:-}" = update-environment ] || exit 1
    printf '%s\n' "${FM_TEST_TMUX_UPDATE_ENVIRONMENT:-}"
    exit 0
    ;;
  has-session)
    [ "$server" = existing ] || [ -f "$state.session" ]
    exit $?
    ;;
  show-environment)
    [ "$server" != fresh ] || exit 1
    if [ "${2:-}" = -t ]; then
      [ "$server" = existing ] || [ -f "$state.session" ] || exit 1
    fi
    scope=FM_FAKE_TMUX_GLOBAL_ENV_
    [ "${2:-}" != -t ] || scope=FM_FAKE_TMUX_ENV_
    if { [ "${2:-}" = -g ] && [ "$#" = 2 ]; } || { [ "${2:-}" = -t ] && [ "$#" = 3 ]; }; then
      while IFS= read -r knob; do
        name=${knob#"$scope"}
        if [ "${!knob}" = - ]; then printf -- '-%s\n' "$name"
        else printf '%s=%s\n' "$name" "${!knob}"; fi
      done < <(compgen -A variable "$scope")
      if [ "${2:-}" = -t ] && [ -f "$state.imports" ]; then cat "$state.imports"; fi
      exit 0
    fi
    if [ "${2:-}" = -t ] && [ -f "$state.imports" ]; then
      name=${!#}
      while IFS= read -r entry; do
        case "$entry" in "$name="*|"-$name") printf '%s\n' "$entry"; exit 0 ;; esac
      done < "$state.imports"
    fi
    ;;
  new-session)
    [ "$server" != fresh ] || : > "$state.server"
    : > "$state.session"
    : > "$state.imports"
    while IFS= read -r pattern; do
      matched=0
      while IFS= read -r name; do
        case "$name" in
          $pattern) printf '%s=%s\n' "$name" "${!name}" >> "$state.imports"; matched=1 ;;
        esac
      done < <(compgen -e)
      [ "$matched" = 1 ] || printf -- '-%s\n' "$pattern" >> "$state.imports"
    done <<<"${FM_TEST_TMUX_UPDATE_ENVIRONMENT:-}"
    ;;
esac
exec "$(dirname "$0")/tmux-base" "$@"
SH
  chmod +x "$fakebin/tmux"
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  mkdir -p "$HOME_DIR/user-home"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    FM_TEST_TMUX_STATE="$CASE_DIR/tmux" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" FM_BACKEND=tmux TMUX='' \
    PATH="$FAKEBIN_DIR:$PATH" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

# --- tests ------------------------------------------------------------------

# Test 1: claude spawn refuses when ANTHROPIC_API_KEY is set and no allowlist.
test_refuse_api_key_no_allowlist() {
  local rec out status
  rec=$(make_case refuse-api-key claude refuse-api-key-a1)
  read_case "$rec"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn refuse-api-key-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn should refuse when ANTHROPIC_API_KEY is set"$'\n'"$out"
  assert_contains "$out" "ANTHROPIC_API_KEY" \
    "the refusal message should name the variable"
  pass "claude spawn refuses when ANTHROPIC_API_KEY is set and no allowlist"
}

# Test 2: claude spawn refuses when ANTHROPIC_AUTH_TOKEN is set and no allowlist.
test_refuse_auth_token_no_allowlist() {
  local rec out status
  rec=$(make_case refuse-auth-token claude refuse-auth-token-a1)
  read_case "$rec"
  out=$(ANTHROPIC_AUTH_TOKEN=sk-ant-test-token \
    run_case_spawn refuse-auth-token-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn should refuse when ANTHROPIC_AUTH_TOKEN is set"$'\n'"$out"
  assert_contains "$out" "ANTHROPIC_AUTH_TOKEN" \
    "the refusal message should name the variable"
  pass "claude spawn refuses when ANTHROPIC_AUTH_TOKEN is set and no allowlist"
}

# Test 3: claude spawn succeeds when neither variable is set.
test_succeed_unset() {
  local rec out status
  rec=$(make_case succeed-unset claude succeed-unset-a1)
  read_case "$rec"
  out=$(run_case_spawn succeed-unset-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed when no API key is set"$'\n'"$out"
  pass "claude spawn succeeds when no API key is set"
}

# Test 4: claude spawn succeeds when ANTHROPIC_API_KEY is set but allowlist
# filters it out.
test_succeed_api_key_filtered_by_allowlist() {
  local rec out status
  rec=$(make_case succeed-filtered claude succeed-filtered-a1)
  read_case "$rec"
  # Write an allowlist that does NOT include ANTHROPIC_API_KEY.
  printf '%s\n' 'HOME' 'PATH' 'USER' 'LOGNAME' 'SHELL' 'TERM' 'TMPDIR' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn succeed-filtered-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed when ANTHROPIC_API_KEY is filtered out by allowlist"$'\n'"$out"
  pass "claude spawn succeeds when ANTHROPIC_API_KEY is filtered out by allowlist"
}

# Test 5: claude spawn succeeds with --allow-api-key when ANTHROPIC_API_KEY is set.
test_succeed_with_allow_api_key_flag() {
  local rec out status
  rec=$(make_case succeed-allow-flag claude succeed-allow-flag-a1)
  read_case "$rec"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn succeed-allow-flag-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --allow-api-key 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed with --allow-api-key when ANTHROPIC_API_KEY is set"$'\n'"$out"
  assert_contains "$out" "spawned" \
    "the spawn should succeed and print the spawned line"
  pass "claude spawn succeeds with --allow-api-key flag"
}

# Test 6: non-claude harness succeeds when ANTHROPIC_API_KEY is set.
test_non_claude_harness_ignores_api_key() {
  local rec out status
  rec=$(make_case non-claude-ignores codex non-claude-ignores-a1)
  read_case "$rec"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn non-claude-ignores-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "non-claude harness should succeed when ANTHROPIC_API_KEY is set"$'\n'"$out"
  pass "non-claude harness ignores ANTHROPIC_API_KEY"
}

# Test 7: claude spawn succeeds with worker-account pin when ANTHROPIC_API_KEY
# is set, because the pin shed strips it from the launch (F2).
test_succeed_with_pin_shed() {
  local rec out status
  rec=$(make_case succeed-pin-shed claude succeed-pin-shed-a1)
  read_case "$rec"
  install_signed_in_pin
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn succeed-pin-shed-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed with worker-account pin when ANTHROPIC_API_KEY is set"$'\n'"$out"
  pass "claude spawn succeeds with pin shed when ANTHROPIC_API_KEY is set"
}

# Test 8: --allow-api-key is recorded in task metadata.
test_allow_api_key_recorded_in_meta() {
  local rec out status meta
  rec=$(make_case record-api-key claude record-api-key-a1)
  read_case "$rec"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn record-api-key-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --allow-api-key 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "spawn with --allow-api-key should succeed"$'\n'"$out"
  meta="$HOME_DIR/state/record-api-key-a1.meta"
  [ -f "$meta" ] || fail "task meta should exist after spawn"
  assert_grep 'api_key=allow' "$meta" \
    "task meta should record api_key=allow when --allow-api-key is used"
  pass "task meta records api_key=allow when --allow-api-key is used"
}

# Test 9: a key only in the tmux session environment is refused, because a new
# window in that session inherits it even though fm-spawn's own env is clean.
test_refuse_tmux_session_env() {
  local rec out status
  rec=$(make_case refuse-tmux-session claude refuse-tmux-session-a1)
  read_case "$rec"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_TEST_TMUX_SERVER=existing \
    FM_FAKE_TMUX_ENV_ANTHROPIC_API_KEY=sk-ant-session-key \
    run_case_spawn refuse-tmux-session-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn should refuse when the tmux session environment holds ANTHROPIC_API_KEY"$'\n'"$out"
  assert_contains "$out" "ANTHROPIC_API_KEY is set in the tmux session environment" \
    "the refusal should name the variable and the tmux session scope"
  assert_not_contains "$out" "sk-ant-session-key" "the refusal must not print the credential"
  pass "claude spawn refuses a key set only in the tmux session environment"
}

# Test 10: a key only in the tmux global environment is refused. A session
# lookup alone reports "unknown variable" here, yet a new window inherits the
# global value.
test_refuse_tmux_global_env() {
  local rec out status
  rec=$(make_case refuse-tmux-global claude refuse-tmux-global-a1)
  read_case "$rec"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_TEST_TMUX_SERVER=existing \
    FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_AUTH_TOKEN=sk-ant-global-token \
    run_case_spawn refuse-tmux-global-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn should refuse when the tmux global environment holds ANTHROPIC_AUTH_TOKEN"$'\n'"$out"
  assert_contains "$out" "ANTHROPIC_AUTH_TOKEN is set in the tmux global environment" \
    "the refusal should name the variable and the tmux global scope"
  assert_not_contains "$out" "sk-ant-global-token" "the refusal must not print the credential"
  pass "claude spawn refuses a key set only in the tmux global environment"
}

# Test 11: a session removal marker (-NAME) wins over a global value, as it
# does for the window tmux creates.
test_succeed_tmux_session_removal_marker() {
  local rec out status
  rec=$(make_case succeed-tmux-removed claude succeed-tmux-removed-a1)
  read_case "$rec"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_TEST_TMUX_SERVER=existing \
    FM_FAKE_TMUX_ENV_ANTHROPIC_API_KEY=- \
    FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_API_KEY=sk-ant-global-key \
    run_case_spawn succeed-tmux-removed-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed when the tmux session removes the global key"$'\n'"$out"
  pass "claude spawn honors a tmux session removal marker over a global key"
}

# Test 12: a tmux-environment key does not refuse when the worker-account pin
# shed strips it from the launch.
test_succeed_tmux_env_with_pin_shed() {
  local rec out status
  rec=$(make_case succeed-tmux-pin claude succeed-tmux-pin-a1)
  read_case "$rec"
  install_signed_in_pin
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_TEST_TMUX_SERVER=existing \
    FM_FAKE_TMUX_ENV_ANTHROPIC_API_KEY=sk-ant-session-key \
    FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_AUTH_TOKEN=sk-ant-global-token \
    run_case_spawn succeed-tmux-pin-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed with a pin when only the tmux environment holds a key"$'\n'"$out"
  pass "claude spawn succeeds with pin shed when the tmux environment holds a key"
}

# Test 13: a tmux-environment key the allowlist does not list is filtered out
# of the launch, so it does not refuse; a listed one does.
test_tmux_env_follows_the_allowlist() {
  local rec out status
  rec=$(make_case tmux-allowlist claude tmux-allowlist-a1 tmux-allowlist-a2)
  read_case "$rec"
  printf '%s\n' 'HOME' 'PATH' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_TEST_TMUX_SERVER=existing \
    FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_API_KEY=sk-ant-global-key \
    run_case_spawn tmux-allowlist-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed when the allowlist filters out the tmux key"$'\n'"$out"
  printf '%s\n' 'HOME' 'PATH' 'ANTHROPIC_API_KEY' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    FM_TEST_TMUX_SERVER=existing \
    FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_API_KEY=sk-ant-global-key \
    run_case_spawn tmux-allowlist-a2 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "claude spawn should refuse when the allowlist forwards the tmux key"$'\n'"$out"
  assert_contains "$out" "ANTHROPIC_API_KEY is set in the tmux global environment" \
    "the refusal should name the forwarded variable"
  pass "claude spawn tmux-environment check follows config/launch-env-allowlist"
}

# Execute the generated launch in a synthetic pane, which may have a captured
# credential that is absent from the spawning process and tmux server.
observe_launch() {
  cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
observed="$FM_OBSERVED"
case "${1:-}:${2:-}:${3:-}" in
  --version:*) observed="$FM_OBSERVED.version" ;;
  --dangerously-skip-permissions:--print:compound-worker) observed="$FM_OBSERVED.worker" ;;
esac
printf 'API_KEY=%s\nAUTH_TOKEN=%s\nCONFIG_DIR=%s\n' \
  "${ANTHROPIC_API_KEY-unset}" "${ANTHROPIC_AUTH_TOKEN-unset}" \
  "${CLAUDE_CONFIG_DIR-unset}" > "$observed"
SH
  chmod +x "$FAKEBIN_DIR/claude"
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN_DIR:$PATH" \
    FM_OBSERVED="$CASE_DIR/observed" ANTHROPIC_API_KEY=sk-ant-pane-only \
    ANTHROPIC_AUTH_TOKEN=sk-ant-pane-token CLAUDE_CONFIG_DIR="$CASE_DIR/stale-claude" \
    bash -c "$(cat "$LAUNCH_LOG")" \
    || fail "synthetic pane could not execute the Claude launch"
}

# A credential captured by an old pane must be shed for a non-opt-in launch.
test_launch_sheds_captured_credentials() {
  local rec out status
  rec=$(make_case launch-sheds-captured claude launch-sheds-captured-a1)
  read_case "$rec"
  out=$(run_case_spawn launch-sheds-captured-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn should succeed"$'\n'"$out"
  observe_launch
  assert_grep 'API_KEY=unset' "$CASE_DIR/observed" "the pane's API key must not reach Claude"
  assert_grep 'AUTH_TOKEN=unset' "$CASE_DIR/observed" "the pane's auth token must not reach Claude"
  pass "a non-opt-in launch sheds credentials captured by the pane"
}

# An explicit billing opt-in must allow the pane's credentials through.
test_launch_preserves_credentials_with_opt_in() {
  local rec out status
  rec=$(make_case launch-opt-in claude launch-opt-in-a1)
  read_case "$rec"
  out=$(run_case_spawn launch-opt-in-a1 "$PROJ_DIR" --mode no-mistakes --yolo off --allow-api-key 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "claude spawn with --allow-api-key should succeed"$'\n'"$out"
  observe_launch
  assert_grep 'API_KEY=sk-ant-pane-only' "$CASE_DIR/observed" "the opted-in pane API key should reach Claude"
  assert_grep 'AUTH_TOKEN=sk-ant-pane-token' "$CASE_DIR/observed" "the opted-in pane token should reach Claude"
  pass "an opted-in launch passes credentials captured by the pane"
}

test_compound_launch_credentials_and_account() {
  local scenario pin allowlist opt_in rec id out status probe expected actual root
  local expected_key expected_token
  local -a flags
  for scenario in ambient allowlist opt-in-ambient opt-in-allowlist \
    named ordinary named-opt-in ordinary-opt-in named-allowlist ordinary-allowlist; do
    pin=none
    allowlist=0
    opt_in=0
    case "$scenario" in
      named*) pin=named ;;
      ordinary*) pin=ordinary ;;
    esac
    case "$scenario" in
      *allowlist) allowlist=1 ;;
    esac
    case "$scenario" in
      *opt-in*) opt_in=1 ;;
    esac
    id="compound-$scenario-a1"
    rec=$(make_case "compound-$scenario" claude "$id")
    read_case "$rec"
    root="$CASE_DIR/stale-claude"
    if [ "$pin" != none ]; then
      install_signed_in_pin
      root="$CASE_DIR/auth-pin"
      if [ "$pin" = ordinary ]; then
        printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
        root='unset'
      fi
    fi
    if [ "$allowlist" -eq 1 ]; then
      printf '%s\n' HOME PATH FM_OBSERVED ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN \
        CLAUDE_CONFIG_DIR > "$HOME_DIR/config/launch-env-allowlist"
    fi
    flags=()
    [ "$opt_in" -eq 0 ] || flags+=(--allow-api-key)
    out=$(
      unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
      if [ "$opt_in" -eq 1 ] || [ "$pin" != none ]; then
        export ANTHROPIC_API_KEY=sk-ant-pane-only ANTHROPIC_AUTH_TOKEN=sk-ant-pane-token
      fi
      FM_OBSERVED="$CASE_DIR/observed" run_case_spawn "$id" "$PROJ_DIR" \
        'claude --version && claude --dangerously-skip-permissions --print compound-worker' \
        --mode no-mistakes --yolo off "${flags[@]+"${flags[@]}"}" 2>&1
    )
    status=$?
    [ "$status" -eq 0 ] || fail "$scenario compound Claude spawn should succeed"$'\n'"$out"
    observe_launch
    expected_key='unset'
    expected_token='unset'
    if [ "$opt_in" -eq 1 ] && [ "$pin" = none ]; then
      expected_key=sk-ant-pane-only
      expected_token=sk-ant-pane-token
    fi
    for probe in version worker; do
      [ -f "$CASE_DIR/observed.$probe" ] \
        || fail "$scenario compound launch did not execute the $probe invocation"
      actual=$(cat "$CASE_DIR/observed.$probe")
      expected=$(printf 'API_KEY=%s\nAUTH_TOKEN=%s\nCONFIG_DIR=%s' \
        "$expected_key" "$expected_token" "$root")
      [ "$actual" = "$expected" ] \
        || fail "$scenario $probe invocation must receive the expected credentials and account"$'\n'"expected: $expected"$'\n'"actual: $actual"
    done
    pass "$scenario compound Claude launch enforces credentials and account on both invocations"
  done
}

# Exercise the shared guard's non-tmux backend without starting Herdr.
test_non_tmux_guard() {
  local out status
  # shellcheck source=bin/fm-api-key-guard-lib.sh
  . "$ROOT/bin/fm-api-key-guard-lib.sh"
  out=$(ANTHROPIC_API_KEY=sk-ant-herdr-test \
    fm_api_key_guard claude 0 '' 0 '' herdr 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the Herdr Claude guard must refuse an inherited API key"
  assert_contains "$out" "ANTHROPIC_API_KEY" "the refusal should identify the API key"
  out=$(ANTHROPIC_AUTH_TOKEN=sk-ant-herdr-test \
    fm_api_key_guard claude 0 '' 0 '' herdr 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the Herdr Claude guard must refuse an inherited auth token"
  assert_contains "$out" "ANTHROPIC_AUTH_TOKEN" "the refusal should identify the auth token"
  ANTHROPIC_API_KEY=sk-ant-herdr-test fm_api_key_guard claude 1 '' 0 '' herdr \
    || fail "an explicit API billing opt-in must permit the Herdr launch"
  ANTHROPIC_API_KEY=sk-ant-herdr-test fm_api_key_guard claude 0 '' 1 'HOME' herdr \
    || fail "a filtered-out key must not refuse the Herdr launch"
  pass "the shared guard enforces non-tmux Claude keys and respects opt-in and filtering"
}

# --- run --------------------------------------------------------------------

# Test: the guard holds unchanged when config/claude-launcher routes Claude
# through TeamClaude, and --allow-api-key still reaches the TeamClaude launch.
test_teamclaude_launcher_keeps_the_api_key_guard() {
  local rec out status
  rec=$(make_case teamclaude-api-key claude teamclaude-api-key-a1 teamclaude-api-key-a2)
  read_case "$rec"
  fm_test_fake_teamclaude "$FAKEBIN_DIR"
  printf 'teamclaude\n' > "$HOME_DIR/config/claude-launcher"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn teamclaude-api-key-a1 "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a TeamClaude claude spawn should refuse when ANTHROPIC_API_KEY is set"$'\n'"$out"
  assert_contains "$out" "ANTHROPIC_API_KEY" "the refusal message should name the variable"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused TeamClaude spawn must not launch anything"
  assert_absent "$HOME_DIR/state/teamclaude-api-key-a1.meta" "a refused TeamClaude spawn must leave no task record"

  out=$(ANTHROPIC_API_KEY=sk-ant-test-key \
    run_case_spawn teamclaude-api-key-a2 "$PROJ_DIR" --mode no-mistakes --yolo off --allow-api-key 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "a TeamClaude claude spawn should honor --allow-api-key"$'\n'"$out"
  assert_contains "$(cat "$LAUNCH_LOG")" "$ROOT/bin/fm-teamclaude-launch.sh' " \
    "an allowed API-key launch should still start through TeamClaude"
  pass "config/claude-launcher=teamclaude keeps the API-key refusal and the --allow-api-key opt-in"
}

test_existing_tmux_ignores_caller_credentials() {
  local name server rec out status id
  for name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    for server in existing existing-no-firstmate; do
      id="caller-${name##*_}-$server"
      rec=$(make_case "$id" claude "$id")
      read_case "$rec"
      out=$(export "$name=sk-ant-caller-only"
        [ "$server" != existing ] || export FM_TEST_TMUX_UPDATE_ENVIRONMENT='ANTHROPIC_*'
        FM_TEST_TMUX_SERVER="$server" \
          run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
      status=$?
      [ "$status" -eq 0 ] || fail "existing tmux $server must ignore caller-only $name"$'\n'"$out"
      assert_contains "$out" "spawned" "existing tmux should launch without destination credentials"
    done
  done
  pass "existing tmux with or without firstmate ignores both caller-only credentials"
}

test_existing_tmux_without_firstmate_checks_global_credentials() {
  local name rec out status id
  for name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    id="global-${name##*_}"
    rec=$(make_case "$id" claude "$id")
    read_case "$rec"
    out=$(export "FM_FAKE_TMUX_GLOBAL_ENV_$name=sk-ant-existing-global"
      FM_TEST_TMUX_SERVER=existing-no-firstmate \
        run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "existing tmux without firstmate must refuse global $name"$'\n'"$out"
    assert_contains "$out" "$name is set in the tmux global environment" "the global credential must be checked before firstmate exists"
    assert_not_contains "$out" "sk-ant-existing-global" "the refusal must not disclose credentials"
    [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must not send a launch"
    assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not create task metadata"
  done
  pass "existing tmux without firstmate checks both global credentials"
}

test_fresh_tmux_auth_token_exceptions() {
  local variant rec out status id
  for variant in filtered listed pin allowed; do
    id="fresh-token-$variant"
    rec=$(make_case "$id" claude "$id")
    read_case "$rec"
    case "$variant" in
      filtered) printf 'HOME\nPATH\n' > "$HOME_DIR/config/launch-env-allowlist" ;;
      listed) printf 'HOME\nPATH\nANTHROPIC_AUTH_TOKEN\n' > "$HOME_DIR/config/launch-env-allowlist" ;;
      pin) install_signed_in_pin ;;
    esac
    if [ "$variant" = allowed ]; then
      out=$(ANTHROPIC_AUTH_TOKEN=sk-ant-fresh-token run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --allow-api-key 2>&1)
    else
      out=$(ANTHROPIC_AUTH_TOKEN=sk-ant-fresh-token run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
    fi
    status=$?
    if [ "$variant" = listed ]; then
      [ "$status" -ne 0 ] || fail "fresh tmux must refuse an allowlisted auth token"$'\n'"$out"
      assert_contains "$out" "ANTHROPIC_AUTH_TOKEN" "the refusal must name the listed auth token"
    else
      [ "$status" -eq 0 ] || fail "fresh tmux must honor the $variant auth-token exception"$'\n'"$out"
      assert_contains "$out" "spawned" "the auth-token exception must reach successful spawn"
    fi
  done
  pass "fresh tmux honors auth-token filtering, pin shedding, and explicit opt-in"
}
test_prospective_tmux_credentials() {
  local name pattern variant rec out status id
  for name in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    for pattern in "$name" 'ANTHROPIC_*' 'ANTHROPIC_?*_*' 'ANTHROPIC_[A-Z]*' 'ANTHROPIC_[A-Z ]*'; do
      id="prospective-${name##*_}-${pattern//[^a-zA-Z0-9]/x}"
      rec=$(make_case "$id" claude "$id")
      read_case "$rec"
      out=$(export "$name=sk-ant-imported"
        FM_TEST_TMUX_SERVER=existing-no-firstmate FM_TEST_TMUX_UPDATE_ENVIRONMENT="$pattern" \
          run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
      status=$?
      [ "$status" -ne 0 ] || fail "prospective tmux must refuse $name imported by $pattern"$'\n'"$out"
      assert_contains "$out" "$name" "the imported credential refusal must name its variable"
      assert_contains "$out" "tmux update-environment" "the refusal must identify the prospective import"
      assert_not_contains "$out" sk-ant-imported "the refusal must not disclose the imported credential"
      [ ! -s "$LAUNCH_LOG" ] || fail "an imported credential refusal must not launch"
      assert_absent "$HOME_DIR/state/$id.meta" "an imported credential refusal must not create metadata"
    done
    for variant in removed empty filtered listed pin allowed; do
      id="prospective-${name##*_}-$variant"
      rec=$(make_case "$id" claude "$id")
      read_case "$rec"
      case "$variant" in
        filtered) printf 'HOME\nPATH\n' > "$HOME_DIR/config/launch-env-allowlist" ;;
        listed) printf 'HOME\nPATH\n%s\n' "$name" > "$HOME_DIR/config/launch-env-allowlist" ;;
        pin) install_signed_in_pin ;;
      esac
      out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
        export "FM_FAKE_TMUX_GLOBAL_ENV_$name=sk-ant-global"
        if [ "$variant" = empty ]; then
          export "$name="
        elif [ "$variant" != removed ]; then
          export "$name=sk-ant-imported"
        fi
        if [ "$variant" = allowed ]; then
          FM_TEST_TMUX_SERVER=existing-no-firstmate FM_TEST_TMUX_UPDATE_ENVIRONMENT="$name" \
            run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --allow-api-key 2>&1
        else
          FM_TEST_TMUX_SERVER=existing-no-firstmate FM_TEST_TMUX_UPDATE_ENVIRONMENT="$name" \
            run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
        fi)
      status=$?
      if [ "$variant" = listed ]; then
        [ "$status" -ne 0 ] || fail "prospective tmux must refuse an allowlisted imported $name"$'\n'"$out"
        assert_contains "$out" "$name" "the allowlisted import refusal must identify the credential"
      else
        [ "$status" -eq 0 ] || fail "prospective tmux must honor $variant for $name"$'\n'"$out"
        assert_contains "$out" spawned "the prospective credential exception must launch"
      fi
    done
  done
  pass "prospective tmux imports both credentials with glob patterns and honors removal, emptiness, filtering, pins, and opt-in"
}

test_fresh_claude_dispatch_consumes_initialized_auth_boundary() {
  local variant rec id out status percent expected_harness expected_config expected_home expected_bash_env launch
  for variant in caller-config pane-config filtered-config home-mismatch default-available default-exhausted startup-config startup-home startup-default; do
    id="fresh-auth-$variant"
    rec=$(make_case "$id" claude "$id")
    read_case "$rec"
    printf '%s\n' '{"rules":[{"when":"assigned work","use":{"harness":"claude"},"fallback":[{"harness":"omp","model":"openrouter/z-ai/glm-5.3-flash","effort":"high"}]}]}' \
      > "$HOME_DIR/config/crew-dispatch.json"
    percent=0
    [ "$variant" != default-available ] || percent=50
    printf '%s\n' "$percent" > "$FAKEBIN_DIR/remaining"
    cat > "$FAKEBIN_DIR/quota-axi" <<'SH'
#!/bin/sh
percent=$(cat "${0%/*}/remaining")
printf '%s\n' "$HOME" > "${0%/*}/quota-home"
printf '{"schemaVersion":6,"providers":[{"provider":"claude","accountKey":"default","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s"}}]}}]}\n' \
  "$percent" "$([ "$percent" = 0 ] && printf exhausted_now || printf available)"
SH
    cat > "$FAKEBIN_DIR/claude" <<'SH'
#!/bin/sh
printf '%s\n' "HOME=$HOME" "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR-}" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY-}" "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN-}" "BASH_ENV=${BASH_ENV-}" \
  > "${0%/*}/worker.env"
pwd -P > "${0%/*}/worker.cwd"
SH
    cat > "$FAKEBIN_DIR/omp" <<'SH'
#!/bin/sh
case "${1:-}" in
  models) printf '%s\n' '{"models":[{"provider":"openrouter","id":"z-ai/glm-5.3-flash","selector":"openrouter/z-ai/glm-5.3-flash"}]}' ;;
  *) exec "${0%/*}/claude" "$@" ;;
esac
SH
    chmod +x "$FAKEBIN_DIR/quota-axi" "$FAKEBIN_DIR/claude" "$FAKEBIN_DIR/omp"
    expected_home="$HOME_DIR/user-home"
    expected_config=
    expected_harness=claude
    expected_bash_env=
    case "$variant" in
      caller-config) expected_config="$CASE_DIR/caller-config" ;;
      pane-config|startup-default) expected_config="$CASE_DIR/pane-config" ;;
      filtered-config)
        printf '%s\n' HOME PATH > "$HOME_DIR/config/launch-env-allowlist"
        expected_harness=omp
        ;;
      home-mismatch) expected_home="$CASE_DIR/other-home" ;;
      default-exhausted|startup-config|startup-home) expected_harness=omp ;;
    esac
    mkdir -p "$expected_home"
    printf 'export HOME=%q\nexport PATH=%q\n' "$expected_home" "$FAKEBIN_DIR:$PATH" > "$CASE_DIR/pane-init.sh"
    case "$variant" in
      pane-config|filtered-config|startup-default)
        printf 'export CLAUDE_CONFIG_DIR=%q\n' "$CASE_DIR/pane-config" >> "$CASE_DIR/pane-init.sh"
        ;;
    esac
    case "$variant" in
      startup-config|startup-home|startup-default)
        expected_bash_env="$CASE_DIR/bash-env.sh"
        case "$variant" in
          startup-config) printf 'export CLAUDE_CONFIG_DIR=%q\n' "$CASE_DIR/startup-config" > "$expected_bash_env" ;;
          startup-home) printf 'export HOME=%q\n' "$CASE_DIR/startup-home" > "$expected_bash_env" ;;
          startup-default) printf 'unset CLAUDE_CONFIG_DIR\n' > "$expected_bash_env" ;;
        esac
        printf 'export BASH_ENV=%q\n' "$expected_bash_env" >> "$CASE_DIR/pane-init.sh"
        ;;
    esac
    out=$(
      unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR
      FM_FAKE_PANE_INIT="$CASE_DIR/pane-init.sh" \
        FM_FAKE_PANE_ERREXIT=1 \
        FM_FAKE_QUERY_LOG="$CASE_DIR/query.log" \
        FM_FAKE_TMUX_GLOBAL_ENV_HOME="$HOME_DIR/user-home" \
        FM_FAKE_TMUX_ENV_HOME="$HOME_DIR/user-home" \
        FM_TEST_CLAUDE_CONFIG_DIR="$([ "$variant" != caller-config ] || printf '%s' "$expected_config")" \
        run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --harness claude --dispatch-rule rule_1
    )
    status=$?
    [ "$status" -eq 0 ] || fail "$variant fresh Claude dispatch should succeed"$'\n'"$out"
    assert_contains "$out" "spawned $id harness=$expected_harness" "$variant selected capacity from a different authentication boundary"
    if [ "$expected_harness" = omp ]; then
      assert_contains "$out" "fallback launched omp" "$variant did not serve the exhausted default fallback"
    else
      assert_not_contains "$out" "fallback launched" "$variant must not activate an unsupported fallback"
    fi
    assert_grep "harness=$expected_harness" "$HOME_DIR/state/$id.meta" "$variant recorded the wrong served harness"
    [ -s "$CASE_DIR/query.log" ] || fail "$variant did not consume an actual initialized-pane endpoint query"
    launch=$(cat "$LAUNCH_LOG")
    [ -n "$launch" ] || fail "$variant did not send an actual worker launch"
    fm_test_consume_pane_launch "$FAKEBIN_DIR" "$launch" \
      > "$CASE_DIR/worker.out" 2>&1 || fail "$variant initialized-pane launch could not be consumed"
    grep -Fxq "HOME=$expected_home" "$FAKEBIN_DIR/worker.env" || fail "$variant worker HOME disagreed with its actual probe"
    grep -Fxq "CLAUDE_CONFIG_DIR=$expected_config" "$FAKEBIN_DIR/worker.env" || fail "$variant worker config root disagreed with its actual probe"
    grep -Fxq "BASH_ENV=$expected_bash_env" "$FAKEBIN_DIR/worker.env" || fail "$variant worker must inherit BASH_ENV unchanged"
    assert_equals "$(cd "$WT_DIR" && pwd -P)" "$(cat "$FAKEBIN_DIR/worker.cwd")" "$variant worker must consume the initialized destination cwd"
    grep -Fxq 'ANTHROPIC_API_KEY=' "$FAKEBIN_DIR/worker.env" || fail "$variant leaked billing credentials"
    grep -Fxq 'ANTHROPIC_AUTH_TOKEN=' "$FAKEBIN_DIR/worker.env" || fail "$variant leaked billing tokens"
    if [ -f "$FAKEBIN_DIR/quota-home" ]; then
      assert_equals "$HOME_DIR/user-home" "$(cat "$FAKEBIN_DIR/quota-home")" "$variant queried quota outside the caller identity"
    fi
  done
  pass "fresh Claude dispatch consumes initialized pane authentication, filters inherited alternate roots, and binds native quota only to matching default HOME"
}


test_refuse_api_key_no_allowlist
test_refuse_auth_token_no_allowlist
test_succeed_unset
test_succeed_api_key_filtered_by_allowlist
test_succeed_with_allow_api_key_flag
test_non_claude_harness_ignores_api_key
test_succeed_with_pin_shed
test_allow_api_key_recorded_in_meta
test_refuse_tmux_session_env
test_refuse_tmux_global_env
test_succeed_tmux_session_removal_marker
test_succeed_tmux_env_with_pin_shed
test_tmux_env_follows_the_allowlist
test_launch_sheds_captured_credentials
test_launch_preserves_credentials_with_opt_in
test_compound_launch_credentials_and_account
test_non_tmux_guard
test_teamclaude_launcher_keeps_the_api_key_guard
test_existing_tmux_ignores_caller_credentials
test_existing_tmux_without_firstmate_checks_global_credentials
test_fresh_tmux_auth_token_exceptions
test_prospective_tmux_credentials
test_fresh_claude_dispatch_consumes_initialized_auth_boundary
