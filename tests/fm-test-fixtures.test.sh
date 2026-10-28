#!/usr/bin/env bash
# Behavior tests for tests/lib.sh primitives and tests/fixtures.sh builders.
#
# Cases call shared primitives directly or write stubs into a fakebin and exec
# them as a test would. Assertions are on observable output, exit status, and
# filesystem effects - never on helper source text, except the owner-requested
# check that only tests/lib.sh reads FM_TEST_ONLY. Migrated spawn suites cover
# fm_test_run_spawn through the real fm-spawn.sh; this file pins the shared
# primitives and stubs those suites use.
#
# It is also the fixture Git-config isolation regression, with host signing
# armed on a scratch config file: it drives every entry point that must reach
# tests/git-config-helpers.sh - the shared helpers, bin/fm-test-run.sh's
# per-suite wrapper, and the standalone scripts runnable without a live vendor.
# That helper's header owns the contract and the layers it leaves in force.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-fixtures)

test_git_config_isolation() (
  local dir="$TMP_ROOT/git-config" helper jobs timeout fakebin rc
  mkdir -p "$dir/runner/bin" "$dir/runner/tests"
  git init -q "$dir/caller"
  git -C "$dir/caller" config commit.gpgsign false
  cd "$dir/caller" || exit 1
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$dir/runner/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$dir/runner/tests/"
  fakebin=$(fm_fakebin "$dir/standalone")
  fm_fake_exit0 "$fakebin" pi
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  if [ "$1" = -c ]; then
    git -C "$2" log -1 --format=%s > "${FM_TEST_STANDALONE_COMMIT:?}"
    exit 1
  fi
  shift
done
SH
  chmod +x "$fakebin/tmux"
  cat > "$dir/runner/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
repo=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-runner.XXXXXX")
trap 'rm -rf "$repo"' EXIT
git init -q "$repo"
git -C "$repo" config user.name 'Runner Fixture'
git -C "$repo" config user.email runner@example.invalid
git -C "$repo" commit -q --allow-empty -m initial
[ "$(git -C "$repo" log -1 --format='%s:%an:%ae')" = 'initial:Runner Fixture:runner@example.invalid' ]
[ "$(git -C "$repo" config --get fixture.input)" = preserved ]
[ "$(GIT_CONFIG_GLOBAL="$FM_TEST_GIT_CONFIG" git config --global --get commit.gpgsign)" = true ]
SH
  chmod +x "$dir/runner/tests/fm-test-run.test.sh"
  export GIT_CONFIG_GLOBAL="$dir/global" GIT_CONFIG_SYSTEM="$dir/system"
  export GIT_CONFIG_NOSYSTEM=0
  unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS

  # A failing signer exposes inherited config without requiring GPG or keys.
  arm_host_signing() {  # <scope>: only this layer carries the failing signer
    : > "$dir/global"
    : > "$dir/system"
    git config --file "$dir/$1" commit.gpgsign true
    git config --file "$dir/$1" gpg.format openpgp
    git config --file "$dir/$1" gpg.program /usr/bin/false
    cp "$dir/$1" "$dir/expected"
  }

  assert_helper_isolates() {  # <helper> <scope>
    bash -eus -- "$ROOT/tests/$1.sh" "$dir/$2-$1" "$dir/$2" <<'SH' || exit 1
. "$1"
fm_git_init_commit "$2"
[ "$(git -C "$2" log -1 --format=%s)" = initial ] || fail "fixture has no initial commit"
fm_git_identity
# Child Git processes and direct commits inherit the same isolation.
bash -eu -c 'git -C "$1" commit -q --allow-empty -m child' _ "$2"
# Repository-local config and explicit command inputs remain authoritative.
git -C "$2" config commit.gpgsign true
git -C "$2" config gpg.program /usr/bin/false
if git -C "$2" commit -q --allow-empty -m signed > "$2/signing.log" 2>&1; then
  fail "repository-local signing config was ignored"
fi
assert_grep 'gpg failed to sign' "$2/signing.log" "local signing was not attempted"
git -C "$2" -c commit.gpgsign=false commit -q --allow-empty -m explicit
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  git -C "$2" commit -q --allow-empty -m environment
# A config test can deliberately supply its own global file after sourcing.
[ "$(GIT_CONFIG_GLOBAL="$3" git config --global --get commit.gpgsign)" = true ] || fail "explicit global config was ignored"
SH
  }

  assert_host_config_still_governs() {  # <scope>
    # Sourcing in test subprocesses cannot change the caller or its config files.
    [ "$(git config --"$1" --get commit.gpgsign)" = true ] || fail "caller lost signing preference"
    cmp -s "$dir/$1" "$dir/expected" || fail "host config file was changed"
    git init -q "$dir/$1-outside"
    if git -C "$dir/$1-outside" -c user.name=test -c user.email=test@example.invalid \
      commit -q --allow-empty -m outside > "$dir/outside.log" 2>&1; then
      fail "commit outside fixtures bypassed signing"
    fi
    assert_grep 'gpg failed to sign' "$dir/outside.log" "outside commit did not attempt signing"
  }

  # Every fixture entry point, once. Each only has to reach the shared helper;
  # which layers that helper neutralizes is the helper's own property, settled
  # by the system-layer case below.
  arm_host_signing global
  for helper in lib fixtures secondmate-helpers wake-helpers; do
    assert_helper_isolates "$helper" global
  done
  bash -eus -- "$ROOT/tests/herdr-test-safety.sh" "$dir/global-herdr" <<'SH' || exit 1
. "$1"
git init -q "$2"
git -C "$2" -c user.name=test -c user.email=test@example.invalid \
  commit -q --allow-empty -m initial
[ "$(git -C "$2" log -1 --format=%s)" = initial ]
SH
  for jobs in 1 2; do
    for timeout in 0 30; do
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=fixture.input GIT_CONFIG_VALUE_0=preserved \
        FM_TEST_GIT_CONFIG="$dir/global" \
        "$dir/runner/bin/fm-test-run.sh" --jobs "$jobs" --per-script-timeout-secs "$timeout" \
        tests/fm-test-run.test.sh > "$dir/runner.log" 2>&1 \
        || fail "runner inherited global config (jobs=$jobs, timeout=$timeout): $(cat "$dir/runner.log")"
      assert_grep 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0' "$dir/runner.log" \
        "runner did not execute the Git fixture"
    done
  done
  rc=0
  FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=HEAD \
    FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=updated \
    FM_TEST_STANDALONE_COMMIT="$dir/global-standalone-commit" PATH="$fakebin:$PATH" \
    bash "$ROOT/tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh" \
    > "$dir/standalone.log" 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "standalone fixture did not stop at the tmux launch"
  assert_grep 'could not start isolated Pi session' "$dir/standalone.log" \
    "standalone fixture failed before the tmux launch: $(cat "$dir/standalone.log")"
  [ "$(cat "$dir/global-standalone-commit")" = 'test: initial instruction contract' ] \
    || fail "standalone fixture did not create its initial commit"
  bash "$ROOT/tests/fm-gitignore-config.test.sh" > "$dir/gitignore.log" 2>&1 \
    || fail "standalone gitignore fixture inherited global config: $(cat "$dir/gitignore.log")"
  assert_host_config_still_governs global

  # The system layer is the shared helper's other half: one entry point settles
  # it, and the caller still signing proves the layer was genuinely armed.
  arm_host_signing system
  assert_helper_isolates lib system
  assert_host_config_still_governs system

  pass "runner and shared helpers isolate host Git config and preserve explicit config and outside commits"
)

