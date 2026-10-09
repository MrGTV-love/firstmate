#!/usr/bin/env bash
# fm-cpu-pass.test.sh - Host-wide CPU pass pool: sizing, exclusive passes,
# waiting outside the caller's bound, crash ownership, and nested paths,
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
unset FM_CPU_PASS_HELD FM_CPU_POOL_DIR

REAL_PYTHON=$(python3 -c 'import sys; print(sys.executable)')
mkdir -p "$TMP_ROOT/test-bin"
printf '#!%s\n' "$REAL_PYTHON" >"$TMP_ROOT/test-bin/python3"
cat >>"$TMP_ROOT/test-bin/python3" <<'PY'
import os, runpy, sys
if len(sys.argv) > 1 and os.path.basename(sys.argv[1]) == "fm-cpu-pass.py":
    if os.environ.get("FM_TEST_CPU_COUNT"):
        os.cpu_count = lambda: int(os.environ["FM_TEST_CPU_COUNT"])
    sys.argv = sys.argv[1:]
    runpy.run_path(sys.argv[0], run_name="__main__")
else:
    os.execv(sys.executable, [sys.executable] + sys.argv[1:])
PY
chmod +x "$TMP_ROOT/test-bin/python3"
export PATH="$TMP_ROOT/test-bin:$PATH"
export FM_TEST_CPU_COUNT=1

start_bg() {
  exec python3 -c 'import os,sys; os.setsid(); os.execvpe(sys.argv[1], sys.argv[1:], os.environ)' "$@"
}

BG_PIDS=()
reap_bg() {
  local pid
  for pid in "${BG_PIDS[@]+"${BG_PIDS[@]}"}"; do
    kill -KILL "$pid" 2>/dev/null || true
    kill -KILL -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    while kill -0 -- "-$pid" 2>/dev/null; do
      sleep 0.05
    done
  done
  BG_PIDS=()
}
trap 'reap_bg; fm_test_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# assert_re <extended-regex> <file> <msg>
assert_re() {
  grep -E -- "$1" "$2" >/dev/null || fail "$3"$'\n'"--- $2 ---"$'\n'"$(cat "$2" 2>/dev/null)"
}

new_pool() {  # <name> -> pool directory path (not created)
  printf '%s\n' "$TMP_ROOT/$1/pool"
}

