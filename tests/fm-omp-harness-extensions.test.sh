#!/usr/bin/env bash
# tests/fm-omp-harness-extensions.test.sh - omp harness regressions (busy extension, composer tables, and turn-end guard).
set -u

# shellcheck source=tests/fm-omp-harness-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-omp-harness-helpers.sh"

# omp's default role lives in one global file that every interactive omp session
# can rewrite. A launch with no --model reads it, and a missing or unlisted role
# makes omp silently pick the first credentialed model (a free-tier model that
# answers HTTP 429). The launch must refuse with the remedy instead.
test_spawn_refuses_a_missing_or_unlisted_default_role() {
  local rec id out status
  rec=$(make_spawn_case role-missing omp omp-role-missing-q5)
  read_case_record "$rec"
  id='omp-role-missing-q5'
  printf 'modelRoles:\n  advisor: openai-codex/gpt-6-astra:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "an omp launch with no model and no default role must refuse: $out"
  assert_contains "$out" "omp modelRoles.default is not set in the shared omp config" "refusal did not name the missing role"
  assert_contains "$out" "pass --model <provider>/<id>" "refusal did not carry the remedy"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must record no launch: $(cat "$LAUNCH_LOG")"

  rec=$(make_spawn_case role-unlisted omp omp-role-unlisted-q6)
  read_case_record "$rec"
  id='omp-role-unlisted-q6'
  printf 'modelRoles:\n  default: openai-codex/gpt-gone:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "a default role naming an unlisted id must refuse: $out"
  assert_contains "$out" "omp modelRoles.default 'openai-codex/gpt-gone:high' is not listed by 'omp models --json' although provider 'openai-codex' is" "refusal did not name the unresolvable role"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"

  rec=$(make_spawn_case role-listed omp omp-role-listed-q7)
  read_case_record "$rec"
  id='omp-role-listed-q7'
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "a listed default role (thinking suffix included) must launch: $out"

  rec=$(make_spawn_case role-pinned omp omp-role-pinned-q8)
  read_case_record "$rec"
  id='omp-role-pinned-q8'
  printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-astra)
  status=$?
  expect_code 0 "$status" "a launch that passes --model never reads the default role: $out"

  rec=$(make_spawn_case role-bridge omp omp-role-bridge-q10)
  read_case_record "$rec"
  id='omp-role-bridge-q10'
  printf 'modelRoles:\n  default: claude-bridge/claude-opus-4-8:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "an unknown default-role provider must pass through: $out"
  assert_contains "$out" "notice: omp provider 'claude-bridge' is not in 'omp models --json'" "default-role pass-through did not state its reason"
  assert_contains "$out" "launching 'claude-bridge/claude-opus-4-8:high' unvalidated" "notice did not identify the default role"
  assert_present "$HOME_DIR/state/$id.meta" "default-role pass-through must publish the task"

  rec=$(make_spawn_case role-unreadable omp omp-role-unreadable-q9)
  read_case_record "$rec"
  id='omp-role-unreadable-q9'
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "an unreadable roles config establishes nothing and must launch: $out"
  pass "fm-spawn: an omp launch with no model refuses a missing or unlisted default role and names the remedy"
}

test_spawn_global_config_is_read_only_and_unlayered() {
  local rec id out status agent_dir
  id='omp-role-project-q11'
  rec=$(make_spawn_case role-project omp "$id")
  read_case_record "$rec"
  printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
  mkdir -p "$PROJ_DIR/.omp"
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$PROJ_DIR/.omp/config.yml"
  out=$(cd "$PROJ_DIR" && run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "a project-layer default must not mask a missing global default: $out"
  assert_contains "$out" "omp modelRoles.default is not set in the shared omp config" "project-layer refusal did not identify the missing global role"
  assert_contains "$out" "pass --model <provider>/<id> (or a dispatch profile) so this launch stops depending on the shared default, or restore the Default role in omp with /model" "project-layer refusal lost the exact remedy"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused project-layer spawn must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused project-layer spawn must record no launch"

  id='omp-role-malformed-q12'
  rec=$(make_spawn_case role-malformed omp "$id")
  read_case_record "$rec"
  printf 'modelRoles:\n  default: [unterminated\n' > "$GLOBAL_CONFIG"
  cp "$GLOBAL_CONFIG" "$CASE_DIR/original-config.yml"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "a malformed global config establishes nothing and must pass through: $out"
  cmp -s "$CASE_DIR/original-config.yml" "$GLOBAL_CONFIG" || fail "the malformed global config must remain byte-identical"
  for out in "$GLOBAL_CONFIG".broken-*; do
    assert_absent "$out" "the global config must not be quarantined"
  done
  assert_present "$HOME_DIR/state/$id.meta" "malformed-config pass-through must publish the task"
  assert_launch_contains "$(cat "$LAUNCH_LOG")" "'$FAKEBIN_DIR/omp'" "malformed-config pass-through must reach the launch"

  id='omp-role-agent-dir-q13'
  rec=$(make_spawn_case role-agent-dir omp "$id")
  read_case_record "$rec"
  printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
  agent_dir="$CASE_DIR/custom-agent"
  mkdir -p "$agent_dir"
  printf 'modelRoles:\n  default: ollama/qwen3:8b:max\n' > "$agent_dir/config.yml"
  printf 'FM_FAKE_OMP_ENV_LOG\n' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(PI_CODING_AGENT_DIR="$agent_dir" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
    run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "the selected agent dir must supply the global default, preserving model-id colons: $out"
  assert_present "$HOME_DIR/state/$id.meta" "a listed agent-dir default must publish the task"
  fm_fake_config "$FAKEBIN_DIR" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log"
  HOME="$HOME_DIR/user-home" PI_CODING_AGENT_DIR="$CASE_DIR/pane-agent" \
    PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
    bash "$LAUNCH_LOG" > "$CASE_DIR/pane-output.log" 2>&1
  status=$?
  expect_code 0 "$status" "the canonical launch must execute in a pane with a different agent directory"
  assert_grep "models:$agent_dir" "$CASE_DIR/omp-env.log" "catalog inspection must use the canonical launch directory"
  assert_grep "--config:$agent_dir" "$CASE_DIR/omp-env.log" "the launched omp must receive the checked directory despite pane inheritance and filtering"

  id='omp-role-agent-dir-missing-q14'
  rec=$(make_spawn_case role-agent-dir-missing omp "$id")
  read_case_record "$rec"
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$GLOBAL_CONFIG"
  agent_dir="$CASE_DIR/custom-agent"
  mkdir -p "$agent_dir"
  printf '{}\n' > "$agent_dir/config.yml"
  out=$(PI_CODING_AGENT_DIR="$agent_dir" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "the HOME default must not mask a missing default in the selected agent dir: $out"
  assert_contains "$out" "omp modelRoles.default is not set" "agent-dir refusal did not identify the missing role"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused agent-dir spawn must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused agent-dir spawn must record no launch"
  pass "fm-spawn: global role inspection is read-only, unlayered, and honors PI_CODING_AGENT_DIR"
}

test_spawn_raw_omp_guard_uses_the_launch_agent_dir() {
  local rec id out status caller_dir launch_dir mode command
  for mode in missing listed unlisted uncertain stderr stdin append descriptor; do
    id="omp-raw-agent-$mode"
    rec=$(make_spawn_case "raw-agent-$mode" omp "$id")
    read_case_record "$rec"
    caller_dir="$CASE_DIR/caller-agent"
    launch_dir="$CASE_DIR/launch-agent"
    mkdir -p "$caller_dir" "$launch_dir"
    printf 'modelRoles:\n  default: openai-codex/gpt-6-astra\n' > "$caller_dir/config.yml"
    printf 'modelRoles: {}\n' > "$launch_dir/config.yml"
    case "$mode" in
      listed)
        printf 'modelRoles: {}\n' > "$caller_dir/config.yml"
        printf 'modelRoles:\n  default: openai-codex/gpt-6-astra\n' > "$launch_dir/config.yml"
        ;;
      unlisted)
        printf 'modelRoles:\n  default: openai-codex/gpt-6-astra\n' > "$launch_dir/config.yml"
        printf '%s\n' '{"models":[{"provider":"openai-codex","id":"other","selector":"openai-codex/other"}]}' > "$launch_dir/catalog.json"
        ;;
      uncertain)
        printf 'modelRoles: {}\n' > "$caller_dir/config.yml"
        ;;
    esac
    command="PI_CODING_AGENT_DIR='$launch_dir' omp --auto-approve"
    # shellcheck disable=SC2016 # The pane expands this variable when executing the raw command.
    [ "$mode" != uncertain ] || command='PI_CODING_AGENT_DIR="$PANE_AGENT_DIR" omp --auto-approve'
    # A raw command runs inside the launch boundary, so a pane variable it
    # expands must be listed.
    [ "$mode" != uncertain ] || printf 'PANE_AGENT_DIR\n' > "$HOME_DIR/config/launch-env-allowlist"
    case "$mode" in
      stderr) command="$command 2>'$CASE_DIR/errors.log'" ;;
      stdin) command="$command <'$launch_dir/config.yml'" ;;
      append) command="$command >>'$CASE_DIR/output.log'" ;;
      descriptor) command="$command 2>&1" ;;
    esac
    out=$(PI_CODING_AGENT_DIR="$caller_dir" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
      run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$command")
    status=$?
    # Decision R7-4 (2026-10-25): a confined macOS launch follows only a literal
    # raw root, and the spawn sees "$PANE_AGENT_DIR" unexpanded, so it refuses
    # and names the variable instead of granting a root it cannot know.
    if [ "$mode" = uncertain ] && [ "$(uname -s)" = Darwin ]; then
      expect_code 1 "$status" "a confined raw omp launch must refuse a root that needs shell expansion: $out"
      assert_contains "$out" "sets PI_CODING_AGENT_DIR to a value that needs shell expansion" "the refusal must name the variable"
      assert_contains "$out" "pass the resolved absolute path" "the refusal must say how to proceed"
      assert_absent "$HOME_DIR/state/$id.meta" "a refused raw-directory launch must publish no record"
      continue
    fi
    case "$mode" in
      missing | unlisted | stderr | stdin | append | descriptor)
        expect_code 1 "$status" "raw omp must refuse the launch directory's invalid role ($mode): $out"
        assert_absent "$HOME_DIR/state/$id.meta" "a refused raw-directory launch must publish no record"
        [ ! -s "$LAUNCH_LOG" ] || fail "a refused raw-directory launch must record no launch"
        if [ "$mode" != unlisted ]; then
          assert_contains "$out" "omp modelRoles.default is not set" "raw assignment must not read the caller's listed role"
        else
          assert_contains "$out" "is not listed by 'omp models --json'" "raw catalog must use the launch directory"
          assert_grep "models:$launch_dir" "$CASE_DIR/omp-env.log" "raw catalog must receive the launch directory"
        fi
        ;;
      listed | uncertain)
        expect_code 0 "$status" "raw omp must launch with a listed or uncertain directory ($mode): $out"
        fm_fake_config "$FAKEBIN_DIR" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log"
        HOME="$HOME_DIR/user-home" PI_CODING_AGENT_DIR="$caller_dir" PANE_AGENT_DIR="$launch_dir" \
          PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
          bash "$LAUNCH_LOG" > "$CASE_DIR/pane-output.log" 2>&1
        status=$?
        expect_code 0 "$status" "the raw command must execute unchanged"
        assert_grep "--auto-approve:$launch_dir" "$CASE_DIR/omp-env.log" "raw omp must receive its assignment rather than the caller directory"
        if [ "$mode" = listed ]; then
          assert_grep "models:$launch_dir" "$CASE_DIR/omp-env.log" "the role and catalog must inspect the same directory"
        else
          ! grep -q '^models:' "$CASE_DIR/omp-env.log" || fail "uncertain directory must establish no catalog evidence"
        fi
        ;;
    esac
  done
  pass "fm-spawn: raw role and catalog inspection honor the actual launch directory and uncertain evidence passes through"
}

