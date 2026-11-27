#!/usr/bin/env bash
# Behavior tests for the free-disk floor (bin/fm-disk-floor-lib.sh owns the
# contract): a NEW spawn, a new no-mistakes run and the library's own admit
# command refuse to start below the floor, while a relaunch, a teardown, an
# unreadable meter and a floor read from config/disk-free-floor behave as the
# docs state. The relaunch routes live in tests/fm-disk-floor-relaunch.test.sh.
#
# Every case drives the real bin/fm-spawn.sh, bin/fm-teardown.sh,
# bin/fm-mem-guard.sh or bin/fm-disk-floor-lib.sh as a separate process against a
# private temp world. The sandbox cannot fill the real disk, so a fake df
# (tests/assets/fake-bin/df, first on PATH through tests/lib.sh) prints the
# chosen free kilobytes. A deferral is judged by what it left behind - no task
# record, no launch brief, no terminal or pool call, no git worktree - never by
# wording alone. The pipeline-start and bin/fm-duration.py routes are covered in
# tests/fm-cpu-pass-admission.py, which owns that pool's fixtures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
LIB="$ROOT/bin/fm-disk-floor-lib.sh"
MEMGUARD="$ROOT/bin/fm-mem-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-disk-floor)
DEFER_EXIT=75

# --- fixture ----------------------------------------------------------------

# Free kilobytes for a whole number of GiB, plus an optional extra KiB.
kb() { printf '%s\n' $(($1 * 1048576 + ${2:-0})); }

make_case() { # <name> [task-id...]
  local name=$1 case_dir fakebin id home
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  mkdir -p "$case_dir" "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  : > "$case_dir/df.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = lease ] && [ "${2:-}" = --help ]; then
  printf 'Usage:\n  treehouse lease <name> [flags]\n\nFlags:\n      --lease-holder string   Optional label recorded as the lease holder\n'
  exit 0
fi
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "${1:-}" in status) printf '[]\n' ;; esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the free-disk floor for $id.

## Firstmate spec
Admission test.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  done
  printf '%s\n' "$case_dir"
}

new_worktree() { # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

worktree_list() { git -C "$1/project" worktree list --porcelain; }
call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

# One real spawn of <args...> with the fake df printing <avail-kb> (or a mode).
run_spawn() { # <case-dir> <avail-kb|mode:NAME> <pane-path> <args...>
  local case_dir=$1 avail=$2 pane=$3 home="$1/home" mode=plenty kbs=
  shift 3
  case "$avail" in
    mode:*:*) mode=${avail#mode:}; kbs=${mode#*:}; mode=${mode%%:*} ;;
    mode:*) mode=${avail#mode:} ;;
    *) kbs=$avail ;;
  esac
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_FAKE_DF_AVAIL_KB="$kbs" FM_FAKE_DF_MODE="$mode" FM_FAKE_DF_LOG="$case_dir/df.log" \
    FM_GUARD_EVENT_LOG="$case_dir/guard-events.jsonl" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship() { # <case-dir> <avail-kb|mode:NAME> <id> [pane-path]
  local case_dir=$1 avail=$2 id=$3 pane=${4:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn "$case_dir" "$avail" "$pane" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

assert_nothing_created() { # <case-dir> <id> <calls-before> <worktrees-before>
  local case_dir=$1 id=$2 before=$3 worktrees=$4 home="$1/home" after
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a deferred spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] ||
    fail "a deferred spawn touched the terminal or worktree pool for $id: $(tail -n +"$((before + 1))" "$case_dir/calls.log")"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a deferred spawn left a git worktree for $id"
}

guard_events() { # <case-dir> <decision>
  jq -c --arg d "$2" 'select(.guard == "disk-free-floor" and .decision == $d)' \
    "$1/guard-events.jsonl" 2>/dev/null
}

# --- cases ------------------------------------------------------------------

# Test 1: below the floor a NEW spawn defers with 75 and one clear message, and
# nothing exists afterwards that a retry would have to clean up.
test_new_spawn_below_the_floor_defers_and_leaves_nothing() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case below task-a)
  home="$case_dir/home"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" "$(kb 19)" task-a "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn below the floor was not deferred: $out"
  assert_contains "$out" "deferred: disk free floor refused spawn of task task-a: 19 GiB free on the volume holding $case_dir/project, below the floor of 20 GiB ($home/config/disk-free-floor)" \
    "the deferral did not name the free GiB, the floor, the measured path and the config file"
  assert_contains "$out" "nothing was started" "the deferral did not say nothing was started"
  [ "$(grep -c 'disk free floor' <<<"$out")" -eq 1 ] || fail "the deferral was not one message: $out"
  assert_nothing_created "$case_dir" task-a "$before" "$worktrees"
  assert_contains "$(cat "$case_dir/df.log")" "$case_dir/project" "the meter did not measure the project's volume"
  [ -n "$(guard_events "$case_dir" deny)" ] || fail "the refusal wrote no deny guard event"
  pass "a new spawn below the floor exits 75 with one message naming free GiB, floor, path and config file, and creates nothing"
}