held_count() {  # <pool> <size>
  FM_CPU_POOL_DIR=$1 FM_TEST_CPU_COUNT=$2 "$PASS_TOOL" status --json \
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

test_size_follows_host() {
  local host got
  host=$(python3 -c 'import os; print(max(1, os.cpu_count() or 1))')
  got=$(FM_TEST_CPU_COUNT='' "$PASS_TOOL" size)
  assert_equals "$host" "$got" "default pool size must equal the host's logical CPU count"
  pass "pool size follows the host CPU count"
}

test_run_passes_status_and_marks_child() {
  local pool out rc
  pool=$(new_pool run-status)
  out="$TMP_ROOT/run-status.out"
  rc=0
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=2 "$PASS_TOOL" run --passes 2 -- \
    bash -c 'echo "held=$FM_CPU_PASS_HELD"; echo err >&2; exit 7' >"$out" 2>&1 || rc=$?
  assert_equals 7 "$rc" "run must exit with the command's own status"
  assert_equals "$(printf 'held=2\nerr')" "$(cat "$out")" \
    "the child must see its exact pass count and the output must be the command's alone"
  rc=0
  FM_CPU_POOL_DIR=$pool "$PASS_TOOL" run -- "$TMP_ROOT/absent-command" 2>/dev/null || rc=$?
  assert_equals 127 "$rc" "a missing command must exit 127"
  rc=0
  "$PASS_TOOL" run >/dev/null 2>&1 || rc=$?
  assert_equals 125 "$rc" "run without a command must be a usage error"
  pass "run returns the command's status and marks the child with its exact count"
}

test_invalid_pass_counts_never_run_work() {
  local pool count rc marker form
  local options
  pool=$(new_pool invalid-count)
  marker="$TMP_ROOT/invalid-ran"
  for count in 0 -1 3 invalid 1.5 ''; do
    for form in split equals; do
      if [ "$form" = split ]; then options=(--passes "$count"); else options=("--passes=$count"); fi
      rc=0
      FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=2 "$PASS_TOOL" run "${options[@]}" -- \
        touch "$marker" >/dev/null 2>&1 || rc=$?
      assert_equals 125 "$rc" "an invalid pass count must be a usage error"
      [ ! -e "$marker" ] || fail "an invalid pass count started work"
      rc=0
      FM_CPU_PASS_HELD=1 FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=2 "$PASS_TOOL" run "${options[@]}" -- \
        touch "$marker" >/dev/null 2>&1 || rc=$?
      assert_equals 125 "$rc" "nested work must also reject an invalid count"
      [ ! -e "$marker" ] || fail "invalid nested work started"
    done
  done
  pass "invalid reservations refuse work in both option forms, including nested calls"
}

test_passes_are_exclusive_and_waiters_queue() {
  local pool dir holder waiter log out
  dir="$TMP_ROOT/exclusive"
  mkdir -p "$dir"
  pool=$(new_pool exclusive)
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 start_bg "$PASS_TOOL" run --label first-holder -- \
    bash -c 'touch "$1/first-started"; while [ ! -e "$1/release" ]; do sleep 0.05; done; touch "$1/first-done"' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/first-started" "first holder"
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 "$PASS_TOOL" status >"$dir/status"
  assert_grep "pool=1 held=1 free=0" "$dir/status" "status must report the held pass"
  assert_grep "label=first-holder" "$dir/status" "status must name the holder"

  log="$dir/notices"
  out="$dir/second.out"
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 start_bg "$PASS_TOOL" run --label second --log-fd 3 -- \
    bash -c '[ -e "$1/first-done" ] && echo second-after-first' _ "$dir" \
    >"$out" 2>&1 3>"$log" &
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
  local pool dir holder big waiter
  dir="$TMP_ROOT/multi"
  mkdir -p "$dir"
  pool=$(new_pool multi)
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=2 start_bg "$PASS_TOOL" run --label active-holder -- \
    bash -c 'touch "$1/one"; while [ ! -e "$1/release" ]; do sleep 0.05; done' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/one" "single holder"
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=2 "$PASS_TOOL" run --label finished-earlier -- true \
    || fail "earlier reservation failed"
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=2 start_bg "$PASS_TOOL" run --passes 2 --label current-collector --log-fd 3 -- \
    bash -c 'echo "big=$FM_CPU_PASS_HELD"' >"$dir/big.out" 2>&1 3>"$dir/collector.log" &
  big=$!
  BG_PIDS+=("$big")
  wait_held "$pool" 2 2 "multi-pass collector holding its first slot"
  [ ! -s "$dir/big.out" ] || fail "a two-pass request ran with one pass"
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=2 "$PASS_TOOL" status >"$dir/status"
  assert_grep "label=current-collector" "$dir/status" "partial status must name the current collector"
  assert_no_grep "label=finished-earlier" "$dir/status" "partial status must not name the finished earlier run"
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=2 "$PASS_TOOL" status --json >"$dir/status.json"
  python3 - "$dir/status.json" <<'PY' || fail "partial JSON status must identify the current reservations"
import json, sys
with open(sys.argv[1]) as handle:
    status = json.load(handle)
assert status["held"] == 2 and status["free"] == 0, status
assert {item["holder"].split("label=", 1)[1] for item in status["holders"]} == {
    "active-holder", "current-collector"
}, status
PY
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=2 start_bg "$PASS_TOOL" run --label queued-behind-collector --log-fd 3 -- \
    bash -c 'echo "small=$FM_CPU_PASS_HELD"' >"$dir/small.out" 2>&1 3>"$dir/waiter.log" &
  waiter=$!
  BG_PIDS+=("$waiter")
  for _ in $(seq 1 600); do
    if grep -q "waiting" "$dir/collector.log" && grep -q "waiting" "$dir/waiter.log"; then break; fi
    sleep 0.05
  done
  assert_re 'all passes in use; pool size 2; holders: .*label=current-collector' \
    "$dir/collector.log" "a partial collector's notice must identify its own held slot"
  assert_re 'another request is collecting passes; pool size 2; holders: .*label=current-collector' \
    "$dir/waiter.log" "a turnstile waiter's notice must identify the current collector"
  assert_no_grep "label=finished-earlier" "$dir/collector.log" "collector notices must not name the finished earlier run"
  assert_no_grep "label=finished-earlier" "$dir/waiter.log" "turnstile notices must not name the finished earlier run"
  [ ! -s "$dir/big.out" ] || fail "a partial collector ran while waiting"
  [ ! -s "$dir/small.out" ] || fail "a queued request bypassed the collecting request"
  touch "$dir/release"
  wait "$holder" || fail "single holder failed"
  wait "$big" || fail "two-pass run failed"
  wait "$waiter" || fail "queued single-pass run failed"
  BG_PIDS=()
  assert_equals big=2 "$(cat "$dir/big.out")" "the two-pass request must run with both passes"
  assert_equals small=1 "$(cat "$dir/small.out")" "the queued request must run with its requested pass"
  assert_equals 0 "$(held_count "$pool" 2)" "all passes must be free after queued reservations end"
  pass "a multi-pass request keeps collected passes and runs once it holds all"
}

test_killed_wrapper_keeps_work_reserved() {
  local pool dir holder child
  dir="$TMP_ROOT/crash"
  mkdir -p "$dir"
  pool=$(new_pool crash)
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 start_bg "$PASS_TOOL" run -- \
    bash -c 'echo $$ >"$1/child.pid"; exec sleep 60' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/child.pid" "crash holder"
  wait_held "$pool" 1 1 "crash holder"
  kill -KILL "$holder"
  wait "$holder" 2>/dev/null || true
  assert_equals 1 "$(held_count "$pool" 1)" "a SIGKILLed wrapper must not release its running child's pass"
  child=$(cat "$dir/child.pid")
  kill "$child" 2>/dev/null || true
  wait_held "$pool" 1 0 "after the surviving work exits"
  reap_bg
  pass "passes survive a killed wrapper and are freed when its work ends"
}

test_cleanup_terminates_running_work() {
  local pool dir holder child
  dir="$TMP_ROOT/cleanup"
  mkdir -p "$dir"
  pool=$(new_pool cleanup)
  FM_CPU_POOL_DIR=$pool start_bg "$PASS_TOOL" run -- \
    bash -c 'echo $$ >"$1/child.pid"; exec sleep 60' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/child.pid" "cleanup holder"
  child=$(cat "$dir/child.pid")
  reap_bg
  if kill -0 "$child" 2>/dev/null; then
    fail "cleanup left the workload alive"
  fi
  assert_equals 0 "$(held_count "$pool" 1)" "cleanup must release the workload's pass"
  pass "failure cleanup terminates and reaps wrappers and their workloads"
}

test_term_to_holder_keeps_pass_with_running_work() {
  local pool dir holder rc
  dir="$TMP_ROOT/term"
  mkdir -p "$dir"
  pool=$(new_pool term)
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 start_bg "$PASS_TOOL" run -- \
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
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 start_bg "$PASS_TOOL" run -- \
    bash -c 'touch "$1/started"; while [ ! -e "$1/release" ]; do sleep 0.05; done' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/started" "holder"
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 start_bg "$PASS_TOOL" run --log-fd 3 -- \
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

test_nested_runs_directly() {
  local pool dir holder rc
  dir="$TMP_ROOT/nested"
  mkdir -p "$dir"
  pool=$(new_pool nested)
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 start_bg "$PASS_TOOL" run -- \
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

  rc=0
  FM_CPU_PASS_HELD=1 FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=2 \
    "$PASS_TOOL" run --passes 2 -- touch "$dir/over-request-ran" \
    >"$dir/over-request.out" 2>&1 || rc=$?
  assert_equals 125 "$rc" "a nested request must not exceed its inherited reservation"
  [ ! -e "$dir/over-request-ran" ] || fail "nested over-request started work"
  FM_CPU_PASS_HELD=2 FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=2 \
    "$PASS_TOOL" run --passes 1 -- bash -c 'echo "inner=$FM_CPU_PASS_HELD"' \
    >"$dir/subset.out" || fail "nested work within its reservation failed"
  assert_equals inner=2 "$(cat "$dir/subset.out")" \
    "a smaller nested request must preserve the outer reservation"
  pass "nested runs execute under the outer reservation"
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

  rc=0
  out=$(PATH="$fakebin" "$PASS_TOOL" run -- \
    bash -c 'echo "held=$FM_CPU_PASS_HELD"; echo "child stderr" >&2; exit 5' 2>"$log") || rc=$?
  assert_equals 5 "$rc" "the default notice fd must preserve the command's exit status"
  assert_equals held=0 "$out" "the default notice must not leak into command stdout"
  assert_equals $'fm-cpu-pass: running bash without a CPU pass: python3 not found\nchild stderr' \
    "$(cat "$log")" "default stderr must contain one degradation notice and the child's stderr"
  pass "an unusable pool or missing python3 runs the command without a pass and says so"
}

test_no_python_validates_pass_counts() {
  local fakebin detector count form nested rc marker out env_tool
  local options counts environment
  marker="$TMP_ROOT/no-python-invalid-ran"
  env_tool=$(command -v env)
  for detector in unknown sysctl getconf; do
    fakebin="$TMP_ROOT/no-python-$detector"
    mkdir -p "$fakebin"
    ln -s "$(command -v bash)" "$fakebin/bash"
    ln -s "$(command -v dirname)" "$fakebin/dirname"
    counts=(0 -1 invalid 1.5 '')
    if [ "$detector" != unknown ]; then
      printf '#!%s\nprintf "2\\n"\n' "$(command -v bash)" >"$fakebin/$detector"
      chmod +x "$fakebin/$detector"
      counts+=(3 0003 9999999999999999999999999999999999)
    fi
    for nested in ordinary nested; do
      environment=(-u FM_CPU_PASS_HELD "PATH=$fakebin")
      if [ "$nested" = nested ]; then environment+=(FM_CPU_PASS_HELD=2); fi
      for form in split equals; do
        for count in "${counts[@]}"; do
          if [ "$form" = split ]; then options=(--passes "$count"); else options=("--passes=$count"); fi
          rc=0
          "$env_tool" "${environment[@]}" "$PASS_TOOL" run "${options[@]}" -- \
            bash -c 'printf ran >"$1"' _ "$marker" >/dev/null 2>&1 || rc=$?
          assert_equals 125 "$rc" "without Python $detector $nested $form count '$count' must be refused"
          [ ! -e "$marker" ] || fail "invalid no-Python work started"
        done
        if [ "$form" = split ]; then options=(--passes 02); else options=(--passes=02); fi
        rc=0
        out=$("$env_tool" "${environment[@]}" "$PASS_TOOL" run "${options[@]}" --log-fd 3 -- \
          bash -c 'echo "held=$FM_CPU_PASS_HELD"; exit 5' 3>/dev/null) || rc=$?
        assert_equals 5 "$rc" "a valid no-Python request must preserve the command's exit status"
        if [ "$nested" = nested ]; then
          assert_equals held=2 "$out" "no-Python nested work must preserve its reservation"
        else
          assert_equals held=0 "$out" "ordinary no-Python work must run without a pass"
        fi
      done
    done
    rc=0
    PATH="$fakebin" FM_CPU_PASS_HELD=1 "$PASS_TOOL" run --passes 2 -- \
      bash -c 'printf ran >"$1"' _ "$marker" >/dev/null 2>&1 || rc=$?
    assert_equals 125 "$rc" "no-Python nested work must refuse an over-request even without a size detector"
    [ ! -e "$marker" ] || fail "no-Python nested over-request started work"
    rc=0
    PATH="$fakebin" "$PASS_TOOL" run --passes >/dev/null 2>&1 || rc=$?
    assert_equals 125 "$rc" "a missing no-Python pass count must be a usage error"
  done
  pass "no-Python execution rejects invalid counts and preserves valid degraded work"
}

make_runner_repo() {  # <repo>
  local repo=$1
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-cpu-pass.sh" "$ROOT/bin/fm-cpu-pass.py" \
    "$ROOT/bin/fm-timeout-lib.sh" "$repo/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$repo/tests/"
  chmod +x "$repo/bin/fm-test-run.sh" "$repo/bin/fm-cpu-pass.sh"
}

test_inherited_marker_validation() {
  local dir repo marker mode held rc out command
  dir="$TMP_ROOT/inherited-validation"
  repo="$dir/repo"
  marker="$dir/ran"
  make_runner_repo "$repo"
  printf 'printf ran >"$MARKER"\n' >"$repo/tests/fm-brief.test.sh"
  for mode in engine no-python runner; do
    case "$mode" in
      engine) command=("$PASS_TOOL" run -- bash -c 'printf ran >"$MARKER"') ;;
      no-python) command=("$(command -v env)" "PATH=$TMP_ROOT/no-python-unknown" \
        "$PASS_TOOL" run -- bash -c 'printf ran >"$MARKER"') ;;
      runner) command=("$repo/bin/fm-test-run.sh" tests/fm-brief.test.sh) ;;
    esac
    for held in '' -1 invalid 1.5 +1 ' 1' '１'; do
      rc=0
      FM_CPU_PASS_HELD=$held MARKER=$marker "${command[@]}" >"$dir/out" 2>"$dir/err" || rc=$?
      assert_equals 125 "$rc" "$mode must refuse malformed inherited count '$held'"
      [ ! -e "$marker" ] || fail "$mode started work under a malformed marker"
    done
    for held in 0 00 01 2; do
      rc=0
      FM_CPU_PASS_HELD=$held MARKER=$marker "${command[@]}" >"$dir/out" 2>"$dir/err" || rc=$?
      assert_equals 0 "$rc" "$mode must accept inherited count '$held': $(cat "$dir/err")"
      [ -e "$marker" ] || fail "$mode did not run work under a valid marker"
      rm "$marker"
    done
  done
  for mode in engine no-python; do
    case "$mode" in
      engine) command=("$PASS_TOOL" run --passes 2) ;;
      no-python) command=("$(command -v env)" "PATH=$TMP_ROOT/no-python-unknown" \
        "$PASS_TOOL" run --passes 2) ;;
    esac
    out=$(FM_CPU_PASS_HELD=0 FM_TEST_CPU_COUNT=2 "${command[@]}" -- \
      bash -c 'echo "held=$FM_CPU_PASS_HELD"') || fail "$mode blocked nested degraded work"
    assert_equals held=0 "$out" "$mode must preserve the degraded marker"
  done
  pass "inherited markers are validated consistently while degraded work still runs"
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
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 start_bg "$PASS_TOOL" run --label outside-burst -- \
    bash -c 'touch "$1/hold"; while [ ! -e "$1/release" ]; do sleep 0.05; done' _ "$dir" &
  holder=$!
  BG_PIDS+=("$holder")
  wait_file "$dir/hold" "outside burst"
  FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 start_bg bash -c \
    'cd "$1" && exec bin/fm-test-run.sh --per-script-timeout-secs 3 tests/probe.test.sh' _ "$repo" \
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
  (cd "$repo" && FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 \
    bin/fm-test-run.sh --per-script-timeout-secs 1 tests/hang.test.sh) \
    >"$dir/hang.out" 2>"$dir/hang.err" || rc=$?
  assert_equals 1 "$rc" "a hung script must still fail the run"
  assert_grep "tests/hang.test.sh exit=124" "$dir/hang.out" "the per-script bound must still fire inside the pass"
  assert_equals 0 "$(held_count "$pool" 1)" "the pass must be free after a bounded script was terminated"
  pass "the runner takes each script's pass outside its bound and keeps notices off script output"
}