test_spawn_omp_profiles_leave_directory_evidence_unreadable() {
  local rec id out status mode role command first_arg omp_profile pi_profile launch_dir
  local spawn_args=()
  for mode in flag flag-equals assignment-omp assignment-pi env-omp env-pi raw-env-omp raw-env-pi; do
    for role in missing unlisted; do
      id="omp-profile-$mode-$role"
      rec=$(make_spawn_case "profile-$mode-$role" omp "$id")
      read_case_record "$rec"
      launch_dir="$CASE_DIR/launch-agent"
      mkdir -p "$launch_dir"
      if [ "$role" = missing ]; then
        printf 'modelRoles: {}\n' > "$launch_dir/config.yml"
      else
        printf 'modelRoles:\n  default: openai-codex/gpt-gone\n' > "$launch_dir/config.yml"
      fi
      omp_profile='' pi_profile=''
      command="PI_CODING_AGENT_DIR='$launch_dir' omp --auto-approve"
      first_arg=--auto-approve
      case "$mode" in
        flag) command="$command --profile work" ;;
        flag-equals) command="$command --profile=work" ;;
        assignment-omp) command="OMP_PROFILE=work $command" ;;
        assignment-pi) command="PI_PROFILE=work $command" ;;
        env-omp | raw-env-omp) omp_profile=work ;;
        env-pi | raw-env-pi) pi_profile=work ;;
      esac
      spawn_args=("$command")
      case "$mode" in
        env-omp | env-pi)
          spawn_args=(--harness omp)
          first_arg=--config
          ;;
      esac
      out=$(OMP_PROFILE="$omp_profile" PI_PROFILE="$pi_profile" PI_CODING_AGENT_DIR="$launch_dir" \
        FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "${spawn_args[@]}")
      status=$?
      # Decision R8-1 (2026-10-25): a confined macOS launch refuses every raw
      # omp profile selector and points to the supported --harness omp route.
      case "$mode" in
        flag | flag-equals | assignment-omp | assignment-pi)
          if [ "$(uname -s)" = Darwin ]; then
            expect_code 1 "$status" "a confined raw omp launch must refuse its own profile selector ($mode): $out"
            assert_contains "$out" "selects its own omp profile" "the refusal must name the profile selector ($mode)"
            assert_contains "$out" "launch the profile through --harness omp" "the refusal must name the supported route ($mode)"
            assert_absent "$HOME_DIR/state/$id.meta" "a refused profile-selecting launch must publish no record"
            continue
          fi
          ;;
      esac
      expect_code 0 "$status" "profile selection must pass through an unrelated $role default ($mode): $out"
      assert_present "$HOME_DIR/state/$id.meta" "a profile-selecting launch must publish the task"
      ! grep -q '^models:' "$CASE_DIR/omp-env.log" 2>/dev/null || fail "profile selection must establish no catalog evidence"
      case "$mode" in
        env-omp | env-pi) ;;
        *) assert_launch_contains "$(cat "$LAUNCH_LOG")" "$command" "the raw profile-selecting command must reach the launch unchanged" ;;
      esac
      fm_fake_config "$FAKEBIN_DIR" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log"
      HOME="$HOME_DIR/user-home" PI_CODING_AGENT_DIR="$launch_dir" \
        OMP_PROFILE="$omp_profile" PI_PROFILE="$pi_profile" \
        PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        bash "$LAUNCH_LOG" > "$CASE_DIR/pane-output.log" 2>&1
      status=$?
      expect_code 0 "$status" "the profile-selecting launch must execute ($mode)"
      assert_grep "$first_arg:$launch_dir" "$CASE_DIR/omp-env.log" "profile selection must still launch omp ($mode)"
    done
  done
  pass "fm-spawn: omp profile flags, assignments, and invoking environment pass through without default-role catalog probes"
}

test_spawn_raw_omp_expansions_pass_through_unchanged() {
  local rec id out status mode role command launch_dir first_arg pane_home
  for mode in profile after-delimiter substitution backticks redirect glob long-glob tilde tilde-redirection tilde-user tilde-assignment process ansi locale braces heredoc punctuation; do
    for role in missing unlisted; do
      id="omp-expansion-$mode-$role"
      rec=$(make_spawn_case "expansion-$mode-$role" omp "$id")
      read_case_record "$rec"
      launch_dir=$(dirname "$GLOBAL_CONFIG")
      if [ "$role" = missing ]; then
        printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
      else
        printf 'modelRoles:\n  default: openai-codex/gpt-gone\n' > "$GLOBAL_CONFIG"
      fi
      command="PI_CODING_AGENT_DIR='$launch_dir' omp"
      first_arg=--auto-approve
      case "$mode" in
        profile)
          command="$command \"\$PROFILE_FLAG\" --auto-approve"
          first_arg=--profile=work
          ;;
        after-delimiter) command="$command --auto-approve -- \"\$PROFILE_FLAG\"" ;;
        substitution)
          command="$command \"\$(printf evaluated > '$CASE_DIR/expanded'; printf %s --profile=work)\" --auto-approve"
          first_arg=--profile=work
          ;;
        backticks)
          command="$command \"\`printf evaluated > '$CASE_DIR/expanded'; printf %s --profile=work\`\" --auto-approve"
          first_arg=--profile=work
          ;;
        redirect) command="$command --auto-approve 2>\"\$ERROR_LOG\"" ;;
        glob)
          printf 'input\n' > "$CASE_DIR/input.txt"
          command="$command --auto-approve '$CASE_DIR'/*.txt"
          ;;
        long-glob)
          command="$command --auto-approve /work/vernant/generated/reports/abcdefghijklmnopqrstuvwxyz0123456789/input*.txt"
          {
            printf '#!/usr/bin/env bash\n. %q\n' "$ROOT/bin/fm-timeout-lib.sh"
            printf 'exec 3<&0\nfm_run_timed 3 bash -c '\''exec "$@" <&3'\'' _ %q "$@"\n' "$(command -v node)"
            # shellcheck disable=SC2016 # Capture status in the generated wrapper, not while generating it.
            printf 'status=$?\n'
            # shellcheck disable=SC2016 # The generated wrapper evaluates its own status.
            printf 'if fm_timed_out "$status"; then printf timeout > %q; fi\nexit "$status"\n' "$CASE_DIR/node-timeout"
          } > "$FAKEBIN_DIR/node"
          chmod +x "$FAKEBIN_DIR/node"
          ;;
        tilde) command="$command --auto-approve ~/input.txt" ;;
        tilde-redirection) command="$command --auto-approve 2>~/omp-errors.log" ;;
        tilde-user) command="$command --auto-approve ~root/input.txt" ;;
        tilde-assignment) command="EXTRA_DIR=~ $command --auto-approve" ;;
        process) command="$command --auto-approve <(printf input)" ;;
        ansi) command="$command --auto-approve \$'input'" ;;
        locale) command="$command --auto-approve \$\"input\"" ;;
        braces) command="$command --auto-approve {a,b}" ;;
        heredoc) command="$command --auto-approve <<'EOF'