test_touch_epoch_preserves_repeated_dst_hour() {
  local TZ=Europe/Paris epoch path actual
  export TZ
  for epoch in 1761438600 1761442200; do
    fm_touch_epoch "$epoch" "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"
    for path in "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"; do
      actual=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null) \
        || fail "could not read fixture mtime for $path"
      [ "$actual" = "$epoch" ] \
        || fail "fm_touch_epoch should preserve epoch $epoch, got $actual"
    done
  done
  pass "fm_touch_epoch preserves both epochs in the repeated DST hour"
}

test_no_mistakes_version_constant() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/nm")
  fm_test_fake_no_mistakes "$fakebin"
  out=$("$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION" ] || \
    fail "fake no-mistakes --version should be the shared constant, got '$out'"
  out=$(FM_FAKE_NO_MISTAKES_VERSION="$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" \
    "$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" ] || \
    fail "timestamped banner override should round-trip, got '$out'"
  case "$out" in
    "$FM_TEST_NO_MISTAKES_FAKE_VERSION "*) ;;
    *) fail "timestamped banner '$out' is not the shared constant plus a suffix" ;;
  esac
  out=$(FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v9.9.9 (fake)' \
    "$fakebin/no-mistakes" --version)
  [ "$out" = 'no-mistakes version v9.9.9 (fake)' ] || \
    fail "FM_FAKE_NO_MISTAKES_VERSION should override the default banner, got '$out'"
  "$fakebin/no-mistakes" doctor
  expect_code 0 $? "fake no-mistakes non-version verbs should exit 0"
  pass "fake no-mistakes --version is the shared constant and overridable"
}

