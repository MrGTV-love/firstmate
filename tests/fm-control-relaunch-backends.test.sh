#!/usr/bin/env bash
# Backend and host surfaces around bin/fm-control.sh relaunch: secondmate
# child-work safety, lifecycle-lock participation, TeamClaude on every
# relaunch path, Herdr lifecycle admission, bounded reboot recovery, and the
# quota routes that decide whether a replacement may launch.
# The core relaunch contract and fm-spawn --relaunch's own refusals live in
# tests/fm-control-relaunch.test.sh; recovery, relocation, and continuation
# authorization live in tests/fm-control-relaunch-recovery.test.sh.
# Shared fixtures: tests/fm-control-relaunch-helpers.sh.

# shellcheck source=tests/fm-control-relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-helpers.sh"

test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter() {
  local dir home out rc
  dir=$(new_case sm sm1)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm1\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  {
    echo "window=fmses:fm-sm1"
    echo "endpoint_task_id=sm1"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm1.meta"
  printf '%s\n' "fm-sm1" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  # No --note: a secondmate reconciles its own home's records at startup, so
  # the note is optional there.
  out=$(run_control "$dir" sm1 relaunch); rc=$?
  expect_code 0 "$rc" "a checkpointed secondmate should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm1 children)" = 2 ] \
    || fail "the checkpoint must account for the secondmate's child work, got '$(journal_field "$dir" sm1 children)'"
  assert_not_contains "$out" "requires --note" "a secondmate relaunch must not demand a progress note"
  [ "$(cat "$dir/smhome/data/charter.md")" = "# charter" ] \
    || fail "a secondmate's standing charter must never be rewritten by a relaunch"
  assert_present "$dir/smhome/state/c1.meta" "child records must survive the relaunch"
  assert_present "$dir/smhome/state/c2.meta" "child records must survive the relaunch"
  pass "fm-control relaunch: a secondmate's child work is accounted for and its charter is left alone"
}

test_default_secondmate_relaunch_survives_unsafe_routing_sources() {
  local dir home source_kind out rc
  for source_kind in dangling directory; do
    dir=$(new_case "default-routing-$source_kind" sm-default)
    home="$dir/home"
    mkdir -p "$home/config"
    printf 'claude\n' > "$home/config/secondmate-harness"
    printf 'codex\n' > "$home/config/crew-harness"
    case "$source_kind" in
      dangling) ln -s "$home/missing-index" "$home/config/model-index.json" ;;
      directory) mkdir "$home/config/crew-dispatch.json" ;;
    esac
    fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
    mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/config" "$dir/smhome/bin"
    printf 'sm-default\n' > "$dir/smhome/.fm-secondmate-home"
    printf '# charter\n' > "$dir/smhome/data/charter.md"
    printf '# agents\n' > "$dir/smhome/AGENTS.md"
    printf 'config/\n' > "$dir/smhome/.gitignore"
    {
      printf 'window=fmses:fm-sm-default\nendpoint_task_id=sm-default\n'
      printf 'worktree=%s\nproject=%s\nhome=%s\n' "$dir/smhome" "$dir/smhome" "$dir/smhome"
      printf 'harness=claude\nkind=secondmate\nmode=secondmate\nyolo=off\nmodel=default\neffort=default\n'
    } > "$home/state/sm-default.meta"
    printf 'fm-sm-default\n' > "$dir/fake/windows"
    printf '%s' "$dir/smhome" > "$dir/fake/cwd"
    out=$(run_control "$dir" sm-default relaunch); rc=$?
    expect_code 0 "$rc" "default secondmate relaunch must survive $source_kind routing source"$'\n'"$out"
    [ "$(cat "$dir/fake/command")" = claude ] || fail 'default-model replacement left no running agent'
    [ "$(journal_field "$dir" sm-default phase)" = complete ] || fail 'default-model replacement did not complete'
    [ "$(meta_field "$dir" sm-default model)" = default ] || fail 'default-model replacement changed model selection'
    [ "$(cat "$dir/smhome/config/crew-harness")" = codex ] || fail 'routing refusal blocked unrelated inheritance'
    assert_contains "$out" 'inheritance failed' 'unsafe routing source must remain a warning'
  done
  pass 'default-model secondmate replacements keep warning-only routing inheritance'
}

test_secondmate_relaunch_refuses_an_unmarked_home() {
  local dir home out rc
  dir=$(new_case smbad sm2)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state"
  printf 'someone-else\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm2"
    echo "endpoint_task_id=sm2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
  } > "$home/state/sm2.meta"
  printf '%s\n' "fm-sm2" > "$dir/fake/windows"
  out=$(run_control "$dir" sm2 relaunch); rc=$?
  expect_code 1 "$rc" "a home marked for another secondmate should refuse"
  assert_contains "$out" "not marked as its own seeded secondmate home" \
    "the refusal should name the identity mismatch"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a secondmate home that is not this secondmate's is refused"
}

test_secondmate_checkpoint_refuses_unreadable_child_state() {
  local dir home out rc
  dir=$(new_case smchildren sm5)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state/bad.meta"
  printf 'sm5\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm5"
    echo "endpoint_task_id=sm5"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "home=$dir/smhome"
  } > "$home/state/sm5.meta"
  printf '%s\n' "fm-sm5" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  expect_code 1 "$rc" "a non-readable child record should refuse"
  assert_contains "$out" "not a readable regular file" "the refusal should name the unreadable child record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "child record failure must not stop the secondmate"
  pass "fm-control relaunch: unreadable child records fail checkpoint"
  if [ "$(id -u)" = 0 ]; then
    pass "fm-control relaunch: unlistable state check skipped as root (mode 000 does not restrict root)"
    return 0
  fi
  rmdir "$dir/smhome/state/bad.meta"
  printf 'window=x:c1\n' > "$dir/smhome/state/c1.meta"
  chmod 000 "$dir/smhome/state"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  chmod 755 "$dir/smhome/state"
  expect_code 1 "$rc" "an unlistable state directory should refuse"
  assert_contains "$out" "no readable state directory" \
    "the refusal should name the unlistable home state directory"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "unlistable child state must not stop the secondmate"
  pass "fm-control relaunch: unlistable state fails checkpoint"
}

test_secondmate_checkpoint_ignores_a_vanished_scratch_find_walk() {
  local dir home out rc real_find
  dir=$(new_case smfindrace sm6)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  : > "$dir/smhome/state/.hash-0"
  : > "$dir/smhome/state/.count-0"
  : > "$dir/smhome/state/.last-0"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  real_find=$(command -v find)
  cat > "$dir/fakebin/find" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "$dir/smhome/state" ]; then
    echo "find: \$arg/.hash-0: No such file or directory" >&2
    exit 1
  fi
done
exec "$real_find" "\$@"
SH
  chmod +x "$dir/fakebin/find"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "a vanished watcher scratch file must not refuse relaunch"$'\n'"$out"
  assert_contains "$out" "relaunched sm6" "readable child metas must still allow the replacement launch"
  [ "$(journal_field "$dir" sm6 children)" = 2 ] \
    || fail "readable child metas must still be counted, got '$(journal_field "$dir" sm6 children)'"
  pass "fm-control relaunch: a vanished watcher scratch file does not fail the child-record checkpoint"
}

test_concurrent_relaunch_is_refused() {
  local dir out rc lock holder ready i
  dir=$(new_case lock rl19)
  add_ship_task "$dir" rl19 claude
  lock="$dir/home/state/.control-rl19.lock"
  ready="$dir/control-lock-ready"
  # A live holder of this task's control lock, taken through the same lock
  # library fm-control uses.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  i=0
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true; fail "could not stage a held control lock"; }
  [ -e "$lock" ] || { kill "$holder" 2>/dev/null; fail "could not stage a held control lock"; }
  printf 'held\n' > "$dir/home/state/rl19.composer-dialog"
  out=$(run_control "$dir" rl19 relaunch --note "concurrent"); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "a second concurrent control action should refuse"
  assert_contains "$out" "another lifecycle action is already running" \
    "the refusal should name the concurrent action"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused concurrent relaunch must not stop the agent"
  [ "$(cat "$dir/home/state/rl19.composer-dialog" 2>/dev/null)" = held ] \
    || fail "a refused concurrent relaunch must not remove the lock holder's dialog file"
  pass "fm-control relaunch: two control actions on one task serialize instead of interleaving"
}

test_direct_spawn_relaunch_participates_in_the_lifecycle_lock() {
  local dir out rc lock holder ready i=0
  dir=$(new_case spawnlock rl26)
  add_ship_task "$dir" rl26 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.control-rl26.lock"
  ready="$dir/spawn-lock-ready"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true; fail "could not stage the lifecycle lock"; }
  out=$(run_spawn "$dir" rl26 --relaunch --harness claude); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "direct relaunch spawn should refuse a held lifecycle lock"
  assert_contains "$out" "another lifecycle action is already running" \
    "direct relaunch spawn should name lifecycle contention"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "contended direct relaunch spawn must deliver no launch bytes"
  pass "fm-spawn relaunch: direct entry participates in lifecycle serialization"
}

test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution() {
  local dir out rc lock holder ready i=0
  dir=$(new_case promotelock rl29)
  add_ship_task "$dir" rl29 claude
  lock="$dir/home/state/.control-rl29.lock"
  ready="$dir/promotion-lock-ready"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || { kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true; fail "could not stage the promotion lifecycle lock"; }
  out=$(FM_HOME="$dir/home" "$PROMOTE" rl29 --mode direct-PR --yolo on 2>&1); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "promotion should refuse a concurrent lifecycle action"
  assert_contains "$out" "another lifecycle action is already running" \
    "promotion should lock before interpreting the task metadata"
  [ "$(meta_field "$dir" rl29 kind)" = ship ] \
    || fail "a contended promotion must leave task metadata unchanged"
  pass "fm-promote: promotion participates in lifecycle serialization"
}

test_teamclaude_reaches_tmux_relaunch_paths() {
  local dir out rc
  dir=$(new_case tc-tmux-spawn tc1)
  add_ship_task "$dir" tc1 claude
  enable_teamclaude "$dir"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" tc1 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "a TeamClaude fm-spawn --relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(teamclaude_launch_line "$dir/fake/literal")" \
    "tmux fm-spawn --relaunch"

  dir=$(new_case tc-tmux-control tc2)
  add_ship_task "$dir" tc2 claude
  enable_teamclaude "$dir"
  out=$(run_control "$dir" tc2 relaunch --note "resume under TeamClaude"); rc=$?
  expect_code 0 "$rc" "a TeamClaude fm-control relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(teamclaude_launch_line "$dir/fake/literal")" \
    "tmux fm-control relaunch"

  dir=$(new_case tc-tmux-session-end tc3)
  add_ship_task "$dir" tc3 claude
  enable_teamclaude "$dir"
  arm_session_end "$dir" tc3
  printf 'zsh' > "$dir/fake/command"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "the session-end scan should succeed"$'\n'"$out"
  assert_contains "$out" "tc3 auto-relaunched after session-end" \
    "the session-end scan should relaunch the ended worker"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(teamclaude_launch_line "$dir/fake/literal")" \
    "tmux session-end auto-relaunch"
  pass "config/claude-launcher=teamclaude: tmux fm-spawn --relaunch, fm-control relaunch, and session-end auto-relaunch reach claude through TeamClaude"
}