input
EOF" ;;
        punctuation) command="$command --auto-approve input!" ;;
      esac
      # A raw command runs inside the launch boundary, so a pane variable it
      # expands must be listed.
      case "$mode" in
        profile | after-delimiter | redirect)
          printf '%s\n' PROFILE_FLAG ERROR_LOG > "$HOME_DIR/config/launch-env-allowlist"
          ;;
      esac
      out=$(FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$command")
      status=$?
      # Decision R8-1 (2026-10-25): a confined macOS launch refuses every raw
      # omp profile selector, including one inside a substitution, and never
      # evaluates it.
      case "$mode" in
        substitution | backticks)
          if [ "$(uname -s)" = Darwin ]; then
            expect_code 1 "$status" "a confined raw omp launch must refuse a profile selector in an expansion ($mode): $out"
            assert_contains "$out" "launch the profile through --harness omp" "the refusal must name the supported route ($mode)"
            assert_absent "$CASE_DIR/expanded" "the refusal must not evaluate the command substitution ($mode)"
            assert_absent "$HOME_DIR/state/$id.meta" "a refused expanded launch must publish no record"
            continue
          fi
          ;;
      esac
      assert_absent "$CASE_DIR/node-timeout" "a long literal prefix ending in a glob must classify within three seconds"
      expect_code 0 "$status" "a raw shell expansion must pass through the $role role ($mode): $out"
      assert_present "$HOME_DIR/state/$id.meta" "expanded raw launch must publish the task"
      ! grep -q '^models:' "$CASE_DIR/omp-env.log" 2>/dev/null || fail "expanded raw launch must establish no catalog evidence"
      assert_absent "$CASE_DIR/expanded" "validation must not evaluate command substitutions"
      assert_absent "$CASE_DIR/errors.log" "validation must not evaluate redirections"
      assert_launch_contains "$(cat "$LAUNCH_LOG")" "$command" "expanded raw command must reach the launch unchanged"
      # This fixture nests user-home inside the firstmate home, which macOS
      # write confinement protects; the tilde redirection writes to a home
      # outside it, as a real user home is.
      pane_home="$HOME_DIR/user-home"
      if [ "$mode" = tilde-redirection ]; then
        pane_home="$CASE_DIR/pane-home"
        mkdir -p "$pane_home"
      fi
      fm_fake_config "$FAKEBIN_DIR" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log"
      HOME="$pane_home" PROFILE_FLAG=--profile=work ERROR_LOG="$CASE_DIR/errors.log" \
        PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        bash "$LAUNCH_LOG" > "$CASE_DIR/pane-output.log" 2>&1
      status=$?
      expect_code 0 "$status" "expanded raw command must execute in the pane ($mode)"
      assert_grep "$first_arg:$launch_dir" "$CASE_DIR/omp-env.log" "expanded raw command must launch omp in its assigned directory"
      case "$mode" in
        substitution | backticks)
          [ "$(cat "$CASE_DIR/expanded")" = evaluated ] || fail "the pane must evaluate the command substitution"
          ;;
        redirect) assert_present "$CASE_DIR/errors.log" "the pane must evaluate the redirection" ;;
        tilde-redirection) assert_present "$pane_home/omp-errors.log" "the pane must expand the tilde redirection" ;;
      esac
    done
  done
  pass "fm-spawn: any expanded raw token passes through unchanged without evaluating it or probing the default-role catalog"
}

test_spawn_raw_omp_literal_evidence_still_refuses() {
  local rec id out status quoting role command launch_dir
  for quoting in unquoted single double; do
    for role in missing unlisted; do
      id="omp-literal-$quoting-$role"
      rec=$(make_spawn_case "literal-$quoting-$role" omp "$id")
      read_case_record "$rec"
      launch_dir=$(dirname "$GLOBAL_CONFIG")
      if [ "$role" = missing ]; then
        printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
      else
        printf 'modelRoles:\n  default: openai-codex/gpt-gone\n' > "$GLOBAL_CONFIG"
      fi
      case "$quoting" in
        unquoted) command="PI_CODING_AGENT_DIR=$launch_dir omp --auto-approve 2>$CASE_DIR/errors.log" ;;
        single) command="PI_CODING_AGENT_DIR='$launch_dir' omp '--auto-approve' 'literal ~ \$ value' 2>'$CASE_DIR/errors.log'" ;;
        double) command="PI_CODING_AGENT_DIR=\"$launch_dir\" omp \"--auto-approve\" \"literal ~ value\" 2>\"$CASE_DIR/errors.log\"" ;;
      esac
      out=$(FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$command")
      status=$?
      expect_code 1 "$status" "literal-only raw command must refuse the $role role ($quoting): $out"
      assert_contains "$out" "error: omp modelRoles.default" "literal evidence must reach the default-role guard"
      assert_absent "$HOME_DIR/state/$id.meta" "a refused literal launch must publish no record"
      [ ! -s "$LAUNCH_LOG" ] || fail "a refused literal launch must record no command"
      assert_absent "$CASE_DIR/errors.log" "validation must not execute a literal redirection"
      if [ "$role" = unlisted ]; then
        assert_grep "models:$launch_dir" "$CASE_DIR/omp-env.log" "literal evidence must probe the launch directory's catalog"
      else
        ! grep -q '^models:' "$CASE_DIR/omp-env.log" 2>/dev/null || fail "a missing literal default must refuse without a catalog probe"
      fi
    done
  done
  pass "fm-spawn: unquoted, single-quoted, and double-quoted literal evidence still refuses invalid defaults"
}

test_spawn_raw_omp_guard_uses_the_launch_model() {
  # Inline replacement quotes are removed by Bash 5.2; variable contents stay literal.
  local rec id out status command expected index=0 model_flag="--model 'openai-codex/gpt-6-astra' "
  local model_args=()
  while IFS='|' read -r command expected; do
    index=$((index + 1))
    id="omp-raw-role-$index"
    rec=$(make_spawn_case "raw-role-$index" omp "$id")
    read_case_record "$rec"
    printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
    model_args=()
    case "$command" in
      *'__MODELFLAG__'* | 'omp --auto-approve') model_args=(--model openai-codex/gpt-6-astra) ;;
    esac
    command="PI_CODING_AGENT_DIR='$(dirname "$GLOBAL_CONFIG")' $command"
    out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$command" ${model_args[@]+"${model_args[@]}"})
    status=$?
    expect_code "$expected" "$status" "raw omp guard must follow the effective model in '$command': $out"
    if [ "$expected" = 0 ]; then
      assert_present "$HOME_DIR/state/$id.meta" "a pinned raw launch must publish the task"
      assert_launch_contains "$(cat "$LAUNCH_LOG")" "${command//__MODELFLAG__/$model_flag}" "raw model selection did not reach the launch"
    else
      assert_contains "$out" "omp modelRoles.default is not set" "an unpinned raw launch must refuse the missing role"
      assert_absent "$HOME_DIR/state/$id.meta" "a refused raw launch must publish no record"
      [ ! -s "$LAUNCH_LOG" ] || fail "a refused raw launch must record no launch"
    fi
  done <<'CASES'
omp --model openai-codex/gpt-6-astra|0
omp --model='openai-codex/gpt-6-astra'|0
omp -m 'openai-codex/gpt-6-astra'|0
omp __MODELFLAG__|0
omp --model default|0
omp --auto-approve|1
omp -- '--model' 'openai-codex/gpt-6-astra'|1
omp '--model openai-codex/gpt-6-astra'|1
CASES
  pass "fm-spawn: raw omp launches validate the default only without an effective model override"
}

test_secondmate_launch_relies_on_discovery() {
  # A seeded secondmate home, launched for real through fm-spawn on omp: the
  # launch must carry the posture overlay and pin --cwd to the home. Its only
  # -e is the state-resident busy extension: omp auto-discovers the home's
  # tracked .omp/extensions, and a file named both ways loads twice.
  local world home fakebin launchlog out status launch
  world="$TMP_ROOT/secondmate"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  mkdir -p "$world/user-home/.omp/agent"
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$world/user-home/.omp/agent/config.yml"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  mkdir -p "$home/state"
  printf 'model=deepseek/deepseek-v4-pro\nerror=402 old run\n' > "$home/state/.omp-live-model"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  # FM_BACKEND=tmux pins the fake tmux even where the developer shell carries a
  # live Herdr environment; without it auto-detection would spawn a real pane.
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" HOME="$world/user-home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" omp --secondmate 2>&1)
  status=$?
  expect_code 0 "$status" "omp secondmate spawn should succeed: $out"
  assert_grep "harness=omp" "$world/home/state/sm.meta" "secondmate meta missing harness=omp"
  launch=$(cat "$launchlog")
  [ "$(printf '%s\n' "$launch" | grep -o ' -e ' | wc -l | tr -d ' ')" = 1 ] \
    || fail "an omp secondmate launch must name exactly one -e: omp auto-discovers .omp/extensions and a file named both ways loads twice: $launch"
  assert_launch_contains "$launch" "-e '$world/home/state/sm.omp-ext.ts'" "an omp secondmate launch must load the parent-home busy extension: $launch"
  assert_launch_contains "$launch" "--config '$ROOT/.omp/fm-session-overlay.yml' --auto-approve --cwd '$home'" "secondmate launch lost the posture overlay or the pinned home directory: $launch"
  assert_not_contains "$launch" "fm-worker-overlay.yml" "secondmate launch must preserve the lane's memory settings"
  assert_not_contains "$launch" "PI_EDIT_VARIANT" "an omp secondmate launch must not force the worker-only replace edit mode"
  assert_launch_contains "$launch" "FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$fakebin/omp'" "secondmate launch lost the omp marker or executable"
  assert_launch_contains "$launch" "FM_SUPERVISION_MODEL=extension" "an omp secondmate must run the extension supervision model"
  assert_present "$world/home/state/sm.omp-ext.ts" "a secondmate must receive the per-task busy extension"
  assert_absent "$home/state/.omp-live-model" "a secondmate launch must not keep its home's previous live-model record"
  pass "fm-spawn: a real omp secondmate launch loads only the busy -e and auto-discovers its primary extensions"
}