test_no_mistakes_init_doctor_markers() {
  local fakebin dir rc
  dir="$TMP_ROOT/nm-init"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_no_mistakes_init_doctor "$fakebin"
  ( cd "$dir" && "$fakebin/no-mistakes" init )
  assert_present "$dir/.no-mistakes-init" "init did not touch the marker"
  ( cd "$dir" && "$fakebin/no-mistakes" doctor )
  assert_present "$dir/.no-mistakes-doctor" "doctor did not touch the marker"
  rc=0
  ( cd "$dir" && "$fakebin/no-mistakes" axi ) || rc=$?
  expect_code 2 "$rc" "unknown no-mistakes verb should exit 2"
  pass "init/doctor no-mistakes stub touches markers and refuses other verbs"
}

test_fake_gh_and_gh_axi() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/gh")
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  "$fakebin/gh" auth status
  expect_code 0 $? "fake gh auth status should succeed"
  "$fakebin/gh" pr list
  expect_code 0 $? "fake gh other verbs should exit 0"
  out=$("$fakebin/gh-axi" --version)
  [ "$out" = "$FM_TEST_GH_AXI_VERSION" ] || \
    fail "fake gh-axi --version should be $FM_TEST_GH_AXI_VERSION, got '$out'"
  out=$(FM_FAKE_GH_AXI_VERSION=0.9.9 "$fakebin/gh-axi" --version)
  [ "$out" = 0.9.9 ] || fail "FM_FAKE_GH_AXI_VERSION should override, got '$out'"
  pass "fake gh authenticates and fake gh-axi reports the shared version"
}

