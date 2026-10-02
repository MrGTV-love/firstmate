#!/usr/bin/env bash
# tests/fm-teamclaude-launch.test.sh - bin/fm-teamclaude-launch.sh starts Claude
# only with the client environment the local TeamClaude CLI exports, and refuses
# rather than start Claude unproxied.
#
# Each case runs the real launcher in a clean non-interactive shell against a
# fake teamclaude and a recording claude, so no shell alias or inherited proxy
# variable can supply what the assertions look for.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

LAUNCHER="$ROOT/bin/fm-teamclaude-launch.sh"
TMP_ROOT=$(fm_test_tmproot fm-teamclaude-launch)
BASH_DIR=$(fm_test_bash_only_dir "$TMP_ROOT")

# new_case <name> -> a case dir holding an empty fakebin and a throwaway HOME.
new_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/fakebin" "$dir/home"
  printf '%s\n' "$dir"
}

# run_launcher <case-dir> <launcher-args...>: stdout+stderr, launcher's status.
run_launcher() {
  local dir=$1
  shift
  env -i HOME="$dir/home" PATH="$dir/fakebin:$BASH_DIR:/usr/bin:/bin" \
    FM_FAKE_CLAUDE_ENV_LOG="$dir/claude-env" \
    FM_FAKE_TEAMCLAUDE_STATUS="${FM_FAKE_TEAMCLAUDE_STATUS:-0}" \
    "$LAUNCHER" "$@" </dev/null 2>&1
}

# run_launcher_with_ambient_proxy <case-dir> <launcher-args...>: run_launcher,
# plus the caller's HTTPS_PROXY already in the launcher's environment.
run_launcher_with_ambient_proxy() {
  local dir=$1
  shift
  env -i HOME="$dir/home" PATH="$dir/fakebin:$BASH_DIR:/usr/bin:/bin" \
    HTTPS_PROXY="$HTTPS_PROXY" FM_FAKE_CLAUDE_ENV_LOG="$dir/claude-env" \
    "$LAUNCHER" "$@" </dev/null 2>&1
}

# The spawn's TeamClaude configuration paths reach the launcher's teamclaude
# calls under private names and never reach claude.
test_config_paths_reach_teamclaude_but_not_claude() {
  local dir out rc
  dir=$(new_case config-paths)
  fm_test_fake_teamclaude "$dir/fakebin"
  out=$(env -i HOME="$dir/home" PATH="$dir/fakebin:$BASH_DIR:/usr/bin:/bin" \
    FM_FAKE_CLAUDE_ENV_LOG="$dir/claude-env" FM_FAKE_TEAMCLAUDE_ENV_LOG="$dir/teamclaude-env" \
    FM_TC_XDG_CONFIG_HOME="$dir/xdg" FM_TC_TEAMCLAUDE_CONFIG="$dir/teamclaude.json" \
    "$LAUNCHER" --version </dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "a launch with TeamClaude configuration paths should start claude"$'\n'"$out"
  grep -Fqx "XDG_CONFIG_HOME=$dir/xdg" "$dir/teamclaude-env" \
    || fail "teamclaude must read the spawn's XDG_CONFIG_HOME"
  grep -Fqx "TEAMCLAUDE_CONFIG=$dir/teamclaude.json" "$dir/teamclaude-env" \
    || fail "teamclaude must read the spawn's TEAMCLAUDE_CONFIG"
  grep -Fqx "HTTPS_PROXY=$FM_TEST_TEAMCLAUDE_PROXY" "$dir/claude-env" \
    || fail "claude must still receive the TeamClaude proxy"
  ! grep -Eq '^(XDG_CONFIG_HOME|TEAMCLAUDE_CONFIG|FM_TC_[A-Z_]+)=' "$dir/claude-env" \
    || fail "claude must not receive the TeamClaude configuration paths: $(cat "$dir/claude-env")"
  pass "TeamClaude configuration paths reach only the launcher's teamclaude calls, never claude"
}

test_claude_receives_the_teamclaude_client_environment() {
  local dir out rc
  dir=$(new_case proxied)
  fm_test_fake_teamclaude "$dir/fakebin"
  cat > "$dir/fakebin/claude" <<'SH'
#!/usr/bin/env bash
env > "$FM_FAKE_CLAUDE_ENV_LOG"
printf '%s\n' "$@" > "$FM_FAKE_CLAUDE_ENV_LOG.args"
SH
  out=$(run_launcher "$dir" --dangerously-skip-permissions --settings '{"a": 1}' 'brief text'); rc=$?
  expect_code 0 "$rc" "a live proxy should start claude"$'\n'"$out"
  assert_grep "HTTPS_PROXY=$FM_TEST_TEAMCLAUDE_PROXY" "$dir/claude-env" \
    "claude must receive HTTPS_PROXY from teamclaude env"
  assert_grep "NODE_EXTRA_CA_CERTS=$FM_TEST_TEAMCLAUDE_CA" "$dir/claude-env" \
    "claude must receive the TeamClaude CA from teamclaude env"
  [ "$(cat "$dir/claude-env.args")" = "$(printf '%s\n' --dangerously-skip-permissions --settings '{"a": 1}' 'brief text')" ] \
    || fail "claude must receive the launch arguments unchanged: $(cat "$dir/claude-env.args")"
  pass "a live TeamClaude proxy hands claude its HTTPS_PROXY and CA, with arguments unchanged"
}

test_stopped_proxy_refuses_without_starting_claude() {
  local dir out rc
  dir=$(new_case stopped)
  fm_test_fake_teamclaude "$dir/fakebin"
  out=$(FM_FAKE_TEAMCLAUDE_STATUS=1 run_launcher "$dir" --version); rc=$?
  expect_code 1 "$rc" "a stopped proxy must refuse"
  assert_contains "$out" "proxy is not running" "the refusal must name the stopped proxy"
  assert_contains "$out" "refusing to launch Claude without it" "the refusal must say claude was not started"
  assert_absent "$dir/claude-env" "a stopped proxy must not start claude"
  pass "a stopped TeamClaude proxy refuses without starting claude"
}

# A loaded host answers `teamclaude status` slowly; a live proxy that takes
# longer than a moment must still start claude rather than read as stopped.
test_slow_status_still_starts_claude() {
  local dir out rc
  dir=$(new_case slow-status)
  fm_test_fake_teamclaude "$dir/fakebin"
  mv "$dir/fakebin/teamclaude" "$dir/fakebin/teamclaude-fast"
  cat > "$dir/fakebin/teamclaude" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != status ] || /bin/sleep 12
exec "$dir/fakebin/teamclaude-fast" "\$@"
SH
  chmod +x "$dir/fakebin/teamclaude"
  out=$(run_launcher "$dir" --version); rc=$?
  expect_code 0 "$rc" "a slow but live proxy should start claude"$'\n'"$out"
  assert_grep "HTTPS_PROXY=$FM_TEST_TEAMCLAUDE_PROXY" "$dir/claude-env" \
    "claude must receive HTTPS_PROXY after a slow status check"
  pass "a live TeamClaude proxy that answers status slowly still starts claude"
}

