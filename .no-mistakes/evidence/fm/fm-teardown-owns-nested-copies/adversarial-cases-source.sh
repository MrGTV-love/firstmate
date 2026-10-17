# Extra adversarial cases, driven against the real bin/fm-teardown.sh and the REAL lsof.
live_run() {  # <rc-var> [teardown args...]
  local rc_var=$1 case_dir=$FOREIGN_CASE status=0
  shift
  rm -f "$case_dir/fakebin/lsof"
  env FM_TEARDOWN_VERNANT_PYTHON="$case_dir/vernant-python" FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$case_dir/code-root" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    NM_HOME="$case_dir/nm" PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@" > "$case_dir/stdout" 2> "$case_dir/stderr" || status=$?
  printf -v "$rc_var" '%s' "$status"
}

live_A_real_lsof_idle_locked_copy_released() {
  local rc
  dead_launcher_pid
  make_foreign_copy_case live-A "$FOREIGN_DEAD_PID"
  live_run rc
  echo "A rc=$rc"; cat "$FOREIGN_CASE/stderr"
  expect_code 0 "$rc" "A: should release"
  assert_absent "$FOREIGN_COPY" "A: copy survived"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "A: slot not returned"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" "A: driver"
  pass "A: real lsof, finished task, dead launcher: Vernant-locked landed copy released via driver and slot returned"
}

live_B_real_lsof_unrelated_process_in_copy_refuses() {
  local rc pid
  make_foreign_copy_case live-B
  (cd "$FOREIGN_COPY" && exec sleep 300) &
  pid=$!
  sleep 1
  live_run rc
  echo "B rc=$rc pid=$pid"; cat "$FOREIGN_CASE/stderr"
  kill -0 "$pid" 2>/dev/null || { fail "B: unrelated process was killed"; }
  kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  expect_code 1 "$rc" "B: must refuse"
  assert_grep "process $pid is running in it" "$FOREIGN_CASE/stderr" "B: refusal names pid"
  assert_foreign_copy_untouched B
  pass "B: real lsof, unrelated live process in copy: refused by pid, process not signalled, copy+slot untouched"
}

live_C_force_does_not_waive_unlanded() {
  local rc
  make_foreign_copy_case live-C
  printf 'unlanded\n' > "$FOREIGN_COPY/unlanded.txt"
  git -C "$FOREIGN_COPY" add unlanded.txt
  git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm 'unlanded foreign work'
  live_run rc --force
  echo "C rc=$rc"; cat "$FOREIGN_CASE/stderr"
  expect_code 1 "$rc" "C: --force must not waive"
  assert_grep "is not proved landed" "$FOREIGN_CASE/stderr" "C: reason"
  assert_foreign_copy_untouched C
  pass "C: --force does not waive the landed proof; copy kept with written reason"
}

live_D_real_lsof_task_own_session_ended() {
  local rc agent child pidfile i
  local script='my $child = fork(); if (!$child) { chdir $ARGV[1]; exec "sleep", "300"; } $SIG{CHLD} = "IGNORE"; open my $fh, ">", $ARGV[0]; print $fh $child; close $fh; sleep 300;'
  make_foreign_copy_case live-D
  pidfile=$FOREIGN_CASE/child-pid
  teardown_fixture_start "$FOREIGN_SLOT" KILL perl -e "$script" "$pidfile" "$FOREIGN_COPY"
  agent=$TEARDOWN_FIXTURE_PID
  for i in $(seq 100); do [ -s "$pidfile" ] && break; sleep 0.05; done
  child=$(cat "$pidfile")
  sleep 1
  git -C "$FOREIGN_CASE/project" worktree lock --reason "vernant-session-active owner=launcher:$agent launcher=$agent" "$FOREIGN_COPY"
  live_run rc
  echo "D rc=$rc agent=$agent child=$child"; cat "$FOREIGN_CASE/stderr"
  kill -KILL "$child" "$agent" 2>/dev/null || true
  expect_code 0 "$rc" "D: should release"
  assert_absent "$FOREIGN_COPY" "D: copy survived"
  assert_grep "	TERM	$child	" "$FOREIGN_CASE/state/task-x1.teardown-processes" "D: signal audit for process in copy"
  pass "D: real lsof, task's own session + child inside Vernant-locked copy: both ended (audited), copy released, slot returned"
}

live_E_reap_line() {
  local rc line
  make_foreign_copy_case live-E 
  git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'unlanded'
  live_run rc
  eval "$(sed -n '/^first_refusal_line() {/,/^}/p' "$ROOT/bin/fm-idle-session-reap.sh")"
  line=$(first_refusal_line "$(cat "$FOREIGN_CASE/stdout" "$FOREIGN_CASE/stderr")")
  echo "E rc=$rc reap-line: $line"
  expect_code 1 "$rc" "E: refuse"
  pass "E: reaper first_refusal_line = $line"
}

live_F_idempotent_rerun() {
  local rc
  make_foreign_copy_case live-F
  live_run rc
  expect_code 0 "$rc" "F1"
  live_run rc
  echo "F second run rc=$rc"; cat "$FOREIGN_CASE/stderr" | tail -3
  pass "F: second teardown after success rc=$rc"
}