test_secondmate_config_pinned_model_is_validated() {
  # The same seeded secondmate home, but the harness and model come from the
  # primary's config/secondmate-harness rather than the command line: the
  # durable pin lands on MODEL after the harness case arm, so an unlisted id
  # under a listed provider must still be refused before endpoint creation.
  local world home fakebin launchlog out status
  world="$TMP_ROOT/secondmate-config-model"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  mkdir -p "$world/user-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  printf 'omp openai-codex/gpt-nope\n' > "$world/home/config/secondmate-harness"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" HOME="$world/user-home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" --secondmate 2>&1)
  status=$?
  expect_code 1 "$status" "a config-pinned unlisted omp model must refuse the secondmate spawn: $out"
  assert_contains "$out" "omp model 'openai-codex/gpt-nope' is not listed by 'omp models --json' although provider 'openai-codex' is" \
    "the refusal did not name the config-pinned model under its listed provider: $out"
  assert_absent "$world/home/state/sm.meta" "a refused secondmate spawn must publish no sm.meta"
  [ ! -s "$launchlog" ] || fail "a refused secondmate spawn must record no launch: $(cat "$launchlog")"
  pass "fm-spawn: the config/secondmate-harness model pin is validated against the omp catalog before launch"
}

test_secondmate_explicit_omp_deepseek_profile_is_refused() {
  # Explicit omp selections must refuse DeepSeek instead of silently
  # bypassing the model-family route, including secondmate configuration.
  local world home fakebin launchlog out status via
  local -a extra
  for via in config model; do
    extra=()
    [ "$via" != model ] || extra=(--model deepseek/deepseek-v4-flash)
    world="$TMP_ROOT/secondmate-deepseek-$via"
    home="$world/sm"
    mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data" "$world/user-home"
    printf '# Firstmate\n' > "$home/AGENTS.md"
    printf 'sm\n' > "$home/.fm-secondmate-home"
    printf 'charter\n' > "$home/data/charter.md"
    printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
    git -C "$home" init -q -b main
    fakebin=$(make_spawn_fakebin "$world/fake" claude)
    make_fake_omp "$fakebin"
    launchlog="$world/launch.log"
    : > "$launchlog"
    case "$via" in
      config) printf 'omp deepseek/deepseek-v4-flash\n' > "$world/home/config/secondmate-harness" ;;
      model) printf 'omp\n' > "$world/home/config/secondmate-harness" ;;
    esac
    out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
      FM_ROOT_OVERRIDE='' FM_HOME="$world/home" HOME="$world/user-home" \
      FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
      FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
      "$ROOT/bin/fm-spawn.sh" sm "$home" --secondmate ${extra[@]+"${extra[@]}"} 2>&1)
    status=$?
    expect_code 1 "$status" "a $via-selected DeepSeek secondmate must not fall back to omp: $out"
    assert_contains "$out" "DeepSeek runs through dsh-tui, not omp" "the refusal must name the adapter cutover"
    assert_absent "$world/home/state/sm.meta" "a refused DeepSeek secondmate must publish no metadata"
    [ ! -s "$launchlog" ] || fail "a refused DeepSeek secondmate must launch nothing"
  done
  pass "fm-spawn: contradictory omp DeepSeek secondmate profiles refuse before launch"
}

test_busy_extension_lifecycle() {
  local rec id=omp-busy-q5 out state ext
  rec=$(make_spawn_case busy omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  assert_present "$ext" "omp spawn did not write the per-task extension"
  out=$(drive_omp_ext "$ext" handlers) || fail "handler listing failed: $out"
  case " $out " in
    *" agent_settled "*) fail "the omp extension must not listen for agent_settled (omp has no such event)" ;;
    *" tool_result "*) fail "the omp extension must leave tool results unchanged, got '$out'" ;;
  esac
  for handler in agent_start agent_end turn_end tool_call retry_fallback_applied session_start; do
    case " $out " in
      *" $handler "*) ;;
      *) fail "the omp extension must register $handler, got '$out'" ;;
    esac
  done

  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge"

  out=$(drive_omp_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_start must classify 'busy omp-ext'"

  out=$(drive_omp_ext "$ext" end-continuing) || fail "continuing agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_end with willContinue must stay busy (a session_stop continuation is coming)"

  out=$(drive_omp_ext "$ext" end-final) || fail "final agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "idle omp-ext" ] || fail "a plain agent_end must classify 'idle omp-ext'"
  out=$(drive_omp_ext "$ext" quota-error) || fail "quota error drive failed: $out"
  assert_contains "$(fm_busy_record_read "$state" "$id")" 'quota-exhausted' "a terminal native usage failure must be actionable"
  printf 'done: PR opened\n' > "$state/$id.status"
  out=$(drive_omp_ext "$ext" fallback-served) || fail "fallback status drive failed: $out"
  grep -Eq '^note \[at=[0-9]+\]: model-matrix fallback served deepseek/deepseek-v4-flash:high$' "$state/$id.status" \
    || fail "native model fallback must publish the serving model as a note: $(cat "$state/$id.status")"
  [ "$(last_status_line "$state/$id.status")" = 'done: PR opened' ] || fail "the fallback notice must not replace the worker's done declaration"
  rm "$state/$id.busy-gen"
  printf 'working: replacement owns this task\n' > "$state/$id.status"
  out=$(drive_omp_ext "$ext" fallback-served) || fail "retired callback drive failed: $out"
  assert_equals 'working: replacement owns this task' "$(cat "$state/$id.status")" "a retired callback must not publish a stale serving model"

  # The model serving the task is published for bin/fm-crew-state.sh: a fallback
  # moves it, an unrecovered run error is carried, and the next run clears the
  # error and follows the model back to the recorded one.
  assert_absent "$state/$id.live-model" "a task that never saw a model must publish no live-model record"
  out=$(drive_omp_ext "$ext" fallback) || fail "retry_fallback_applied drive failed: $out"
  assert_contains "$(cat "$state/$id.live-model")" "model=deepseek/deepseek-v4-pro" "a fallback must publish the model now serving the task"
  out=$(drive_omp_ext "$ext" end-error) || fail "errored agent_end drive failed: $out"
  assert_contains "$(cat "$state/$id.live-model")" "error=402 This request would exceed your available credits." \
    "a run that ended in an unrecovered error must publish it"
  out=$(drive_omp_ext "$ext" restore) || fail "restore drive failed: $out"
  assert_contains "$(cat "$state/$id.live-model")" "model=openai-codex/gpt-6.1-sol" "a restore to the primary must be published"
  assert_not_contains "$(cat "$state/$id.live-model")" "error=" "the next run must clear the previous run's error"

  # A record from another harness's writer is never trusted for omp.
  fm_busy_source_trusted omp pi-ext && fail "omp must not trust the Pi extension's records"
  fm_busy_source_trusted omp omp-ext || fail "omp must trust its own extension's records"
  pass "omp extension: agent_start busy, willContinue stays busy, plain agent_end idle, turn_end a notification, jev-guard tool_call hook installed, no tool_result hook"
}

# --- 4. Control, composer, supervision model -----------------------------------

test_control_composer_and_model_tables() {
  [ "$(fm_control_exit_command omp)" = /quit ] || fail "omp exit command must be /quit"
  [ "$(fm_control_interrupt_key omp)" = Escape ] || fail "omp interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat omp)" = 1 ] || fail "omp interrupts on a single press"
  [ -z "$(fm_control_interrupt_clear_key omp)" ] || fail "omp leaves its composer empty and needs no clear key"
  printf 'Working…\n' | fm_busy_lines_match omp || fail "omp busy regex must match the TUI ellipsis form"
  printf 'Working...\n' | fm_busy_lines_match omp && fail "omp busy regex must not match the three-dot form no supervised pane renders"
  printf ' ⠧ 11s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the braille spinner plus elapsed cell"
  printf ' ⣾ 3s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the status-set spinner frames, not only the activity set"
  printf ' 󰵗  · gpt-6-astra · 36.7%%/41K\n' | fm_busy_lines_match omp && fail "an idle omp status row must not read busy"
  printf 'esc to interrupt\n' | fm_busy_lines_match omp && fail "omp must not borrow Claude's footer"
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named-model")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_SUPERVISION_MODEL \
    "$bin/omp" -c '. "$1"; fm_supervision_model' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$out" = extension ] || fail "an omp primary must run the extension supervision model, got '$out'"
  pass "control, composer, and supervision-model tables carry omp's verified values"
}