test_spawn_tmux_and_fakebin() {
  local fakebin out log
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn" gh-axi)
  log="$TMP_ROOT/spawn/launch.log"
  : > "$log"
  out=$(FM_FAKE_PANE_PATH=/tmp/wt "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ "$out" = /tmp/wt ] || fail "spawn tmux pane path should be FM_FAKE_PANE_PATH, got '$out'"
  out=$(unset FM_FAKE_PANE_PATH; "$fakebin/tmux" display-message -p '#{pane_current_path}')
  [ -z "$out" ] || fail "spawn tmux pane path should default to empty, got '$out'"
  out=$("$fakebin/tmux" display-message -p '#S')
  [ "$out" = firstmate ] || fail "spawn tmux session name should be firstmate, got '$out'"
  FM_FAKE_LAUNCH_LOG="$log" "$fakebin/tmux" send-keys -t @w -l 'codex --yolo'
  assert_grep 'codex --yolo' "$log" "send-keys -l payload was not logged"
  [ -x "$fakebin/treehouse" ] || fail "spawn fakebin should include treehouse"
  [ -x "$fakebin/gh-axi" ] || fail "extra exit-0 tools should land in the spawn fakebin"
  "$fakebin/treehouse" get
  expect_code 0 $? "fake treehouse should exit 0"
  pass "spawn fakebin answers pane path, logs -l payloads, and installs extra tools"
}

test_send_stubs_and_ssh() {
  local fakebin log ssh_log out
  fakebin=$(make_stubs "$TMP_ROOT/send")
  log="$TMP_ROOT/send/send.log"
  ssh_log="$TMP_ROOT/send/ssh.log"
  : > "$log"
  fm_test_fake_ssh "$fakebin"
  FM_SEND_LOG="$log" "$fakebin/tmux" send-keys -t sess:w -l 'hello steer'
  assert_grep 'hello steer' "$log" "send stubs did not log the -l payload"
  out=$("$fakebin/tmux" display-message -p '#{cursor_y}')
  [ "$out" = 1 ] || fail "send tmux cursor_y should be 1, got '$out'"
  out=$("$fakebin/tmux" capture-pane -p)
  case "$out" in
    *'╭────╮'*) ;;
    *) fail "send tmux capture-pane should render an empty composer, got '$out'" ;;
  esac
  printf 'ignored\n' | FM_SSH_LOG="$ssh_log" "$fakebin/fake-ssh" host -- cmd
  assert_grep 'host -- cmd' "$ssh_log" "fake ssh did not record argv"
  FM_FAKE_SSH_RC=7 "$fakebin/fake-ssh" x < /dev/null
  expect_code 7 $? "fake ssh should honor FM_FAKE_SSH_RC"
  pass "send stubs log typed text and fake ssh records argv with a controllable exit"
}

test_spawn_home_layout() {
  local home="$TMP_ROOT/home"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" t1 'do the thing'
  assert_present "$home/data" "spawn home missing data/"
  assert_present "$home/state/.last-watcher-beat" "spawn home missing watcher beat"
  assert_grep claude "$home/config/crew-harness" "crew-harness was not pinned"
  assert_grep 'do the thing' "$home/data/t1/brief.md" "brief text was not written"
  pass "spawn-home layout writes harness pin, beat, and brief"
}

# A host whose `sleep` is a multicall coreutils (uutils on Ubuntu 26.04) refuses
# to run under a foreign name, so a harness-named symlink to it never becomes a
# live process. The fake `sleep` below models that refusal on any host, which
# keeps this case meaningful where CI's own `sleep` is single-purpose.
test_agent_standin_survives_a_multicall_sleep() (
  local dir="$TMP_ROOT/standin" fakebin real_sleep standin pid
  real_sleep=$(command -v sleep) || fail "sleep not found"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/sleep" <<SH
#!/usr/bin/env bash
case "\${0##*/}" in
  sleep) exec "$real_sleep" "\$@" ;;
  *) echo "Requested utility \${0##*/} does not match executable name" >&2; exit 1 ;;
esac
SH
  chmod +x "$fakebin/sleep"
  ln -s "$fakebin/sleep" "$dir/pi"
  "$fakebin/sleep" 0 || fail "the fake multicall sleep must run under its own name"
  if "$dir/pi" 0 2>/dev/null; then
    fail "the fake multicall sleep must refuse a harness name, or this case proves nothing"
  fi

  if standin=$(PATH="$fakebin:$(fm_test_base_path_sans "$PATH" cc gcc)" fm_agent_standin "$dir/nocc"); then
    fail "without a compiler, a multicall sleep must not be offered as a stand-in, got '$standin'"
  fi
  assert_absent "$dir/nocc/standin" "a refused stand-in must not be left behind"

  if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    echo "skip: no C compiler, so the compiled stand-in half of the multicall case cannot run"
    pass "agent stand-in: a multicall sleep is refused rather than offered as a stand-in"
    exit 0
  fi
  standin=$(PATH="$fakebin:$PATH" fm_agent_standin "$dir/cc") \
    || fail "with a compiler, a multicall host sleep must still yield a stand-in"
  ln -s "$standin" "$dir/cc/pi"
  "$dir/cc/pi" 60 &
  pid=$!
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "the stand-in must stay alive under a harness name"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "agent stand-in: a multicall sleep is refused, and the compiled stand-in survives a harness name"
)