test_teamclaude_reaches_herdr_relaunch_paths() {
  local dir id out rc
  recovery_case_or_skip tc-herdr-spawn tc4 || {
    echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  enable_teamclaude "$dir"
  out=$(run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "a TeamClaude herdr fm-spawn --relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "herdr fm-spawn --relaunch"

  recovery_case_or_skip tc-herdr-control tc5 || return 0
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  enable_teamclaude "$dir"
  rm -f "$dir/fake/herdr-stopped"
  out=$(run_control "$dir" "$id" relaunch --note "resume under TeamClaude"); rc=$?
  expect_code 0 "$rc" "a TeamClaude herdr fm-control relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "herdr fm-control relaunch"

  recovery_case_or_skip tc-herdr-session-end tc6 || return 0
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  enable_teamclaude "$dir"
  rm -f "$dir/fake/herdr-stopped"
  arm_session_end "$dir" "$id"
  out=$(run_session_end_scan "$dir"); rc=$?
  expect_code 0 "$rc" "the herdr session-end scan should succeed"$'\n'"$out"
  assert_contains "$out" "$id auto-relaunched after session-end" \
    "the session-end scan should relaunch the ended herdr worker"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "herdr session-end auto-relaunch"
  pass "config/claude-launcher=teamclaude: herdr fm-spawn --relaunch, fm-control relaunch, and session-end auto-relaunch reach claude through TeamClaude"
}

test_concrete_ask_admission_completes_fresh_spawns() {
  local kind id dir home project wt fakebin out
  local args=()
  for kind in ship scout; do
    id="ask-admitted-$kind"
    # shellcheck disable=SC2031 # Only the ownership fixture's child subshell reassigns TMP_ROOT; this reads the parent's root.
    dir="$TMP_ROOT/$id"
    home="$dir/home" project="$dir/project" wt="$dir/wt"
    fakebin=$(fm_test_make_spawn_fakebin "$dir/tools" codex gh-axi)
    fm_test_spawn_home "$home" codex
    fm_git_worktree "$project" "$wt" "task-$id"
    fm_test_spawn_brief "$home" "$id" 'Fix the badge refresh without redesigning the dashboard.'
    if [ "$kind" = ship ]; then args=(--mode direct-PR --yolo off); else args=(--scout); fi
    out=$(FM_BACKEND=tmux FM_FAKE_LAUNCH_LOG="$dir/launch.log" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$project" --harness codex "${args[@]}") \
      || fail "$kind: substantive ask did not complete spawn: $out"
    assert_contains "$out" "spawned $id" "$kind: no completed launch was reported"
    assert_grep "kind=$kind" "$home/state/$id.meta" "$kind: launched task lost its kind"
  done
  pass 'fm-spawn: substantive ship/scout asks complete launch with isolated fake runtime state'
}

# A charter is not a fresh project task and must not be judged as one.
test_fresh_charter_bypasses_concrete_ask_check() {
  local dir id=charter-ask home smhome out
  dir=$(new_case charter-ask "$id")
  home="$dir/home"
  smhome="$dir/$id-home"
  add_teamclaude_secondmate "$dir" "$id"
  rm "$home/state/$id.meta"
  : > "$dir/fake/windows"
  printf 'See report.md.\n' > "$smhome/data/charter.md"
  out=$(run_spawn "$dir" "$id" "$smhome" --secondmate --harness claude) \
    || fail "fresh charter must bypass concrete-ask check: $out"
  assert_contains "$out" "spawned $id" 'fresh charter never launched'
  assert_not_contains "$out" 'has no concrete ask' 'charter was treated as a project intent'
  assert_grep 'kind=secondmate' "$home/state/$id.meta" 'charter launch lost its supervisor kind'
  pass 'fm-spawn: fresh secondmate charters bypass the concrete-ask minimum'
}

test_teamclaude_reaches_secondmate_respawn_on_both_backends() {
  local dir id out rc
  dir=$(new_case tc-tmux-secondmate tc7)
  printf 'window=fmses:fm-tc7\n' > "$dir/home/state/tc7.meta"
  add_teamclaude_secondmate "$dir" tc7
  printf '%s\n' "fm-tc7" > "$dir/fake/windows"
  enable_teamclaude "$dir"
  out=$(run_control "$dir" tc7 relaunch); rc=$?
  expect_code 0 "$rc" "a TeamClaude tmux secondmate relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(teamclaude_launch_line "$dir/fake/literal")" \
    "tmux secondmate respawn"

  recovery_case_or_skip tc-herdr-secondmate tc8 || {
    echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  grep -E '^(window|backend|herdr_[a-z_]+)=' "$dir/home/state/$id.meta" > "$dir/meta.endpoint"
  mv "$dir/meta.endpoint" "$dir/home/state/$id.meta"
  add_teamclaude_secondmate "$dir" "$id"
  enable_teamclaude "$dir"
  rm -f "$dir/fake/herdr-stopped"
  out=$(run_control "$dir" "$id" relaunch); rc=$?
  expect_code 0 "$rc" "a TeamClaude herdr secondmate relaunch should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "herdr secondmate respawn"
  pass "config/claude-launcher=teamclaude: a Claude second mate respawns through TeamClaude on tmux and herdr"
}

# A stopped proxy or a malformed launcher file must refuse while the old agent
# still runs: fm-spawn --relaunch would refuse too, but only after fm-control
# had already stopped it.
test_teamclaude_refusal_lands_before_the_old_agent_stops() {
  local dir out rc id=tc-stop
  dir=$(new_case tc-stopped "$id")
  add_ship_task "$dir" "$id" claude
  enable_teamclaude "$dir"
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  out=$(FM_FAKE_TEAMCLAUDE_STATUS=1 run_control "$dir" "$id" relaunch --note "proxy stopped"); rc=$?
  expect_code 1 "$rc" "a relaunch with the TeamClaude proxy stopped must refuse"
  assert_contains "$out" "proxy is not running" "the refusal should name the stopped proxy"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a stopped proxy must refuse before the running agent stops"
  [ ! -s "$dir/fake/literal" ] || fail "a stopped proxy must refuse before any lifecycle input is sent"
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "a refused relaunch must leave the task record untouched"

  printf 'proxy\n' > "$dir/home/config/claude-launcher"
  out=$(run_control "$dir" "$id" relaunch --note "malformed launcher"); rc=$?
  expect_code 1 "$rc" "a relaunch with a malformed config/claude-launcher must refuse"
  assert_contains "$out" "the only accepted value is teamclaude" "the refusal should name the accepted value"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a malformed launcher file must refuse before the running agent stops"
  [ ! -s "$dir/fake/literal" ] || fail "a malformed launcher file must refuse before any lifecycle input is sent"
  pass "fm-control relaunch: a stopped TeamClaude proxy or malformed launcher file refuses before the old agent stops"
}

# A fresh herdr spawn needs no relaunch, but it shares this suite's herdr
# stub: the pane the stub's `tab create` mints reads back in the task's copy.
test_teamclaude_reaches_fresh_herdr_spawns() {
  local dir out rc
  command -v jq >/dev/null 2>&1 || {
    echo "skip - herdr spawn needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$(new_case tc-herdr-fresh tc9)
  make_herdr_stub "$dir"
  fm_fake_exit0 "$dir/fakebin" treehouse
  fm_git_worktree "$dir/proj" "$dir/wt" task-tc9
  fm_test_spawn_brief "$dir/home" tc9
  mkdir -p "$dir/home/projects"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  printf '%s' "$dir/wt" > "$dir/fake/herdr-treehouse-worktree"
  printf '%s' '%9' > "$dir/fake/herdr-pane"
  enable_teamclaude "$dir"
  # shellcheck disable=SC2031 # Register in the parent; the collision fixture resets only its child copy.
  TASK_TMPS+=("/tmp/fm-tc9")
  out=$(run_spawn "$dir" tc9 "$dir/proj" claude --backend herdr --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "a TeamClaude fresh herdr spawn should succeed"$'\n'"$out"
  assert_contains "$(cat "$dir/fake/herdr-log")" "tab create" "the fresh spawn should open its own herdr tab"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "fresh herdr ship spawn"

  dir=$(new_case tc-herdr-fresh-secondmate tc10)
  make_herdr_stub "$dir"
  printf '%s' '%9' > "$dir/fake/herdr-pane"
  add_teamclaude_secondmate "$dir" tc10
  rm "$dir/home/state/tc10.meta"
  enable_teamclaude "$dir"
  out=$(run_spawn "$dir" tc10 "$dir/tc10-home" --secondmate --backend herdr); rc=$?
  expect_code 0 "$rc" "a TeamClaude fresh herdr secondmate spawn should succeed"$'\n'"$out"
  fm_test_assert_teamclaude_launch "$dir/fakebin" "$(cat "$dir/fake/launched-command")" \
    "fresh herdr secondmate launch"
  pass "config/claude-launcher=teamclaude: fresh herdr ship and second mate launches reach claude through TeamClaude"
}

test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case reverify rl40)
  add_ship_task "$dir" rl40 claude
  seed_backlog "$dir" rl40 in_flight
  break_tasks_axi_start "$dir"

  out=$(run_control "$dir" rl40 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch must not re-run a transition the row already reflects"$'\n'"$out"
  [ "$(backlog_state "$dir" rl40)" = in_flight ] \
    || fail "a relaunch changed an already In-flight item to $(backlog_state "$dir" rl40)"
  pass "relaunch re-reads the backlog item instead of blindly re-running the transition"
}

test_relaunch_moves_a_drifted_item_back_in_flight() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case drifted rl41)
  add_ship_task "$dir" rl41 claude
  seed_backlog "$dir" rl41 queued

  out=$(run_control "$dir" rl41 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch onto a drifted item should succeed"$'\n'"$out"
  [ "$(backlog_state "$dir" rl41)" = in_flight ] \
    || fail "a relaunch left its item at $(backlog_state "$dir" rl41)"
  pass "relaunch heals an item that drifted out of In flight while the task stayed live"
}

test_live_herdr_lifecycle_refuses_unmanaged_native_launches_without_mutation() {
  local dir id kind proof action scenario out rc gen busy draft before head_before work_before suffix
  local CONTROL="$ROOT/bin/fm-control.sh" preserved=() case_index=0
  for kind in ${2:-ship scout secondmate}; do
  for proof in ${3:-env-v1 legacy}; do
    for action in ${4:-exit busy-exit relaunch interrupt spawn}; do
      for scenario in ${1:-different-cwd same-cwd-personal historical-startup in-process-personal pinned-personal mismatched unreadable missing-registration}; do
        [ "$proof" != legacy ] || [ "$action" = spawn ] || continue
        case_index=$((case_index + 1))
        recovery_case_or_skip "ownership-$kind-$proof-$action-$scenario" "owner-$case_index" \
          || fail "live lifecycle ownership regression requires jq"
        dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
        prepare_herdr_recovery "$dir" "$id" "$kind"
        [ "$proof" != legacy ] || printf 'launch_proof=\n' >> "$dir/home/state/$id.meta"
        case "$scenario" in
          missing-registration) : > "$dir/fake/recovery-registration-missing" ;;
          different-cwd|same-cwd-personal)
            printf '%s' "$dir/wt/personal-session.jsonl" > "$dir/fake/recovery-process-ref"
            printf '%s' "$dir/wt/personal-session.jsonl" > "$dir/fake/recovery-registration-ref"
            ;;
          in-process-personal|pinned-personal)
            printf '["omp","--resume=%s"]' "$dir/wt/recorded-session.jsonl" > "$dir/fake/recovery-process-argv"
            printf '%s' "$dir/wt/personal-session.jsonl" > "$dir/fake/recovery-registration-ref"
            if [ "$scenario" = pinned-personal ]; then
              printf old > "$dir/fake/recovery-spawn-gen"
              write_recovery_session_proof "$dir" "$id" "$dir/wt/personal-session.jsonl"
            fi
            ;;
          mismatched) printf other > "$dir/fake/recovery-spawn-gen" ;;
          unreadable) : > "$dir/fake/recovery-env-unreadable" ;;
        esac
        if [ "$scenario" = different-cwd ]; then
          printf '%s' "$dir/proj" > "$dir/fake/recovery-process-cwd"
          write_recovery_native_session "$dir/wt/personal-session.jsonl" "$dir/proj" "personal task unrelated to Firstmate"
        fi
        busy=busy draft='!git diff'
        if [ "$action" = exit ]; then busy=idle draft=; fi
        printf '%s' "$draft" > "$dir/fake/recovery-pending"
        gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id" \
          --state "$busy" --source omp-ext --event agent-start) || fail "could not arm lifecycle ownership fixture"
        printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/$id.meta"
        printf 'working: preserve the recorded task\n' > "$dir/home/state/$id.status"
        preserved=("$dir/home/state/$id.meta" "$dir/home/state/$id.status"
          "$dir/home/state/$id.busy-gen" "$dir/home/state/$id.busy-state"
          "$dir/home/data/$id/brief.md" "$dir/fake/recovery-pending" "$dir/wt/unlanded.txt"
          "$dir/wt/recorded-session.jsonl" "$dir/wt/personal-session.jsonl")
        preserved+=("$dir/fake/recovery-pid" "$dir/fake/recovery-spawn-gen" "$dir/fake/recovery-session-ref")
        preserved+=("$dir/home/state/$id.omp-session.json")
        case "$scenario" in in-process-personal|pinned-personal)
          preserved+=("$dir/fake/recovery-process-argv" "$dir/fake/recovery-registration-ref") ;; esac
        [ "$kind" != secondmate ] || preserved+=("$dir/wt/AGENTS.md" "$dir/wt/data/charter.md")
        before=$(shasum -a 256 "${preserved[@]}")
        head_before=$(git -C "$dir/wt" rev-parse HEAD)
        work_before=$(git -C "$dir/wt" status --porcelain)
        rc=0
        case "$action" in
          spawn) out=$(run_spawn "$dir" "$id" --relaunch --harness omp) || rc=$? ;;
          relaunch) out=$(run_control "$dir" "$id" relaunch --note "preserve the live task") || rc=$? ;;
          busy-exit) out=$(run_control "$dir" "$id" exit) || rc=$? ;;
          *) out=$(run_control "$dir" "$id" "$action") || rc=$? ;;
        esac
        expect_code 1 "$rc" "$proof/$action/$scenario must refuse personal lifecycle input"$'\n'"$out"
        if [ "$action" = spawn ]; then
          assert_contains "$out" "positively agent-free endpoint" "direct spawn must refuse its live endpoint"
        else
          assert_contains "$out" "cannot positively attribute its live Herdr agent" "refusal must name missing live task ownership"
        fi
        assert_not_contains "$(cat "$dir/fake/herdr-log")" "pane send-" "personal pane must receive no lifecycle input"
        assert_present "$dir/fake/herdr-agent-live" "personal agent must remain live"
        [ "$before" = "$(shasum -a 256 "${preserved[@]}")" ] \
          || fail "$proof/$action/$scenario changed draft, metadata, brief, status, busy records or work"
        [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] \
          && [ "$(git -C "$dir/wt" status --porcelain)" = "$work_before" ] \
          || fail "$proof/$action/$scenario changed the task checkout"
        for suffix in control-relaunch control-relaunch.note control-relaunch.meta-prior control-relaunch.brief-prior control-exit; do
          assert_absent "$dir/home/state/$id.$suffix" "ownership refusal must leave no $suffix marker"
        done
        assert_absent "$dir/fake/exit-pending" "ownership refusal must not stage an exit"
        assert_absent "$dir/fake/launched-command" "ownership refusal must not stage a replacement"
        assert_absent "$dir/home/state/.control-$id.lock" "ownership refusal must release the control lock"
        assert_absent "$dir/home/state/.meta-$id.lock" "ownership refusal must release the metadata lock"
      done
    done
  done
  done
  pass "all lifecycle verbs refuse native startup and pinned personal session switches without input or task mutation"
}

test_legacy_herdr_record_keeps_prior_lifecycle_rule() {
  local dir id action out rc gen before CONTROL="$ROOT/bin/fm-control.sh"
  for action in exit relaunch; do
    recovery_case_or_skip "legacy-lifecycle-$action" "legacy-$action" \
      || fail "legacy lifecycle regression requires jq"
    dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
    prepare_herdr_recovery "$dir" "$id" ship
    printf 'launch_proof=\n' >> "$dir/home/state/$id.meta"
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id" \
      --state idle --source omp-ext --event agent-start) || fail "could not arm legacy lifecycle fixture"
    printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/$id.meta"
    printf 'working: preserve legacy task progress\n' > "$dir/home/state/$id.status"
    before=$(shasum -a 256 "$dir/wt/unlanded.txt")
    rc=0
    if [ "$action" = relaunch ]; then
      out=$(run_control "$dir" "$id" relaunch --note "continue legacy work") || rc=$?
    else
      out=$(run_control "$dir" "$id" exit) || rc=$?
    fi
    expect_code 0 "$rc" "legacy record without a launch pin must keep $action"$'\n'"$out"
    [ "$before" = "$(shasum -a 256 "$dir/wt/unlanded.txt")" ] || fail "legacy $action changed preserved work"
    if [ "$action" = relaunch ]; then
      [ "$(journal_field "$dir" "$id" phase)" = complete ] || fail "legacy relaunch did not complete"
      [ "$(meta_field "$dir" "$id" launch_proof)" = env-v1 ] || fail "legacy relaunch must publish a proven launch"
      [ "$(meta_field "$dir" "$id" spawn_gen)" != old ] || fail "legacy relaunch kept the old incarnation"
      assert_present "$dir/fake/launched-command" "legacy relaunch must deliver its replacement"
      assert_present "$dir/fake/herdr-agent-live" "legacy relaunch must leave a live replacement"
    else
      assert_contains "$out" "stopped $id" "legacy exit must report a confirmed stop"
      assert_absent "$dir/fake/herdr-agent-live" "legacy exit must stop its agent"
    fi
    assert_absent "$dir/home/state/.control-$id.lock" "legacy $action must release its control lock"
  done
  pass "legacy Herdr records without a launch pin keep exit and relaunch"
}