test_missing_teamclaude_refuses_without_starting_claude() {
  local dir out rc
  dir=$(new_case missing)
  fm_test_fake_teamclaude "$dir/fakebin"
  rm "$dir/fakebin/teamclaude"
  out=$(run_launcher "$dir" --version); rc=$?
  expect_code 1 "$rc" "a missing teamclaude must refuse"
  assert_contains "$out" "TeamClaude is not installed" "the refusal must name the missing launcher"
  assert_absent "$dir/claude-env" "a missing teamclaude must not start claude"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/teamclaude"
  chmod -x "$dir/fakebin/teamclaude"
  out=$(run_launcher "$dir" --version); rc=$?
  expect_code 1 "$rc" "a non-executable teamclaude must refuse"
  assert_contains "$out" "TeamClaude is not installed" "the refusal must name the unusable launcher"
  assert_absent "$dir/claude-env" "a non-executable teamclaude must not start claude"
  pass "a missing or non-executable teamclaude refuses without starting claude"
}

test_export_without_a_proxy_setting_refuses() {
  local dir out rc
  dir=$(new_case no-proxy)
  fm_test_fake_teamclaude "$dir/fakebin"
  # shellcheck disable=SC2016 # The fake script body expands at its own run time.
  printf '#!/usr/bin/env bash\n[ "$1" = status ] && exit 0\nprintf "export API_TIMEOUT_MS=1\\n"\n' \
    > "$dir/fakebin/teamclaude"
  out=$(run_launcher "$dir" --version); rc=$?
  expect_code 1 "$rc" "an export with no proxy setting must refuse"
  assert_contains "$out" "did not set HTTPS_PROXY" "the refusal must name the missing proxy"
  assert_absent "$dir/claude-env" "an unrouted export must not start claude"

  # shellcheck disable=SC2016 # The fake script body expands at its own run time.
  printf '#!/usr/bin/env bash\n[ "$1" = status ] && exit 0\nprintf "export ANTHROPIC_BASE_URL=http://127.0.0.1:13456\\n"\n' \
    > "$dir/fakebin/teamclaude"
  out=$(run_launcher "$dir" --version); rc=$?
  expect_code 1 "$rc" "a base-URL export with no HTTPS_PROXY must refuse"
  assert_contains "$out" "did not set HTTPS_PROXY" "the refusal must name the missing proxy"
  assert_absent "$dir/claude-env" "a base-URL export must not start claude"

  out=$(HTTPS_PROXY=http://127.0.0.1:9 run_launcher_with_ambient_proxy "$dir" --version); rc=$?
  expect_code 1 "$rc" "an ambient HTTPS_PROXY must not stand in for the TeamClaude export"
  assert_absent "$dir/claude-env" "an ambient HTTPS_PROXY must not start claude"

  # shellcheck disable=SC2016 # The fake script body expands at its own run time.
  printf '#!/usr/bin/env bash\n[ "$1" = status ] && exit 0\nexit 1\n' > "$dir/fakebin/teamclaude"
  out=$(run_launcher "$dir" --version); rc=$?
  expect_code 1 "$rc" "a failed export must refuse"
  assert_contains "$out" "teamclaude env failed" "the refusal must name the failed export"
  assert_absent "$dir/claude-env" "a failed export must not start claude"
  pass "a TeamClaude export that fails or sets no HTTPS_PROXY refuses without starting claude"
}

# An nvm install is found without PATH, and its `#!/usr/bin/env node` script
# reaches the node installed beside it: the fake node here exists only there.
test_nvm_install_is_found_and_runs_with_its_own_node() {
  local dir bin out rc
  dir=$(new_case nvm)
  fm_test_fake_teamclaude "$dir/fakebin"
  bin="$dir/home/.nvm/versions/node/v1.0.0/bin"
  mkdir -p "$bin"
  { printf '#!/usr/bin/env node\n'; tail -n +2 "$dir/fakebin/teamclaude"; } > "$bin/teamclaude"
  printf '#!/usr/bin/env bash\nexec bash "$@"\n' > "$bin/node"
  chmod +x "$bin/teamclaude" "$bin/node"
  rm "$dir/fakebin/teamclaude"
  out=$(run_launcher "$dir" --version); rc=$?
  expect_code 0 "$rc" "a single nvm install should start claude"$'\n'"$out"
  assert_grep "HTTPS_PROXY=$FM_TEST_TEAMCLAUDE_PROXY" "$dir/claude-env" \
    "claude must receive HTTPS_PROXY through the nvm install"

  mkdir -p "$dir/home/.nvm/versions/node/v2.0.0/bin"
  cp "$bin/teamclaude" "$bin/node" "$dir/home/.nvm/versions/node/v2.0.0/bin/"
  rm -f "$dir/claude-env"
  out=$(run_launcher "$dir" --version); rc=$?
  expect_code 1 "$rc" "two nvm installs must refuse"
  assert_contains "$out" "TeamClaude is ambiguous" "the refusal must name the ambiguity"
  assert_absent "$dir/claude-env" "an ambiguous launcher must not start claude"
  pass "one nvm-installed teamclaude runs with its own node; two refuse as ambiguous"
}

test_exec_runs_the_given_command_with_the_proxy() {
  local dir out rc
  dir=$(new_case exec)
  fm_test_fake_teamclaude "$dir/fakebin"
  out=$(run_launcher "$dir" --exec /bin/sh -c 'claude --model opus'); rc=$?
  expect_code 0 "$rc" "--exec should run the given command against a live proxy"$'\n'"$out"
  grep -Fqx "HTTPS_PROXY=$FM_TEST_TEAMCLAUDE_PROXY" "$dir/claude-env" \
    || fail "the --exec command must receive HTTPS_PROXY from teamclaude env"
  [ "$(cat "$dir/claude-env.args")" = "$(printf '%s\n' --model opus)" ] \
    || fail "the --exec command must run with its own arguments: $(cat "$dir/claude-env.args")"
  rm -f "$dir/claude-env" "$dir/claude-env.args"
  out=$(FM_FAKE_TEAMCLAUDE_STATUS=1 run_launcher "$dir" --exec /bin/sh -c 'claude --model opus'); rc=$?
  expect_code 1 "$rc" "--exec must refuse against a stopped proxy"
  assert_absent "$dir/claude-env" "a refused --exec must not run its command"
  out=$(run_launcher "$dir" --exec); rc=$?
  expect_code 1 "$rc" "--exec with no command must refuse"
  assert_absent "$dir/claude-env" "an empty --exec must not start claude"
  pass "--exec runs the given command unchanged with the TeamClaude proxy, and refuses without one"
}

test_check_validates_without_starting_claude() {
  local dir out rc
  dir=$(new_case check)
  fm_test_fake_teamclaude "$dir/fakebin"
  out=$(run_launcher "$dir" --check); rc=$?
  expect_code 0 "$rc" "--check should pass against a live proxy"$'\n'"$out"
  assert_absent "$dir/claude-env" "--check must not start claude"
  out=$(FM_FAKE_TEAMCLAUDE_STATUS=1 run_launcher "$dir" --check); rc=$?
  expect_code 1 "$rc" "--check must fail against a stopped proxy"
  out=$(run_launcher "$dir" --check --version); rc=$?
  expect_code 1 "$rc" "--check must refuse claude arguments"
  assert_absent "$dir/claude-env" "a refused --check must not start claude"
  pass "--check validates the proxy without starting claude"
}

test_claude_receives_the_teamclaude_client_environment
test_stopped_proxy_refuses_without_starting_claude
test_missing_teamclaude_refuses_without_starting_claude
test_export_without_a_proxy_setting_refuses
test_nvm_install_is_found_and_runs_with_its_own_node
test_check_validates_without_starting_claude
test_exec_runs_the_given_command_with_the_proxy
test_config_paths_reach_teamclaude_but_not_claude
test_slow_status_still_starts_claude

echo "# all fm-teamclaude-launch tests passed"