test_ownership_proof_is_omp_keyed() {
  local root home pid
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own/root"; home="$TMP_ROOT/own/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the omp session"
  owns "$root" "$home" || fail "a live session that loaded both omp extensions must own supervision"
  bash -c '. "$1"; fm_pi_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    && fail "omp markers must never satisfy the Pi proof"
  bash -c '. "$1"; fm_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    || fail "the shared extension proof must accept the omp pair"

  root="$TMP_ROOT/own-drift/root"; home="$TMP_ROOT/own-drift/home"
  record_omp_session "$root" "$home" "$pid" "" watch || fail "could not record the drifted session"
  owns "$root" "$home" && fail "a session that loaded an older watch build must not own supervision"
  root="$TMP_ROOT/own-omit/root"; home="$TMP_ROOT/own-omit/home"
  record_omp_session "$root" "$home" "$pid" turnend || fail "could not record the partial session"
  owns "$root" "$home" && fail "a session missing the turn-end guard extension must not own supervision"
  root="$TMP_ROOT/own-dead/root"; home="$TMP_ROOT/own-dead/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the dead session"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  owns "$root" "$home" && fail "a dead session must not own supervision"

  # The pull-guard verdict tolerates the extension's own hand-off only with the proof.
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own-verdict/root"; home="$TMP_ROOT/own-verdict/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the verdict session"
  touch "$home/state/.last-watcher-beat"
  local verdict
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "${verdict%% *}" = true ] || fail "an unheld lock with a fresh beacon and the omp proof must be healthy, got '$verdict'"
  rm -f "$home/state/.omp-turnend-extension-loaded"
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "$verdict" = "false no-watcher" ] || fail "without the proof the same hand-off must alarm as no-watcher, got '$verdict'"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-wake-lib: the omp ownership proof is keyed on its own extensions and gates the hand-off tolerance"
}

test_turnend_guard_extension_compels_one_continuation() {
  local repo home out status
  repo="$TMP_ROOT/guard/repo"; home="$TMP_ROOT/guard/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat); printf '%s\n' "$payload" >> "${FM_GUARD_LOG:?}"
case "$payload" in *'"stop_hook_active":true'*) exit 0 ;; esac
printf 'guard says: repair with fm_watch_arm_omp\n' >&2; exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-watch-arm.sh*'&'*) printf 'fm watcher-arm seatbelt: blocked\n' >&2; exit 2 ;; esac; exit 0
SH
  # shellcheck disable=SC2016 # $2 expands in the generated script
  printf '#!/usr/bin/env bash\nprintf "OMP DIGEST source=%%s\\n" "$2"\n' > "$repo/bin/fm-sessionstart-run.sh"
  chmod +x "$repo/bin/"*.sh
  out=$(FM_GUARD_LOG="$TMP_ROOT/guard/guard.log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync, writeFileSync, rmSync } from "node:fs";
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
for (const name of ["session_start", "before_agent_start", "session_compact", "session_shutdown", "tool_call", "session_stop"]) {
  if (!handlers.has(name)) throw new Error(`${name} handler was not registered`);
}
if (handlers.has("agent_settled")) throw new Error("omp guard must not listen for agent_settled");
const ctx = { sessionManager: { getSessionId: () => "s1" } };
handlers.get("session_start")({ type: "session_start" }, ctx);
const first = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!first?.message?.content?.includes("FIRSTMATE_OP: v1 session-start: OMP DIGEST source=startup")) throw new Error(`first start did not deliver a startup digest: ${JSON.stringify(first)}`);
if (first.message.display !== false || first.message.customType !== "firstmate-sessionstart-nudge") throw new Error("digest message lost its persistent shape");
// A later in-process session_start is a replacement and maps to clear.
handlers.get("session_start")({ type: "session_start" }, ctx);
const second = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!second?.message?.content?.includes("source=clear")) throw new Error(`in-process replacement did not map to clear: ${JSON.stringify(second)}`);
const allowed = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "ls" } }, {});
if (allowed.block) throw new Error("an ordinary command was blocked");
const blocked = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh &" } }, {});
if (blocked.block !== true || !blocked.reason.includes("seatbelt")) throw new Error(`backgrounded arm was not blocked: ${JSON.stringify(blocked)}`);
const r1 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: false }, {});
if (r1?.continue !== true) throw new Error(`guard exit 2 did not compel a continuation: ${JSON.stringify(r1)}`);
if (!r1.additionalContext.startsWith("⁣FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`continuation context is not typed operational input: ${r1.additionalContext}`);
if (!r1.additionalContext.includes("TURN WOULD END BLIND") || !r1.additionalContext.includes("repair with fm_watch_arm_omp")) throw new Error("continuation dropped the guard text");
const r2 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, {});
if (r2 !== undefined) throw new Error(`the flagged second stop must stand down, got ${JSON.stringify(r2)}`);
const payloads = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n");
if (payloads.join("|") !== '{"stop_hook_active":false}|{"stop_hook_active":true}') throw new Error(`guard payloads were ${payloads.join("|")}`);
if (!existsSync(`${process.env.FM_HOME}/state/.omp-turnend-extension-loaded`)) throw new Error("loaded marker was not written");
// The same extension publishes the model serving this home's session, for the
// parent's bin/fm-crew-state.sh, and only while no other live process owns the lock.
const record = `${process.env.FM_HOME}/state/.omp-live-model`;
await handlers.get("agent_start")({ type: "agent_start" }, { model: { provider: "deepseek", id: "deepseek-v4-pro" } });
if (!readFileSync(record, "utf8").includes("model=deepseek/deepseek-v4-pro")) throw new Error(`the home extension did not publish the serving model: ${readFileSync(record, "utf8")}`);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.ppid}\n`);
await handlers.get("agent_start")({ type: "agent_start" }, { model: { provider: "openai-codex", id: "gpt-6.1-sol" } });
if (!readFileSync(record, "utf8").includes("model=deepseek/deepseek-v4-pro")) throw new Error("a process that does not own the session lock overwrote the record");
rmSync(`${process.env.FM_HOME}/state/.lock`);
await handlers.get("session_shutdown")({}, {});
EOF
)
  status=$?
  expect_code 0 "$status" "omp turn-end guard extension contract: $out"
  [ -z "$out" ] || fail "omp guard extension test printed output: $out"
  pass ".omp turn-end guard: digest delivery, seatbelt block, one compelled continuation, flagged stop stands down"
}

test_watch_extension_distinguishes_lock_loss_from_retry_exhaustion() {
  local kind repo home out status
  for kind in other missing exhausted; do
    repo="$TMP_ROOT/watch-restore-reason-$kind/repo"; home="$TMP_ROOT/watch-restore-reason-$kind/home"
    install_omp_extension_fixture "$repo"
    mkdir -p "$home/state" "$home/config"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --handling-delivered ] || exit 0
printf '%s\n' "$$" >> "$FM_HOME/arms"
n=$(wc -l < "$FM_HOME/arms" | tr -d ' ')
if [ "$n" -gt 1 ]; then
  printf 'watcher: FAILED - controlled successor startup refusal\n'
  exit 1
fi
printf 'watcher: started pid=%s\n' "$$"
while [ ! -e "$FM_HOME/close" ]; do sleep 0.1; done
printf 'check: restoration branch fixture\n'
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
      FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
      RESTORE_CASE="$kind" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync, unlinkSync } from "node:fs";
const home = process.env.FM_HOME, kind = process.env.RESTORE_CASE;
const handlers = new Map();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const until = async (predicate, failure) => {
  for (let i = 0; i < 200 && !predicate(); i++) await sleep(25);
  if (!predicate()) throw new Error(failure);
};
const arms = () => existsSync(`${home}/arms`) ? readFileSync(`${home}/arms`, "utf8").trim().split("\n").length : 0;
const failures = () => {
  const file = `${home}/state/extensions/omp-primary-watch/lifecycle.log`;
  return existsSync(file) ? readFileSync(file, "utf8").split("\n").filter((line) => line.includes("event=restore-failed ")) : [];
};
const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool() {}, sendUserMessage() {} };
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
(await import(pathToFileURL(process.env.EXT).href)).default(pi);
try {
  await handlers.get("session_start")({}, { isIdle: () => true });
  await until(() => arms() === 1, "initial watcher never started");
  if (kind === "other") writeFileSync(`${home}/state/.lock`, "1\n");
  if (kind === "missing") unlinkSync(`${home}/state/.lock`);
  writeFileSync(`${home}/close`, "");
  await until(() => failures().length > 0, "restoration failure never reached the lifecycle log");
  const reason = kind === "exhausted" ? "retries-exhausted" : "lock-lost";
  const rows = failures();
  if (rows.length !== 1 || !rows[0].endsWith(`reason=${reason}`)) {
    throw new Error(`${kind}: expected one restore-failed reason=${reason}, got ${JSON.stringify(rows)}`);
  }
  const expectedArms = kind === "exhausted" ? 3 : 1;
  if (arms() !== expectedArms) throw new Error(`${kind}: expected ${expectedArms} arm launches, got ${arms()}`);
  console.log(`${kind}: restore-failed reason=${reason}; arm launches=${arms()}`);
} finally {
  await handlers.get("session_shutdown")({}, {});
}
process.exit(0);
EOF
)
    status=$?
    expect_code 0 "$status" "omp restoration failure reason ($kind): $out"
    pass ".omp watch extension: $kind restoration has its own failure reason and arm count"
  done
}

# A send may settle only after the model turn. Close the successor while that
# promise is still pending: continuity must advance without a repair tool call.
# The foreign rows replace the session while that send still holds its claim.
test_watch_extension_restores_while_delivery_pending() {
  local kind repo home out status
  for kind in pending rejected replay foreign-late foreign-never; do
    repo="$TMP_ROOT/watch-pending-$kind/repo"; home="$TMP_ROOT/watch-pending-$kind/home"
    install_omp_extension_fixture "$repo"
    mkdir -p "$home/state" "$home/config"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --handling-delivered ] || exit 0
printf '%s %s\n' "$$" "$FM_WATCH_PREDECESSOR_ARM_PID" >> "$FM_HOME/arms"
n=$(wc -l < "$FM_HOME/arms" | tr -d ' ')
printf 'watcher: started pid=%s\n' "$$"
while [ ! -e "$FM_HOME/close-$n" ]; do sleep 0.1; done
printf 'check: pending-delivery-%s\n' "$n"
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    # A queue query is an external boundary, not an internal pending-record oracle.
    cat > "$repo/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
[ -e "$FM_HOME/drained" ] || printf 'check\t1\tfixture\t0\tcheck: controlled delivery\n'
SH
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
      FM_OMP_SUCCESSOR_GRACE_MS=60000 DELIVERY_CASE="$kind" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" \
      node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME, kind = process.env.DELIVERY_CASE;
const handlers = new Map(), sends = [], failures = [];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (predicate, failure) => {
  for (let i = 0; i < 200 && !predicate(); i++) await sleep(50);
  if (!predicate()) throw new Error(failure);
};
const arms = () => existsSync(`${home}/arms`) ? readFileSync(`${home}/arms`, "utf8").trim().split("\n").map((line) => line.split(" ")) : [];
let settle, unsettled = true, rejected = false;
const ctx = { isIdle: () => true };
const pi = {
  on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool() {},
  sendUserMessage(message) {
    if (message.includes("watcher: FAILED")) { failures.push(message); return undefined; }
    sends.push(message);
    if (kind === "rejected" && !rejected) { rejected = true; return Promise.reject(new Error("controlled delivery refusal")); }
    if (sends.length === 1) return new Promise((resolve) => { settle = () => { unsettled = false; resolve(); }; });
    return undefined;
  },
};
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
(await import(pathToFileURL(process.env.EXT).href)).default(pi);
try {
  await handlers.get("session_start")({}, ctx);
  await until(() => arms().length === 1, "initial watcher never started");
  writeFileSync(`${home}/close-1`, "");
  await until(() => sends.length === 1, "first wake never reached delivery");
  if (kind === "rejected") {
    await until(() => failures.some((m) => m.includes("controlled delivery refusal")), "rejected delivery did not surface its failure");
    await until(() => sends.length === 2, "rejected wake was lost rather than retried");
  } else if (kind.startsWith("foreign")) {
    await until(() => arms().length === 2, "first actionable close has no extension-started successor");
    await handlers.get("session_shutdown")({}, {});
    await handlers.get("session_start")({}, ctx);
    await until(() => arms().length === 3, "replacement session never armed");
    writeFileSync(`${home}/close-3`, "");
    await until(() => arms().length === 4, "replacement close has no extension-started successor while an earlier generation's claim is pending");
    await until(() => sends.length === 2, "replacement close wake was not delivered");
    await sleep(300);
    if (!unsettled || sends.length !== 2) throw new Error("earlier generation's claimed wake was taken over before its claim settled");
    const observed = arms();
    if (observed[3][1] !== observed[2][0]) throw new Error(`replacement successor did not follow its predecessor: ${JSON.stringify(observed)}`);
  } else {
    writeFileSync(`${home}/close-2`, "");
    await until(() => arms().length === 3, "second actionable close has no extension-started successor while first delivery is pending");
    if (!unsettled || sends.length !== 1) throw new Error("pending wake settled early or was submitted twice");
    const observed = arms();
    if (observed[1][1] !== observed[0][0] || observed[2][1] !== observed[1][0]) throw new Error(`successors were not in close order: ${JSON.stringify(observed)}`);
  }
  if (kind === "replay") {
    await handlers.get("session_shutdown")({}, {});
    const handoff = `${home}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
    if (!existsSync(handoff)) throw new Error("unconsumed accepted wake was not persisted");
    await handlers.get("session_start")({}, ctx);
    settle();
    await until(() => sends.length === 2, "replacement did not replay the unconsumed wake");
    writeFileSync(`${home}/drained`, "");
    await handlers.get("message_start")({ message: { role: "user", content: sends[1] } }, ctx);
    await sleep(1300);
    if (sends.length !== 2 || existsSync(handoff)) throw new Error("replacement replay duplicated or retained consumed work");
  } else if (kind === "foreign-late") {
    const handoff = `${home}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
    await handlers.get("message_start")({ message: { role: "user", content: sends[1] } }, ctx);
    settle();
    await until(() => sends.length === 3, "replacement did not replay the held wake once the earlier claim settled");
    writeFileSync(`${home}/drained`, "");
    await handlers.get("message_start")({ message: { role: "user", content: sends[2] } }, ctx);
    await sleep(1300);
    if (sends.length !== 3 || arms().length !== 4 || existsSync(handoff)) {
      throw new Error(`late claim settlement duplicated, lost or retained work: ${JSON.stringify({ sends: sends.length, arms: arms().length, handoff: existsSync(handoff) })}`);
    }
  } else if (kind === "foreign-never") {
    const handoff = `${home}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
    await handlers.get("message_start")({ message: { role: "user", content: sends[1] } }, ctx);
    writeFileSync(`${home}/close-4`, "");
    await until(() => arms().length === 5, "later close has no extension-started successor while an earlier claim never settles");
    const observed = arms();
    if (observed[4][1] !== observed[3][0]) throw new Error(`later successor did not follow its predecessor: ${JSON.stringify(observed)}`);
    await until(() => sends.length === 3, "later close wake was not delivered");
    writeFileSync(`${home}/drained`, "");
    await handlers.get("message_start")({ message: { role: "user", content: sends[2] } }, ctx);
    await handlers.get("session_shutdown")({}, {});
    const held = () => existsSync(handoff) && JSON.parse(readFileSync(handoff, "utf8")).pending.some((item) => item.predecessorArmPid === observed[0][0]);
    if (!held()) throw new Error("claimed wake was not kept durable for replay");
    await handlers.get("session_start")({}, ctx);
    await until(() => arms().length === 6, "second replacement session never armed");
    await sleep(500);
    if (sends.length !== 3 || !held()) throw new Error(`never-settled claim was taken over or dropped: ${sends.length}`);
  } else {
    writeFileSync(`${home}/drained`, "");
    if (settle) settle();
    await handlers.get("message_start")({ message: { role: "user", content: sends.at(-1) } }, ctx);
    await sleep(1300);
    const expected = kind === "rejected" ? 2 : 1;
    if (sends.length !== expected) throw new Error(`delivery was lost or doubled after settlement: ${sends.length}`);
  }
  console.log(`controlled-${kind}: successor order, delivery settlement and consumption verified`);
} finally {
  await handlers.get("session_shutdown")({}, {});
}
process.exit(0);
EOF
)
    status=$?
    expect_code 0 "$status" "omp pending delivery ($kind): $out"
    pass ".omp watch extension: controlled $kind delivery preserves continuity and wake ownership"
  done
}