# An inherited absolute GIT_DIR (a linked-worktree hook exports one) overrides
# `git -C`, so fixture setup would commit, move refs, and register worktrees in
# the caller's repository; GIT_INDEX_FILE and GIT_COMMON_DIR redirect the index
# and refs the same way, and GIT_WORK_TREE breaks the setup outright. Each entry
# point runs the teardown suites' make_case Git setup with each variable aimed in
# turn at a disposable ambient clone, which must come through unchanged.
test_inherited_git_location_isolation() (
  local dir="$TMP_ROOT/git-location" before after var value helper rc
  mkdir -p "$dir/runner/bin" "$dir/runner/tests"
  fm_git_init_commit "$dir/ambient"
  git -C "$dir/ambient" worktree add -q --detach "$dir/linked" main
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$dir/runner/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$dir/runner/tests/"
  cat > "$dir/setup.sh" <<'SH'
case_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-location.XXXXXX")
git init -q --bare "$case_dir/origin.git"
git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
echo seed > "$case_dir/_seed/seed.txt"
git -C "$case_dir/_seed" add seed.txt
git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q -m "origin baseline"
git -C "$case_dir/_seed" push -q origin main
git clone -q "$case_dir/origin.git" "$case_dir/project"
git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
[ "$(git -C "$case_dir/wt" log -1 --format=%s)" = "origin baseline" ]
SH
  { printf '#!/usr/bin/env bash\nset -eu\n'; cat "$dir/setup.sh"; } > "$dir/runner/tests/fm-test-run.test.sh"
  chmod +x "$dir/runner/tests/fm-test-run.test.sh"

  ambient_state() {
    git -C "$dir/ambient" for-each-ref --format='%(refname) %(objectname)'
    git -C "$dir/ambient" worktree list --porcelain
    git -C "$dir/ambient" ls-files --stage
    git -C "$dir/linked" ls-files --stage
  }

  before=$(ambient_state)
  for var in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR; do
    case $var in
      GIT_DIR) value=$(git -C "$dir/linked" rev-parse --absolute-git-dir) ;;
      GIT_WORK_TREE) value="$dir/linked" ;;
      GIT_INDEX_FILE) value=$(git -C "$dir/linked" rev-parse --path-format=absolute --git-path index) ;;
      GIT_COMMON_DIR) value=$(git -C "$dir/linked" rev-parse --path-format=absolute --git-common-dir) ;;
    esac
    for helper in lib herdr-test-safety runner-1 runner-2; do
      rc=0
      case $helper in
        runner-*)
          env "$var=$value" TMPDIR="$dir" "$dir/runner/bin/fm-test-run.sh" --jobs "${helper#runner-}" \
            tests/fm-test-run.test.sh > "$dir/out.log" 2>&1 || rc=$?
          [ "$rc" != 0 ] || assert_grep 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0' "$dir/out.log" \
            "$helper did not execute the Git fixture under $var" ;;
        *)
          # shellcheck disable=SC2016 # expanded by the child bash
          env "$var=$value" TMPDIR="$dir" bash -eu -c '. "$1"; . "$2"' _ "$ROOT/tests/$helper.sh" "$dir/setup.sh" \
            > "$dir/out.log" 2>&1 || rc=$? ;;
      esac
      # The ambient check comes first: it is the escape this case exists to catch.
      after=$(ambient_state)
      [ "$before" = "$after" ] \
        || fail "$helper fixture setup under $var changed the ambient repository: $(diff <(echo "$before") <(echo "$after"))"
      [ "$rc" = 0 ] || fail "$helper fixture setup failed under $var: $(cat "$dir/out.log")"
    done
  done
  pass "shared helpers and runner keep fixture Git off an inherited repository location"
)