test_herdr_shell_only_ordinary_lifecycle_accepts_missing_registration() {
  local dir id action out rc before CONTROL="$ROOT/bin/fm-control.sh"
  for action in exit relaunch; do
    recovery_case_or_skip "ordinary-shell-$action" "ordinary-shell-$action" \
      || fail "ordinary shell lifecycle regression requires jq"
    dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
    prepare_herdr_recovery "$dir" "$id" ship
    : > "$dir/fake/recovery-registration-missing"
    rm "$dir/fake/herdr-agent-live"
    before=$(shasum -a 256 "$dir/wt/unlanded.txt" "$dir/wt/recorded-session.jsonl")
    rc=0
    if [ "$action" = relaunch ]; then
      out=$(run_control "$dir" "$id" relaunch --note "continue from the idle shell") || rc=$?
    else
      out=$(run_control "$dir" "$id" exit) || rc=$?
    fi
    expect_code 0 "$rc" "ordinary $action must accept a positively shell-only pane"$'\n'"$out"
    assert_contains "$(cat "$dir/fake/herdr-log")" "pane process-info" "shell admission must consult process evidence"
    [ "$before" = "$(shasum -a 256 "$dir/wt/unlanded.txt" "$dir/wt/recorded-session.jsonl")" ] \
      || fail "ordinary shell $action changed preserved work"
    if [ "$action" = relaunch ]; then
      [ "$(journal_field "$dir" "$id" phase)" = complete ] || fail "ordinary shell relaunch did not complete"
      assert_present "$dir/fake/launched-command" "ordinary shell relaunch must launch its replacement"
      assert_present "$dir/fake/herdr-agent-live" "ordinary shell relaunch must leave its replacement live"
    else
      assert_contains "$out" already-stopped "ordinary shell exit must report already stopped"
      assert_not_contains "$(cat "$dir/fake/herdr-log")" "pane send-" "ordinary shell exit must send no input"
      assert_absent "$dir/fake/launched-command" "ordinary shell exit must not launch"
      assert_absent "$dir/home/state/$id.control-relaunch" "ordinary shell exit must not checkpoint"
    fi
    assert_absent "$dir/home/state/.control-$id.lock" "ordinary shell action must release its control lock"
  done
  pass "ordinary lifecycle accepts genuine unregistered shell panes with process-table proof"
}

test_live_herdr_lifecycle_accepts_managed_launches() {
  local dir id proof launch action out rc gen busy before head_before log meta_before brief_before status_before
  local CONTROL="$ROOT/bin/fm-control.sh"
  for proof in ${1:-env-v1 legacy}; do
    for launch in ${2:-managed missing-registration}; do
      for action in ${3:-interrupt exit busy-exit relaunch}; do
        recovery_case_or_skip "owned-$proof-$launch-$action" "owned-$proof-$launch-$action" \
          || fail "positive lifecycle ownership regression requires jq"
        dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
        prepare_herdr_recovery "$dir" "$id" ship
        [ "$proof" != legacy ] || printf 'launch_proof=\n' >> "$dir/home/state/$id.meta"
        if [ "$launch" = managed ]; then
          printf old > "$dir/fake/recovery-spawn-gen"
          printf node > "$dir/fake/recovery-harness"
          printf '["node","/installed/agent.js"]' > "$dir/fake/recovery-process-argv"
          printf '%s' "$dir/proj" > "$dir/fake/recovery-process-cwd"
        fi
        if [ "$launch" = missing-registration ]; then
          : > "$dir/fake/recovery-registration-missing"
          printf old > "$dir/fake/recovery-spawn-gen"
        fi
        busy=idle
        [ "$action" != busy-exit ] || busy=busy
        gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id" \
          --state "$busy" --source omp-ext --event agent-start) || fail "could not arm owned lifecycle fixture"
        printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/$id.meta"
        printf 'working: preserve task progress\n' > "$dir/home/state/$id.status"
        before=$(shasum -a 256 "$dir/wt/unlanded.txt" "$dir/wt/recorded-session.jsonl")
        head_before=$(git -C "$dir/wt" rev-parse HEAD)
        # exit retires the armed busy generation and drops its record, so the
        # identity comparison covers every other field.
        meta_before=$(grep -v '^busy_gen=' "$dir/home/state/$id.meta" | shasum -a 256)
        brief_before=$(shasum -a 256 "$dir/home/data/$id/brief.md")
        status_before=$(shasum -a 256 "$dir/home/state/$id.status")
        rc=0
        case "$action" in
          relaunch) out=$(run_control "$dir" "$id" relaunch --note "continue owned work") || rc=$? ;;
          busy-exit) out=$(run_control "$dir" "$id" exit) || rc=$? ;;
          *) out=$(run_control "$dir" "$id" "$action") || rc=$? ;;
        esac
        expect_code 0 "$rc" "$proof/$launch/$action must accept positive task attribution"$'\n'"$out"
        log=$(cat "$dir/fake/herdr-log")
        [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] \
          && [ "$before" = "$(shasum -a 256 "$dir/wt/unlanded.txt" "$dir/wt/recorded-session.jsonl")" ] \
          || fail "$proof/$launch/$action changed preserved task work"
        [ "$status_before" = "$(shasum -a 256 "$dir/home/state/$id.status")" ] \
          || fail "$proof/$launch/$action changed task status"
        if [ "$action" = relaunch ]; then
          [ "$(journal_field "$dir" "$id" phase)" = complete ] || fail "owned relaunch did not complete"
          [ "$(meta_field "$dir" "$id" spawn_gen)" != old ] || fail "owned relaunch kept the old incarnation"
          [ "$(meta_field "$dir" "$id" window)" = 'fmlab:%7' ] || fail "owned relaunch moved the pane"
          [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] || fail "owned relaunch moved the local copy"
          [ "$(meta_field "$dir" "$id" model)" = openai-codex/gpt-6-astra ] || fail "owned relaunch changed model"
          [ "$(meta_field "$dir" "$id" effort)" = high ] || fail "owned relaunch changed effort"
          assert_present "$dir/fake/herdr-agent-live" "owned relaunch must leave a live replacement"
          assert_present "$dir/fake/launched-command" "owned relaunch must deliver its replacement"
        else
          [ "$meta_before" = "$(grep -v '^busy_gen=' "$dir/home/state/$id.meta" | shasum -a 256)" ] \
            && [ "$brief_before" = "$(shasum -a 256 "$dir/home/data/$id/brief.md")" ] \
            || fail "$proof/$launch/$action changed task identity or instructions"
          assert_absent "$dir/home/state/$id.control-relaunch" "ordinary lifecycle action must not checkpoint"
          if [ "$action" = interrupt ]; then
            assert_contains "$out" interrupt-delivered "owned interrupt must report delivery"
            assert_present "$dir/fake/herdr-agent-live" "owned interrupt must leave the agent live"
            assert_contains "$log" "pane send-keys %7 escape" "owned interrupt must deliver Escape"
          else
            assert_contains "$out" "stopped $id" "owned exit must report a confirmed stop"
            assert_absent "$dir/fake/herdr-agent-live" "owned exit must stop its agent"
            assert_present "$dir/home/state/$id.control-exit" "owned exit must record its deliberate stop"
            if [ "$action" = busy-exit ]; then
              assert_contains "$log" "pane send-keys %7 escape" "owned busy exit must interrupt first"
            else
              assert_not_contains "$log" "pane send-keys %7 escape" "owned idle exit must not interrupt"
            fi
          fi
        fi
      done
    done
  done
  pass "managed versioned and legacy launches retain interrupt, exit, busy-exit and same-pane relaunch"
}

test_managed_herdr_relaunch_refuses_unproven_replacement_env() {
  local dir id pin out rc CONTROL="$ROOT/bin/fm-control.sh"
  for pin in missing mismatched unreadable; do
    recovery_case_or_skip "replacement-env-$pin" "replacement-env-$pin" || return 0
    dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
    prepare_herdr_recovery "$dir" "$id" ship
    printf old > "$dir/fake/recovery-spawn-gen"
    printf '%s' "$pin" > "$dir/fake/replacement-env"
    rc=0
    out=$(run_control "$dir" "$id" relaunch --note "continue managed work") || rc=$?
    expect_code 1 "$rc" "$pin replacement env must refuse alive confirmation"$'\n'"$out"
    assert_present "$dir/fake/launched-command" "$pin refusal must exercise a launched replacement"
    assert_present "$dir/fake/herdr-agent-live" "$pin refusal must observe the replacement running"
    [ "$(journal_field "$dir" "$id" phase)" = failed:launching ] || fail "$pin unproven replacement was confirmed"
    assert_absent "$dir/home/state/.control-$id.lock" "$pin failed confirmation retained the control lock"
  done
  pass "ordinary managed relaunch requires matching readable replacement pin for alive confirmation"
}

test_reboot_recovery_inspects_without_native_attribution() {
  local dir id proof mode scenario out rc expected verdict expected_out before head_before log failures=0 gen suffix
  local personal personal_id personal_before personal_log CONTROL="$ROOT/bin/fm-control.sh"
  local preserved=()
  for proof in ${2:-env-v1 legacy}; do
    for mode in direct sweep; do
      for scenario in ${1:-different-cwd different-resume in-process-personal pinned-personal header-only historical-startup managed managed-claude unknown-harness mismatched unreadable missing-registration}; do
        recovery_case_or_skip "native-$proof-$mode-$scenario" "native-$proof-$mode-$scenario" \
          || fail "native identity regression requires jq"
        dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
        prepare_herdr_recovery "$dir" "$id" ship
        [ "$proof" != legacy ] || printf 'launch_proof=\n' >> "$dir/home/state/$id.meta"
        : > "$dir/fake/recovery-pending"
        gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id") || fail "could not arm native identity fixture"
        printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/$id.meta"
        printf 'working: preserve recorded task\n' > "$dir/home/state/$id.status"
        case "$scenario" in
          missing-registration) : > "$dir/fake/recovery-registration-missing" ;;
          different-cwd) printf '%s' "$dir/proj" > "$dir/fake/recovery-process-cwd" ;;
          different-resume) printf '%s' "$dir/wt/personal-session.jsonl" > "$dir/fake/recovery-process-ref" ;;
          in-process-personal|pinned-personal)
            printf '%s' "$dir/wt/personal-session.jsonl" > "$dir/fake/recovery-registration-ref"
            printf '["omp","--resume=%s"]' "$dir/wt/recorded-session.jsonl" > "$dir/fake/recovery-process-argv"
            if [ "$scenario" = pinned-personal ]; then
              printf old > "$dir/fake/recovery-spawn-gen"
              write_recovery_session_proof "$dir" "$id" "$dir/wt/personal-session.jsonl"
            fi
            ;;
          header-only)
            jq -nc --arg cwd "$dir/wt" '{type:"session",version:3,id:"personal",cwd:$cwd}' > "$dir/wt/personal-session.jsonl"
            printf '%s' "$dir/wt/personal-session.jsonl" > "$dir/fake/recovery-process-ref"
            ;;
          managed)
            printf old > "$dir/fake/recovery-spawn-gen"
            printf '%s' "$dir/proj" > "$dir/fake/recovery-process-cwd"
            printf '["omp","personal prompt"]' > "$dir/fake/recovery-process-argv"
            ;;
          mismatched) printf other > "$dir/fake/recovery-spawn-gen" ;;
          unreadable) : > "$dir/fake/recovery-env-unreadable" ;;
          managed-claude|unknown-harness)
            printf 'harness=claude\nmodel=opus\n' >> "$dir/home/state/$id.meta"
            printf claude > "$dir/fake/recovery-harness"
            [ "$scenario" != managed-claude ] || printf old > "$dir/fake/recovery-spawn-gen"
            ;;
        esac
        recovery_case_or_skip "personal-$proof-$mode-$scenario" "personal-$proof-$mode-$scenario" personal \
          || fail "personal pane fixture requires jq"
        personal=$HERDR_CASE_DIR personal_id=$HERDR_CASE_ID
        prepare_herdr_recovery "$personal" "$personal_id" ship
        rm "$personal/home/state/$personal_id.meta"
        printf 'personal draft\n' > "$personal/fake/recovery-pending"
        mkdir -p "$dir/fake/herdr-sessions"
        printf '%s\n' "$personal/fake" > "$dir/fake/herdr-sessions/personal"
        personal_before=$(shasum -a 256 "$personal/fake/recovery-pending" "$personal/wt/unlanded.txt")
        personal_log=$(cat "$personal/fake/herdr-log")
        preserved=("$dir/home/state/$id.meta" "$dir/home/state/$id.status"
          "$dir/home/state/$id.busy-gen" "$dir/home/state/$id.busy-state"
          "$dir/home/data/$id/brief.md" "$dir/fake/recovery-pending" "$dir/wt/unlanded.txt")
        preserved+=("$dir/fake/recovery-pid" "$dir/fake/recovery-spawn-gen" "$dir/fake/recovery-session-ref"
          "$dir/wt/recorded-session.jsonl" "$dir/wt/personal-session.jsonl")
        preserved+=("$dir/home/state/$id.omp-session.json")
        case "$scenario" in in-process-personal|pinned-personal)
          preserved+=("$dir/fake/recovery-process-argv" "$dir/fake/recovery-registration-ref") ;; esac
        before=$(shasum -a 256 "${preserved[@]}")
        head_before=$(git -C "$dir/wt" rev-parse HEAD)
        rc=0
        if [ "$mode" = direct ]; then
          CONTROL="$ROOT/bin/fm-control.sh"
          out=$(run_control "$dir" "$personal_id" relaunch --recover-launch) || rc=$?
          expect_code 1 "$rc" "unrecorded personal task must refuse"$'\n'"$out"
          rc=0
          out=$(run_control "$dir" "$id" relaunch --recover-launch) || rc=$?
        else
          CONTROL="$ROOT/bin/fm-reboot-recover.sh"
          out=$(run_control "$dir" recover) || rc=$?
        fi
        log=$(cat "$dir/fake/herdr-log")
        (
          [ "$personal_before" = "$(shasum -a 256 "$personal/fake/recovery-pending" "$personal/wt/unlanded.txt")" ] \
            || fail "$proof/$mode/$scenario changed personal draft or work"
          [ "$personal_log" = "$(cat "$personal/fake/herdr-log")" ] \
            || fail "$proof/$mode/$scenario inspected or acted on an unrecorded personal pane"
          assert_present "$personal/fake/herdr-agent-live" "personal pane must remain alive"
          assert_absent "$personal/fake/launched-command" "personal pane must not be replaced"
          [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] || fail "$proof/$mode/$scenario changed HEAD"
          assert_not_contains "$log" "pane send-" "$proof/$mode/$scenario must send no lifecycle input"
          expected=0
          if { [ "$scenario" = unreadable ] || [ "$scenario" = unknown-harness ]; } && [ "$proof" = env-v1 ]; then expected=1; fi
          expect_code "$expected" "$rc" "$proof/$mode/$scenario inspection must not recover"$'\n'"$out"
          verdict=unmanaged
          case "$scenario" in
            managed|managed-claude) verdict=managed ;;
            unreadable|unknown-harness) verdict=unknown ;;
          esac
          [ "$proof" != legacy ] || [ "$verdict" = managed ] || verdict=legacy-$verdict
          case "$mode/$verdict" in
            direct/managed) expected_out="recovery-skipped $id launch=managed" ;;
            direct/unmanaged) expected_out="recovery-skipped $id launch=unmanaged; no lifecycle action taken" ;;
            direct/unknown) expected_out="launch recovery for $id cannot prove its live launch settings; no lifecycle action taken" ;;
            direct/legacy-unmanaged) expected_out="recovery-skipped $id launch=legacy record; exit and relaunch are allowed" ;;
            direct/legacy-unknown) expected_out="recovery-skipped $id launch=legacy-unproven" ;;
            sweep/unmanaged) expected_out="REBOOT_RECOVERY: $id: live launch is unmanaged; no lifecycle action taken" ;;
            sweep/unknown) expected_out="REBOOT_RECOVERY: $id: live launch settings are unreadable; no lifecycle action taken" ;;
            sweep/legacy-unmanaged) expected_out="REBOOT_RECOVERY: $id: legacy record; exit and relaunch are allowed" ;;
            *) expected_out= ;;
          esac
          if [ -n "$expected_out" ]; then
            assert_contains "$out" "$expected_out" "$proof/$mode/$scenario must report its $verdict inspection verdict"
          else
            [ -z "$out" ] || fail "$proof/$mode/$scenario sweep must stay silent for a $verdict launch, got: $out"
            assert_contains "$log" "pane process-info" "$proof/$mode/$scenario sweep must inspect the live launch"
          fi
          [ "$proof" != legacy ] || assert_not_contains "$out" unmanaged \
            "$mode inspection must never report a legacy record as unmanaged"
          [ "$before" = "$(shasum -a 256 "${preserved[@]}")" ] || fail "$proof/$mode/$scenario changed records, draft or work"
          assert_present "$dir/fake/herdr-agent-live" "inspected pane must remain alive"
          assert_absent "$dir/fake/exit-pending" "inspection must not deliver an exit"
          assert_absent "$dir/fake/launched-command" "inspection must not launch a replacement"
          for suffix in control-relaunch control-relaunch.note control-relaunch.meta-prior control-relaunch.brief-prior control-exit; do
            assert_absent "$dir/home/state/$id.$suffix" "inspection must leave no $suffix transaction"
          done
          assert_absent "$dir/home/state/.control-$id.lock" "recovery must release its control lock"
          assert_absent "$dir/home/state/.secondmate-liveness-$id.lock" "recovery must leave no liveness lock"
          assert_absent "$dir/home/state/.meta-$id.lock" "recovery must leave no metadata lock"
          pass "$proof/$mode/$scenario inspection preserves recorded and unrecorded personal panes"
        ) || failures=$((failures + 1))
      done
    done
  done
  [ "$failures" = 0 ] || fail "$failures inspection scenarios failed"
}