test_watch_extension_arms_and_delivers() {
  local repo home out status
  repo="$TMP_ROOT/watch/repo"; home="$TMP_ROOT/watch/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The first arm child closes with one actionable reason; every successor
  # stays up, so exactly one wake exists to consume.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# The extension confirms a handling handoff through this same script; answering
# at once keeps its synchronous call from blocking the whole run.
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ]; then
  : > "$FM_HOME/state/.e2e-fired"
  sleep 1
  . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
  fm_wake_append signal omp-e2e 'signal: omp-e2e done' || exit 1
  printf 'signal: omp-e2e done\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; let command = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand(n, o) { if (n === "fm-watch-arm-omp") command = o.handler; },
  registerTool(t) { tool = t; },
  // omp sendUserMessage returns synchronously, not a promise.
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("before_agent_start")({}, { isIdle: () => true });
if (!tool || tool.name !== "fm_watch_arm_omp") throw new Error("fm_watch_arm_omp was not registered");
if (!command) throw new Error("/fm-watch-arm-omp was not registered");
if (tool.parameters?.type !== "object") throw new Error("tool parameters must be an empty object schema");
const result = await tool.execute();
if (!/^watcher: started omp extension arm child 1;/.test(result.content[0].text)) throw new Error(`unexpected arm result: ${result.content[0].text}`);
const marker = readFileSync(`${process.env.FM_HOME}/state/.omp-watch-extension-loaded`, "utf8").split("\n");
if (marker[1] !== String(process.pid)) throw new Error("loaded marker must record the session pid");
const again = await tool.execute();
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(again.content[0].text)) throw new Error(`redundant arm was not an ownership no-op: ${again.content[0].text}`);
// Wait for delivery, bounded at 60 seconds, rather than assuming child-close timing.
for (let i = 0; i < 600 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 1) throw new Error(`expected one follow-up wake, saw ${sent.length}: ${JSON.stringify(sent)}`);
if (!sent[0].m.startsWith("⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: omp-e2e done")) throw new Error(`unexpected wake text: ${sent[0].m}`);
if (sent[0].o?.deliverAs !== undefined) throw new Error("an idle wake must start its own turn");
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("message_start")({ message: { role: "user", content: sent[0].m } }, {});
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "");
await handlers.get("agent_end")({}, { isIdle: () => true });
await new Promise((resolve) => setTimeout(resolve, 1200));
await handlers.get("session_shutdown")({}, {});
if (existsSync(`${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("a consumed wake must not ride the replacement handoff");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension contract: $out"
  [ -z "$out" ] || fail "omp watch extension test printed output: $out"
  pass ".omp watch extension: fm_watch_arm_omp arms once, repeats as a no-op, and delivers an actionable close as one follow-up"
}

test_primary_extensions_leave_a_task_worker_copy_clean() {
  local repo out path
  # A task worker: no state directory exists, and none may appear.
  repo="$TMP_ROOT/worker-copy/repo"
  install_omp_extension_fixture "$repo"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  cp -R "$repo" "$TMP_ROOT/worker-copy/home"
  out=$(run_omp_primary_extensions "$repo" fm-example-task) || fail "worker-copy extensions run failed: $out"
  [ -z "$out" ] || fail "worker-copy extensions printed output: $out"
  assert_absent "$repo/state" "a task worker copy must get no state directory from the primary extensions"
  for path in state/.omp-live-model state/.omp-turnend-extension-loaded state/.omp-watch-extension-loaded state/extensions/omp-primary-watch; do
    assert_absent "$repo/$path" "a task worker copy must not hold $path"
  done
  # The same copy as a home: every one of the four paths is written.
  repo="$TMP_ROOT/worker-copy/home"
  mkdir -p "$repo/state"
  out=$(run_omp_primary_extensions "$repo") || fail "home extensions run failed: $out"
  [ -z "$out" ] || fail "home extensions printed output: $out"
  for path in state/.omp-live-model state/.omp-turnend-extension-loaded state/.omp-watch-extension-loaded state/extensions/omp-primary-watch; do
    [ -e "$repo/$path" ] || fail "a home must still write $path"
  done
  pass ".omp primary extensions: a task worker copy stays clean and keeps the arm seatbelt, a home still writes its four paths"
}

test_watch_extension_reads_durable_payloads() {
  local kind repo home out status
  for kind in decision merged multiline stale; do
    repo="$TMP_ROOT/watch-identity-$kind/repo"; home="$TMP_ROOT/watch-identity-$kind/home"
    install_omp_extension_fixture "$repo"
    cp -R "$ROOT/bin/." "$repo/bin/"
    mkdir -p "$home/state"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
if [ -e "$FM_HOME/state/.e2e-fired" ]; then exec sleep 30; fi
: > "$FM_HOME/state/.e2e-fired"
sleep 1
. "$FM_ROOT_OVERRIDE/bin/fm-push-transition-lib.sh"
FM_WATCH_DELIVERY_PID=$$
case "$ROW_KIND" in
  decision)
    reason='signal: decision.status'
    fm_wake_append signal decision.status 'needs-decision: decision.status' || exit 1
    ;;
  merged)
    reason='check: poll-file: merged'
    fm_wake_append check merged-demo 'check: merge landed: demo https://example.test/pull/1' || exit 1
    ;;
  multiline)
    reason=$'check: custom: ready\nsecond line'
    fm_wake_append check custom "$reason" || exit 1
    ;;
  stale)
    printf 'signal: already handled\n'
    exit 0
    ;;
esac
wake "$reason"
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(ROW_KIND="$kind" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
      EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = []; const ctx = { isIdle: () => true };
const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool() {},
  sendUserMessage(m, o) { sent.push({ m, o }); } };
(await import(pathToFileURL(process.env.EXT).href)).default(pi);
await handlers.get("session_start")({}, ctx);
if (process.env.ROW_KIND === "stale") await new Promise((resolve) => setTimeout(resolve, 3000));
else for (let i = 0; i < 300 && sent.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 100));
if (process.env.ROW_KIND === "stale") {
  if (sent.length !== 0) throw new Error(`an unqueued watcher row was injected: ${JSON.stringify(sent)}`);
} else {
  const payloads = {
    decision: "needs-decision: decision.status",
    merged: "check: merge landed: demo https://example.test/pull/1",
    multiline: "check: custom: ready second line",
  };
  if (sent.length !== 1 || !sent[0].m.includes(`FIRSTMATE WATCHER WAKE: ${payloads[process.env.ROW_KIND]}\n\nRun bin/fm-wake-drain.sh`)) {
    throw new Error(`durable ${process.env.ROW_KIND} row was not delivered intact: ${JSON.stringify(sent)}`);
  }
  if (sent[0].o?.deliverAs !== undefined) throw new Error("durable watcher wake bypassed idle delivery");
  await handlers.get("message_start")({ message: { role: "user", content: sent[0].m } }, ctx);
  writeFileSync(`${state}/.wake-queue`, "");
  await handlers.get("agent_end")({}, ctx);
  await new Promise((resolve) => setTimeout(resolve, 1200));
}
await handlers.get("session_shutdown")({}, ctx);
if (process.env.ROW_KIND === "stale") {
  await handlers.get("session_start")({}, ctx);
  for (let i = 0; i < 300 && existsSync(`${state}/extensions/omp-primary-watch/session-replacement-actionable.json`); i += 1) await new Promise((resolve) => setTimeout(resolve, 100));
  if (sent.length !== 0) throw new Error(`replacement replayed an unqueued watcher row: ${JSON.stringify(sent)}`);
  await handlers.get("session_shutdown")({}, ctx);
}
if (existsSync(`${state}/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("completed correlation retained its handoff");
process.exit(0);
EOF
)
    status=$?
    expect_code 0 "$status" "omp durable sequence ($kind): $out"
  done
  pass ".omp watch extension: decision, merge and multiline payloads come from the queue; unqueued closes inject nothing"
}

