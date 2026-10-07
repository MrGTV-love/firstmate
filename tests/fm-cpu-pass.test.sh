#!/usr/bin/env bash
# fm-cpu-pass.test.sh - Host-wide CPU pass pool: sizing, exclusive passes,
# waiting outside the caller's bound, crash release, nested and opt-out paths,
# degraded runs, and the behavior-test runner's use of the pool.
#
# Every case drives bin/fm-cpu-pass.sh or bin/fm-test-run.sh as a separate
# process against a private pool directory, so the host's real pool is never
# touched and no case reads implementation source.
# Child commands are single-quoted on purpose: they expand in the child bash.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PASS_TOOL="$ROOT/bin/fm-cpu-pass.sh"
TMP_ROOT=$(fm_test_tmproot fm-cpu-pass)
# A case below may inherit FM_CPU_PASS_HELD from an outer runner; every case
# states the pass environment it needs instead.
unset FM_CPU_PASS_HELD FM_CPU_POOL FM_CPU_POOL_SIZE FM_CPU_POOL_DIR

BG_PIDS=()
reap_bg() {
  local pid
  for pid in "${BG_PIDS[@]+"${BG_PIDS[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done
  BG_PIDS=()
}
trap 'reap_bg; fm_test_cleanup' EXIT

# assert_re <extended-regex> <file> <msg>
assert_re() {
  grep -E -- "$1" "$2" >/dev/null || fail "$3"$'\n'"--- $2 ---"$'\n'"$(cat "$2" 2>/dev/null)"
}

new_pool() {  # <name> -> pool directory path (not created)
  printf '%s\n' "$TMP_ROOT/$1/pool"
}

held_count() {  # <pool> <size>
  FM_CPU_POOL_DIR=$1 FM_CPU_POOL_SIZE=$2 "$PASS_TOOL" status --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["held"])'
}

wait_held() {  # <pool> <size> <count> <what>
  for _ in $(seq 1 600); do
    [ "$(held_count "$1" "$2")" = "$3" ] && return 0
    sleep 0.05
  done
  fail "$4: pool never reached $3 held passes"
}

wait_file() {  # <path> <what>
  for _ in $(seq 1 600); do
    [ -e "$1" ] && return 0
    sleep 0.05
  done
  fail "$2: $1 never appeared"
}

test_size_follows_host_and_override() {
  local host got rc
  host=$(python3 -c 'import os; print(max(1, os.cpu_count() or 1))')
  got=$("$PASS_TOOL" size)
  assert_equals "$host" "$got" "default pool size must equal the host's logical CPU count"
  got=$(FM_CPU_POOL_SIZE=3 "$PASS_TOOL" size)
  assert_equals 3 "$got" "FM_CPU_POOL_SIZE must override the pool size"
  rc=0
  FM_CPU_POOL_SIZE=zero "$PASS_TOOL" size >/dev/null 2>&1 || rc=$?
  assert_equals 125 "$rc" "an invalid FM_CPU_POOL_SIZE must be a usage error"
  pass "pool size follows the host CPU count and its override"
}

test_run_passes_status_and_marks_child() {
  local pool out rc
  pool=$(new_pool run-status)
  out="$TMP_ROOT/run-status.out"
  rc=0
  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=2 "$PASS_TOOL" run --passes 5 -- \
    bash -c 'echo "held=$FM_CPU_PASS_HELD"; echo err >&2; exit 7' >"$out" 2>&1 || rc=$?
  assert_equals 7 "$rc" "run must exit with the command's own status"
  assert_equals "$(printf 'held=2\nerr')" "$(cat "$out")" \
    "the child must see its clamped pass count and the output must be the command's alone"
  rc=0
  FM_CPU_POOL_DIR=$pool "$PASS_TOOL" run -- "$TMP_ROOT/absent-command" 2>/dev/null || rc=$?
  assert_equals 127 "$rc" "a missing command must exit 127"
  rc=0
  "$PASS_TOOL" run >/dev/null 2>&1 || rc=$?
  assert_equals 125 "$rc" "run without a command must be a usage error"
  pass "run returns the command's status, clamps passes, and marks the child"
}

test_passes_are_exclusive_and_waiters_queue() {
  local pool dir holder waiter log out
  dir="$TMP_ROOT/exclusive"
  mkdir -p "$dir"
  pool=$(new_pool exclusive)
  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 "$PASS_TOOL" run --label first-holder -- \
    bash -c 'touch "$1/first-started"; while [ ! -e "$1/release" ]; do sleep 0.05; done; touch "$1/first-done"' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/first-started" "first holder"
  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 "$PASS_TOOL" status >"$dir/status"
  assert_grep "pool=1 held=1 free=0" "$dir/status" "status must report the held pass"
  assert_grep "label=first-holder" "$dir/status" "status must name the holder"

  log="$dir/notices"
  out="$dir/second.out"
  ( FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 "$PASS_TOOL" run --label second --log-fd 3 -- \
      bash -c '[ -e "$1/first-done" ] && echo second-after-first' _ "$dir" \
      >"$out" 2>&1 3>"$log" ) &
  waiter=$!
  BG_PIDS+=("$waiter")
  # The waiter must still be queued once its first notice is due.
  for _ in $(seq 1 600); do
    grep -q "waiting" "$log" 2>/dev/null && break
    sleep 0.05
  done
  assert_re 'waiting [0-9]+s for 1 CPU pass\(es\) for second: all passes in use; pool size 1; holders: .*label=first-holder' \
    "$log" "a queued waiter must name the pool and its holders on the log fd"
  [ ! -s "$out" ] || fail "a queued waiter must not run its command: $(cat "$out")"
  touch "$dir/release"
  wait "$holder" || fail "first holder failed"
  wait "$waiter" || fail "second run failed: $(cat "$out")"
  BG_PIDS=()
  assert_equals second-after-first "$(cat "$out")" \
    "the waiter must run only after the holder released and its output must carry no notice"
  assert_grep "got 1 CPU pass(es) for second after" "$log" "the waiter must report its wait on the log fd"
  assert_equals 0 "$(held_count "$pool" 1)" "every pass must be free after both runs"
  pass "passes are exclusive, waiters queue, and notices stay off the command's output"
}

test_multi_pass_request_collects_all() {
  local pool dir holder big
  dir="$TMP_ROOT/multi"
  mkdir -p "$dir"
  pool=$(new_pool multi)
  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=2 "$PASS_TOOL" run -- \
    bash -c 'touch "$1/one"; while [ ! -e "$1/release" ]; do sleep 0.05; done' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/one" "single holder"
  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=2 "$PASS_TOOL" run --passes 2 --log-fd 3 -- \
    bash -c 'echo "big=$FM_CPU_PASS_HELD"' >"$dir/big.out" 2>&1 3>/dev/null &
  big=$!
  BG_PIDS+=("$big")
  wait_held "$pool" 2 2 "multi-pass collector holding its first slot"
  [ ! -s "$dir/big.out" ] || fail "a two-pass request ran with one pass"
  touch "$dir/release"
  wait "$holder" || fail "single holder failed"
  wait "$big" || fail "two-pass run failed"
  BG_PIDS=()
  assert_equals big=2 "$(cat "$dir/big.out")" "the two-pass request must run with both passes"
  pass "a multi-pass request keeps collected passes and runs once it holds all"
}

test_killed_holder_releases_its_pass() {
  local pool dir holder child
  dir="$TMP_ROOT/crash"
  mkdir -p "$dir"
  pool=$(new_pool crash)
  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 "$PASS_TOOL" run -- \
    bash -c 'echo $$ >"$1/child.pid"; exec sleep 60' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/child.pid" "crash holder"
  wait_held "$pool" 1 1 "crash holder"
  kill -KILL "$holder"
  wait "$holder" 2>/dev/null || true
  wait_held "$pool" 1 0 "after SIGKILL of the holder"
  child=$(cat "$dir/child.pid")
  kill "$child" 2>/dev/null || true
  BG_PIDS=()
  pass "the kernel frees a pass when its holder is killed, leaving no stale state"
}

test_term_to_holder_keeps_pass_with_running_work() {
  local pool dir holder rc
  dir="$TMP_ROOT/term"
  mkdir -p "$dir"
  pool=$(new_pool term)
  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 "$PASS_TOOL" run -- \
    bash -c 'touch "$1/started"; while [ ! -e "$1/release" ]; do sleep 0.05; done; exit 4' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/started" "term holder"
  kill -TERM "$holder"
  sleep 0.3
  assert_equals 1 "$(held_count "$pool" 1)" "a TERM to the holder alone must not drop the pass of running work"
  touch "$dir/release"
  rc=0
  wait "$holder" || rc=$?
  BG_PIDS=()
  assert_equals 4 "$rc" "the holder must exit with the command's status after the command ends"
  assert_equals 0 "$(held_count "$pool" 1)" "the pass must be free once the command ended"
  pass "a TERM to the holder keeps the pass until the running command ends"
}

test_term_to_waiter_never_runs_command() {
  local pool dir holder waiter rc
  dir="$TMP_ROOT/term-waiter"
  mkdir -p "$dir"
  pool=$(new_pool term-waiter)
  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 "$PASS_TOOL" run -- \
    bash -c 'touch "$1/started"; while [ ! -e "$1/release" ]; do sleep 0.05; done' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/started" "holder"
  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 "$PASS_TOOL" run --log-fd 3 -- \
    touch "$dir/waiter-ran" 3>/dev/null &
  waiter=$!
  BG_PIDS+=("$waiter")
  sleep 0.5
  kill -TERM "$waiter"
  rc=0
  wait "$waiter" || rc=$?
  assert_equals 143 "$rc" "a waiter ended by TERM must exit 143"
  touch "$dir/release"
  wait "$holder" || true
  BG_PIDS=()
  [ ! -e "$dir/waiter-ran" ] || fail "a waiter ended while queued must never run its command"
  pass "a waiter ended while queued exits without running its command"
}

test_nested_and_opt_out_run_directly() {
  local pool dir holder out
  dir="$TMP_ROOT/nested"
  mkdir -p "$dir"
  pool=$(new_pool nested)
  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 "$PASS_TOOL" run -- \
    bash -c '"$2" run -- bash -c "echo inner=\$FM_CPU_PASS_HELD" >"$1/inner.out"' _ "$dir" "$PASS_TOOL" &
  holder=$!
  BG_PIDS+=("$holder")
  for _ in $(seq 1 600); do
    [ -s "$dir/inner.out" ] && break
    sleep 0.05
  done
  wait "$holder" || fail "nested run failed"
  BG_PIDS=()
  assert_equals inner=1 "$(cat "$dir/inner.out")" \
    "a nested run inside a full pool must run directly under the outer pass, not deadlock"

  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 "$PASS_TOOL" run -- \
    bash -c 'touch "$1/hold"; while [ ! -e "$1/release" ]; do sleep 0.05; done' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/hold" "opt-out holder"
  out=$(FM_CPU_POOL=off FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 "$PASS_TOOL" run -- \
    bash -c 'echo "off=${FM_CPU_PASS_HELD-unset}"' 2>&1)
  assert_equals off=unset "$out" "FM_CPU_POOL=off must run at once without a pass or a notice"
  touch "$dir/release"
  wait "$holder" || true
  BG_PIDS=()
  pass "nested runs and FM_CPU_POOL=off run directly"
}

test_unusable_pool_degrades_with_notice() {
  local blocker out log rc fakebin
  blocker="$TMP_ROOT/not-a-dir"
  : >"$blocker"
  log="$TMP_ROOT/degrade.log"
  rc=0
  out=$(FM_CPU_POOL_DIR=$blocker "$PASS_TOOL" run --log-fd 3 -- \
    bash -c 'echo "held=$FM_CPU_PASS_HELD"; exit 3' 3>"$log" 2>&1) || rc=$?
  assert_equals 3 "$rc" "a degraded run must keep the command's status"
  assert_equals held=0 "$out" "a degraded run must mark the child and keep its output clean"
  assert_grep "without a CPU pass" "$log" "a degraded run must say so on the log fd"

  fakebin="$TMP_ROOT/no-python"
  mkdir -p "$fakebin"
  ln -sf "$(command -v bash)" "$fakebin/bash"
  ln -sf "$(command -v dirname)" "$fakebin/dirname"
  rc=0
  out=$(PATH="$fakebin" "$PASS_TOOL" run --label x --log-fd 3 -- \
    bash -c 'echo "held=$FM_CPU_PASS_HELD"; exit 5' 3>"$log" 2>&1) || rc=$?
  assert_equals 5 "$rc" "without python3 run must still execute the command"
  assert_equals held=0 "$out" "without python3 the command output must stay clean"
  assert_grep "python3 not found" "$log" "without python3 run must say so on the log fd"
  pass "an unusable pool or missing python3 runs the command without a pass and says so"
}

make_runner_repo() {  # <repo>
  local repo=$1
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-cpu-pass.sh" "$ROOT/bin/fm-cpu-pass.py" \
    "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh" "$repo/bin/fm-cpu-pass.sh"
}

test_runner_waits_for_pass_outside_script_bound() {
  local dir repo pool holder runner rc
  dir="$TMP_ROOT/runner"
  repo="$dir/repo"
  mkdir -p "$dir"
  make_runner_repo "$repo"
  cat >"$repo/tests/probe.test.sh" <<'SH'
#!/usr/bin/env bash
echo "skip: probe capability absent (held=$FM_CPU_PASS_HELD)"
sleep 1
SH
  pool=$(new_pool runner)
  FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 "$PASS_TOOL" run --label outside-burst -- \
    bash -c 'touch "$1/hold"; while [ ! -e "$1/release" ]; do sleep 0.05; done' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/hold" "outside burst"
  (cd "$repo" && FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 \
    bin/fm-test-run.sh --per-script-timeout-secs 3 tests/probe.test.sh) \
    >"$dir/out" 2>"$dir/err" &
  runner=$!
  BG_PIDS+=("$runner")
  # Release the outside burst only once the runner has shown its wait (after
  # 2s) and then waited past the 3s per-script bound.
  for _ in $(seq 1 600); do
    grep -q "waiting" "$dir/err" 2>/dev/null && break
    sleep 0.05
  done
  sleep 2
  [ ! -s "$dir/out" ] || grep -q "FM_TEST_BEGIN" "$dir/out" \
    || fail "unexpected runner output before the pass: $(cat "$dir/out")"
  assert_no_grep "held=" "$dir/out" "the script must not run before the runner holds its pass"
  touch "$dir/release"
  wait "$holder" || true
  rc=0
  wait "$runner" || rc=$?
  BG_PIDS=()
  assert_equals 0 "$rc" "a script that waited longer than its bound for a pass must not be timed out: $(cat "$dir/out" "$dir/err")"
  assert_re 'tests/probe\.test\.sh exit=0 .*gate_skip=true' "$dir/out" "the gate skip must still be the script's first line"
  assert_grep "held=1" "$dir/out" "the script must run holding one pass"
  assert_re 'waiting [0-9]+s for 1 CPU pass\(es\) for fm-test-run tests/probe\.test\.sh: all passes in use; pool size 1; holders: .*label=outside-burst' \
    "$dir/err" "the runner must show the pass wait on its stderr"
  assert_no_grep "fm-cpu-pass" "$dir/out" "pass notices must never enter the script output"

  rc=0
  cat >"$repo/tests/hang.test.sh" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  (cd "$repo" && FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 \
    bin/fm-test-run.sh --per-script-timeout-secs 1 tests/hang.test.sh) \
    >"$dir/hang.out" 2>"$dir/hang.err" || rc=$?
  assert_equals 1 "$rc" "a hung script must still fail the run"
  assert_grep "tests/hang.test.sh exit=124" "$dir/hang.out" "the per-script bound must still fire inside the pass"
  assert_equals 0 "$(held_count "$pool" 1)" "the pass must be free after a bounded script was terminated"
  pass "the runner takes each script's pass outside its bound and keeps notices off script output"
}

test_runner_inside_pass_holder_takes_none() {
  local dir repo pool holder rc
  dir="$TMP_ROOT/runner-nested"
  repo="$dir/repo"
  mkdir -p "$dir"
  make_runner_repo "$repo"
  cat >"$repo/tests/probe.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - held=$FM_CPU_PASS_HELD"
SH
  pool=$(new_pool runner-nested)
  rc=0
  (cd "$repo" && FM_CPU_POOL_DIR=$pool FM_CPU_POOL_SIZE=1 \
    "$PASS_TOOL" run -- bin/fm-test-run.sh tests/probe.test.sh) >"$dir/out" 2>&1 || rc=$?
  assert_equals 0 "$rc" "a runner inside a pass holder must not wait on the pass it is under: $(cat "$dir/out")"
  assert_grep "ok - held=1" "$dir/out" "the script must inherit the outer pass marker"
  pass "a runner inside a pass holder runs its scripts under that pass"
}

test_size_follows_host_and_override
test_run_passes_status_and_marks_child
test_passes_are_exclusive_and_waiters_queue
test_multi_pass_request_collects_all
test_killed_holder_releases_its_pass
test_term_to_holder_keeps_pass_with_running_work
test_term_to_waiter_never_runs_command
test_nested_and_opt_out_run_directly
test_unusable_pool_degrades_with_notice
test_runner_waits_for_pass_outside_script_bound
test_runner_inside_pass_holder_takes_none