test_reboot_recovery_skips_busy_native_drafts_without_mutation() {
  local dir id kind mode draft command out rc before gen head_before
  local CONTROL="$ROOT/bin/fm-control.sh"
  local preserved=()
  for kind in ship scout secondmate; do
    for mode in direct sweep; do
      for draft in bash python; do
        id="reboot-busy-draft-$kind-$mode-$draft"
        recovery_case_or_skip "$id" "$id" || return 0
        id=$HERDR_CASE_ID
        dir=$HERDR_CASE_DIR
        prepare_herdr_recovery "$dir" "$id" "$kind"
        case "$draft" in
          bash) command='!git diff' ;;
          python) command='$ print(1)' ;;
        esac
        printf '%s' "$command" > "$dir/fake/recovery-pending"
        gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id") \
          || fail "could not arm retained busy draft fixture"
        printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/$id.meta"
        preserved=("$dir/home/state/$id.meta" "$dir/home/state/$id.busy-gen"
          "$dir/home/state/$id.busy-state" "$dir/home/data/$id/brief.md"
          "$dir/fake/recovery-pending" "$dir/wt/unlanded.txt")
        if [ "$kind" = secondmate ]; then
          preserved+=("$dir/wt/AGENTS.md" "$dir/wt/data/charter.md")
        fi
        before=$(shasum -a 256 "${preserved[@]}")
        head_before=$(git -C "$dir/wt" rev-parse HEAD)
        rc=0
        if [ "$mode" = direct ]; then
          out=$(run_control "$dir" "$id" relaunch --recover-launch) || rc=$?
        else
          CONTROL="$ROOT/bin/fm-reboot-recover.sh"
          out=$(run_control "$dir" recover) || rc=$?
          CONTROL="$ROOT/bin/fm-control.sh"
        fi
        expect_code 0 "$rc" "$kind/$mode/$draft inspection must skip a retained busy native draft"$'\n'"$out"
        if [ "$mode" = direct ]; then
          assert_contains "$out" "recovery-skipped $id launch=unmanaged; no lifecycle action taken" \
            "$kind/$mode/$draft direct inspection must report the unmanaged launch"
        else
          assert_contains "$out" "REBOOT_RECOVERY: $id: live launch is unmanaged; no lifecycle action taken" \
            "$kind/$mode/$draft sweep must report the unmanaged launch"
        fi
        [ "$before" = "$(shasum -a 256 "${preserved[@]}")" ] \
          || fail "$kind/$mode/$draft recovery changed metadata, busy state, generation, draft, instructions or work"
        [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] \
          || fail "$kind/$mode/$draft recovery changed the worktree HEAD"
        assert_present "$dir/fake/herdr-agent-live" "$kind/$mode/$draft recovery stopped the retained agent"
        assert_not_contains "$(cat "$dir/fake/herdr-log")" "pane send-" "$kind/$mode/$draft recovery sent lifecycle input, including Escape"
        assert_absent "$dir/fake/exit-pending" "$kind/$mode/$draft recovery delivered an exit"
        assert_absent "$dir/fake/launched-command" "$kind/$mode/$draft recovery launched a replacement"
        assert_absent "$dir/home/state/$id.control-relaunch" "$kind/$mode/$draft recovery began a lifecycle transaction"
        assert_absent "$dir/home/state/$id.control-relaunch.note" "$kind/$mode/$draft recovery recorded a note"
        assert_absent "$dir/home/state/$id.control-relaunch.meta-prior" "$kind/$mode/$draft recovery staged a prior record"
        assert_absent "$dir/home/state/$id.control-relaunch.brief-prior" "$kind/$mode/$draft recovery staged prior instructions"
        assert_absent "$dir/home/state/$id.control-exit" "$kind/$mode/$draft recovery recorded a lifecycle exit"
        assert_absent "$dir/home/state/.control-$id.lock" "$kind/$mode/$draft refusal retained the control lock"
        assert_absent "$dir/home/state/.secondmate-liveness-$id.lock" "$kind/$mode/$draft refusal retained the liveness lock"
      done
    done
  done
  pass "direct and sweep inspection preserve unmanaged busy Bash/Python drafts without lifecycle input"
}

test_reboot_recovery_skips_unpinned_foreground_without_mutation() {
  local dir id kind mode out rc before CONTROL="$ROOT/bin/fm-control.sh"
  for kind in ship scout secondmate; do
    for mode in direct sweep; do
      id="reboot-foreign-$kind-$mode"
      recovery_case_or_skip "$id" "$id" || return 0
      id=$HERDR_CASE_ID
      dir=$HERDR_CASE_DIR
      prepare_herdr_recovery "$dir" "$id" "$kind"
      : > "$dir/fake/recovery-foreign-foreground"
      before=$(shasum -a 256 "$dir/home/state/$id.meta" "$dir/home/data/$id/brief.md" "$dir/wt/unlanded.txt")
      rc=0
      if [ "$mode" = direct ]; then
        out=$(run_control "$dir" "$id" relaunch --recover-launch) || rc=$?
      else
        CONTROL="$ROOT/bin/fm-reboot-recover.sh"
        out=$(run_control "$dir" recover) || rc=$?
        CONTROL="$ROOT/bin/fm-control.sh"
      fi
      expect_code 0 "$rc" "$kind/$mode inspection must skip readable unpinned foreground"$'\n'"$out"
      if [ "$mode" = direct ]; then
        assert_contains "$out" "launch=unmanaged" "readable unpinned foreground must be unmanaged for recorded omp"
      else
        assert_contains "$out" "REBOOT_RECOVERY: $id: live launch is unmanaged; no lifecycle action taken" \
          "readable unpinned foreground sweep must report the unmanaged launch for recorded omp"
      fi
      [ "$before" = "$(shasum -a 256 "$dir/home/state/$id.meta" "$dir/home/data/$id/brief.md" "$dir/wt/unlanded.txt")" ] \
        || fail "$kind/$mode foreign foreground recovery changed records, instructions or work"
      assert_present "$dir/fake/herdr-agent-live" "$kind/$mode recovery stopped the retained agent"
      assert_absent "$dir/home/state/$id.control-relaunch" "$kind/$mode recovery began a lifecycle transaction"
      assert_absent "$dir/home/state/$id.control-relaunch.note" "$kind/$mode recovery recorded a note"
      assert_absent "$dir/fake/launched-command" "$kind/$mode recovery launched a replacement"
      assert_not_contains "$(cat "$dir/fake/herdr-log")" "pane send-" "$kind/$mode recovery sent input to a foreign job"
      assert_absent "$dir/home/state/.control-$id.lock" "$kind/$mode refusal retained the control lock"
      assert_absent "$dir/home/state/.secondmate-liveness-$id.lock" "$kind/$mode refusal retained the liveness lock"
    done
  done
  pass "direct and sweep inspection skip readable unpinned foreground without lifecycle input or task mutation"
}

test_reboot_recovery_refuses_non_omp_launches_without_mutation() {
  local dir id kind mode pin out rc before gen
  local CONTROL="$ROOT/bin/fm-control.sh"
  local preserved=()
  for kind in ship scout secondmate; do
    for mode in direct sweep; do
      for pin in missing mismatched; do
        id="reboot-claude-$kind-$mode-$pin"
        recovery_case_or_skip "$id" "$id" || return 0
        id=$HERDR_CASE_ID
        dir=$HERDR_CASE_DIR
        prepare_herdr_recovery "$dir" "$id" "$kind"
        printf 'harness=claude\nmodel=opus\neffort=high\n' >> "$dir/home/state/$id.meta"
        printf claude > "$dir/fake/recovery-harness"
        [ "$pin" != mismatched ] || printf other > "$dir/fake/recovery-spawn-gen"
        gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id") || fail "could not arm retained non-omp fixture"
        printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/$id.meta"
        printf 'working: preserve the retained launch\n' > "$dir/home/state/$id.status"
        preserved=("$dir/home/state/$id.meta" "$dir/home/data/$id/brief.md" "$dir/wt/unlanded.txt"
          "$dir/home/state/$id.busy-gen" "$dir/home/state/$id.busy-state" "$dir/home/state/$id.status")
        if [ "$kind" = secondmate ]; then
          preserved+=("$dir/wt/AGENTS.md" "$dir/wt/data/charter.md")
        fi
        before=$(shasum -a 256 "${preserved[@]}")
        rc=0
        if [ "$mode" = direct ]; then
          out=$(run_control "$dir" "$id" relaunch --recover-launch) || rc=$?
          assert_contains "$out" "cannot prove its live launch settings" "$kind/$pin direct refusal must name unknown proof"
        else
          CONTROL="$ROOT/bin/fm-reboot-recover.sh"
          out=$(run_control "$dir" recover) || rc=$?
          CONTROL="$ROOT/bin/fm-control.sh"
          assert_contains "$out" "REBOOT_RECOVERY: $id: live launch settings are unreadable; no lifecycle action taken" \
            "$kind/$pin sweep refusal must name unknown proof"
        fi
        expect_code 1 "$rc" "$kind/$mode/$pin recovery must refuse a non-omp launch"$'\n'"$out"
        [ "$before" = "$(shasum -a 256 "${preserved[@]}")" ] \
          || fail "$kind/$mode/$pin recovery changed records, instructions or work"
        assert_present "$dir/fake/herdr-agent-live" "$kind/$mode/$pin recovery stopped the retained agent"
        assert_absent "$dir/home/state/$id.control-relaunch" "$kind/$mode/$pin recovery began a lifecycle transaction"
        assert_absent "$dir/home/state/$id.control-relaunch.note" "$kind/$mode/$pin recovery recorded a note"
        assert_absent "$dir/home/state/$id.control-relaunch.meta-prior" "$kind/$mode/$pin recovery staged a prior record"
        assert_absent "$dir/home/state/$id.control-relaunch.brief-prior" "$kind/$mode/$pin recovery staged prior instructions"
        assert_absent "$dir/home/state/$id.control-exit" "$kind/$mode/$pin recovery recorded lifecycle exit"
        assert_absent "$dir/fake/exit-pending" "$kind/$mode/$pin recovery delivered an exit"
        assert_absent "$dir/fake/launched-command" "$kind/$mode/$pin recovery launched a replacement"
        assert_not_contains "$(cat "$dir/fake/herdr-log")" "pane send-" "$kind/$mode/$pin recovery sent lifecycle input"
        assert_absent "$dir/home/state/.control-$id.lock" "$kind/$mode/$pin refusal retained the control lock"
        assert_absent "$dir/home/state/.secondmate-liveness-$id.lock" "$kind/$mode/$pin refusal retained the liveness lock"
      done
    done
  done
  pass "direct and sweep recovery refuse missing or mismatched non-omp pins for ships, scouts and secondmates without mutation"
}

test_bootstrap_inspects_the_derived_home_when_fm_home_is_unset() {
  local dir id=reboot-bootstrap-derived out rc=0 before
  recovery_case_or_skip "$id" "$id" || return 0
  id=$HERDR_CASE_ID
  dir=$HERDR_CASE_DIR
  prepare_herdr_recovery "$dir" "$id" ship
  ln -s "$ROOT/bin" "$dir/home/bin"
  mkdir -p "$dir/user-home" "$dir/home/.agents/skills" "$dir/home/.omp"
  cp "$ROOT/.omp/fm-session-overlay.yml" "$ROOT/.omp/fm-worker-overlay.yml" "$dir/home/.omp/"
  before=$(shasum -a 256 "$dir/wt/unlanded.txt")
  # shellcheck disable=SC2031 # The session-end scan's PATH override is confined to its subshell.
  out=$(env -u FM_HOME -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_BOOTSTRAP_NETWORK=only FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
    FM_CONTROL_LAUNCH_WAIT=0.05 "$ROOT/bin/fm-bootstrap.sh" 2>&1) || rc=$?
  expect_code 0 "$rc" "network bootstrap must inspect its resolved home"$'\n'"$out"
  assert_contains "$out" "REBOOT_RECOVERY: $id: live launch is unmanaged; no lifecycle action taken" \
    "network bootstrap must report the unmanaged launch recorded in its derived home"
  assert_absent "$dir/home/state/$id.control-relaunch" "bootstrap must not checkpoint unmanaged native launch"
  assert_absent "$dir/fake/launched-command" "bootstrap must not replace unmanaged native launch"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" "pane send-" "bootstrap must send no lifecycle input"
  [ "$(meta_field "$dir" "$id" spawn_gen)" = old ] || fail "bootstrap changed the unmanaged incarnation"
  [ "$(meta_field "$dir" "$id" window)" = 'fmlab:%7' ] || fail "bootstrap recovery moved its pane"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] || fail "bootstrap recovery moved its local copy"
  [ "$(meta_field "$dir" "$id" harness)" = omp ] || fail "bootstrap recovery changed its recorded harness"
  [ "$(meta_field "$dir" "$id" model)" = openai-codex/gpt-6-astra ] || fail "bootstrap recovery changed its recorded model"
  [ "$(meta_field "$dir" "$id" effort)" = high ] || fail "bootstrap recovery changed its recorded effort"
  [ "$before" = "$(shasum -a 256 "$dir/wt/unlanded.txt")" ] || fail "bootstrap recovery changed unfinished work"
  pass "network bootstrap inspects its derived home without mutating unmanaged native launches"
}