# An opted-in home spawns the supervision host in the arm's place; its streamed
# status line drives readiness and the handling handoff, and a handed-back
# wake is delivered with every host line and the away note.
test_watch_extension_runs_the_supervision_host() {  # [away|quiet]
  local kind=${1:-away} repo home log out status f
  repo="$TMP_ROOT/watch-host-$kind/repo"; home="$TMP_ROOT/watch-host-$kind/home"; log="$TMP_ROOT/watch-host-$kind/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  if [ "$kind" = quiet ]; then
    # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
    # QUIET): the extension asks the record owner, so the same handback carries
    # no away note.
    for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$repo/bin/$f"; done
    FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
      || fail "fixture: could not record quiet mode"
  else
    : > "$home/state/.afk-contract"
  fi
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'plain-arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s args=%s primary=%s predecessor=%s\n' "$$" "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
if [ "$(grep -c '^host=' "$FM_ARM_LOG")" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  sleep 1
  printf 'signal: omp-host done\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\nsupervision-host: outcome 1 for demo [captain]: fixture\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-2\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    RECORD_KIND="$kind" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("before_agent_start")({}, { isIdle: () => true });
await tool.execute();
for (let i = 0; i < 60 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.some((row) => row.startsWith("plain-arm="))) throw new Error(`an opted-in home ran the plain arm: ${rows.join(" | ")}`);
const hosts = rows.filter((row) => row.startsWith("host="));
if (hosts.length !== 2) throw new Error(`expected the host and one successor host, got: ${rows.join(" | ")}`);
if (!hosts.every((row) => / args=park --restart primary=omp /.test(row))) throw new Error(`the host must run as 'park --restart' with the omp pin: ${hosts.join(" | ")}`);
if (!/predecessor=[0-9]+$/.test(hosts[1])) throw new Error(`the successor host did not receive the closed host as its predecessor: ${hosts[1]}`);
if (!rows.includes(`confirmed generation=gen-2 watcher=${hosts[1].replace(/^host=([0-9]+).*/, "$1")}`)) {
  throw new Error(`the handling handoff was not confirmed against the successor host's cycle: ${rows.join(" | ")}`);
}
if (sent.length !== 1) throw new Error(`expected one follow-up wake, saw ${sent.length}: ${JSON.stringify(sent)}`);
if (sent[0].m.includes("signal: omp-host done")) throw new Error(`the hand-back injected a close headline with no queued row: ${sent[0].m}`);
for (const needle of [
  "supervision-host: the away session could not take this wake: fixture; this wake is yours",
  "supervision-host: outcome 1 for demo [captain]: fixture",
]) {
  if (!sent[0].m.includes(needle)) throw new Error(`the follow-up lacks '${needle}': ${sent[0].m}`);
}
const awayNote = sent[0].m.includes("not from the captain: it is not a return");
if (process.env.RECORD_KIND === "quiet" ? awayNote : !awayNote) {
  throw new Error(`the away note must appear exactly under an away record (${process.env.RECORD_KIND}): ${sent[0].m}`);
}
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("message_start")({ message: { role: "user", content: sent[0].m } }, {});
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension host mode ($kind record): $out"
  [ -z "$out" ] || fail "omp watch extension host test printed output: $out"
  pass ".omp watch extension: an opted-in home runs the supervision host and relays every host line ($kind record)"
}

# The omp owner stays file-gated: a home without config/supervision-host, or
# one opted out by config/supervision-host-off, spawns the plain arm and never the host.
test_watch_extension_keeps_the_arm_without_the_file_or_with_off() {
  local line label repo home log out status
  for line in - off; do
    label=${line#-}; label=${label:-absent}
    repo="$TMP_ROOT/watch-host-gate-$label/repo"; home="$TMP_ROOT/watch-host-gate-$label/home"; log="$TMP_ROOT/watch-host-gate-$label/arm.log"
    install_omp_extension_fixture "$repo"
    mkdir -p "$home/state" "$home/config"
    [ "$line" = - ] || : > "$home/config/supervision-host-off"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'plain-arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 30
SH
    cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 30
SH
    chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" \
      EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync, writeFileSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null;
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage() { return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 60 && !existsSync(process.env.FM_ARM_LOG); i += 1) await new Promise((r) => setTimeout(r, 100));
const rows = existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n") : [];
if (rows.length === 0 || !rows.every((row) => row.startsWith("plain-arm="))) {
  throw new Error(`a home that does not run the host must spawn only the plain arm: ${rows.join(" | ")}`);
}
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
    status=$?
    expect_code 0 "$status" "omp watch extension gate ($label): $out"
    [ -z "$out" ] || fail "omp watch extension gate test printed output ($label): $out"
  done
  pass ".omp watch extension: a home without config/supervision-host or with an off file keeps the plain arm"
}

test_watch_extension_delivers_host_handbacks() {  # <outcome|away-return|busy|stuck|rejected|unrestored|refused|stuck-refused>
  local kind=${1:-outcome} repo home log out status
  repo="$TMP_ROOT/watch-host-handoff-$kind/repo"; home="$TMP_ROOT/watch-host-handoff-$kind/home"; log="$TMP_ROOT/watch-host-handoff-$kind/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/bin/fm-wake-drain.sh"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  [ "$HAND_BACK_KIND" = rejected ] && exit 1
  exit 0
fi
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
[ "$HAND_BACK_KIND" = unrestored ] && [ "$(grep -c '^host=' "$FM_ARM_LOG")" -gt 1 ] && exit 1
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
if [ "$(grep -c '^host=' "$FM_ARM_LOG")" -eq 1 ]; then
  sleep 1
  case "$HAND_BACK_KIND" in
    away-return) printf 'signal: already handled original\nsupervision-host: the captain returned while the away session was handling this wake; relay its visible outcomes\n' ;;
    *) printf 'supervision-host: branch-outcome: the supervision session handled this wake and recorded captain outcomes for you (store rows 1)\n' ;;
  esac
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(HAND_BACK_KIND="$kind" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
const handlers = new Map(); let tool = null; const sent = []; const notices = []; let refusals = 0, refused = 0;
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) {
    if (refusals > 0 && !o?.deliverAs) {
      refusals -= 1;
      refused += 1;
      throw new Error("omp refused the prompt");
    }
    sent.push({ m, o });
    // The omp prompt flow starts a turn, which consumes the message.
    if (stuck && !o?.deliverAs) handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
    return undefined;
  },
};
// The stuck case runs the fixed one-second flush check of the extension faster.
const stuck = ["stuck", "stuck-refused"].includes(process.env.HAND_BACK_KIND);
const realSetTimeout = globalThis.setTimeout;
if (stuck) globalThis.setTimeout = (callback, delay, ...args) => realSetTimeout(callback, delay === 1000 ? 20 : delay, ...args);
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
let idle = !stuck;
// A failure carried by the first send must survive omp restoring it to the editor.
const failure = { rejected: "watcher: FAILED - handling delivery confirmation was rejected", unrestored: "watcher: FAILED - omp extension could not restore watcher continuity" }[process.env.HAND_BACK_KIND];
let editor = "";
const ctx = stuck
  ? { hasUI: true, isIdle: () => idle, hasPendingMessages: () => true, ui: { getEditorText: () => "", setEditorText() {}, notify: (m) => { notices.push(m); } } }
  : failure || process.env.HAND_BACK_KIND === "refused"
    ? { hasUI: true, isIdle: () => true, hasPendingMessages: () => false, ui: { getEditorText: () => editor, setEditorText: (value) => { editor = value; }, notify: (m) => { notices.push(m); } } }
    : { isIdle: () => process.env.HAND_BACK_KIND !== "busy" };