test_duration_fixture_isolation() (
  local dir="$TMP_ROOT/duration-isolation" out
  mkdir -p "$dir/ambient/data" "$dir/isolated"
  printf 'existing production ledger\n' > "$dir/ambient/data/command-durations.jsonl"
  cp "$dir/ambient/data/command-durations.jsonl" "$dir/expected"
  out=$(FM_DURATION_FILE="$dir/ambient/data/command-durations.jsonl" \
    FM_DURATION_HOME="$dir/ambient" \
    FM_HOME="$dir/ambient" FM_DATA_OVERRIDE="$dir/ambient/data" \
    bash -eu -s -- "$ROOT" "$dir/isolated/durations.jsonl" <<'SH'
# shellcheck source=tests/lib.sh
. "$1/tests/lib.sh"
# shellcheck source=bin/fm-duration-lib.sh
. "$1/bin/fm-duration-lib.sh"
fm_duration_record fixture.ambient 42 0
[ "$FM_DURATION_FILE" = off ]
[ -z "${FM_DURATION_HOME:-}" ]
export FM_DURATION_FILE="$2"
fm_duration_record fixture.isolated 42 0
# Re-sourcing must retain an explicit fixture override, not reset test state.
# shellcheck source=tests/lib.sh
. "$1/tests/lib.sh"
fm_duration_record fixture.isolated 43 0
python3 - "$2" <<'PY'
import json
from pathlib import Path
import sys
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert [(row['key'], row['duration_ms'], row['exit']) for row in rows] == [('fixture.isolated', 42, 0), ('fixture.isolated', 43, 0)]
print('isolated samples: 42,43')
PY
SH
  ) || fail "fixture duration isolation failed: $out"
  cmp -s "$dir/ambient/data/command-durations.jsonl" "$dir/expected" \
    || fail "stubbed fixture command changed ambient production timing evidence"
  [ "$out" = 'isolated samples: 42,43' ] || fail "explicit fixture ledger did not retain measured samples: $out"
  pass "fixture timing defaults off, preserves production evidence, and explicitly isolated samples survive re-sourcing"
)

# A throwaway test file that sources tests/lib.sh and selects cases the way the
# real suites do, so the helper is exercised as a separate process with an exit
# status, never read from source.
write_selector_file() {  # <path> <env|positional|registered>
  local path=$1 mode=$2
  {
    printf '#!/usr/bin/env bash\nset -u\n. "%s/tests/lib.sh"\n' "$ROOT"
    cat <<'SH'
test_alpha() { printf 'ran-alpha\n'; }
test_beta() { printf 'ran-beta\n'; }
test_returns_seven() { printf 'ran-returns-seven\n'; return 7; }
test_calls_fail() { fail 'the case failed'; }
test_unregistered() { printf 'ran-unregistered\n'; }
helper_not_a_case() { printf 'ran-helper\n'; }
SH
    # shellcheck disable=SC2016 # The generated file expands these when it runs.
    case "$mode" in
      env) printf 'fm_test_only\ntest_alpha\ntest_beta\n' ;;
      positional) printf 'if [ "$#" -gt 0 ]; then fm_test_run_cases -- "$@"; exit 0; fi\ntest_alpha\ntest_beta\n' ;;
      registered) printf 'fm_test_before_case() { printf "before-%%s\\n" "$1"; }\ncases=(${FM_FIXTURE_CASES:-test_alpha test_beta})\nfm_test_run_cases "${cases[@]}" -- "$@"\n' ;;
    esac
  } >"$path"
}