test_secondmate_reboot_recovery_preserves_profile_and_child_work() {
  local dir id out rc=0 before
  recovery_case_or_skip reboot-secondmate reboot-sm || return 0
  id=$HERDR_CASE_ID
  dir=$HERDR_CASE_DIR
  prepare_herdr_recovery "$dir" "$id" secondmate
  mkdir -p "$dir/home/config"
  printf 'codex other-model low\n' > "$dir/home/config/secondmate-harness"
  printf 'window=child-session:child-pane\n' > "$dir/wt/state/child.meta"
  printf 'preserve child work\n' > "$dir/wt/unlanded.txt"
  before=$(shasum -a 256 "$dir/wt/unlanded.txt" "$dir/wt/data/charter.md" "$dir/wt/state/child.meta")
  out=$(run_control "$dir" "$id" relaunch --recover-launch) || rc=$?
  expect_code 0 "$rc" "bare secondmate inspection must skip"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" harness)" = omp ] || fail 'recovery picked up a different configured harness'
  [ "$(meta_field "$dir" "$id" model)" = openai-codex/gpt-6-astra ] || fail 'recovery lost the recorded secondmate model'
  [ "$(meta_field "$dir" "$id" effort)" = high ] || fail 'recovery lost the recorded secondmate effort'
  [ "$(meta_field "$dir" "$id" window)" = 'fmlab:%7' ] || fail 'recovery moved the secondmate pane'
  [ "$before" = "$(shasum -a 256 "$dir/wt/unlanded.txt" "$dir/wt/data/charter.md" "$dir/wt/state/child.meta")" ] \
    || fail 'recovery changed secondmate child work or its charter'
  assert_contains "$out" "recovery-skipped $id launch=unmanaged; no lifecycle action taken" \
    "secondmate inspection must report its unmanaged launch"
  assert_absent "$dir/home/state/$id.control-relaunch" "secondmate inspection must not reconcile or checkpoint child work"
  assert_absent "$dir/fake/launched-command" "secondmate inspection must not launch a replacement"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" "pane send-" "secondmate inspection must send no lifecycle input"
  pass 'reboot inspection preserves secondmate profile, pane, charter and child work'
}

test_bounded_reboot_recovery_rotates_unmanaged_inspections_without_mutation() {
  local a b id_a id_b out rc before_a before_b gen_b head_b
  local CONTROL="$ROOT/bin/fm-reboot-recover.sh"
  recovery_case_or_skip reboot-fairness-a fairness-a fmlab-a || return 0
  a=$HERDR_CASE_DIR id_a=$HERDR_CASE_ID
  recovery_case_or_skip reboot-fairness-b fairness-b fmlab-b || return 0
  b=$HERDR_CASE_DIR id_b=$HERDR_CASE_ID
  prepare_herdr_recovery "$a" "$id_a" ship
  prepare_herdr_recovery "$b" "$id_b" ship
  printf 2000000001 > "$a/fake/recovery-pid"
  printf draft > "$a/fake/recovery-pending"
  cp "$a/home/state/$id_a.meta" "$b/home/state/$id_a.meta"
  mkdir -p "$b/home/data/$id_a" "$b/fake/herdr-sessions" "$b/fake/herdr-pids"
  cp "$a/home/data/$id_a/brief.md" "$b/home/data/$id_a/brief.md"
  write_recovery_native_launch "$a" "$b/home" "$id_a" ship
  printf '%s\n' "$a/fake" > "$b/fake/herdr-sessions/fmlab-a"
  printf '%s\n' "$a/fake" > "$b/fake/herdr-pids/2000000001"
  printf 'unfinished a\n' > "$a/wt/unlanded.txt"
  printf 'unfinished b\n' > "$b/wt/unlanded.txt"
  before_a=$(shasum -a 256 "$b/home/state/$id_a.meta" "$a/fake/recovery-pending" "$a/wt/unlanded.txt")
  before_b=$(shasum -a 256 "$b/wt/unlanded.txt")
  head_b=$(git -C "$b/wt" rev-parse HEAD)
  rc=0
  out=$(run_control "$b" recover --one) || rc=$?
  expect_code 0 "$rc" "first tick must inspect unmanaged a"$'\n'"$out"
  assert_contains "$out" "REBOOT_RECOVERY: $id_a: live launch is unmanaged; no lifecycle action taken" \
    "first tick must report unmanaged a"
  [ "$(cat "$b/home/state/.reboot-recovery-cursor")" = "$id_a" ] || fail 'first tick did not stop after a'
  [ ! -s "$b/fake/herdr-log" ] || fail 'one tick inspected a second recorded task'
  [ "$before_a" = "$(shasum -a 256 "$b/home/state/$id_a.meta" "$a/fake/recovery-pending" "$a/wt/unlanded.txt")" ] \
    || fail 'pending refusal changed a or its work'
  rc=0
  out=$(run_control "$b" recover --one) || rc=$?
  expect_code 0 "$rc" "next tick must inspect b despite pending a"$'\n'"$out"
  assert_contains "$out" "REBOOT_RECOVERY: $id_b: live launch is unmanaged; no lifecycle action taken" \
    "second tick must report unmanaged b"
  gen_b=$(meta_field "$b" "$id_b" spawn_gen)
  [ "$gen_b" = old ] || fail 'inspection replaced unmanaged b'
  [ "$(cat "$b/home/state/.reboot-recovery-cursor")" = "$id_b" ] || fail 'second tick did not stop after b'
  assert_absent "$b/home/state/$id_b.control-relaunch" "b inspection must not checkpoint"
  [ "$(meta_field "$b" "$id_b" window)" = 'fmlab-b:%7' ] || fail 'b recovery changed its endpoint'
  [ "$(meta_field "$b" "$id_b" harness)" = omp ] || fail 'b recovery changed its recorded harness'
  [ "$(meta_field "$b" "$id_b" model)" = openai-codex/gpt-6-astra ] || fail 'b recovery changed its recorded model'
  [ "$(meta_field "$b" "$id_b" effort)" = high ] || fail 'b recovery changed its recorded effort'
  [ "$(git -C "$b/wt" rev-parse HEAD)" = "$head_b" ] \
    && [ "$before_b" = "$(shasum -a 256 "$b/wt/unlanded.txt")" ] || fail 'b recovery changed unfinished work'
  rc=0
  out=$(run_control "$b" recover --one) || rc=$?
  expect_code 0 "$rc" "rotation must revisit unmanaged a"$'\n'"$out"
  [ -z "$out" ] || fail "rotation must not repeat the unchanged notice for a, got: $out"
  [ "$(cat "$b/home/state/.reboot-recovery-cursor")" = "$id_a" ] || fail 'rotation did not wrap to a'
  [ "$(meta_field "$b" "$id_b" spawn_gen)" = "$gen_b" ] || fail 'rotation replaced unmanaged b'
  [ "$before_a" = "$(shasum -a 256 "$b/home/state/$id_a.meta" "$a/fake/recovery-pending" "$a/wt/unlanded.txt")" ] \
    || fail 'repeated recovery touched pending a or its work'
  assert_not_contains "$(cat "$a/fake/herdr-log")" "pane send-" "repeated inspections must send no input to a"
  assert_not_contains "$(cat "$b/fake/herdr-log")" "pane send-" "repeated inspections must send no input to b"
  assert_absent "$a/fake/launched-command" "repeated inspections must not replace a"
  assert_absent "$b/fake/launched-command" "repeated inspections must not replace b"
  pass 'bounded ticks inspect one recorded unmanaged launch, rotate past drafts, and wrap without mutation'
}

test_bounded_reboot_recovery_notifies_each_unmanaged_identity_once() {
  local home id_home dir id n tick out rc notices seen noticed pid
  local CONTROL="$ROOT/bin/fm-reboot-recover.sh"
  recovery_case_or_skip reboot-notice-home notice-home fmlab-h || return 0
  home=$HERDR_CASE_DIR id_home=$HERDR_CASE_ID
  prepare_herdr_recovery "$home" "$id_home" ship
  mkdir -p "$home/fake/herdr-sessions" "$home/fake/herdr-pids"
  for n in 1 2 3 4; do
    recovery_case_or_skip "reboot-notice-$n" "notice-$n" "fmlab-$n" || return 0
    dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
    prepare_herdr_recovery "$dir" "$id" ship
    printf '%s' "$((2000000000 + n))" > "$dir/fake/recovery-pid"
    cp "$dir/home/state/$id.meta" "$home/home/state/$id.meta"
    mkdir -p "$home/home/data/$id"
    cp "$dir/home/data/$id/brief.md" "$home/home/data/$id/brief.md"
    write_recovery_native_launch "$dir" "$home/home" "$id" ship
    printf '%s\n' "$dir/fake" > "$home/fake/herdr-sessions/fmlab-$n"
    printf '%s\n' "$dir/fake" > "$home/fake/herdr-pids/$((2000000000 + n))"
  done
  notices=0 seen=' '
  for tick in $(seq 1 15); do
    rc=0
    out=$(run_control "$home" recover --one) || rc=$?
    expect_code 0 "$rc" "tick $tick must inspect without failing"$'\n'"$out"
    [ -n "$out" ] || continue
    notices=$((notices + 1))
    assert_contains "$out" "live launch is unmanaged" "tick $tick must report an unmanaged launch"
    [ "$tick" -le 5 ] || fail "tick $tick repeated an unchanged unmanaged notice: $out"
    noticed=$(cat "$home/home/state/.reboot-recovery-cursor")
    case "$seen" in *" $noticed "*) fail "unmanaged $noticed woke twice" ;; esac
    seen="$seen$noticed "
  done
  [ "$notices" = 5 ] || fail "5 unmanaged agents must wake once each across 15 ticks, got $notices"
  pid=2000000009
  printf '%s' "$pid" > "$dir/fake/recovery-pid"
  printf '%s\n' "$dir/fake" > "$home/fake/herdr-pids/$pid"
  notices=0
  for tick in 1 2 3 4 5 6 7 8 9 10; do
    rc=0
    out=$(run_control "$home" recover --one) || rc=$?
    expect_code 0 "$rc" "restored identity tick $tick must inspect without failing"$'\n'"$out"
    [ -n "$out" ] || continue
    notices=$((notices + 1))
    assert_contains "$out" "$id: live launch is unmanaged" "only the restored identity may notify again"
  done
  [ "$notices" = 1 ] || fail "a changed restored-agent identity must notify exactly once, got $notices"
  out=$(run_control "$home" recover) || true
  [ "$(printf '%s\n' "$out" | grep -c 'live launch is unmanaged')" = 5 ] \
    || fail "unbounded recover must still report every unmanaged launch: $out"
  pass 'bounded recovery wakes once per unmanaged restored-agent identity and again only when it changes'
}

test_bounded_reboot_recovery_advances_after_interrupted_inspection() {
  local a b c dir id id_a id_b id_c session out rc before_a before_b head_b
  local CONTROL
  recovery_case_or_skip reboot-interrupted-a interrupted-a fmlab-a || return 0
  a=$HERDR_CASE_DIR id_a=$HERDR_CASE_ID
  recovery_case_or_skip reboot-interrupted-b interrupted-b fmlab-b || return 0
  b=$HERDR_CASE_DIR id_b=$HERDR_CASE_ID
  recovery_case_or_skip reboot-interrupted-c interrupted-c fmlab-c || return 0
  c=$HERDR_CASE_DIR id_c=$HERDR_CASE_ID
  prepare_herdr_recovery "$a" "$id_a" ship
  prepare_herdr_recovery "$b" "$id_b" ship
  prepare_herdr_recovery "$c" "$id_c" ship
  mkdir -p "$b/fake/herdr-sessions" "$b/fake/herdr-pids"
  for id in "$id_a" "$id_c"; do
    dir=$a session=fmlab-a
    [ "$id" != "$id_c" ] || { dir=$c; session=fmlab-c; }
    [ "$id" != "$id_a" ] || printf 2000000001 > "$dir/fake/recovery-pid"
    [ "$id" != "$id_c" ] || printf 2000000002 > "$dir/fake/recovery-pid"
    cp "$dir/home/state/$id.meta" "$b/home/state/$id.meta"
    mkdir -p "$b/home/data/$id"
    cp "$dir/home/data/$id/brief.md" "$b/home/data/$id/brief.md"
    write_recovery_native_launch "$dir" "$b/home" "$id" ship
    printf '%s\n' "$dir/fake" > "$b/fake/herdr-sessions/$session"
    printf '%s\n' "$dir/fake" > "$b/fake/herdr-pids/$(cat "$dir/fake/recovery-pid")"
  done
  before_a=$(shasum -a 256 "$b/home/state/$id_a.meta" "$b/home/data/$id_a/brief.md" "$a/wt/unlanded.txt")
  before_b=$(shasum -a 256 "$b/wt/unlanded.txt")
  head_b=$(git -C "$b/wt" rev-parse HEAD)
  cat > "$b/fakebin/interrupt-recovery" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$a/fake/recovery-inspection-interrupt"
exec "$ROOT/bin/fm-reboot-recover.sh" "\$@"
SH
  chmod +x "$b/fakebin/interrupt-recovery"
  CONTROL="$b/fakebin/interrupt-recovery"
  rc=0
  out=$(run_control "$b" recover --one) || rc=$?
  expect_code 143 "$rc" "the first bounded tick must be interrupted at its early agent-state probe"$'\n'"$out"
  assert_present "$a/fake/recovery-inspection-entered" "interruption never reached the early probe"
  [ "$(cat "$b/home/state/.reboot-recovery-cursor")" = "$id_a" ] || fail 'interrupted inspection did not persist a'
  [ "$before_a" = "$(shasum -a 256 "$b/home/state/$id_a.meta" "$b/home/data/$id_a/brief.md" "$a/wt/unlanded.txt")" ] \
    || fail 'interrupted inspection changed a or its work'
  assert_present "$a/fake/herdr-agent-live" "interrupted inspection stopped a"
  assert_absent "$b/home/state/$id_a.control-relaunch" "interrupted inspection began a repair"
  assert_absent "$a/fake/launched-command" "interrupted inspection replaced a"
  assert_not_contains "$(cat "$a/fake/herdr-log")" "pane send-" "interrupted inspection sent lifecycle input"
  [ "$(meta_field "$b" "$id_b" spawn_gen)" = old ] || fail 'interrupted tick repaired b'
  CONTROL="$ROOT/bin/fm-reboot-recover.sh"
  rc=0
  out=$(run_control "$b" recover --one) || rc=$?
  expect_code 0 "$rc" "next bounded tick must inspect b without reentering a"$'\n'"$out"
  assert_contains "$out" "REBOOT_RECOVERY: $id_b: live launch is unmanaged; no lifecycle action taken" \
    "next bounded tick must report unmanaged b"
  assert_absent "$b/home/state/$id_b.control-relaunch" "unmanaged b inspection must not checkpoint"
  assert_absent "$b/fake/launched-command" "unmanaged b inspection must not replace"
  assert_not_contains "$(cat "$b/fake/herdr-log")" "pane send-" "unmanaged b inspection must send no input"
  [ "$(meta_field "$b" "$id_b" spawn_gen)" = old ] || fail 'inspection changed b incarnation'
  [ "$(cat "$b/home/state/.reboot-recovery-cursor")" = "$id_b" ] || fail 'second tick advanced beyond one inspection'
  [ "$(meta_field "$b" "$id_c" spawn_gen)" = old ] || fail 'one bounded tick repaired c too'
  assert_absent "$b/home/state/$id_c.control-relaunch" "one bounded tick attempted c too"
  [ "$before_a" = "$(shasum -a 256 "$b/home/state/$id_a.meta" "$b/home/data/$id_a/brief.md" "$a/wt/unlanded.txt")" ] \
    || fail 'the next tick changed interrupted a'
  [ "$(meta_field "$b" "$id_b" window)" = 'fmlab-b:%7' ] || fail 'b repair moved its endpoint'
  [ "$(meta_field "$b" "$id_b" worktree)" = "$b/wt" ] || fail 'b repair moved its local copy'
  [ "$(git -C "$b/wt" rev-parse HEAD)" = "$head_b" ] \
    && [ "$before_b" = "$(shasum -a 256 "$b/wt/unlanded.txt")" ] || fail 'b repair changed preserved work'
  [ ! -s "$c/fake/herdr-log" ] || fail 'one bounded tick inspected c too'
  pass 'bounded recovery persists inspection cursor before interruption and only inspects the next unmanaged launch'
}