await handlers.get("before_agent_start")({}, ctx);
await tool.execute();
for (let i = 0; i < 100 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 1 || !sent[0].m.includes("FIRSTMATE SUPERVISION HOST:")) throw new Error(`host hand-back was not delivered once: ${JSON.stringify(sent)}`);
const expected = process.env.HAND_BACK_KIND === "away-return" ? "the captain returned" : "branch-outcome:";
if (!sent[0].m.includes(expected)) throw new Error(`host hand-back lost its outcome: ${sent[0].m}`);
if (sent[0].m.includes("signal: already handled original")) throw new Error(`host hand-back injected a handled headline: ${sent[0].m}`);
if (["busy", "stuck", "stuck-refused"].includes(process.env.HAND_BACK_KIND) ? sent[0].o?.deliverAs !== "followUp" : sent[0].o?.deliverAs !== undefined) throw new Error("host hand-back changed its idle/busy delivery routing");
const rejected = sent[0].m.includes("watcher: FAILED - handling delivery confirmation was rejected");
if (process.env.HAND_BACK_KIND === "rejected" ? !rejected : rejected) throw new Error(`a rejected handling confirmation must reach main exactly when it happens: ${sent[0].m}`);
if (failure) {
  if (!sent[0].m.includes(failure)) throw new Error(`the hand-back lost its failure on the first send: ${sent[0].m}`);
  editor = sent[0].m;
  for (let i = 0; i < 100 && sent.length < 2; i += 1) await new Promise((r) => setTimeout(r, 100));
  const handbacks = sent.filter(({ m }) => m.includes("FIRSTMATE SUPERVISION HOST:"));
  if (editor !== "" || handbacks.length !== 2) throw new Error(`the restored hand-back was not sent again: ${JSON.stringify(sent)}`);
  if (!handbacks[1].m.includes(failure) || !handbacks[1].m.includes("branch-outcome:")) throw new Error(`the re-sent hand-back lost its failure: ${handbacks[1].m}`);
}
if (process.env.HAND_BACK_KIND === "refused") {
  // Escape restores the hand-back, then omp refuses every resend: the copy
  // must survive in the composer, each refusal counts, and the third warns once.
  editor = sent[0].m;
  refusals = 3;
  const warned = () => notices.filter((m) => m.includes("wake not delivered"));
  for (let i = 0; i < 150 && (refused < 3 || warned().length < 1); i += 1) await new Promise((r) => setTimeout(r, 100));
  if (refused !== 3 || warned().length !== 1 || editor !== sent[0].m || sent.length !== 1) throw new Error(`a refused restored hand-back was lost or not bounded: ${JSON.stringify({ refused, notices, editor, sent })}`);
  await new Promise((r) => setTimeout(r, 1500));
  if (refused !== 3 || warned().length !== 1 || editor !== sent[0].m || sent.length !== 1) throw new Error(`a refused restored hand-back was retried or warned again past its bound: ${JSON.stringify({ refused, notices })}`);
}
if (process.env.HAND_BACK_KIND === "stuck-refused") {
  // omp went idle and never ran the queued follow-up, then refuses every
  // prompt resend: the hand-back stays tracked, retries within three attempts,
  // warns once, and is consumed once when omp finally runs the original copy.
  refusals = 3;
  idle = true;
  const warned = () => notices.filter((m) => m.includes("wake not delivered"));
  for (let i = 0; i < 150 && (refused < 3 || warned().length < 1); i += 1) await new Promise((r) => setTimeout(r, 100));
  if (refused !== 3 || warned().length !== 1 || sent.length !== 1) throw new Error(`a refused stuck-queue hand-back lost tracking or was not bounded: ${JSON.stringify({ refused, notices, sent })}`);
  await new Promise((r) => setTimeout(r, 1000));
  if (refused !== 3 || warned().length !== 1 || sent.length !== 1) throw new Error(`a refused stuck-queue hand-back was retried or warned again past its bound: ${JSON.stringify({ refused, notices, sent })}`);
} else if (stuck) {
  // omp went idle and never ran the queued follow-up.
  idle = true;
  for (let i = 0; i < 100 && sent.length < 2; i += 1) await new Promise((r) => setTimeout(r, 100));
  await new Promise((r) => setTimeout(r, 500));
  if (sent.length !== 2 || sent[1].m !== sent[0].m || sent[1].o?.deliverAs !== undefined) throw new Error(`a hand-back stuck in the idle omp queue was not sent through the prompt flow: ${JSON.stringify(sent)}`);
}
await handlers.get("message_start")({ message: { role: "user", content: sent.filter(({ m }) => m.includes("FIRSTMATE SUPERVISION HOST:")).pop().m } }, ctx);
await handlers.get("session_shutdown")({}, {});
if (existsSync(handoff)) throw new Error("a consumed host hand-back retained its handoff");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension host-only handoff: $out"
  [ -z "$out" ] || fail "omp watch extension host-only handoff test printed output: $out"
  pass ".omp watch extension: an unqueued host hand-back is delivered once ($kind)"
}

test_watch_extension_distinguishes_lock_loss_from_retry_exhaustion
test_watch_extension_restores_while_delivery_pending
test_spawn_refuses_a_missing_or_unlisted_default_role
test_spawn_global_config_is_read_only_and_unlayered
test_spawn_raw_omp_guard_uses_the_launch_model
test_spawn_raw_omp_guard_uses_the_launch_agent_dir
test_spawn_omp_profiles_leave_directory_evidence_unreadable
test_spawn_raw_omp_expansions_pass_through_unchanged
test_spawn_raw_omp_literal_evidence_still_refuses
test_secondmate_launch_relies_on_discovery
test_secondmate_config_pinned_model_is_validated
test_secondmate_explicit_omp_deepseek_profile_is_refused
test_busy_extension_lifecycle
test_control_composer_and_model_tables
test_ownership_proof_is_omp_keyed
test_turnend_guard_extension_compels_one_continuation
test_watch_extension_arms_and_delivers
test_primary_extensions_leave_a_task_worker_copy_clean
test_watch_extension_reads_durable_payloads
test_watch_extension_runs_the_supervision_host
test_watch_extension_runs_the_supervision_host quiet
test_watch_extension_keeps_the_arm_without_the_file_or_with_off
test_watch_extension_delivers_host_handbacks outcome
test_watch_extension_delivers_host_handbacks away-return
test_watch_extension_delivers_host_handbacks busy
test_watch_extension_delivers_host_handbacks stuck
test_watch_extension_delivers_host_handbacks rejected
test_watch_extension_delivers_host_handbacks unrestored
test_watch_extension_delivers_host_handbacks refused
test_watch_extension_delivers_host_handbacks stuck-refused