test_single_case_selection() (
  local dir="$TMP_ROOT/select" out err rc
  mkdir -p "$dir"
  write_selector_file "$dir/env.test.sh" env
  write_selector_file "$dir/positional.test.sh" positional
  write_selector_file "$dir/registered.test.sh" registered
  run_file() {  # <env assignments...> -- <file> [args...]
    local -a assignments=()
    while [ "$1" != -- ]; do assignments+=("$1"); shift; done
    shift
    out=$(env "${assignments[@]}" bash "$@" 2>"$dir/err"); rc=$?
    err=$(cat "$dir/err")
  }

  # An unknown name is refused, names the case, and runs nothing.
  run_file FM_TEST_ONLY=test_renamed_away -- "$dir/env.test.sh"
  [ "$rc" -eq 2 ] || fail "an unknown FM_TEST_ONLY case exited $rc, expected 2: $out $err"
  case "$err" in *'Unknown test case: test_renamed_away'*) ;; *) fail "the refusal did not name the unknown case: $err" ;; esac
  [ -z "$out" ] || fail "a refused selection still ran a case: $out"
  run_file X=1 -- "$dir/positional.test.sh" test_alpha test_renamed_away
  [ "$rc" -eq 2 ] || fail "an unknown positional case exited $rc, expected 2: $out $err"
  [ -z "$out" ] || fail "a refused positional selection ran test_alpha before refusing: $out"
  pass "an unknown case name is refused with a message naming it, exit 2, and no case runs"

  # A name that is not a test_ function is never run as a command.
  for name in helper_not_a_case rm test_ 'test_alpha;printf pwned' 'test alpha'; do
    run_file "FM_TEST_ONLY=$name" -- "$dir/env.test.sh"
    [ "$rc" -eq 2 ] || fail "FM_TEST_ONLY='$name' exited $rc, expected 2: $out $err"
    [ -z "$out" ] || fail "FM_TEST_ONLY='$name' ran something: $out"
  done
  pass "a name that is not a defined test_ function is refused rather than executed"

  # A known case runs alone and its own status is the file's status.
  run_file FM_TEST_ONLY=test_beta -- "$dir/env.test.sh"
  [ "$rc" -eq 0 ] && [ "$out" = ran-beta ] || fail "a known passing case did not run alone and pass: rc=$rc out=$out"
  run_file FM_TEST_ONLY=test_returns_seven -- "$dir/env.test.sh"
  [ "$rc" -eq 7 ] || fail "a case returning 7 made the file exit $rc: $out"
  run_file FM_TEST_ONLY=test_calls_fail -- "$dir/env.test.sh"
  [ "$rc" -eq 1 ] || fail "a case calling fail made the file exit $rc: $out"
  run_file FM_TEST_ONLY= -- "$dir/env.test.sh"
  [ "$rc" -eq 0 ] && [ "$out" = $'ran-alpha\nran-beta' ] || fail "an empty FM_TEST_ONLY did not run the whole file: rc=$rc out=$out"
  pass "the selected case's own status is the file's status, and an empty selector runs everything"

  # Positional selection without a registry runs the named test_ functions in the order given.
  run_file X=1 -- "$dir/positional.test.sh" test_beta test_unregistered
  [ "$rc" -eq 0 ] && [ "$out" = $'ran-beta\nran-unregistered' ] || fail "positional cases did not run in the order given: rc=$rc out=$out"
  run_file X=1 -- "$dir/positional.test.sh" test_returns_seven test_alpha
  [ "$rc" -eq 7 ] && [ "$out" = ran-returns-seven ] || fail "the first failing positional case did not end the file: rc=$rc out=$out"

  # With a registry, only registered names are cases and they run in registration order.
  run_file X=1 -- "$dir/registered.test.sh" test_beta test_alpha
  [ "$rc" -eq 0 ] && [ "$out" = $'before-test_alpha\nran-alpha\nbefore-test_beta\nran-beta' ] \
    || fail "registered cases did not run in registration order with the before hook: rc=$rc out=$out"
  run_file X=1 -- "$dir/registered.test.sh"
  [ "$rc" -eq 0 ] && [ "$out" = $'before-test_alpha\nran-alpha\nbefore-test_beta\nran-beta' ] \
    || fail "no request did not run every registered case: rc=$rc out=$out"
  run_file X=1 -- "$dir/registered.test.sh" test_unregistered
  [ "$rc" -eq 2 ] && [ -z "$out" ] || fail "a defined but unregistered case was not refused: rc=$rc out=$out"
  run_file FM_FIXTURE_CASES='test_alpha test_returns_seven test_beta' -- "$dir/registered.test.sh"
  [ "$rc" -eq 7 ] && [ "$out" = $'before-test_alpha\nran-alpha\nbefore-test_returns_seven\nran-returns-seven' ] \
    || fail "a registered case returning 7 did not end the full run: rc=$rc out=$out"
  pass "a registry limits the cases, keeps registration order, runs the before hook, and stops at the first failing case"
)