# Test 2: exactly the floor admits, one kilobyte under it refuses because the
# whole-GiB figure rounds down, and plenty admits.
test_the_floor_is_inclusive_and_rounds_down() {
  local case_dir out rc=0
  case_dir=$(make_case edge task-a task-b task-c)
  out=$(spawn_ship "$case_dir" "$(kb 20)" task-a) || rc=$?
  expect_code 0 "$rc" "exactly 20 GiB free was refused: $out"
  assert_contains "$out" "spawned task-a" "exactly 20 GiB free did not launch the worker"
  assert_not_contains "$out" "disk free floor" "an admitted spawn printed a floor message"
  [ -n "$(guard_events "$case_dir" allow)" ] || fail "the admission wrote no allow guard event"
  rc=0
  out=$(spawn_ship "$case_dir" "$(kb 19 1048575)" task-b "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "20 GiB minus 1 KiB (19.999 GiB) was admitted: $out"
  assert_contains "$out" "19 GiB free" "df rounding was not down to 19 GiB"
  rc=0
  out=$(spawn_ship "$case_dir" "$(kb 500)" task-c) || rc=$?
  expect_code 0 "$rc" "500 GiB free was refused: $out"
  pass "exactly 20 GiB admits, 20 GiB minus 1 KiB refuses at 19 GiB, and more admits"
}

# Test 4: cleanup is what frees space, so teardown runs at 1 GiB free and never
# reads the meter.
test_teardown_runs_below_the_floor() {
  local case_dir home out rc=0 wt
  case_dir=$(make_case teardown task-t)
  home="$case_dir/home"
  wt=$(new_worktree "$case_dir" task-t)
  out=$(spawn_ship "$case_dir" "$(kb 40)" task-t "$wt") || rc=$?
  expect_code 0 "$rc" "setup spawn for the teardown case failed: $out"
  : > "$case_dir/df.log"
  rc=0
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_CALL_LOG="$case_dir/calls.log" FM_FAKE_DF_AVAIL_KB="$(kb 1)" FM_FAKE_DF_LOG="$case_dir/df.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-t --force --drop-file "$(fm_test_drop_file)" 2>&1) || rc=$?
  expect_code 0 "$rc" "teardown at 1 GiB free failed: $out"
  assert_not_contains "$out" "disk free floor" "teardown printed a floor message"
  assert_absent "$home/state/task-t.meta" "teardown left the worker's record"
  [ ! -s "$case_dir/df.log" ] || fail "teardown read the disk meter: $(cat "$case_dir/df.log")"
  pass "teardown runs at 1 GiB free and is never refused by the floor"
}

# Test 5: an unreadable meter must not stop recovery or work: the step is
# admitted, one warning is printed, and a warn event is recorded.
test_an_unreadable_meter_admits_with_a_warning() {
  local case_dir out rc mode id n=0
  for mode in fail empty garbage; do
    n=$((n + 1))
    id="task-m$n"
    case_dir=$(make_case "unreadable-$mode" "$id")
    rc=0
    out=$(spawn_ship "$case_dir" "mode:$mode" "$id") || rc=$?
    expect_code 0 "$rc" "an unreadable meter ($mode) stopped the spawn: $out"
    assert_contains "$out" "warning: disk free floor not enforced for spawn of task $id: cannot read the free space of $case_dir/project; admitted" \
      "the unreadable meter ($mode) printed no warning"
    [ "$(grep -c 'disk free floor' <<<"$out")" -eq 1 ] || fail "the warning ($mode) was not one line: $out"
    [ -n "$(guard_events "$case_dir" warn)" ] || fail "the unreadable meter ($mode) wrote no warn guard event"
  done
  pass "df failing, printing nothing or printing garbage admits the spawn with one warning and a warn event"
}

# Test 6: the floor is read from config/disk-free-floor; absent means 20 and a
# malformed file refuses to start and names itself.
test_config_overrides_the_floor_and_a_malformed_file_refuses() {
  local case_dir home out rc=0 bad
  case_dir=$(make_case config task-a task-b task-c)
  home="$case_dir/home"
  printf '5\n' > "$home/config/disk-free-floor"
  out=$(spawn_ship "$case_dir" "$(kb 5)" task-a) || rc=$?
  expect_code 0 "$rc" "6 GiB-or-less free against a floor of 5 was refused at exactly 5: $out"
  rc=0
  out=$(spawn_ship "$case_dir" "$(kb 4)" task-b "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "4 GiB free against a floor of 5 was admitted: $out"
  assert_contains "$out" "4 GiB free on the volume holding $case_dir/project, below the floor of 5 GiB ($home/config/disk-free-floor)" \
    "the deferral did not use the configured floor"
  rm "$home/config/disk-free-floor"
  rc=0
  out=$(spawn_ship "$case_dir" "$(kb 19)" task-b "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an absent config did not mean 20: $out"
  assert_contains "$out" "below the floor of 20 GiB" "an absent config did not mean 20"
  for bad in 'abc' '0' '-5' '12.5' '007' '1234567' '5 GiB'; do
    printf '%s\n' "$bad" > "$home/config/disk-free-floor"
    rc=0
    out=$(bash "$LIB" floor "$home/config" 2>&1) || rc=$?
    expect_code 2 "$rc" "a malformed floor '$bad' was accepted: $out"
    assert_contains "$out" "$home/config/disk-free-floor must hold one positive whole number of GiB" \
      "the malformed floor '$bad' did not name its file"
  done
  # A real spawn with a malformed floor refuses to start and publishes nothing.
  printf 'abc\n' > "$home/config/disk-free-floor"
  rc=0
  out=$(spawn_ship "$case_dir" "$(kb 500)" task-c "$case_dir/unused") || rc=$?
  expect_code 2 "$rc" "a malformed floor did not refuse a spawn: $out"
  assert_contains "$out" "error: disk free floor refused spawn of task task-c: $home/config/disk-free-floor must hold one positive whole number of GiB" \
    "the spawn refusal did not name the floor file"
  assert_absent "$home/state/task-c.meta" "a malformed floor still published a record"
  printf '5\n6\n' > "$home/config/disk-free-floor"
  rc=0
  out=$(spawn_ship "$case_dir" "$(kb 500)" task-c "$case_dir/unused") || rc=$?
  expect_code 2 "$rc" "a two-line floor did not refuse to start: $out"
  assert_contains "$out" "holds more than one line" "the two-line floor was not named"
  pass "config/disk-free-floor overrides the floor, an absent file means 20, and a malformed file refuses naming itself"
}

# A copy that does not exist yet is measured on the volume it will be created on.
test_a_missing_path_is_measured_on_its_nearest_existing_ancestor() {
  local case_dir out rc=0
  case_dir=$(make_case ancestor)
  out=$(FM_FAKE_DF_AVAIL_KB="$(kb 7)" FM_FAKE_DF_LOG="$case_dir/df.log" \
    bash "$LIB" admit stack "$case_dir/home/not/created/yet" "$case_dir/home/config" 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a missing path was not measured on its ancestor: $out"
  assert_contains "$out" "7 GiB free on the volume holding $case_dir/home/not/created/yet" "the missing path was not named"
  assert_equals "$case_dir/home" "$(tail -n 1 "$case_dir/df.log")" "df did not measure the nearest existing ancestor"
  out=$(FM_FAKE_DF_AVAIL_KB="$(kb 9)" bash "$LIB" free "$case_dir/home/not/created/yet")
  assert_equals 9 "$out" "free did not print the whole GiB of the ancestor's volume"
  pass "a path that does not exist yet is measured on its nearest existing ancestor, never admitted as unreadable"
}

# Test 7 (the mem-guard route): the no-mistakes run start refuses below the floor
# and admits above it. The pool route and fm-duration.py are in
# tests/fm-cpu-pass-admission.py.
test_the_mem_guard_run_start_refuses_below_and_admits_above() {
  local case_dir home native out rc=0 marker
  case_dir=$(make_case memguard)
  home="$case_dir/home"
  native="$case_dir/native"
  mkdir -p "$native"
  printf '34359738368\n1\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' > "$native/sysctl"
  printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1000.\nPages speculative: 100.\nAnonymous pages: 1048576.\nFile-backed pages: 500000.\nPages purgeable: 1000.\nPages occupied by compressor: 32768.\n' > "$native/vm_stat"
  printf '[{"pid":101,"ppid":1,"comm":"xprotectd","started":"start-101","rss_bytes":1073741824,"fleet":false,"run":null}]\n' > "$native/processes.json"
  marker="$case_dir/started"
  out=$(cd "$case_dir" && FM_HOME="$home" FM_MEMORY_FIXTURE_DIR="$native" FM_FAKE_DF_AVAIL_KB="$(kb 19)" \
    "$MEMGUARD" run -- touch "$marker" 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the run start at 19 GiB free was not deferred: $out"
  assert_contains "$out" "deferred: disk free floor refused no-mistakes run start: 19 GiB free on the volume holding $case_dir, below the floor of 20 GiB ($home/config/disk-free-floor)" \
    "the run-start deferral did not use the same message"
  assert_absent "$marker" "a deferred run start still ran its command"
  rc=0
  out=$(cd "$case_dir" && FM_HOME="$home" FM_MEMORY_FIXTURE_DIR="$native" FM_FAKE_DF_AVAIL_KB="$(kb 20)" \
    "$MEMGUARD" run -- touch "$marker" 2>&1) || rc=$?
  expect_code 0 "$rc" "the run start at exactly 20 GiB free was refused: $out"
  assert_present "$marker" "an admitted run start did not run its command"
  pass "the no-mistakes run start refuses at 19 GiB free and admits at 20 GiB through fm-mem-guard.sh run"
}

# The library's own admit command is the one entry any other start path calls.
test_the_admit_command_defers_and_admits() {
  local case_dir out rc=0
  case_dir=$(make_case admit)
  out=$(FM_FAKE_DF_AVAIL_KB="$(kb 3)" bash "$LIB" admit stack "$case_dir" "$case_dir/home/config" 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the admit command at 3 GiB free was not deferred: $out"
  assert_contains "$out" "deferred: disk free floor refused stack: 3 GiB free on the volume holding $case_dir, below the floor of 20 GiB" \
    "the admit command did not use the common message"
  rc=0
  out=$(FM_FAKE_DF_AVAIL_KB="$(kb 20)" bash "$LIB" admit stack "$case_dir" "$case_dir/home/config" 2>&1) || rc=$?
  expect_code 0 "$rc" "the admit command at 20 GiB free was refused: $out"
  assert_equals "" "$out" "an admitted start printed output"
  pass "fm-disk-floor-lib.sh admit defers at 3 GiB free with 75 and admits at 20 GiB silently"
}

# The stack entry point the worker brief names: below the floor the command is
# never run, at the floor it runs and its exit status passes through, and an
# unreadable meter admits with the same warning as every other start.
test_the_stack_start_refuses_below_and_admits_above() {
  local case_dir out rc=0 marker STACK="$ROOT/bin/fm-stack-start.sh"
  case_dir=$(make_case stack)
  marker="$case_dir/stack-started"
  out=$(cd "$case_dir" && FM_HOME="$case_dir/home" FM_GUARD_EVENT_LOG="$case_dir/guard-events.jsonl" \
    FM_FAKE_DF_AVAIL_KB="$(kb 19 1048575)" "$STACK" -- touch "$marker" 2>&1) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the stack start at 19.999 GiB free was not deferred: $out"
  assert_contains "$out" "deferred: disk free floor refused stack: 19 GiB free on the volume holding $case_dir, below the floor of 20 GiB ($case_dir/home/config/disk-free-floor)" \
    "the stack deferral did not use the shared message"
  assert_absent "$marker" "a deferred stack start still ran its command"
  [ -n "$(guard_events "$case_dir" deny)" ] || fail "the stack refusal wrote no deny guard event"
  rc=0
  # shellcheck disable=SC2016
  out=$(cd "$case_dir" && FM_HOME="$case_dir/home" FM_FAKE_DF_AVAIL_KB="$(kb 20)" "$STACK" -- bash -c 'touch "$1"; exit 7' _ "$marker" 2>&1) || rc=$?
  expect_code 7 "$rc" "the stack command's own exit status was not passed through: $out"
  assert_present "$marker" "an admitted stack start did not run its command"
  rm -f "$marker"
  rc=0
  out=$(cd "$case_dir" && FM_HOME="$case_dir/home" FM_FAKE_DF_MODE=fail "$STACK" -- touch "$marker" 2>&1) || rc=$?
  expect_code 0 "$rc" "an unreadable meter stopped the stack start: $out"
  assert_contains "$out" "warning: disk free floor not enforced for stack: cannot read the free space of $case_dir; admitted" \
    "the unreadable meter printed no warning"
  assert_present "$marker" "an unreadable meter still blocked the stack command"
  rc=0
  out=$(cd "$case_dir" && FM_HOME="$case_dir/home" "$STACK" 2>&1) || rc=$?
  expect_code 64 "$rc" "a start with no command was not a usage error: $out"
  pass "the stack start defers at 19.999 GiB, runs at 20 GiB passing its exit status through, and admits an unreadable meter with a warning"
}

# A df that prints a parseable table and then exits nonzero is an unreadable
# meter, not a measurement: the exit status is df's own, never the last pipe stage's.
test_a_failing_df_with_parseable_output_admits_with_a_warning() {
  local case_dir out rc kb_value n=0 id
  for kb_value in "$(kb 1)" "$(kb 500)"; do
    n=$((n + 1))
    id="task-p$n"
    case_dir=$(make_case "partial-$n" "$id")
    rc=0
    out=$(spawn_ship "$case_dir" "mode:failafter:$kb_value" "$id") || rc=$?
    expect_code 0 "$rc" "a df that failed after printing $kb_value KiB free stopped the spawn: $out"
    assert_contains "$out" "warning: disk free floor not enforced for spawn of task $id: cannot read the free space of $case_dir/project; admitted" \
      "a failing df with $kb_value KiB free printed no warning"
    assert_not_contains "$out" "deferred:" "a failing df with $kb_value KiB free was read as a measurement"
    [ -n "$(guard_events "$case_dir" warn)" ] || fail "a failing df with $kb_value KiB free wrote no warn guard event"
    [ -z "$(guard_events "$case_dir" deny)" ] || fail "a failing df with $kb_value KiB free wrote a deny guard event"
  done
  pass "a df that prints a valid line then exits 1 admits the spawn with one warning and a warn event, at low and plentiful values"
}

disk_floor_test_cases=(
test_new_spawn_below_the_floor_defers_and_leaves_nothing
test_the_floor_is_inclusive_and_rounds_down
test_teardown_runs_below_the_floor
test_an_unreadable_meter_admits_with_a_warning
test_config_overrides_the_floor_and_a_malformed_file_refuses
test_a_missing_path_is_measured_on_its_nearest_existing_ancestor
test_the_mem_guard_run_start_refuses_below_and_admits_above
test_the_admit_command_defers_and_admits
test_the_stack_start_refuses_below_and_admits_above
test_a_failing_df_with_parseable_output_admits_with_a_warning
)

fm_test_run_cases "${disk_floor_test_cases[@]}" -- "$@"