test_runner_inside_pass_holder_takes_none() {
  local dir repo pool rc jobs notice_count
  dir="$TMP_ROOT/runner-nested"
  repo="$dir/repo"
  mkdir -p "$dir"
  make_runner_repo "$repo"
  cat >"$repo/tests/fm-brief.test.sh" <<'SH'
#!/usr/bin/env bash
if ! mkdir "$NESTED_EVIDENCE/active"; then
  echo "not ok - nested scripts overlapped"
  exit 1
fi
trap 'rmdir "$NESTED_EVIDENCE/active"' EXIT
echo start >>"$NESTED_EVIDENCE/events"
echo "ok - held=$FM_CPU_PASS_HELD"
sleep 1
echo end >>"$NESTED_EVIDENCE/events"
SH
  cp "$repo/tests/fm-brief.test.sh" "$repo/tests/fm-composer-lib.test.sh"
  pool=$(new_pool runner-nested)
  for jobs in explicit automatic; do
    : >"$dir/events"
    rc=0
    (
      cd "$repo" || exit
      if [ "$jobs" = explicit ]; then set -- --jobs 2; else set --; fi
      FM_CPU_POOL_DIR=$pool FM_TEST_CPU_COUNT=1 NESTED_EVIDENCE=$dir \
        "$PASS_TOOL" run -- bin/fm-test-run.sh "$@" \
        tests/fm-brief.test.sh tests/fm-composer-lib.test.sh --json "$dir/timing.json"
    ) >"$dir/out" 2>"$dir/err" || rc=$?
    assert_equals 0 "$rc" "a nested $jobs runner must run within its one-pass reservation: $(cat "$dir/out" "$dir/err")"
    assert_equals "$(printf 'start\nend\nstart\nend')" "$(cat "$dir/events")" \
      "nested $jobs scripts must never overlap"
    assert_equals 2 "$(grep -c 'ok - held=1' "$dir/out")" \
      "both scripts must inherit the outer pass marker"
    notice_count=$(grep -c 'reducing --jobs .* to inherited FM_CPU_PASS_HELD=1' "$dir/err")
    assert_equals 1 "$notice_count" "a nested concurrency reduction must produce exactly one notice"
    assert_no_grep "reducing --jobs" "$dir/out" "the reduction notice must stay outside captured script output"
    python3 - "$dir/timing.json" <<'PY' || fail "nested timing must report the actual worker count"
import json, sys
assert json.load(open(sys.argv[1]))["selection"].split(";")[-1] == "jobs=1"
PY
  done
  pass "nested runners take no new pass and limit scripts to the inherited reservation"
}

test_size_follows_host
test_run_passes_status_and_marks_child
test_invalid_pass_counts_never_run_work
test_passes_are_exclusive_and_waiters_queue
test_multi_pass_request_collects_all
test_killed_wrapper_keeps_work_reserved
test_cleanup_terminates_running_work
test_term_to_holder_keeps_pass_with_running_work
test_term_to_waiter_never_runs_command
test_nested_runs_directly
test_unusable_pool_degrades_with_notice
test_no_python_validates_pass_counts
test_inherited_marker_validation
test_runner_waits_for_pass_outside_script_bound
test_runner_inside_pass_holder_takes_none