# fm_test_only in tests/lib.sh is the only reader of FM_TEST_ONLY: a file that
# reads it itself can run an unknown name as a command or drop the case's exit
# status. Every file under the tests directory is searched, so a new selector
# needs no list entry. Prints file:line:text for each read outside lib.sh.
selector_reads_outside_lib() {  # <tests-dir>
  grep -rnIE '[$][{]?FM_TEST_ONLY([^A-Za-z0-9_]|$)' "$1" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | awk -v lib="$1/lib.sh:" 'index($0, lib) != 1'
}

test_only_lib_reads_the_case_selector() (
  local dir="$TMP_ROOT/selector-reads" found
  mkdir -p "$dir/sub"
  printf 'x=1\n"$%s"\n# "$%s"\n' FM_TEST_ONLY FM_TEST_ONLY >"$dir/sub/reads.sh"
  # shellcheck disable=SC2016 # The fixture file holds the unexpanded read.
  printf '[ -n "${%s:-}" ]\necho "$%s_AUTHOR"\n' FM_TEST_ONLY FM_TEST_ONLY >"$dir/other.test.sh"
  printf 'fm_test_only() { "$%s"; }\n' FM_TEST_ONLY >"$dir/lib.sh"
  found=$(selector_reads_outside_lib "$dir" | cut -d: -f1,2 | LC_ALL=C sort)
  [ "$found" = "$dir/other.test.sh:1"$'\n'"$dir/sub/reads.sh:2" ] \
    || fail "the selector check did not name exactly the two reads outside lib.sh: $found"
  pass "the selector check names each read outside lib.sh by file and line, and skips comments, lib.sh and other variables"

  found=$(selector_reads_outside_lib "$ROOT/tests")
  [ -z "$found" ] || fail "these test files read FM_TEST_ONLY themselves; select cases through fm_test_only in tests/lib.sh:
$found"
  pass "no test file reads FM_TEST_ONLY outside fm_test_only in tests/lib.sh"
)

test_duration_fixture_isolation || fail "Fixture duration isolation"
test_git_config_isolation || fail "Git fixture config isolation"
test_inherited_git_location_isolation || fail "Git fixture location isolation"
test_agent_standin_survives_a_multicall_sleep || fail "agent stand-in multicall case"
test_touch_epoch_preserves_repeated_dst_hour
test_no_mistakes_version_constant
test_no_mistakes_init_doctor_markers
test_fake_gh_and_gh_axi
test_spawn_tmux_and_fakebin
test_send_stubs_and_ssh
test_spawn_home_layout
test_single_case_selection || fail "Single-case selection"
test_only_lib_reads_the_case_selector || fail "Single-case selector ownership"