test_exit_and_relaunch_remove_the_dialog_file() {
  local dir out rc
  dir=$(new_case dialog-file-exit rl70)
  add_ship_task "$dir" rl70 claude
  out=$(run_control "$dir" rl70 exit); rc=$?
  expect_code 0 "$rc" "exit should stop the agent"$'\n'"$out"
  [ ! -e "$dir/home/state/rl70.composer-dialog" ] \
    || fail "exit should remove the dialog file"

  dir=$(new_case dialog-file-relaunch rl71)
  add_ship_task "$dir" rl71 claude
  out=$(run_control "$dir" rl71 relaunch --note "replace the agent"); rc=$?
  expect_code 0 "$rc" "relaunch should replace the agent"$'\n'"$out"
  [ ! -e "$dir/home/state/rl71.composer-dialog" ] \
    || fail "relaunch should remove the dialog file"
  pass "fm-control removes the dialog file after exit and after relaunch"
}

# The lock release removes paths at or under the control lock with rm, so a
# recording rm sees the state directory at the moment of release without a
# second overlapping command.
test_exit_removes_the_dialog_file_before_releasing_the_lock() {
  local dir out rc lock sink trace
  dir=$(new_case dialog-file-order rl72)
  add_ship_task "$dir" rl72 claude
  lock="$dir/home/state/.control-rl72.lock"
  sink="$dir/home/state/rl72.composer-dialog"
  trace="$dir/fake/rm-trace"
  cat > "$dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    "$lock"|"$lock"/*)
      if [ -e "$sink" ]; then echo present; else echo absent; fi >> "$trace"
      break
      ;;
  esac
done
exec "$(command -v rm)" "\$@"
SH
  chmod +x "$dir/fakebin/rm"
  out=$(run_control "$dir" rl72 exit); rc=$?
  expect_code 0 "$rc" "exit should stop the agent"$'\n'"$out"
  [ ! -e "$lock" ] || fail "exit should release the control lock"
  [ "$(tail -n 1 "$trace" 2>/dev/null)" = absent ] \
    || fail "the dialog file must be gone when the control lock is released, got: $(cat "$trace" 2>/dev/null)"
  pass "fm-control exit removes the dialog file before it releases the control lock"
}

test_quota_recovery_keeps_the_typed_route_class() {
  local dir id=rl-route route meta out rc
  for route in powerful:high fast:high; do
    dir=$(new_case "route-${route%%:*}" "$id")
    add_ship_task "$dir" "$id" omp
    printf omp > "$dir/fake/command"
    printf omp > "$dir/fake/becomes"
    printf 'unfinished change\n' > "$dir/wt/unfinished.txt"
    meta=$(cat "$dir/home/state/$id.meta")
    meta=${meta/model=default/model=openai-codex/gpt-6.1-sol}
    meta=${meta/effort=default/effort=high}
    printf '%s\ndispatch_rule=rule_1\ndispatch_route=%s\n' "$meta" "$route" > "$dir/home/state/$id.meta"
    mkdir -p "$dir/home/config"
    jq -n '{rules:[{when:"assigned work",
      use:{harness:"omp",model:"openai-codex/gpt-6.1-sol",effort:"high",provider:"codex"},
      fallback:[{harness:"omp",model:"openai-codex/gpt-6-luna",effort:"low"}]}]}' > "$dir/home/config/crew-dispatch.json"
    jq -n --argjson now "$(date +%s)" '{reports:[{provider:"openai-codex",fetchedAt:($now*1000),
      metadata:{meterStates:{chat:{allowed:true,limitReached:false}}},
      limits:[{scope:{modelId:"gpt-6.1-sol"},status:"exhausted",amount:{remainingFraction:0}}]}]}' > "$dir/usage.json"
    cat > "$dir/fakebin/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'omp/18.1.20\n' ;;
  usage) cat "$FM_FAKE_DIR/../usage.json" ;;
  models) printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-luna","selector":"openai-codex/gpt-6-luna"},{"provider":"openai-codex","id":"gpt-6.1-sol","selector":"openai-codex/gpt-6.1-sol"}]}' ;;
  *) exit 0 ;;
esac
SH
    chmod +x "$dir/fakebin/omp"
    "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id" --state idle --source omp-ext --event quota-exhausted >/dev/null
    mkdir -p "$dir/user-home"
    # shellcheck disable=SC2031 # The helper subshell's PATH change does not reach here.
    out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
      -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
      PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
      FM_WAKE_QUEUE="$dir/home/state/.wake-queue" \
      HOME="$dir/user-home" FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
      bash -s -- "$ROOT" <<'SH'
. "$1/bin/fm-session-end-relaunch-lib.sh"
fm_session_end_relaunch_scan "$FM_HOME/state" 180 || exit
printf "%s\n" "$FM_SESSION_END_WAKE"
SH
    )
    rc=$?
    expect_code 0 "$rc" "supervised quota recovery must evaluate the typed route: $out"
    assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "recovery must preserve uncommitted work"
    if [ "$route" = powerful:high ]; then
      assert_contains "$out" 'auto-relaunch failed' "a powerful route must refuse the cheap stand-in"
      assert_equals omp "$(cat "$dir/fake/command")" "the refused stand-in must leave the old agent running"
      assert_equals openai-codex/gpt-6.1-sol "$(meta_field "$dir" "$id" model)" "the powerful model identity must remain unchanged"
      assert_no_grep '/quit' "$dir/fake/literal" "no exit may be sent when no powerful replacement exists"
    else
      assert_contains "$out" 'auto-relaunched after quota exhaustion' "a fast route may recover on the declared stand-in"
      assert_equals openai-codex/gpt-6-luna "$(meta_field "$dir" "$id" model)" "the fast route serves the stand-in"
      assert_equals high "$(meta_field "$dir" "$id" effort)" "recovery clamps the stand-in effort to the route level"
      assert_equals fast:high "$(meta_field "$dir" "$id" dispatch_route)" "the typed route is carried through the replacement"
    fi
  done
  pass "supervised OMP recovery enforces the typed route class and effort on stand-ins"
}

# Adoption fixtures reuse the existing fake Herdr process/registration model;
# only the kernel cwd reader is additional, and no live server is contacted.
prepare_omp_adoption() { # <case-name>
  recovery_case_or_skip "adoption-$1" "adoption-$1" || fail "adoption needs jq"
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID meta
  meta="$dir/home/state/$id.meta"
  while IFS= read -r line; do
    case "$line" in harness=*) printf 'harness=omp\n' ;; *) printf '%s\n' "$line" ;; esac
  done < "$meta" > "$meta.new"
  mv "$meta.new" "$meta"
  printf 'spawn_gen=old\nlaunch_proof=env-v1\n' >> "$meta"
  rm -f "$dir/fake/herdr-stopped"
  printf '%s' "$id" > "$dir/fake/recovery-case-id"
  : > "$dir/fake/herdr-agent-live"
  : > "$dir/fake/recovery-spawn-gen"
  printf 2000000000 > "$dir/fake/recovery-pid"
  printf 2000000000 > "$dir/fake/holder-pid"
  printf omp > "$dir/fake/holder-comm"
  printf omp > "$dir/fake/holder-args"
  printf '%s' "$dir/wt/recorded-session.jsonl" > "$dir/fake/recovery-session-ref"
  mkdir -p "$dir/wt/subdirectory"
  printf '%s' "$dir/wt/subdirectory" > "$dir/fake/adoption-cwd"
  write_recovery_native_launch "$dir" "$dir/home" "$id" ship
  # The recorded process is long gone; no host can hand this PID to a live one.
  jq -nc --arg task "$dir/wt/recorded-session.jsonl" \
    '{version:1,spawn_gen:"old",pid:2000000001,task_session_file:$task,current_session_file:""}' \
    > "$dir/home/state/$id.omp-session.json"
  make_continuation_owner_fixture "$dir"
}

assert_adoption_refused() { # <case-dir> <id> <named-proof>
  local dir=$1 id=$2 expected=$3 before out rc=0
  before=$(shasum -a 256 "$dir/home/state/$id.meta" "$dir/home/state/$id.omp-session.json" \
    "$dir/home/data/$id/brief.md" "$dir/wt/recorded-session.jsonl")
  out=$(run_continuation_control "$dir" "$id" adopt) || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe adoption succeeded: $out"
  assert_contains "$out" "$expected" "adoption must name the missing proof"
  assert_equals "$before" "$(shasum -a 256 "$dir/home/state/$id.meta" "$dir/home/state/$id.omp-session.json" \
    "$dir/home/data/$id/brief.md" "$dir/wt/recorded-session.jsonl")" "refusal must preserve record and task files"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" 'send-' "adoption must not deliver lifecycle input"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" 'server ' "adoption must not start a server"
}

test_omp_adoption_matching_workspace() {
  prepare_omp_adoption matching
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID out rc=0 meta_before
  meta_before=$(cat "$dir/home/state/$id.meta")
  out=$(run_control "$dir" "$id" interrupt) || rc=$?
  [ "$rc" -ne 0 ] || fail "broken pre-adoption record authorized interrupt: $out"
  out=$(run_continuation_control "$dir" "$id" adopt) || fail "matching workspace must adopt: $out"
  assert_contains "$out" "adopted: $id" "adoption reports its exact task"
  jq -e --arg task "$dir/wt/recorded-session.jsonl" \
    '. == {version:1,spawn_gen:"old",pid:2000000000,task_session_file:$task,current_session_file:$task}' \
    "$dir/home/state/$id.omp-session.json" >/dev/null || fail "adoption did not preserve the task file and generation with live values"
  assert_equals "$meta_before" "$(cat "$dir/home/state/$id.meta")" "adoption never changes metadata"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" 'send-' "successful adoption sends no lifecycle input"
  out=$(FM_CONTROL_SETTLE_WAIT=.05 run_control "$dir" "$id" interrupt) || fail "repaired record must allow fake interrupt: $out"
  assert_contains "$out" "interrupt-delivered $id" "previously refused task becomes controllable"
  pass "omp adoption: matching workspace adopted and fake interrupt works without a launch env pin"
}

test_omp_adoption_foreign_workspace() {
  prepare_omp_adoption foreign
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  printf 'worktree=%s\n' "$dir/wt/subdirectory" > "$dir/home/state/foreign.meta"
  assert_adoption_refused "$dir" "$id" 'unique deepest match; cwd belongs to foreign'
  pass "omp adoption: workspace of another task refused, including a deeper nested worktree"
}

test_omp_adoption_duplicate_pane() {
  prepare_omp_adoption duplicate
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  printf 'window=fmlab:%%7\nworktree=%s\nremote_host=\n' "$dir" > "$dir/home/state/duplicate.meta"
  assert_adoption_refused "$dir" "$id" 'unique-claim proof'
  pass "omp adoption: two metas claiming one pane refused"
}

test_omp_adoption_ambiguous_foreground() {
  prepare_omp_adoption ambiguous
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  : > "$dir/fake/adoption-ambiguous"
  assert_adoption_refused "$dir" "$id" 'foreground proof needs one uniquely resolved live process'
  pass "omp adoption: ambiguous foreground refused"
}

test_omp_adoption_generation_mismatch() {
  prepare_omp_adoption generation
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID record
  record="$dir/home/state/$id.omp-session.json"
  jq '.spawn_gen="different"' "$record" > "$record.new" && mv "$record.new" "$record"
  assert_adoption_refused "$dir" "$id" 'existing record spawn_gen to equal metadata spawn_gen'
  pass "omp adoption: record generation mismatch refused"
}

test_omp_adoption_current_session_contradiction() {
  prepare_omp_adoption current-session-contradiction
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID record out rc=0
  record="$dir/home/state/$id.omp-session.json"
  write_recovery_native_session "$dir/wt/personal-session.jsonl" "$dir/wt" "personal conversation"
  jq --arg current "$dir/wt/personal-session.jsonl" --argjson pid "$(cat "$dir/fake/recovery-pid")" \
    '.pid=$pid | .current_session_file=$current' "$record" > "$record.new" && mv "$record.new" "$record"
  # The launch environment pin still matches, but the extension's same-PID
  # activation names a personal file while Herdr retains the task registration.
  printf old > "$dir/fake/recovery-spawn-gen"
  out=$(run_control "$dir" "$id" interrupt) || rc=$?
  [ "$rc" -ne 0 ] || fail "contradictory current-session proof already authorized interrupt: $out"
  assert_adoption_refused "$dir" "$id" 'current-session proof contradicts the registered task session for the live PID'
  rc=0
  out=$(run_control "$dir" "$id" interrupt) || rc=$?
  [ "$rc" -ne 0 ] || fail "adoption erased personal-session proof and authorized interrupt: $out"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" 'send-' "contradictory activation must remain unauthorized"
  pass "omp adoption: same-PID personal current session overrides stale task registration and remains refused"
}

test_omp_adoption_unproven_same_pid() {
  local shape dir id record out rc
  for shape in empty null; do
    prepare_omp_adoption "unproven-$shape"
    dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID record="$HERDR_CASE_DIR/home/state/$HERDR_CASE_ID.omp-session.json"
    jq --argjson pid "$(cat "$dir/fake/recovery-pid")" --arg shape "$shape" \
      '.pid=$pid | .current_session_file=(if $shape == "null" then null else "" end)' \
      "$record" > "$record.new" && mv "$record.new" "$record"
    printf old > "$dir/fake/recovery-spawn-gen"
    assert_adoption_refused "$dir" "$id" 'current-session proof for the live PID is empty or invalid'
    rc=0
    out=$(FM_CONTROL_SETTLE_WAIT=.05 run_control "$dir" "$id" interrupt) || rc=$?
    [ "$rc" -ne 0 ] || fail "unproven same-PID record ($shape) authorized interrupt: $out"
    assert_not_contains "$(cat "$dir/fake/herdr-log")" 'send-' "an unproven same-PID record must receive no lifecycle input"
  done
  pass "omp adoption: the extension's unproven mark for the live PID is not overwritten"
}

test_omp_adoption_non_omp_process() {
  local shape dir id out rc comm args
  for shape in non-agent other-agent omp-directory-comm omp-directory-argv0; do
    prepare_omp_adoption "non-omp-$shape"
    dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID rc=0
    # Herdr still registers the omp task file while something else runs in the
    # pane: a plain program, or another harness's agent started in its shell.
    case "$shape" in
      non-agent)
        comm=python3 args='python3 -c input()'
        : > "$dir/fake/recovery-foreign-foreground" ;;
      other-agent)
        comm=claude args='claude --continue'
        printf claude > "$dir/fake/recovery-harness" ;;
      omp-directory-comm)
        comm=/opt/omp/bin/python3 args='python3 -c input()' ;;
      omp-directory-argv0)
        comm=python3 args='/opt/omp/bin/python3 -c input()' ;;
    esac
    printf '%s' "$comm" > "$dir/fake/holder-comm"
    printf '%s' "$args" > "$dir/fake/holder-args"
    assert_adoption_refused "$dir" "$id" 'process proof needs the resolved foreground process to be a readable omp process'
    rm -f "$dir/fake/recovery-foreign-foreground" "$dir/fake/recovery-harness"
    printf omp > "$dir/fake/holder-comm"
    printf omp > "$dir/fake/holder-args"
    out=$(run_continuation_control "$dir" "$id" adopt) || fail "omp process must adopt: $out"
    printf '%s' "$comm" > "$dir/fake/holder-comm"
    printf '%s' "$args" > "$dir/fake/holder-args"
    out=$(FM_CONTROL_SETTLE_WAIT=.05 run_control "$dir" "$id" interrupt) || rc=$?
    [ "$rc" -ne 0 ] || fail "adopted record authorized lifecycle input once a $shape process replaced omp: $out"
    assert_not_contains "$(cat "$dir/fake/herdr-log")" 'send-' "a $shape process must receive no lifecycle input"
  done
  pass "omp adoption: unrelated executables, including paths under an omp directory, refused at adoption and at the lifecycle recheck"
}

test_omp_adoption_unreadable_environment() {
  prepare_omp_adoption unreadable-environment
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID out rc=0
  : > "$dir/fake/recovery-env-unreadable"
  assert_adoption_refused "$dir" "$id" 'launch-pin proof needs a positively readable environment without a usable launch pin'
  rm -f "$dir/fake/recovery-env-unreadable"
  out=$(run_continuation_control "$dir" "$id" adopt) || fail "readable unpinned workspace must adopt: $out"
  : > "$dir/fake/recovery-env-unreadable"
  out=$(FM_CONTROL_SETTLE_WAIT=.05 run_control "$dir" "$id" interrupt) || rc=$?
  [ "$rc" -ne 0 ] || fail "adopted record authorized lifecycle input over an unreadable launch environment: $out"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" 'send-' "an unreadable launch environment must receive no lifecycle input"
  rm -f "$dir/fake/recovery-env-unreadable"
  out=$(FM_CONTROL_SETTLE_WAIT=.05 run_control "$dir" "$id" interrupt) || fail "readable environment must restore the repaired authorization: $out"
  assert_contains "$out" "interrupt-delivered $id" "repaired record controls the task once the environment is readable"
  pass "omp adoption: unreadable launch environment stays unknown and is not promoted to managed"
}

test_omp_adoption_other_generation_pin() {
  prepare_omp_adoption other-generation-pin
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID out rc=0
  # A readable pin for another launch generation names a different launch, not
  # a missing pin, so the live process is not this task's agent to adopt.
  printf other > "$dir/fake/recovery-spawn-gen"
  assert_adoption_refused "$dir" "$id" 'generation proof needs the live process not to be pinned to another launch generation'
  out=$(FM_CONTROL_SETTLE_WAIT=.05 run_control "$dir" "$id" interrupt) || rc=$?
  [ "$rc" -ne 0 ] || fail "process pinned to another generation authorized interrupt: $out"
  # Without any pin the same record repairs, and a later foreign pin withdraws it.
  : > "$dir/fake/recovery-spawn-gen"
  out=$(run_continuation_control "$dir" "$id" adopt) || fail "unpinned process must adopt: $out"
  printf other > "$dir/fake/recovery-spawn-gen"
  rc=0
  out=$(FM_CONTROL_SETTLE_WAIT=.05 run_control "$dir" "$id" interrupt) || rc=$?
  [ "$rc" -ne 0 ] || fail "adopted record authorized a process now pinned to another generation: $out"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" 'send-' "another launch's process must receive no lifecycle input"
  pass "omp adoption: a live process pinned to another launch generation is not adopted"
}

test_omp_adoption_caller_gate() {
  prepare_omp_adoption caller-gate
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  FM_FAKE_TASK_ID=$id assert_adoption_refused "$dir" "$id" 'workers cannot adopt a session record'
  FM_FAKE_ACTOR=branch assert_adoption_refused "$dir" "$id" 'the supervision branch never performs this action'
  printf '1\n' > "$dir/home/state/.lock"
  assert_adoption_refused "$dir" "$id" 'session record adoption requires the actual lock-owning main Firstmate'
  pass "omp adoption: workers, the supervision branch, and a non-owning session are refused with the record unchanged"
}

test_omp_adoption_proof_boundaries() {
  local shape dir id record out rc
  for shape in missing-pane missing-worktree outside-cwd unreadable-cwd different-session missing-task-file ancestor-worktree alias-worktree unreadable-inventory; do
    prepare_omp_adoption "$shape"
    dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID record="$HERDR_CASE_DIR/home/state/$HERDR_CASE_ID.omp-session.json"
    case "$shape" in
      missing-pane)
        printf '%%8' > "$dir/fake/herdr-pane"
        assert_adoption_refused "$dir" "$id" 'endpoint proof needs the recorded pane' ;;
      missing-worktree)
        # A physically missing workspace cannot become authority through its pathname.
        while IFS= read -r line; do
          case "$line" in worktree=*) printf 'worktree=%s\n' "$dir/gone" ;; *) printf '%s\n' "$line" ;; esac
        done < "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.new"
        mv "$dir/home/state/$id.meta.new" "$dir/home/state/$id.meta"
        assert_adoption_refused "$dir" "$id" 'workspace proof needs an existing absolute worktree' ;;
      outside-cwd)
        printf '%s' "$dir" > "$dir/fake/adoption-cwd"
        assert_adoption_refused "$dir" "$id" "foreground cwd inside this task's recorded worktree" ;;
      unreadable-cwd)
        : > "$dir/fake/adoption-cwd-unreadable"
        assert_adoption_refused "$dir" "$id" 'kernel cwd proof' ;;
      different-session)
        printf '{}\n' > "$dir/personal.jsonl"
        printf '%s' "$dir/personal.jsonl" > "$dir/fake/recovery-session-ref"
        assert_adoption_refused "$dir" "$id" 'live session file to identify the preserved task session' ;;
      unreadable-inventory)
        if [ "$(id -u)" != 0 ]; then
          (
            trap 'chmod 700 "$dir/home/state"' EXIT
            chmod 300 "$dir/home/state"
            assert_adoption_refused "$dir" "$id" 'unique-claim proof needs a readable complete inventory'
          ) || fail "unreadable claim inventory did not refuse safely"
        fi ;;
      alias-worktree)
        ln -s "$dir/wt" "$dir/alias"
        printf 'worktree=%s\n' "$dir/alias" > "$dir/home/state/alias.meta"
        assert_adoption_refused "$dir" "$id" 'unique deepest match' ;;
      missing-task-file|ancestor-worktree)
        if [ "$shape" = missing-task-file ]; then
          jq 'del(.task_session_file)' "$record" > "$record.new" && mv "$record.new" "$record"
        else
          printf 'worktree=%s\n' "$dir" > "$dir/home/state/parent.meta"
        fi
        out=$(run_continuation_control "$dir" "$id" adopt) || fail "safe boundary $shape refused: $out"
        jq -e --arg file "$dir/wt/recorded-session.jsonl" \
          '.task_session_file==$file and .current_session_file==$file and .spawn_gen=="old"' "$record" >/dev/null \
          || fail "safe boundary $shape wrote wrong session identity"
        # A repair never licenses an agent once its workspace loses ownership.
        printf 'worktree=%s\n' "$dir/wt/subdirectory" > "$dir/home/state/new-owner.meta"
        rc=0
        out=$(run_control "$dir" "$id" interrupt) || rc=$?
        [ "$rc" -ne 0 ] || fail "adopted record authorized a now-foreign workspace: $out"
        assert_not_contains "$(cat "$dir/fake/herdr-log")" 'send-' "lost workspace proof must send nothing" ;;
    esac
  done
  pass "omp adoption: pane, workspace, session-file identity, aliases, and ongoing authorization boundaries"
}

# A real process whose argv[0] is <name>, standing in for whatever now holds a
# recorded PID; it is killed by stop_stand_in or the suite's job reaping.
start_stand_in() { # <name> -> STAND_IN_PID
  local tries=0
  (exec -a "$1" /bin/sleep 60) &
  STAND_IN_PID=$!
  until [ "$(ps -p "$STAND_IN_PID" -o args= 2>/dev/null | cut -d' ' -f1)" = "$1" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 100 ] || fail "the stand-in $1 process did not start"
    sleep 0.05
  done
}

stop_stand_in() {
  kill "$STAND_IN_PID" 2>/dev/null || true
  wait "$STAND_IN_PID" 2>/dev/null || true
}

test_omp_adoption_live_recorded_pid() {
  local shape dir id record
  for shape in other-live-omp resolved-live-process; do
    prepare_omp_adoption "live-recorded-$shape"
    dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID record="$HERDR_CASE_DIR/home/state/$HERDR_CASE_ID.omp-session.json"
    # A record naming another live omp process belongs to the extension running
    # in it, and a real process named omp stands in for it. A record already
    # naming the resolved PID, as an earlier adopt leaves it, is not rewritten.
    case "$shape" in
      other-live-omp)
        start_stand_in omp
        jq --argjson pid "$STAND_IN_PID" '.pid=$pid' "$record" > "$record.new" ;;
      resolved-live-process)
        jq --argjson pid "$(cat "$dir/fake/recovery-pid")" '.pid=$pid | .current_session_file=.task_session_file' \
          "$record" > "$record.new" ;;
    esac
    mv "$record.new" "$record"
    case "$shape" in
      other-live-omp)
        assert_adoption_refused "$dir" "$id" "$STAND_IN_PID is a live omp process, so the omp extension owns this record"
        stop_stand_in ;;
      resolved-live-process)
        assert_adoption_refused "$dir" "$id" "the record already names $(cat "$dir/fake/recovery-pid"), so it was not changed" ;;
    esac
  done
  pass "omp adoption: a record already naming the live PID or naming another live omp process is refused unchanged"
}

test_omp_adoption_reused_recorded_pid() {
  local shape dir id record out pid
  for shape in non-agent other-agent; do
    prepare_omp_adoption "reused-$shape"
    dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID record="$HERDR_CASE_DIR/home/state/$HERDR_CASE_ID.omp-session.json"
    # After a reboot the recorded PID can belong to an unrelated live process:
    # the test shell itself, or another harness's agent, names no omp extension.
    case "$shape" in
      non-agent) pid=$$ ;;
      other-agent) start_stand_in claude; pid=$STAND_IN_PID ;;
    esac
    jq --argjson pid "$pid" '.pid=$pid' "$record" > "$record.new" && mv "$record.new" "$record"
    out=$(run_continuation_control "$dir" "$id" adopt) || fail "a recorded PID reused by a $shape process blocked repair: $out"
    [ "$shape" != other-agent ] || stop_stand_in
    assert_contains "$out" "adopted: $id" "repair over a reused PID reports its exact task"
    jq -e --arg task "$dir/wt/recorded-session.jsonl" \
      '. == {version:1,spawn_gen:"old",pid:2000000000,task_session_file:$task,current_session_file:$task}' \
      "$record" >/dev/null || fail "repair over a PID reused by a $shape process did not publish the live process and preserved task file"
    assert_not_contains "$(cat "$dir/fake/herdr-log")" 'send-' "repair over a reused PID sends no lifecycle input"
  done
  pass "omp adoption: a recorded PID reused by a process other than omp, another harness's agent included, does not block repair"
}

# The real omp extension, not a model of it, runs as the live process the fake
# Herdr resolves. Commands and acknowledgements travel over FIFOs and the
# adoption pause is a FIFO rendezvous, so every interleaving is ordered by
# messages and never by sleeps.
start_adoption_extension() { # <case-dir> <id> -> EXT_PROC_PID; fds 4 (commands) and 5 (acks)
  local dir=$1 id=$2 line
  mkdir -p "$dir/ext"
  cp "$ROOT/.omp/extensions/lib/fm-task-session.ts" "$dir/ext/fm-task-session.ts"
  cat > "$dir/ext/driver.mjs" <<'JS'
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';
const { createTaskSessionProof } = await import(pathToFileURL(process.env.EXT).href);
let active = process.env.SESSION;
const manager = { getSessionFile: () => active };
const session = { sessionManager: manager, waitForSessionTransition: () => Promise.resolve() };
const proof = createTaskSessionProof(process.env.STATE, process.env.TASK, { list: () => [{ kind: 'main', session }] });
const ctx = { sessionManager: manager, ui: { notify() {} } };
console.log(`ready ${process.pid}`);
for await (const event of createInterface({ input: process.stdin })) {
  if (event === 'exit') process.exit(0);
  try {
    if (event === 'personal') { active = process.env.PERSONAL; proof.start(ctx); }
    else proof[event](ctx);
    console.log(`ok ${event}`);
  } catch (error) { console.log(`error ${event} ${error.message}`); }
}
JS
  mkfifo "$dir/ext/commands" "$dir/ext/acks"
  FM_SPAWN_GEN=old EXT="$dir/ext/fm-task-session.ts" STATE="$dir/home/state" TASK="$id" \
    SESSION="$dir/wt/recorded-session.jsonl" PERSONAL="$dir/wt/personal-session.jsonl" \
    node --experimental-strip-types --no-warnings "$dir/ext/driver.mjs" \
    < "$dir/ext/commands" > "$dir/ext/acks" 2> "$dir/ext/errors" &
  exec 4> "$dir/ext/commands" 5< "$dir/ext/acks"
  read -r line <&5
  case "$line" in
    'ready '*) EXT_PROC_PID=${line#ready } ;;
    *) fail "the real omp extension process did not start: $line $(cat "$dir/ext/errors")" ;;
  esac
}

extension_event() { # start|shutdown
  local ack
  printf '%s\n' "$1" >&4
  read -r ack <&5
  [ "$ack" = "ok $1" ] || fail "the real omp extension $1 failed: $ack"
}

stop_adoption_extension() {
  printf 'exit\n' >&4
  exec 4>&- 5<&-
  wait "$EXT_PROC_PID" 2>/dev/null || true
}

# Wrap mv: the first call naming the session record, which is publication,
# announces itself on the events FIFO, then waits for the test to release it.
arm_adoption_barrier() { # <case-dir> <id>
  local dir=$1 id=$2
  mkfifo "$dir/fake/barrier-events" "$dir/fake/barrier-resume"
  cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
D=\$FM_FAKE_DIR
if [ -f "\$D/barrier-armed" ]; then
  for arg in "\$@"; do
    if [ "\${arg##*/}" = "$id.omp-session.json" ]; then
      rm -f "\$D/barrier-armed"
      printf 'reached mv\n' > "\$D/barrier-events"
      read -r _ < "\$D/barrier-resume"
      break
    fi
  done
fi
exec /bin/mv "\$@"
SH
  chmod +x "$dir/fakebin/mv"
  : > "$dir/fake/barrier-armed"
}

test_omp_adoption_personal_session_anchor_case() { # matching|unreadable
  local shape=$1 dir id record line rc=0 out reached=0 before adopt_job
  prepare_omp_adoption "personal-anchor-$shape"
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID record="$HERDR_CASE_DIR/home/state/$HERDR_CASE_ID.omp-session.json"
  write_recovery_native_session "$dir/wt/personal-session.jsonl" "$dir/wt" "personal conversation"
  start_adoption_extension "$dir" "$id"
  # The extension genuinely holds a matching pin, even when the external
  # observer cannot read its environment. Its predecessor record names a dead PID.
  printf '%s' "$EXT_PROC_PID" > "$dir/fake/recovery-pid"
  printf '%s' "$EXT_PROC_PID" > "$dir/fake/holder-pid"
  printf old > "$dir/fake/recovery-spawn-gen"
  [ "$shape" != unreadable ] || : > "$dir/fake/recovery-env-unreadable"
  before=$(cat "$record")
  arm_adoption_barrier "$dir" "$id"
  exec 6<> "$dir/fake/barrier-events"
  (
    rc=0
    run_continuation_control "$dir" "$id" adopt > "$dir/adopt.out" || rc=$?
    printf 'done %s\n' "$rc" > "$dir/fake/barrier-events"
  ) &
  adopt_job=$!
  read -r line <&6
  if [ "$line" = 'reached mv' ]; then
    reached=1
    # This is the window after the last comparison and before publication.
    # Activate a different persisted conversation through the REAL extension.
    extension_event personal
    printf 'go\n' > "$dir/fake/barrier-resume"
    read -r line <&6
  fi
  case "$line" in 'done '*) rc=${line#done } ;; *) fail "adoption ended unexpectedly: $line" ;; esac
  wait "$adopt_job"
  out=$(cat "$dir/adopt.out")
  exec 6>&-
  if [ "$reached" = 0 ]; then
    # The pin refusal comes before staging; the extension still sees T and
    # preserves it as task_session_file when it subsequently activates S.
    assert_equals "$before" "$(cat "$record")" "pin refusal must preserve the record before extension activation"
    extension_event personal
  fi
  # Probe recovery must never turn a newly rebound personal anchor into managed.
  rm -f "$dir/fake/recovery-env-unreadable"
  local anchor_ok=0
  jq -e --arg task "$dir/wt/recorded-session.jsonl" --arg personal "$dir/wt/personal-session.jsonl" \
    --argjson pid "$EXT_PROC_PID" \
    '.pid==$pid and .task_session_file==$task and .current_session_file==$personal' "$record" >/dev/null \
    && anchor_ok=1
  if [ "$anchor_ok" != 1 ]; then
    stop_adoption_extension
    fail "adoption ($shape) rebound the task anchor to a personal session (publication reached=$reached): $(cat "$record")"
  fi
  [ "$rc" -ne 0 ] || fail "adoption ($shape) accepted a pinned or unreadable process: $out"
  [ "$reached" = 0 ] || fail "adoption ($shape) reached publication for a process not proven unpinned: $out"
  assert_contains "$out" 'launch-pin proof needs a positively readable environment without a usable launch pin' "pin refusal must name the required proof"
  assert_not_contains "$out" 'adopted:' "a refused adoption must not report success"
  assert_equals 0 "$(find "$dir/home/state" -name '.*omp-session*' | wc -l | tr -d ' ')" \
    "a pin refusal must leave no staged record"
  rc=0
  out=$(FM_CONTROL_SETTLE_WAIT=.05 run_control "$dir" "$id" interrupt) || rc=$?
  stop_adoption_extension
  [ "$rc" -ne 0 ] || fail "adoption ($shape) authorized the personal conversation after probe recovery: $out"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" 'send-' "the personal session must receive no lifecycle input"
  pass "omp adoption: $shape pin proof refuses before staging and preserves the task anchor across real personal activation"
}

test_omp_adoption_personal_session_anchor() {
  test_omp_adoption_personal_session_anchor_case matching
}

test_omp_adoption_unreadable_personal_session_anchor() {
  test_omp_adoption_personal_session_anchor_case unreadable
}

test_omp_adoption_publication_race() {
  test_omp_adoption_personal_session_anchor
  test_omp_adoption_unreadable_personal_session_anchor
}

test_omp_adoption() {
  test_omp_adoption_matching_workspace
  test_omp_adoption_foreign_workspace
  test_omp_adoption_duplicate_pane
  test_omp_adoption_ambiguous_foreground
  test_omp_adoption_generation_mismatch
  test_omp_adoption_current_session_contradiction
  test_omp_adoption_unproven_same_pid
  test_omp_adoption_non_omp_process
  test_omp_adoption_unreadable_environment
  test_omp_adoption_other_generation_pin
  test_omp_adoption_caller_gate
  test_omp_adoption_proof_boundaries
  test_omp_adoption_live_recorded_pid
  test_omp_adoption_reused_recorded_pid
  test_omp_adoption_publication_race
}

test_quota_exhaustion_relaunches_only_a_permitted_route() {
  local dir model id meta out rc
  for model in openai-codex/gpt-6-luna openai-codex/gpt-6.1-sol; do
    id=rl-pool
    dir=$(new_case pooled-quota "$id")
    add_ship_task "$dir" "$id" omp
    printf omp > "$dir/fake/command"
    printf omp > "$dir/fake/becomes"
    printf 'unfinished change\n' > "$dir/wt/unfinished.txt"
    meta=$(cat "$dir/home/state/$id.meta")
    meta=${meta/model=default/model=$model}
    meta=${meta/effort=default/effort=high}
    printf '%s\ndispatch_rule=rule_1\n' "$meta" > "$dir/home/state/$id.meta"
    mkdir -p "$dir/home/config"
    jq -n --arg model "$model" '{rules:[{when:"assigned work",
      use:{harness:"omp",model:$model,effort:"high",provider:"codex"},
      fallback:(if $model=="openai-codex/gpt-6-luna" then
        [{harness:"omp",model:"lab/native-model",effort:"high"}] else [] end)},
      {when:"invalid stand-in",use:{harness:"omp",model:"openai-codex/gpt-6-astra",effort:"high"},
       fallback:[{harness:"pi",model:"lab/native-model",effort:"high"}]}]}' > "$dir/home/config/crew-dispatch.json"
    jq -n --argjson now "$(date +%s)" '{reports:[
      {provider:"openai-codex",fetchedAt:($now*1000),metadata:{meterStates:{chat:{allowed:false,limitReached:true}}}},
      {provider:"openai-codex",fetchedAt:($now*1000),metadata:{meterStates:{chat:{allowed:false,limitReached:true}}}}
    ]}' > "$dir/usage.json"
    cat > "$dir/fakebin/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'omp/18.1.20\n' ;;
  usage) cat "$FM_FAKE_DIR/../usage.json" ;;
  models) printf '%s\n' '{"models":[{"provider":"lab","id":"native-model","selector":"lab/native-model"}]}' ;;
  *) exit 0 ;;
esac
SH
    chmod +x "$dir/fakebin/omp"
    "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id" --state idle --source omp-ext --event quota-exhausted >/dev/null
    mkdir -p "$dir/user-home"
    # shellcheck disable=SC2031 # The helper subshell's PATH change does not reach here.
    out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
      -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
      PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
      FM_WAKE_QUEUE="$dir/home/state/.wake-queue" \
      HOME="$dir/user-home" FM_SPAWN_NO_GUARD=1 \
      FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
      bash -s -- "$ROOT" <<'SH'
. "$1/bin/fm-session-end-relaunch-lib.sh"
fm_session_end_relaunch_scan "$FM_HOME/state" 180 || exit
printf "%s\n" "$FM_SESSION_END_WAKE"
SH
    )
    rc=$?
    expect_code 0 "$rc" "supervised quota recovery must reconcile the route: $out"
    assert_equals 'unfinished change' "$(cat "$dir/wt/unfinished.txt")" "automatic replacement must preserve uncommitted work"
    if [ "$model" = openai-codex/gpt-6-luna ]; then
      assert_contains "$out" 'auto-relaunched after quota exhaustion' "an idle live OMP session must recover automatically"
      assert_equals lab/native-model "$(meta_field "$dir" "$id" model)" "Luna must recover on its declared stand-in"
      assert_equals complete "$(journal_field "$dir" "$id" phase)" "the real replacement transaction must complete"
      assert_grep 'fallback relaunched' "$dir/home/state/$id.status" "the served route must be reported"
    else
      assert_contains "$out" 'auto-relaunch failed' "strongest-model exhaustion must be surfaced without a weak stand-in"
      assert_equals omp "$(cat "$dir/fake/command")" "an unavailable strongest route must refuse before stopping the old agent"
      assert_equals openai-codex/gpt-6.1-sol "$(meta_field "$dir" "$id" model)" "the strongest model identity must remain unchanged"
      assert_no_grep '/quit' "$dir/fake/literal" "no exit may be sent when the strongest replacement is unavailable"
    fi
  done
  pass "supervised OMP quota recovery uses the declared stand-in or preserves the strongest route and work"
}

test_retiring_omp_removes_only_its_generated_configuration() {
  local dir out rc
  dir=$(new_case omp-config-retirement rl-config)
  add_ship_task "$dir" rl-config omp
  printf 'dispatch_rule=rule_1\n' >> "$dir/home/state/rl-config.meta"
  mkdir -p "$dir/home/config"
  printf '{"rules":[{"when":"OMP work","use":{"harness":"omp"}}]}\n' > "$dir/home/config/crew-dispatch.json"
  printf omp > "$dir/fake/command"
  printf claude > "$dir/fake/becomes"
  printf 'export default () => {};\n' > "$dir/home/state/rl-config.omp-ext.ts"
  printf '{"retry":{"modelFallback":false}}\n' > "$dir/home/state/rl-config.omp-fallback.yml"
  printf '{"current_session_file":"retired"}\n' > "$dir/home/state/rl-config.omp-session.json"
  printf '{"at":1,"task":"rl-config","decision":"clear"}\n' > "$dir/home/state/rl-config.jev-guard.jsonl"
  cp "$dir/home/state/rl-config.jev-guard.jsonl" "$dir/prior-audit"
  mkdir -p "$dir/wt/.omp"
  printf 'user configuration\n' > "$dir/wt/.omp/config.yml"
  out=$(run_control "$dir" rl-config relaunch --harness claude --note "replace the configured runtime explicitly"); rc=$?
  expect_code 0 "$rc" "an explicit runtime replacement must complete: $out"
  assert_absent "$dir/home/state/rl-config.omp-fallback.yml" "retired model policy must not survive replacement"
  assert_absent "$dir/home/state/rl-config.omp-ext.ts" "retired callbacks must not survive replacement"
  assert_absent "$dir/home/state/rl-config.omp-session.json" "the retired session binding must not survive replacement"
  cmp -s "$dir/prior-audit" "$dir/home/state/rl-config.jev-guard.jsonl" || fail "runtime replacement removed historical task audit rows"
  assert_equals 'user configuration' "$(cat "$dir/wt/.omp/config.yml")" "retirement must preserve user configuration"
  out=$(run_control "$dir" rl-config relaunch --note "continue after the explicit runtime override"); rc=$?
  expect_code 0 "$rc" "the retired rule must not block subsequent recovery: $out"
  pass "OMP replacement retires generated policy without removing user configuration"
}

test_relaunch_without_a_usable_recorded_rule_keeps_prior_behavior() {
  local dir out rc recorded id
  for recorded in none stale; do
    id=rl-unlabeled-$recorded
    dir=$(new_case "unlabeled-$recorded" "$id")
    add_ship_task "$dir" "$id" claude
    [ "$recorded" = none ] || printf 'dispatch_rule=rule_7\n' >> "$dir/home/state/$id.meta"
    mkdir -p "$dir/home/config"
    printf '%s\n' '{"rules":[{"when":"Claude work","use":{"harness":"claude"},"fallback":[{"harness":"omp","model":"lab/native-model","effort":"high"}]},{"when":"unconfigured","use":{"harness":"claude","role":"missing-role"}},{"when":"invalid stand-in","use":{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"},"fallback":[{"harness":"codex","model":"gpt-6.1-sol","effort":"high"}]}],"default":{"harness":"claude"}}' > "$dir/home/config/crew-dispatch.json"
    out=$(run_control "$dir" "$id" relaunch --note "resume after the matrix edit"); rc=$?
    expect_code 0 "$rc" "a $recorded recorded rule with an ambiguous match must relaunch as before: $out"
    assert_contains "$out" "relaunched $id harness=claude from=claude" "the relaunch keeps the task's own route"
    assert_no_grep 'dispatch_rule=' "$dir/home/state/$id.meta" "an ambiguous match records no fallback rule"
  done
  pass "relaunch without a usable recorded rule treats an ambiguous match as no fallback"
}

control_relaunch_test_cases=(
test_omp_adoption
test_bounded_reboot_recovery_rotates_unmanaged_inspections_without_mutation
test_bounded_reboot_recovery_notifies_each_unmanaged_identity_once
test_bounded_reboot_recovery_advances_after_interrupted_inspection
test_exit_and_relaunch_remove_the_dialog_file
test_exit_removes_the_dialog_file_before_releasing_the_lock
test_retiring_omp_removes_only_its_generated_configuration
test_relaunch_without_a_usable_recorded_rule_keeps_prior_behavior
test_quota_exhaustion_relaunches_only_a_permitted_route
test_quota_recovery_keeps_the_typed_route_class
test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter
test_default_secondmate_relaunch_survives_unsafe_routing_sources
test_secondmate_relaunch_refuses_an_unmarked_home
test_secondmate_checkpoint_refuses_unreadable_child_state
test_secondmate_checkpoint_ignores_a_vanished_scratch_find_walk
test_concurrent_relaunch_is_refused
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution
test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it
test_relaunch_moves_a_drifted_item_back_in_flight
test_teamclaude_reaches_tmux_relaunch_paths
test_teamclaude_reaches_herdr_relaunch_paths
test_concrete_ask_admission_completes_fresh_spawns
test_fresh_charter_bypasses_concrete_ask_check
test_teamclaude_reaches_secondmate_respawn_on_both_backends
test_teamclaude_reaches_fresh_herdr_spawns
test_teamclaude_refusal_lands_before_the_old_agent_stops
test_reboot_recovery_skips_unpinned_foreground_without_mutation
test_reboot_recovery_refuses_non_omp_launches_without_mutation
test_secondmate_reboot_recovery_preserves_profile_and_child_work
test_bootstrap_inspects_the_derived_home_when_fm_home_is_unset
test_reboot_recovery_skips_busy_native_drafts_without_mutation
test_reboot_recovery_inspects_without_native_attribution
test_live_herdr_lifecycle_refuses_unmanaged_native_launches_without_mutation
test_legacy_herdr_record_keeps_prior_lifecycle_rule
test_live_herdr_lifecycle_accepts_managed_launches
test_herdr_shell_only_ordinary_lifecycle_accepts_missing_registration
test_managed_herdr_relaunch_refuses_unproven_replacement_env
)

control_relaunch_run "$@"
