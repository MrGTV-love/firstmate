#!/usr/bin/env bash
# Post-close cleanup for bin/fm-teardown.sh: leaked processes and the bounded
# reap, parked no-mistakes runs, forced teardowns, Herdr projection journals,
# and secondmate delivery and retirement. Closeout, Docker, and held-copy cases
# live in the closeout, docker, and retained tests/fm-teardown-*.test.sh groups.
# The landed-work proof matrix lives in tests/fm-teardown.test.sh; pool slots
# and returns live in tests/fm-teardown-pool.test.sh. Shared fixtures:
# tests/fm-teardown-helpers.sh.
# Usage: bash tests/fm-teardown-cleanup.test.sh [test_function_name ...]

set -u

# shellcheck source=tests/fm-teardown-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-helpers.sh"

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" unlanded.txt "unlanded work" "unpushed work"

  rc=0
  FM_GUARD_EVENT_LOG="$case_dir/guard-events.jsonl" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  jq -se 'any(.[]; .guard == "teardown-unlanded" and .task == "task-x1" and .rule == "landed-work" and .decision == "bypass" and .override == true and .cleared_by == "force")' "$case_dir/guard-events.jsonl" >/dev/null || fail "forced teardown was not attributed"
  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"

  case_dir=$(make_case force-scout)
  write_meta "$case_dir" local-only scout
  rc=0
  FM_GUARD_EVENT_LOG="$case_dir/guard-events.jsonl" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "force-scout: a forced scout teardown should complete"$'\n'"$(cat "$case_dir/stderr")"
  jq -se '([.[] | select(.guard == "teardown-unlanded")] | length == 0) and ([.[] | select(.task == "task-x1")] | length > 0)' \
    "$case_dir/guard-events.jsonl" >/dev/null \
    || fail "a forced scout teardown recorded a landed-work decision the check never inspects: $(cat "$case_dir/guard-events.jsonl" 2>/dev/null)"
  pass "a forced scout teardown records no landed-work escape"
}

# A teardown starts a detached home-summary refresh, which outlives the teardown
# and, once the fixture that owned the home is cleaned up, can never be stopped
# by anything that looks at the fixture: its command line names only the shared
# code. The child runs a real teardown case with its refresh worker held at the
# fence until the home is gone, then exits so its own fixture cleanup removes the
# home under the waiting worker; no worker may remain. The worker counts its
# fence polls in polls, so one that keeps polling fails by its own polls.
test_fixture_cleanup_leaves_no_home_summary_refresh_worker() {
  local child out polls stub worker identity
  child="$TMP_ROOT/fixture-cleanup-child.sh"
  out="$TMP_ROOT/fixture-cleanup-worker"
  polls="$TMP_ROOT/fixture-cleanup-fence-polls"
  stub="$TMP_ROOT/fixture-cleanup-stub"
  fm_test_refresh_fence_stub "$stub" || fail "could not write the fence stub"
  cat > "$child" <<'CHILD'
#!/usr/bin/env bash
set -u
# shellcheck source=tests/fm-teardown-helpers.sh
. "$1/tests/fm-teardown-helpers.sh"
case_dir=$(make_case leak-child)
write_meta "$case_dir" local-only ship
wt_commit_file "$case_dir" unlanded.txt "unlanded work" "unpushed work"
export FM_TEST_FENCE_ACTION=await-removal FM_TEST_FENCE_HOME="$case_dir"
FM_TEARDOWN_TEST_PATH="$2:$PATH" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
  > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "the child teardown failed: $(cat "$case_dir/stderr")"
fm_test_wait_until --progress-file "$case_dir/state/.test-fence-waiting" -- test -s "$case_dir/state/.test-fence-waiting" \
  || fail "the refresh worker never reached the fence"
worker=$(cat "$case_dir/state/.test-fence-waiting") || fail "the fence stub did not record the worker pid"
printf '%s\t%s\n' "$worker" "$(fm_test_pid_identity "$worker")" > "$3"
CHILD
  (
    fm_test_export_sleep_counter home_summary_fence
    FM_TEST_SLEEP_COUNT="$polls" exec bash "$child" "$ROOT" "$stub" "$out"
  ) || fail "the fixture child failed"
  IFS=$'\t' read -r worker identity < "$out" || fail "the child recorded no worker"
  [ -n "$worker" ] && [ -n "$identity" ] || fail "the child recorded no worker identity"
  # shellcheck disable=SC2329 # Invoked through fm_test_wait_until.
  worker_gone() { [ "$(fm_test_pid_identity "$worker" 2>/dev/null || true)" != "$identity" ]; }
  if ! fm_test_wait_until --while-alive "$worker" --cycles 10 "$polls" -- worker_gone; then
    kill -KILL "$worker" 2>/dev/null || true
    fail "the home-summary refresh worker $worker outlived its fixture's cleanup"
  fi
  pass "fixture cleanup after a teardown leaves no home-summary refresh worker"
}

# Registering a PR inside a secondmate home publishes the child's ready line
# with the canonical URL on the parent channel from fm-pr-check itself, once;
# a main home publishes nothing.
test_secondmate_pr_registration_publishes_ready_line() {
  local case_dir pr_head channel url
  url=https://github.com/example/repo/pull/7
  case_dir=$(make_case mate-pr-ready)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code-root" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" > "$case_dir/pr-check.out" 2> "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: fm-pr-check failed: $(cat "$case_dir/pr-check.err")"
  grep -q '^armed:' "$case_dir/pr-check.out" || fail "mate-pr-ready: poll was not armed"
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url mode=no-mistakes" <(sed -E 's/ \[at=[0-9]+\]//' "$channel") \
    "mate-pr-ready: the ready line did not reach the parent channel"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: registration reported a channel problem: $(cat "$case_dir/pr-check.err")"
  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code-root" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2>&1 \
    || fail "mate-pr-ready: re-registration failed"
  [ "$(grep -c 'child-pr-task-x1' "$channel")" -eq 1 ] \
    || fail "mate-pr-ready: re-registration duplicated the ready line"

  case_dir=$(make_case main-pr-ready)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  FM_ROOT_OVERRIDE="$case_dir/code-root" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2> "$case_dir/pr-check.err" \
    || fail "main-pr-ready: fm-pr-check failed"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "main-pr-ready: a main home reported a channel problem"
  [ ! -e "$case_dir/state/parent-replies.status" ] || fail "main-pr-ready: a main home wrote a parent reply"
  pass "fm-pr-check publishes the PR-ready line on a secondmate's parent channel once"
}

# Tearing a child down inside a secondmate home delivers the child's final
# ledger line to the parent before the record goes, and refuses (retaining
# every record) while the parent channel cannot be written; a rerun after the
# repair delivers and completes.
test_secondmate_home_teardown_delivers_final_line_or_refuses() {
  local case_dir rc channel wt_head err seq generation

  case_dir=$(make_case mate-teardown-delivers)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'working: shipping\ndone: PR https://github.com/example/repo/pull/9 checks green\n' \
    > "$case_dir/state/task-x1.status"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "mate-teardown-delivers: teardown should succeed: $(cat "$case_dir/stderr")"
  sed -E 's/ \[at=[0-9]+\]//' "$channel" | grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green pr=https://github.com/example/repo/pull/9 mode=local-only$' \
    || fail "mate-teardown-delivers: the final ledger line did not reach the parent: $(cat "$channel" 2>/dev/null)"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-delivers: teardown left the task record"

  case_dir=$(make_case mate-teardown-refuses)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  # The channel path is occupied by a directory, so no line can be appended.
  mkdir -p "$case_dir/parent/state/mate-x.status"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  mkdir -p "$case_dir/tasktmp"
  printf '!\n' > "$case_dir/state/task-x1.grok-turnend-token"
  printf '!\n' > "$case_dir/state/task-x1.kimi-turnend-token"
  printf 'tasktmp=%s\n' "$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'done: PR https://github.com/example/repo/pull/9 checks green\n' > "$case_dir/state/task-x1.status"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "mate-teardown-refuses: teardown proceeded with an undelivered final line"
  grep -q 'has not reached the parent channel' "$case_dir/stderr" \
    || fail "mate-teardown-refuses: refusal did not name the parent channel: $(cat "$case_dir/stderr")"
  [ -f "$case_dir/state/task-x1.meta" ] && [ -f "$case_dir/state/task-x1.status" ] \
    || fail "mate-teardown-refuses: refusal did not retain the task records"
  [ -f "$case_dir/state/task-x1.grok-turnend-token" ] \
    && [ -f "$case_dir/state/task-x1.kimi-turnend-token" ] \
    && [ -d "$case_dir/tasktmp" ] \
    || fail "mate-teardown-refuses: refusal removed endpoint records before parent delivery"
  rmdir "$channel"
  err=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" 2>&1 >/dev/null)
  seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p')
  generation=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p')
  [ -z "$seq" ] || FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 0 "$rc" "mate-teardown-refuses: rerun after repair should succeed: $(cat "$case_dir/stderr2")"
  sed -E 's/ \[at=[0-9]+\]//' "$channel" | grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green' \
    || fail "mate-teardown-refuses: the rerun did not deliver the final line"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-refuses: rerun left the task record"
  pass "a secondmate home's teardown delivers the child's final line or refuses until it can"
}

# The report step runs under teardown's progress line but keeps its own
# diagnostics: a misconfigured reconciler names its own cause.
test_secondmate_home_teardown_shows_report_diagnostics() {
  local case_dir rc wt_head

  case_dir=$(make_case mate-teardown-report-stderr)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'done: PR https://github.com/example/repo/pull/9 checks green\n' > "$case_dir/state/task-x1.status"
  rc=0
  FM_HOME="$case_dir/home" FM_INACTIVE_RECONCILE_BUDGET_SECS=40 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "mate-teardown-report-stderr: teardown went on past a report that could not run"
  grep -q 'FM_INACTIVE_RECONCILE_BUDGET_SECS must be a whole number from 1 to 30' "$case_dir/stderr" \
    || fail "mate-teardown-report-stderr: the report's own diagnostic was hidden: $(cat "$case_dir/stderr")"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-report-stderr: teardown did not keep the task record"
  pass "a secondmate home's teardown shows the report step's own diagnostics"
}

# A secondmate-home ship teardown whose completion-gate read at the report step
# goes silent does not know whether the child's done: is accepted. That is a
# retry (exit 75, the status the sweeps retry without a refusal memo), never the
# undeliverable-channel refusal: every record stays and nothing is delivered.
test_secondmate_home_teardown_unknown_acceptance_is_a_retry() {
  local case_dir rc channel wt_head

  case_dir=$(make_case mate-teardown-unknown)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'done: PR https://github.com/example/repo/pull/9 checks green\n' > "$case_dir/state/task-x1.status"
  rc=0
  FM_HOME="$case_dir/home" FM_FAKE_NM_GATE_HANG=1 FM_DOD_NM_STALL_SECS=2 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 75 "$rc" "mate-teardown-unknown: an unknown acceptance should ask for a retry: $(cat "$case_dir/stderr")"
  grep -q "^UNKNOWN: .*final outcome is accepted is unknown.*retry teardown" "$case_dir/stderr" \
    || fail "mate-teardown-unknown: teardown did not say the outcome is unknown: $(cat "$case_dir/stderr")"
  ! grep -q 'has not reached the parent channel\|REFUSED' "$case_dir/stderr" \
    || fail "mate-teardown-unknown: an unknown acceptance was reported as a refusal: $(cat "$case_dir/stderr")"
  [ -f "$case_dir/state/task-x1.meta" ] && [ -f "$case_dir/state/task-x1.status" ] \
    || fail "mate-teardown-unknown: teardown did not keep the task records"
  ! grep -q 'child-outcome-task-x1' "$channel" 2>/dev/null \
    || fail "mate-teardown-unknown: an unknown acceptance was delivered: $(cat "$channel")"
  pass "a secondmate home's teardown with an unknown done: acceptance keeps its records and asks for a retry"
}

test_teardown_missing_busy_sidecar_completes() {
  local case_dir gen rc
  case_dir=$(make_case missing-busy-sidecar)
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.busy-gen"

  rc=0
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "missing-busy-sidecar: teardown should treat the incarnation as already retired"
  assert_absent "$case_dir/state/task-x1.busy-state" \
    "missing-busy-sidecar: teardown left the orphan busy record"
  assert_absent "$case_dir/state/task-x1.meta" \
    "missing-busy-sidecar: teardown remained incomplete"
  pass "teardown completes when an exact busy-state sidecar is already absent"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  # A reachable session whose exact pane is already structurally gone: the
  # locked close is a no-op and the record gate sees a confirmed-gone pane.
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}' ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed: $(cat "$case_dir/stderr")"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes() {
  local case_dir log closed lock ready release holder_pid rc thlog
  case_dir=$(make_case herdr-orphan-refusal)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  # Record every treehouse invocation: the contended-lock refusal must fire
  # BEFORE the isolated copy is returned, so phase 1 may not invoke it at all.
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  lock=$(FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
    || fail "herdr-orphan-refusal: could not resolve the fixture presentation lock path"
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  local waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$ready" ] || fail "herdr-orphan-refusal: the contending lock holder never started"

  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"; wait "$holder_pid" 2>/dev/null || true
    fail "herdr-orphan-refusal: teardown reported success while the exact pane still existed under lock contention"
  fi
  [ -e "$case_dir/state/task-x1.meta" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the durable endpoint metadata"; }
  [ -e "$case_dir/state/task-x1.status" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the task status record"; }
  [ -e "$case_dir/state/task-x1.turn-ended" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the turn-end record"; }
  assert_grep "presentation lock is contended" "$case_dir/stderr" \
    "herdr-orphan-refusal: the pre-return refusal was not explained visibly"
  if [ -s "$thlog" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal still returned the isolated copy: $(cat "$thlog")"
  fi
  [ -d "$case_dir/wt" ] || { : > "$release"; fail "herdr-orphan-refusal: the contended refusal removed the isolated copy"; }
  if [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "fm/task-x1" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal dropped the task branch before refusing"
  fi
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    : > "$release"; fail "herdr-orphan-refusal: refusal still reported cleanup complete"
  fi
  if grep -q "^pane close" "$log"; then
    : > "$release"; fail "herdr-orphan-refusal: an unlocked pane close was attempted under contention"
  fi

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "herdr-orphan-refusal: the retry after lock release failed: $(cat "$case_dir/stderr2")"
  [ -e "$closed" ] || fail "herdr-orphan-refusal: the retry never closed the pane under the lock"
  [ -s "$thlog" ] || fail "herdr-orphan-refusal: the successful retry never returned the isolated copy"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-orphan-refusal: the successful retry left the metadata behind"
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "herdr-orphan-refusal: the successful retry left the status record behind"
  grep -q "teardown task-x1 complete" "$case_dir/stdout2" \
    || fail "herdr-orphan-refusal: the successful retry did not report completion"
  pass "herdr flat teardown refuses before returning the isolated copy under lock contention and the retry completes cleanly"
}

test_herdr_flat_teardown_refuses_records_on_unparseable_presence() {
  local case_dir log closed rc
  case_dir=$(make_case herdr-garbage-presence)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PANE_GET_GARBAGE=1 \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-garbage-presence: teardown erased records on an unparseable pane presence"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the task status record"
  assert_grep "ambiguous structured presence" "$case_dir/stderr" \
    "herdr-garbage-presence: the ambiguity refusal was not explained visibly"
  pass "herdr flat teardown never erases records when pane presence is unparseable"
}

test_herdr_flat_teardown_preflight_refuses_before_changes() {
  assert_herdr_teardown_preflight_refuses_before_changes unresolvable-lock
  assert_herdr_teardown_preflight_refuses_before_changes missing-adapter
  assert_herdr_teardown_preflight_refuses_before_changes missing-parser
  assert_herdr_teardown_preflight_refuses_before_changes missing-explicit-close-helper
  pass "herdr flat teardown preflight refuses before every destructive change"
}

test_herdr_teardown_presentation_lock_namespace_is_per_account() {
  local fake_uid own_ns legacy legacy_before legacy_after own_before case_dir rc lock linux_arms=0
  fake_uid=$(herdr_lock_ns_fake_uid)
  [ "$fake_uid" != "$(id -u)" ] || fail "herdr-lock-ns: fixture account uid collides with the running account"
  own_ns="/tmp/firstmate-herdr-presentation-$fake_uid"
  legacy=/tmp/firstmate-herdr-presentation
  [ ! -e "$own_ns" ] && [ ! -L "$own_ns" ] \
    || fail "herdr-lock-ns: fixture namespace $own_ns already exists; refusing to reuse it"
  printf '%s\n' "$own_ns" >> "$FM_TEST_CLEANUP_REGISTRY"
  mkdir -m 700 "$own_ns" || fail "herdr-lock-ns: could not stage $own_ns"
  legacy_before=$(herdr_lock_ns_path_state "$legacy")

  # This account's own name, really owned by another uid, is still refused and
  # is left exactly as it was.
  own_before=$(herdr_lock_ns_path_state "$own_ns")
  case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-foreign-owner)
  rc=0; run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-lock-ns-foreign-owner: teardown adopted a namespace another uid owns"
  assert_herdr_lock_ns_refused "$case_dir" herdr-lock-ns-foreign-owner
  [ "$(herdr_lock_ns_path_state "$own_ns")" = "$own_before" ] \
    || fail "herdr-lock-ns-foreign-owner: refusal changed the foreign-owned namespace: $(herdr_lock_ns_path_state "$own_ns")"

  if [ "$(uname -s)" != Darwin ]; then
    linux_arms=1
    # The old shared name is owned by another uid whenever it exists here, as
    # on a host where a second account created it first; this account's
    # teardown no longer consults it and completes in its own namespace.
    case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-other-account)
    run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" "$own_ns:$fake_uid:700" \
      || fail "herdr-lock-ns-other-account: teardown was blocked: $(cat "$case_dir/stderr")"
    [ -e "$case_dir/closed" ] || fail "herdr-lock-ns-other-account: the pane was not closed under the lock"
    [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-lock-ns-other-account: teardown left the metadata behind"
    grep -q "teardown task-x1 complete" "$case_dir/stdout" \
      || fail "herdr-lock-ns-other-account: teardown did not report completion"
    lock=$(FM_FAKE_ACCOUNT_UID="$fake_uid" FM_FAKE_NS_STAT="$own_ns:$fake_uid:700" \
      FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
      PATH="$case_dir/fakebin:$PATH" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
      || fail "herdr-lock-ns-other-account: could not resolve the fixture account's lock path"
    case "$lock" in
      "$own_ns"/order-*.lock) ;;
      *) fail "herdr-lock-ns-other-account: the lock is not in this account's namespace: $lock" ;;
    esac

    # This account's own name with the right owner but the wrong mode is refused.
    case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-wrong-mode)
    rc=0; run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" "$own_ns:$fake_uid:755" || rc=$?
    [ "$rc" -ne 0 ] || fail "herdr-lock-ns-wrong-mode: teardown adopted a namespace that is not mode 700"
    assert_herdr_lock_ns_refused "$case_dir" herdr-lock-ns-wrong-mode
    [ -d "$own_ns" ] || fail "herdr-lock-ns-wrong-mode: refusal removed the namespace"
  fi

  legacy_after=$(herdr_lock_ns_path_state "$legacy")
  [ "$legacy_after" = "$legacy_before" ] \
    || fail "herdr-lock-ns: teardown changed the old shared namespace: $legacy_before -> $legacy_after"
  rm -rf "$own_ns"
  if [ "$linux_arms" = 1 ]; then
    pass "herdr teardown takes its lock in a per-account namespace another account cannot block, and still refuses a foreign-owned or wrong-mode one"
  else
    pass "herdr teardown refuses a foreign-owned per-account namespace (owner-shim arms need the non-Darwin stat branch; skipped on Darwin)"
  fi
}

test_forced_secondmate_herdr_child_preflight_refuses_before_changes() {
  local case_dir home log closed rc thlog
  case_dir=$(make_case herdr-child-preflight)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; thlog="$case_dir/treehouse.log"
  : > "$log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-preflight: teardown continued through an unresolvable child lock"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-preflight: refusal erased the parent record"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-preflight: refusal erased the child record"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-preflight: refusal erased child status"
  [ -d "$home" ] || fail "herdr-child-preflight: refusal removed the secondmate home"
  [ ! -s "$thlog" ] || fail "herdr-child-preflight: refusal returned work before child preflight"
  [ ! -e "$closed" ] || fail "herdr-child-preflight: refusal attempted a child close"
  pass "forced secondmate teardown preflights every Herdr child before cleanup mutation"
}

test_forced_secondmate_teardown_holds_descendant_lifecycle_locks() {
  local case_dir home lock ready release holder_pid rc waited=0 child
  case_dir=$(make_case descendant-locks)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_tmux_children "$case_dir"
  home="$case_dir/secondmate-home"
  : > "$case_dir/kill.log"
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/kill.log"
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"

  lock="$home/state/.control-child-b.lock"
  ready="$case_dir/lock-ready"
  release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" \
    HOME_STATE="$home/state" OWNER_PID="$$" bash -c '
    export FM_STATE_OVERRIDE="$HOME_STATE"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ] && kill -0 "$OWNER_PID" 2>/dev/null; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || fail "descendant-locks: the contending lifecycle action never acquired its lock"

  rc=0
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"
    wait "$holder_pid" 2>/dev/null || true
    fail "descendant-locks: forced teardown ignored a descendant lifecycle lock"
  fi
  assert_grep "descendant task child-b has a lifecycle action in flight" "$case_dir/stderr" \
    "descendant-locks: refusal did not name the contended descendant"
  [ ! -e "$home/state/.control-child-a.lock" ] \
    && [ ! -e "$home/state/.meta-child-a.lock" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal leaked earlier descendant locks"; }
  [ ! -s "$case_dir/kill.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal killed an endpoint"; }
  [ ! -s "$case_dir/treehouse.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal returned a worktree"; }
  [ -e "$case_dir/state/task-x1.meta" ] && [ -d "$home" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed parent state"; }
  for child in child-a child-b; do
    [ -e "$home/state/$child.meta" ] && [ -d "$case_dir/$child-wt" ] \
      || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed $child state or worktree"; }
  done

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  rc=0
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "descendant-locks: uncontended retry should complete"
  [ ! -e "$case_dir/state/task-x1.meta" ] && [ ! -d "$home" ] \
    || fail "descendant-locks: uncontended retry retained retired task state"
  [ -s "$case_dir/kill.log" ] && [ -s "$case_dir/treehouse.log" ] \
    || fail "descendant-locks: uncontended retry did not perform endpoint and worktree cleanup"
  pass "forced secondmate teardown holds every descendant lifecycle and metadata lock"
}

test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-child-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-unconfirmed-close: teardown erased records after an ambiguous close"
  [ -e "$closed" ] || fail "herdr-child-unconfirmed-close: fixture did not attempt the child close"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child metadata"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child status"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-unconfirmed-close: failed child cleanup erased parent metadata"
  [ -d "$home" ] || fail "herdr-child-unconfirmed-close: failed child cleanup removed the secondmate home"
  assert_grep "retaining that child's durable identity records" "$case_dir/stderr" \
    "herdr-child-unconfirmed-close: refusal did not explain child record retention"
  pass "forced secondmate teardown retains Herdr child identity until exact pane disappearance"
}

test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed() {
  local case_dir home nested_home log closed rc
  case_dir=$(make_case herdr-grandchild-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_nested_secondmate_with_herdr_grandchild "$case_dir"
  home="$case_dir/secondmate-home"; nested_home="$home/nested-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-grandchild-unconfirmed-close: teardown erased records after an ambiguous grandchild close"
  [ -e "$closed" ] \
    || fail "herdr-grandchild-unconfirmed-close: fixture did not attempt the grandchild close"
  [ -d "$nested_home" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure still removed the nested secondmate home"
  [ -e "$nested_home/state/grandchild-herdr.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's metadata"
  [ -e "$nested_home/state/grandchild-herdr.status" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's status record"
  [ -e "$home/state/nested-sm.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the nested secondmate's own record"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the top-level secondmate's record"
  pass "forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed"
}

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  local rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-projection-unconfirmed-close: teardown reported success after an unknown post-close presence read"
  [ -e "$closed" ] \
    || fail "herdr-projection-unconfirmed-close: regression did not exercise an attempted close"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "unconfirmed task-pane close erased the durable endpoint metadata"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_grep "not confirmed gone" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the records were retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains every record when post-close presence is unknown"
}

test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-restore-failure)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    FM_FAKE_HERDR_RESTORE_FAIL=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-restore-failure: a confirmed close with a failed focus restore blocked teardown"
  [ -e "$closed" ] \
    || fail "herdr-projection-restore-failure: regression did not exercise the exact projected-pane close"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "herdr-projection-restore-failure: confirmed closure did not retire the presentation journal"
  assert_grep "exact-tab restoration failed" "$case_dir/stderr" \
    "herdr-projection-restore-failure: teardown swallowed the focus helper's restore warning"
  pass "herdr projection teardown surfaces failed focus restoration without turning confirmed cleanup into a hard failure"
}

test_teardown_retires_task_watcher_markers_and_orphan_journal() {
  local case_dir log closed restored marker
  case_dir=$(make_case retire-watcher-markers)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  # The projected workspace is already gone before teardown runs, so the close
  # path cannot match the journal to a live workspace and leaves it behind.
  : > "$closed"
  seed_watcher_markers "$case_dir" task-x1
  seed_watcher_markers "$case_dir" task-y2
  seed_watcher_markers "$case_dir" task-x1_extra
  printf '%s\n' 'version=1' 'task_id=task-y2' 'projection_id=ZyXwVuTsRqPoNmLkJiHgFe' \
    > "$case_dir/state/task-y2.herdr-presentation"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retire-watcher-markers: teardown failed: $(cat "$case_dir/stderr")"
  for marker in .seen-task-x1_status .seen-task-x1_turn-ended .hb-surfaced-task-x1 task-x1.herdr-presentation; do
    assert_absent "$case_dir/state/$marker" "teardown left the torn-down task's $marker behind"
  done
  for marker in .seen-task-y2_status .seen-task-y2_turn-ended .hb-surfaced-task-y2 task-y2.herdr-presentation \
    .seen-task-x1_extra_status .seen-task-x1_extra_turn-ended .hb-surfaced-task-x1_extra; do
    assert_present "$case_dir/state/$marker" "teardown removed another task's $marker"
  done
  pass "teardown retires the task's own watcher markers and orphaned presentation journal, leaving other tasks' markers alone"
}

test_teardown_retains_journal_bound_to_another_pane() {
  local case_dir log closed restored
  case_dir=$(make_case retain-drifted-journal)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  : > "$closed"
  # A version 2 binding that advanced to a replacement pane the metadata never
  # recorded may still name a live quarantined space; only the sweep may judge it.
  printf '%s\n' 'version=2' 'task_id=task-x1' 'projection_id=AbCdEfGhIjKlMnOpQrStUv' \
    "home=$case_dir" 'session=fmtest' 'workspace_id=w1' 'tab_id=w1:t2' 'pane_id=w1:p9' \
    'parent_workspace_id=w0' 'parent_label=firstmate' \
    'workspace_label=└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv' 'task_label=fm-task-x1' \
    > "$case_dir/state/task-x1.herdr-presentation"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-drifted-journal: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "teardown retired a journal bound to a pane it never proved gone"
  assert_absent "$case_dir/state/task-x1.meta" "retain-drifted-journal: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown kept the drifted journal without saying why"
  pass "teardown retains a presentation journal bound to a pane other than the closed endpoint"
}

test_teardown_retires_v1_journal_when_projected_workspace_gone() {
  local case_dir log closed
  case_dir=$(make_case retire-v1-journal-workspace-gone)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_WS_COLLAPSED=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retire-v1-journal-workspace-gone: teardown failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal whose token workspace is confirmed gone was not retired"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retire-v1-journal-workspace-gone: teardown did not complete"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retire-v1-journal-workspace-gone: teardown must never call workspace close"
  pass "teardown retires a v1 presentation journal once its token workspace is confirmed gone"
}

test_teardown_retains_v1_journal_when_projected_workspace_present() {
  local case_dir log closed
  case_dir=$(make_case retain-v1-journal-workspace-present)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-v1-journal-workspace-present: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal whose token workspace is still present was wrongly retired, stranding the workspace"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retain-v1-journal-workspace-present: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown retained the v1 journal without saying why"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retain-v1-journal-workspace-present: teardown must not escalate to workspace cleanup"
  pass "teardown retains a v1 presentation journal while its token workspace is still present"
}

test_teardown_retains_v1_journal_when_workspace_query_ambiguous() {
  local case_dir log closed
  case_dir=$(make_case retain-v1-journal-workspace-ambiguous)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  # A malformed workspace-list entry makes the token query ambiguous: teardown
  # cannot prove the token workspace gone, so it must keep the journal.
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_WS_MALFORMED=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-v1-journal-workspace-ambiguous: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal was retired even though the workspace query was ambiguous"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retain-v1-journal-workspace-ambiguous: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown retained the v1 journal without saying why"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retain-v1-journal-workspace-ambiguous: teardown must not escalate to workspace cleanup"
  pass "teardown retains a v1 presentation journal when the workspace query is ambiguous"
}

# Cleanup keeps the task's no-mistakes pipeline spend in this home's records
# (bin/fm-pipeline-spend.sh) while the task branch that attributes its runs and
# the task record still exist, then removes both as before.
test_teardown_records_the_task_pipeline_spend() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend)
  write_meta "$case_dir" no-mistakes ship
  : > "$case_dir/config/pipeline-spend"
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/nm"
  python3 - "$case_dir/nm/state.sqlite" "$case_dir/project" "$(date +%s)" <<'PY'
import sqlite3
import sys

database, project, created = sys.argv[1], sys.argv[2], int(sys.argv[3])
db = sqlite3.connect(database)
db.executescript("""
    CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
    CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                       status TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE agent_invocations (id TEXT, run_id TEXT, purpose TEXT, session_mode TEXT,
        started_at INTEGER, exit_status TEXT, duration_ms INTEGER, input_tokens INTEGER,
        output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
        delta_input_tokens INTEGER, delta_output_tokens INTEGER, delta_cache_read_tokens INTEGER);
""")
db.execute("INSERT INTO repos VALUES ('r1', ?)", (project,))
db.execute("INSERT INTO runs VALUES ('01RUN', 'r1', 'fm/task-x1', 'completed', ?)", (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i1', '01RUN', 'review', 'cold', ?, 'ok', 100, 7, 8, 9, 10, 7, 8, 9)",
           (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i2', '01RUN', 'review', 'cold', ?, 'cancelled', 50, "
           "NULL, NULL, NULL, NULL, NULL, NULL, NULL)", (created + 1,))
db.commit()
PY
  (
    export NM_HOME="$case_dir/nm" FM_FAKE_AXI_OVERVIEW="repo: $case_dir/project"
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  ) || rc=$?

  expect_code 0 "$rc" "pipeline-spend: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend: teardown left no pipeline spend record"
  jq -e '
    .task == "task-x1" and .spawn_gen == "teardown-test-task-x1"
    and .source == "no-mistakes-state" and .branch == "fm/task-x1"
    and [.runs[].id] == ["01RUN"]
    and .total.invocations == 2 and .total.exit == {"ok": 1, "cancelled": 1}
    and .total.input_tokens == {"total": 7, "unknown": 1}
  ' "$ledger" >/dev/null || fail "pipeline-spend: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend: teardown kept the task record"
  ! git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "pipeline-spend: teardown kept the task branch"
  pass "teardown records the task's pipeline spend before removing its branch and record"
}

test_teardown_skips_pipeline_spend_when_disabled() {
  local case_dir rc=0
  case_dir=$(make_case pipeline-spend-disabled)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-disabled: teardown should succeed"
  assert_absent "$case_dir/data/pipeline-spend.jsonl" \
    "pipeline-spend-disabled: teardown created a spend ledger without opt-in"
  assert_absent "$case_dir/state/task-x1.meta" \
    "pipeline-spend-disabled: teardown kept the task record"
  pass 'teardown skips all pipeline-spend recording when the home has not opted in'
}

# An owned ship task whose local copy is already gone and recorded PR is merged
# still leaves an unavailable-source account before its record goes.
test_teardown_records_unavailable_spend_for_a_gone_worktree() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  : > "$case_dir/config/pipeline-spend"
  seed_backlog_in_flight "$case_dir"
  append_pr_meta_url "$case_dir"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-gone: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend-gone: teardown left no pipeline spend record"
  jq -e '.task == "task-x1" and .source == "unavailable" and .total == null
    and (.reason | contains("is gone"))' "$ledger" >/dev/null \
    || fail "pipeline-spend-gone: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend-gone: teardown kept the task record"
  pass "teardown records unavailable pipeline spend for an owned ship task whose copy is gone"
}

test_parked_own_run_is_aborted_before_teardown() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort: teardown should still succeed"
  assert_present "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort was never invoked for the task's own parked run"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort did not target the verified run id"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-abort: teardown did not report aborting the parked run before removing the worker"
  pass "a task's own parked no-mistakes run is aborted, not orphaned, before the worker is removed"
}

# An abort can race a concurrent gate response: the run finishes with a
# passing-but-not-clean outcome (an explicitly approved Test/CI exception)
# instead of landing on `cancelled`. That is still a terminal, finished run,
# so teardown must conclude cleanly rather than refuse as still-parked.
test_parked_own_run_concludes_on_passed_with_override_after_abort() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort-passed-with-override)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT='run:
  id: "01RUN"
  outcome: passed-with-override
ci_override_reason: "live checks not all passed: Lint (fail)"' \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort-passed-with-override: teardown should still succeed"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "parked-run-abort-passed-with-override: a passing override outcome must not be reported as still parked"
  pass "a run that lands on passed-with-override after abort is still recognized as terminal"
}

# The same race, landing on the other automatic passing-but-not-clean outcome:
# publication or CI verification was skipped instead of an explicit override.
# That is still a terminal, finished run.
test_parked_own_run_concludes_on_passed_with_skips_after_abort() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort-passed-with-skips)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT='run:
  id: "01RUN"
  outcome: passed-with-skips
automatic_skips: "publication skipped: no-mistakes.yaml pr.enabled=false"' \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort-passed-with-skips: teardown should still succeed"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "parked-run-abort-passed-with-skips: a passing skips outcome must not be reported as still parked"
  pass "a run that lands on passed-with-skips after abort is still recognized as terminal"
}

# The pipeline advanced the parked run past the submitted head in its own
# repo, so the run head object does not exist in the task copy at all and the
# strict object-local identity rule cannot bind the run. The daemon's own
# runs ledger is what still proves the run is this task's continuation: its
# newest fm/task-x1 row is active at the unfetched head, anchored by the
# immediately older fm/task-x1 row ending exactly at this worktree's HEAD.
# Teardown must conclude the run instead of orphaning a parked gate wait that
# would otherwise hold a fleet slot forever (observed 2026-09-03). Foreign
# branches' rows interleaved in the ledger must not matter.
test_parked_run_advanced_past_unfetched_head_is_still_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-pipeline-advanced-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-pipeline-advanced-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-pipeline-advanced-unfetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-pipeline-advanced-unfetched: teardown did not abort the parked run the ledger proves is this task's continuation"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-pipeline-advanced-unfetched: teardown did not report aborting the parked run"
  pass "a parked run the pipeline advanced past the task copy is still concluded from the runs ledger, not orphaned"
}

test_parked_run_with_mismatched_ledger_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-mismatched-ledger-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-mismatched-ledger-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 deadbee 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-mismatched-ledger-head: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-mismatched-ledger-head: teardown aborted a ledger run with a different head"
  pass "a ledger row for a different head never authorizes a parked-run abort"
}

test_parked_run_with_malformed_ledger_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-malformed-ledger-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-malformed-ledger-row"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
running fm/task-x1 $advanced_short
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-malformed-ledger-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-malformed-ledger-row: teardown aborted from a malformed ledger row"
  pass "a malformed ledger row never authorizes a parked-run abort"
}

test_parked_run_with_impossible_ledger_date_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-impossible-ledger-date)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-impossible-ledger-date"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-02-31 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-02-28 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-impossible-ledger-date: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-impossible-ledger-date: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-impossible-ledger-date: teardown aborted from an impossible ledger date"
  pass "an impossible ledger date never authorizes a parked-run abort"
}

test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback() {
  local case_dir rc advanced_short anchor_short terminal_status
  case_dir=$(make_case parked-run-terminal-status-gate)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-status-gate"
  terminal_status=$(parked_axi_status_toon fm/task-x1 "$advanced_short")
  terminal_status=${terminal_status/status: awaiting_approval/status: completed}

  rc=0
  FM_FAKE_AXI_STATUS="$terminal_status" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-status-gate: teardown should still succeed"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-terminal-status-gate: terminal status queried the ledger fallback"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-status-gate: terminal status with a stale gate aborted"
  pass "a terminal status with a stale gate never reaches ledger cleanup"
}

# Counterfactual twin of the unfetched defect above: the SAME parked-run shape
# with the pipeline's advanced fix head FETCHED into the task copy (objects
# only - no ref moves) resolves through the strict object-local rule alone,
# because a fix round's commits descend from this worktree's submitted HEAD.
# With an EMPTY ledger, teardown must still abort - and must never query the
# ledger at all - proving the fallback stays dormant whenever the run head's
# object is present locally (no ledger dependency on the strict-rule path).
test_parked_run_advanced_head_locally_fetched_is_still_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-fetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  # The one changed condition vs the defect case: fetch the fix commits into
  # the project clone's object store (shared with the task worktree) without
  # moving any ref, so fm_nm_resolve_commit sees the head again.
  git -C "$case_dir/project" fetch -q "$case_dir/pipeline-clone" fm/task-x1
  [ -n "$(git -C "$case_dir/wt" rev-parse --verify --quiet "${advanced_short}^{commit}" 2>/dev/null)" ] \
    || fail "parked-run-advanced-fetched: fixture broke - the pipeline head never reached the task copy"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-fetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-advanced-fetched: teardown did not abort the parked run the strict object-local rule binds"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-advanced-fetched: the ledger fallback fired even though the advanced head resolves locally"
  pass "an advanced head present locally aborts through the strict rule alone - the ledger fallback stays dormant"
}

# No anchor: the unresolvable active row is the branch's ONLY row, so nothing
# proves the run ever touched this worktree's head - a branch-name coincidence
# or an arbitrary daemon-side run must not be concluded.
test_parked_advanced_run_without_anchor_is_never_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-no-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-no-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-no-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-no-anchor: teardown aborted an unanchored run it cannot prove is its own"
  pass "an unresolvable active row with no same-branch anchor is never concluded (conservative refusal)"
}

# The anchor row resolves but to an OLDER commit: the worktree advanced past
# it since the run was submitted, so exact-equality fails and the run is not
# provably this worktree's submission. Ancestor-only anchors must never bind.
test_parked_advanced_run_ancestor_anchor_is_never_aborted() {
  local case_dir rc advanced_short parent_short
  case_dir=$(make_case parked-run-advanced-ancestor-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  parent_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD~1)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ancestor-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$parent_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ancestor-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ancestor-anchor: teardown aborted on an ancestor-only anchor"
  pass "an ancestor-only anchor never binds an advanced parked run to this task"
}

# The branch's newest same-branch row is TERMINAL at an unfetched head: a
# finished run is history, never the branch's current run, and the anchored
# older row never answers for it. Teardown must not conclude a run from a
# stale terminal row.
test_parked_terminal_unfetched_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 08:20)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-unfetched: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-unfetched: teardown concluded a run from a terminal unfetched row"
  pass "a terminal unfetched-head row is stale history and never concludes a run"
}

# The crafted d15 boundary, tightened deliberately: the axi-reported head is
# unresolvable and the branch's newest ledger row is TERMINAL at exactly this
# worktree's head - a perfectly anchored, already-finished run. A finished run
# is history, so the ledger fallback authorizes cleanup only when its proved
# answer is the explicitly active word (`running`): a terminal newest row,
# even anchored at this head, never authorizes an abort. The runs log proves
# the fallback actually engaged, so the refusal is this tightened boundary
# and not an earlier guard.
test_parked_run_terminal_newest_row_at_own_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-newest-at-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-newest-at-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-03 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-newest-at-head: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-terminal-newest-at-head: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-newest-at-head: teardown aborted a run whose newest anchored ledger row is terminal"
  pass "a terminal newest row anchored at this worktree's head never authorizes an abort"
}

# The branch's newest row resolves in this copy to a head that DIVERGED from
# this worktree's HEAD (the branch was rewritten or moved on by a newer run
# from another worktree of the same project): not equal, not a descendant,
# so the shared rule answers nothing and every older row - including this
# task's parked run - stays stale history. Neither this task's run nor the
# unrelated newer run may be concluded here.
test_parked_run_behind_diverged_newer_row_is_never_aborted() {
  local case_dir rc advanced_short diverged_short
  case_dir=$(make_case parked-run-behind-newer-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-behind-newer-row"
  # A newer fm/task-x1 head that THIS copy resolves but that diverged from
  # the worktree's HEAD: rewritten from origin/main and pushed over the
  # branch (the fixture origin allows the non-fast-forward rewrite), then
  # fetched into the project clone (shared object store).
  git -C "$case_dir/origin.git" config receive.denyNonFastForwards false
  git clone -q "$case_dir/origin.git" "$case_dir/newer-clone"
  git -C "$case_dir/newer-clone" checkout -q origin/main
  git -C "$case_dir/newer-clone" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "newer run's diverged work"
  git -C "$case_dir/newer-clone" push -q --force origin HEAD:fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  diverged_short=$(git -C "$case_dir/wt" rev-parse --short=7 origin/fm/task-x1)
  git -C "$case_dir/wt" merge-base --is-ancestor HEAD "$diverged_short" \
    && fail "parked-run-behind-newer-row: fixture broke - the newer row is a descendant, not diverged"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$diverged_short" 2026-09-03 09:00)
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 07:55)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-behind-newer-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-behind-newer-row: teardown concluded this task from another run's ledger row"
  pass "a resolvable diverged newer same-branch row makes every older row stale history; no run is concluded"
}

# Two consecutive unresolvable running rows for the branch: the ledger cannot
# prove which row is current or where the submission boundary is. Ambiguity
# must refuse, never guess.
test_parked_advanced_run_ambiguous_rows_are_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-advanced-ambiguous)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir" 2)
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ambiguous"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 08:30)
$(ledger_row failed fm/other-task ccccccc 2026-09-03 08:10)
$(ledger_row running fm/task-x1 ddddddd 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ambiguous: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ambiguous: teardown guessed through ambiguous ledger rows"
  pass "consecutive unresolvable rows are ambiguous and never conclude a run"
}

# The ledger proves the continuation, but the run is NOT parked at a gate -
# it is autonomously running/fixing against the daemon's own clone. Teardown
# must leave that work alone even when the attribution proof would bind it.
test_ledger_proven_continuation_never_aborts_active_run() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-ledger-active)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-ledger-active"

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-ledger-active: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-ledger-active: teardown aborted an actively running run the ledger happened to bind"
  pass "a ledger-proven continuation is still left alone while the run is autonomously active"
}

test_mismatched_run_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-replaced)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head" 01RUN)" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT="$(parked_axi_status_toon fm/task-x1 "$head" 02RUN)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-replaced: a different run does not confirm the targeted abort"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-replaced: teardown did not abort only the verified run"
  assert_present "$case_dir/wt" "parked-run-replaced: teardown removed the worktree without confirmation"
  pass "a different run cannot confirm the targeted abort"
}

test_empty_status_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-empty-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_EMPTY_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-empty-confirmation: empty status should refuse"
  assert_present "$case_dir/wt" "parked-run-empty-confirmation: teardown removed the worktree"
  pass "empty post-abort status is not accepted as confirmation"
}

test_not_found_status_after_abort_confirms_completion() {
  local case_dir rc head
  case_dir=$(make_case parked-run-not-found-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_NOT_FOUND_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-found-confirmation: explicit not-found should confirm completion"
  pass "the CLI's exact run-not-found signal confirms completion"
}

test_parked_own_run_refuses_when_abort_is_unconfirmed() {
  local case_dir rc head pid
  case_dir=$(make_case parked-run-abort-unconfirmed)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  teardown_fixture_start "$case_dir/wt" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID

  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_ABORT_NOOP=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-abort-unconfirmed: teardown should refuse"
  assert_grep "REFUSED: no-mistakes run for task-x1 is still parked after axi abort" "$case_dir/stderr" \
    "parked-run-abort-unconfirmed: teardown did not explain the parked-run refusal"
  assert_present "$case_dir/wt" \
    "parked-run-abort-unconfirmed: teardown removed the worktree after refusing"
  assert_present "$case_dir/state/task-x1.meta" \
    "parked-run-abort-unconfirmed: teardown removed task metadata after refusing"
  assert_absent "$case_dir/treehouse.log" \
    "parked-run-abort-unconfirmed: teardown returned the worktree after refusing"
  kill -0 "$pid" 2>/dev/null || fail "parked-run-abort-unconfirmed: process reap ran before refusal"
  kill -KILL "$pid" 2>/dev/null || true
  pass "teardown refuses before reap or removal when a task-owned run remains parked"
}

# A no-mistakes daemon that goes quiet is not a daemon with no run to abort.
# Reading that silence as "nothing is parked" would remove the worker that a parked
# gate is waiting on and orphan the run, so teardown stops with the retry status
# (75), closes nothing, and says the answer is unknown.
test_silent_daemon_leaves_the_parked_run_unknown() {
  local case_dir rc head
  case_dir=$(make_case parked-run-daemon-silent)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_STATUS_HANG=1 FM_TEARDOWN_NM_STALL_SECS=2 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 75 "$rc" "parked-run-daemon-silent: a silent daemon should leave the answer unknown"
  assert_grep "UNKNOWN: the no-mistakes daemon went silent" "$case_dir/stderr" \
    "parked-run-daemon-silent: teardown did not say the answer is unknown"
  assert_present "$case_dir/wt" "parked-run-daemon-silent: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "parked-run-daemon-silent: teardown removed the task record"
  assert_absent "$case_dir/nm-abort.log" "parked-run-daemon-silent: teardown aborted a run it could not see"
  pass "a silent daemon leaves teardown unknown and closing nothing, not fail-open"
}

# The same lookup on a loaded host: the daemon answers, but only after burning CPU
# for longer than the ten seconds this read used to be allowed. A slow answer is an
# answer; the parked run is found and aborted before the worker goes.
test_slow_working_daemon_still_finds_the_parked_run() {
  local case_dir rc head
  case_dir=$(make_case parked-run-daemon-slow)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_STATUS_BURN_SECS=13 FM_FAKE_NM_BURN_MARK="$case_dir/nm-burned" FM_TEARDOWN_NM_STALL_SECS=2 \
  FM_DURATION_NO_PROGRESS_SECS=20 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-daemon-slow: a slow, working daemon should not block teardown"
  assert_grep "abort --run" "$case_dir/nm-abort.log" \
    "parked-run-daemon-slow: the parked run was not found and aborted"
  assert_grep "task-x1 is still waiting on a no-mistakes read" "$case_dir/stderr" \
    "parked-run-daemon-slow: teardown printed no progress while it waited, so a sweep could call it silent"
  pass "a slow, working daemon still lets teardown find and abort the parked run, with progress while it waits"
}

# The captain's --force discard is not held hostage by a quiet daemon: once the
# parked-run lookup is unknown, teardown goes on, and says and records that the
# run state is unknown.
test_forced_teardown_goes_on_past_a_silent_daemon() {
  local case_dir rc head
  case_dir=$(make_case parked-run-daemon-silent-forced)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_STATUS_HANG=1 FM_TEARDOWN_NM_STALL_SECS=2 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-daemon-silent-forced: --force should go on past an unknown run state"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "force goes on with the no-mistakes run state unknown" "$case_dir/stderr" \
    "parked-run-daemon-silent-forced: teardown did not say the run state is unknown"
  assert_grep "run state unknown" "$case_dir/data/task-x1/no-mistakes-unknown.log" \
    "parked-run-daemon-silent-forced: teardown did not record the unknown run state"
  assert_absent "$case_dir/state/task-x1.meta" "parked-run-daemon-silent-forced: the forced teardown did not finish"
  pass "a forced teardown goes on past a silent daemon and records the run state as unknown"
}

test_forced_teardown_goes_on_past_a_silent_confirmation() {
  local case_dir rc head
  case_dir=$(make_case parked-run-confirmation-silent-forced)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_VERIFY_HANG=1 FM_TEARDOWN_NM_STALL_SECS=2 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-confirmation-silent-forced: --force should go on past an unknown abort"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "abort --run" "$case_dir/nm-abort.log" \
    "parked-run-confirmation-silent-forced: the parked run was not aborted first"
  assert_grep "stopped after the abort is unknown" "$case_dir/data/task-x1/no-mistakes-unknown.log" \
    "parked-run-confirmation-silent-forced: teardown did not record the unknown abort outcome"
  assert_absent "$case_dir/state/task-x1.meta" "parked-run-confirmation-silent-forced: the forced teardown did not finish"
  pass "a forced teardown goes on past a silent abort confirmation and records it as unknown"
}

# After the abort is sent, only the confirming read goes quiet. That is not "still
# parked": nothing is known yet, and a later teardown confirms it.
test_silent_confirmation_after_abort_is_unknown() {
  local case_dir rc head
  case_dir=$(make_case parked-run-confirmation-silent)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_VERIFY_HANG=1 FM_TEARDOWN_NM_STALL_SECS=2 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 75 "$rc" "parked-run-confirmation-silent: a silent confirmation should leave the answer unknown"
  assert_grep "UNKNOWN: the no-mistakes daemon went silent" "$case_dir/stderr" \
    "parked-run-confirmation-silent: teardown did not say the confirmation is unknown"
  if grep -q 'is still parked after axi abort' "$case_dir/stderr"; then
    fail "parked-run-confirmation-silent: a silent confirmation was reported as still parked"
  fi
  assert_present "$case_dir/wt" "parked-run-confirmation-silent: teardown removed the worktree"
  pass "a silent confirmation after the abort is unknown, not a still-parked verdict"
}

test_another_branchs_parked_run_is_never_touched() {
  local case_dir rc
  case_dir=$(make_case parked-run-not-ours)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  local rc=0
  # A parked run reported for a DIFFERENT branch - e.g. another crew's task
  # still validating on the shared gate - must never be aborted by this task's
  # teardown.
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/some-other-task deadbeef)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-ours: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-not-ours: teardown called axi abort for a run on another branch"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "parked-run-not-ours: teardown reported aborting a run it does not own"
  pass "a parked run on another branch is never aborted by this task's teardown (ownership is precise)"
}

test_own_autonomous_run_is_left_alone() {
  local case_dir rc head
  case_dir=$(make_case autonomous-run-left-alone)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "autonomous-run-left-alone: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "autonomous-run-left-alone: teardown aborted a task-owned autonomous run"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "autonomous-run-left-alone: teardown reported aborting an autonomous run"
  pass "a task-owned autonomous running step is left alone rather than aborted"
}

test_leaked_worktree_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-process-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  # A backgrounded, disowned process rooted (by cwd) under the task's own
  # worktree - the same shape the observed incident's leaked `go test`
  # binaries took (reparented to init, no live task meta to attribute them
  # to once an unpatched teardown had already run).
  teardown_fixture_start "$case_dir/wt" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-process-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-process-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    teardown_fixture_stop "$pid"
    fail "leaked-process-reap: leaked worktree process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-process-reap: teardown did not report reaping the leaked process"
  assert_present "$case_dir/state/task-x1.teardown-processes" \
    "leaked-process-reap: teardown removed the durable process identity audit"
  pass "a leaked descendant process rooted under the task's worktree is reaped by teardown, not left surviving"
}

test_process_identity_is_recorded_before_term_and_kill() {
  local case_dir rc pid journal expected_start expected_cwd epoch signal audit_pid birth command start cwd matched
  case_dir=$(make_case durable-process-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  journal="$case_dir/state/task-x1.teardown-processes"
  teardown_fixture_start "$case_dir/wt" KILL perl -e "$(cat <<'PERL'
    my ($journal, $seen, $ready) = @ARGV;
    $SIG{TERM} = sub {
      open my $in, "<", $journal or die "signal arrived without audit";
      local $/; my $audit = <$in>;
      open my $out, ">", $seen or die "open observation";
      print {$out} $audit; close $out;
    };
    open my $ready_file, ">", $ready or die "ready"; close $ready_file;
    while (1) { sleep 300; }
PERL
  )" "$journal" "$case_dir/term-observed" "$case_dir/ready"
  pid=$TEARDOWN_FIXTURE_PID
  local i=0
  while [ ! -e "$case_dir/ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$case_dir/ready" ] || { teardown_fixture_stop "$pid"; fail "durable-process-identity: process not ready"; }
  expected_start=$(LC_ALL=C ps -p "$pid" -o lstart=)
  expected_cwd=$(cd "$case_dir/wt" && pwd -P)
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if kill -0 "$pid" 2>/dev/null; then
    teardown_fixture_stop "$pid"
    fail "durable-process-identity: leaked process survived"
  fi
  expect_code 0 "$rc" "durable-process-identity: teardown should succeed"
  assert_grep $'\tTERM\t'"$pid"$'\t' "$case_dir/term-observed" \
    "durable-process-identity: TERM preceded its durable identity record"
  assert_grep $'\tKILL\t'"$pid"$'\t' "$journal" \
    "durable-process-identity: KILL has no durable identity record"
  IFS=$'\t' read -r epoch signal audit_pid birth command start cwd matched < "$case_dir/term-observed"
  case "$epoch" in ''|*[!0-9]*) fail "durable-process-identity: invalid timestamp" ;; esac
  case "$command" in *perl*) ;; *) fail "durable-process-identity: command line missing" ;; esac
  case "$birth" in lstart=*|starttime=*) ;; *) fail "durable-process-identity: birth identity missing" ;; esac
  [ "$signal" = TERM ] && [ "$audit_pid" = "$pid" ] \
    || fail "durable-process-identity: signal target missing"
  [ "$start" = "$(printf '%q' "$expected_start")" ] \
    || fail "durable-process-identity: process start time missing or incorrect"
  [ "$cwd" = "$(printf '%q' "$expected_cwd")" ] && [ "$matched" = "$cwd" ] \
    || fail "durable-process-identity: cwd or matched open path missing or incorrect"
  pass "a real leaked process observes its durable identity audit before TERM, and KILL is audited too"
}

test_nested_registered_worktree_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped nested-worktree-custody project
  pass "registered nested-lane and unrelated processes and records remain untouched on forced teardown"
}

test_sibling_clone_nested_lane_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped sibling-nested-worktree-custody sibling
  pass "a nested lane registered by a sibling clone of the project is never signalled on forced teardown"
}

test_registered_lane_missing_git_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped missing-git-lane-custody project no-git
  pass "a still-registered nested lane whose .git is missing is never signalled through outer-worktree discovery"
}

test_deleted_registered_lane_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped deleted-lane-custody project deleted
  pass "a process inside a deleted but still-registered nested lane is never signalled"
}

test_sibling_clone_missing_git_lane_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped sibling-missing-git-lane-custody sibling no-git
  pass "a sibling lane without its .git is preserved because its custody is unproven"
}

test_sibling_clone_deleted_lane_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped sibling-deleted-lane-custody sibling deleted
  pass "a deleted sibling lane process is preserved because its custody is unproven"
}

test_own_deleted_cwd_process_is_not_reaped() {
  assert_unknown_descendant_process_is_not_reaped own-deleted-cwd-custody wt deleted
  assert_unknown_descendant_process_is_not_reaped tasktmp-deleted-cwd-custody tasktmp deleted
  pass "deleted descendants of worktree and non-Git tasktmp roots survive without a signal audit"
}

test_ordinary_descendant_process_is_not_reaped() {
  assert_unknown_descendant_process_is_not_reaped ordinary-descendant-custody wt none
  assert_unknown_descendant_process_is_not_reaped tasktmp-descendant-custody tasktmp none
  pass "ordinary existing descendants of worktree and non-Git tasktmp roots require proven custody"
}

test_process_refusal_has_no_close_replay_authority() {
  local scenario case_dir root pid other_pid birth other_birth rc path_without_lsof
  local flags=()
  for scenario in descendant foreign missing-lsof audit tasktmp legacy existing-marker; do
    case_dir=$(make_case "refusal-replay-$scenario")
    mkdir -p "$case_dir/home/state"
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" landed.txt "delivered work" "landed process fixture"
    git -C "$case_dir/wt" push -q origin HEAD:main
    git -C "$case_dir/project" fetch -q origin
    seed_backlog_in_flight "$case_dir"
    root="$case_dir/wt"
    flags=(--force --drop-file "$(fm_test_drop_file)")
    case "$scenario" in
      descendant|existing-marker|legacy)
        mkdir "$root/dist"
        root="$root/dist"
        if [ "$scenario" = legacy ]; then
          write_legacy_meta "$case_dir" no-mistakes ship
          flags+=(--legacy-record)
        fi
        ;;
      foreign)
        git clone -q "$case_dir/origin.git" "$case_dir/sibling"
        git -C "$case_dir/sibling" worktree add -q --detach "$root/foreign" main
        git -C "$case_dir/sibling" worktree lock "$root/foreign"
        root="$root/foreign"
        ;;
      missing-lsof)
        path_without_lsof=$(make_path_without_lsof "$case_dir")
        ln -s "$(command -v tasks-axi)" "$path_without_lsof/tasks-axi"
        ln -s "$(command -v node)" "$path_without_lsof/node"
        PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
          && fail "refusal-replay-$scenario: fixture exposes lsof"
        ;;
      audit) mkdir "$case_dir/state/task-x1.teardown-processes" ;;
      tasktmp)
        root="$case_dir/tasktmp"
        mkdir -p "$root/dist"
        mkdir -p "$case_dir/pool/1"
        git -C "$case_dir/project" worktree move "$case_dir/wt" "$case_dir/pool/1/project"
        ln -s "pool/1/project" "$case_dir/wt"
        printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
          "$case_dir/pool/1/project" > "$case_dir/pool/treehouse-state.json"
        printf 'task=other-task\nhome=%s\n' "$case_dir/other-home" > "$case_dir/pool/1/.fm-slot-owner"
        cp "$case_dir/pool/1/.fm-slot-owner" "$case_dir/slot-owner.before"
        fm_write_meta "$case_dir/state/task-x1.meta" \
          "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
          "worktree=$case_dir/wt" "project=$case_dir/project" "tasktmp=$root" \
          "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1"
        root="$root/dist"
        ;;
    esac
    mkdir "$case_dir/unrelated"
    fm_write_meta "$case_dir/state/unrelated.meta" "worktree=$case_dir/unrelated" "kind=ship"
    cp "$case_dir/state/task-x1.meta" "$case_dir/task-x1.meta.before"
    cp "$case_dir/state/unrelated.meta" "$case_dir/unrelated.meta.before"
    cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = list-windows ]; then
  echo "can't find session: firstmate" >&2
  exit 1
fi
if [ "\${1:-}" = kill-window ]; then
  printf '%s\n' "\$*" >> "$case_dir/endpoint-close.log"
fi
exit 0
SH
    chmod +x "$case_dir/fakebin/tmux"
    teardown_fixture_start "$root" KILL sleep 300
    pid=$TEARDOWN_FIXTURE_PID
    birth=$(teardown_fixture_birth "$pid") || fail "refusal-replay-$scenario: missing process identity"
    teardown_fixture_start "$case_dir/unrelated" KILL sleep 300
    other_pid=$TEARDOWN_FIXTURE_PID
    other_birth=$(teardown_fixture_birth "$other_pid") || fail "refusal-replay-$scenario: missing unrelated identity"
    sleep 0.3
    if [ "$scenario" = existing-marker ]; then
      FM_STATE_OVERRIDE="$case_dir/state" bash -c '
        . "$1/bin/fm-tasks-axi-lib.sh"
        . "$1/bin/fm-backlog-transition-lib.sh"
        fm_backlog_close_marker_stage "$2/state/.prior-close" task-x1 "$2/data" \
          teardown-test-task-x1 "$2/state" 0 &&
        fm_backlog_atomic_transition publish "$2/state/.prior-close" \
          "$2/state/task-x1.backlog-close" "pending-close record" "$2/state"
      ' _ "$ROOT" "$case_dir" > "$case_dir/marker.stdout" 2> "$case_dir/marker.stderr" \
        || fail "refusal-replay-$scenario: cannot seed existing replay authority"
    fi
    rc=0
    if [ "$scenario" = missing-lsof ]; then
      FM_HOME="$case_dir/home" FM_TEARDOWN_TEST_PATH="$path_without_lsof" run_teardown "$case_dir" ${flags[@]+"${flags[@]}"} \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      FM_HOME="$case_dir/home" run_teardown "$case_dir" ${flags[@]+"${flags[@]}"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    expect_code 1 "$rc" "refusal-replay-$scenario: teardown must refuse"
    case "$scenario" in
      missing-lsof) assert_grep "lsof is unavailable" "$case_dir/stderr" "refusal-replay-$scenario: wrong gate" ;;
      audit) assert_grep "cannot durably record leaked process $pid identity" "$case_dir/stderr" "refusal-replay-$scenario: wrong gate" ;;
      *) assert_grep "REFUSED: process $pid" "$case_dir/stderr" "refusal-replay-$scenario: wrong gate" ;;
    esac
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "refusal-replay-$scenario: refusal changed task metadata"
    assert_absent "$case_dir/state/task-x1.backlog-close" "refusal-replay-$scenario: refusal left replay authority"
    FM_STATE_OVERRIDE="$case_dir/state" bash -c '
      . "$1/bin/fm-tasks-axi-lib.sh"
      . "$1/bin/fm-backlog-transition-lib.sh"
      fm_backlog_close_marker_replay "$2/state" "$2/state/task-x1.backlog-close" "$2/data"
    ' _ "$ROOT" "$case_dir" > "$case_dir/replay.stdout" 2> "$case_dir/replay.stderr" \
      || fail "refusal-replay-$scenario: supported close replay failed"
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "refusal-replay-$scenario: replay changed task metadata"
    cmp "$case_dir/unrelated.meta.before" "$case_dir/state/unrelated.meta" \
      || fail "refusal-replay-$scenario: unrelated metadata changed"
    [ "$(backlog_row_state "$case_dir")" = in_flight ] \
      || fail "refusal-replay-$scenario: replay closed refused task"
    if [ "$scenario" = tasktmp ]; then
      assert_grep "reassigned" "$case_dir/stderr" "refusal-replay-$scenario: slot ownership gate not reached"
      cmp "$case_dir/slot-owner.before" "$case_dir/pool/1/.fm-slot-owner" \
        || fail "refusal-replay-$scenario: reassigned slot claim changed"
    fi
    assert_present "$case_dir/wt" "refusal-replay-$scenario: worktree removed"
    assert_present "$root" "refusal-replay-$scenario: process root removed"
    assert_absent "$case_dir/endpoint-close.log" "refusal-replay-$scenario: endpoint closed"
    teardown_fixture_live "$pid" "$birth" || fail "refusal-replay-$scenario: refused process identity changed"
    teardown_fixture_live "$other_pid" "$other_birth" || fail "refusal-replay-$scenario: unrelated process identity changed"
    teardown_fixture_stop "$pid"
    teardown_fixture_stop "$other_pid"
  done
  pass "process-gate refusals preserve task metadata, backlog, endpoint and process identities across close replay"
}

test_exempt_retry_clears_prior_close_replay_authority() {
  local scenario case_dir pid birth other_pid other_birth rc real_rm target_alive other_alive
  real_rm=$(command -v rm)
  for scenario in manual missing-backlog; do
    case_dir=$(make_case "exempt-retry-$scenario")
    mkdir -p "$case_dir/home/state" "$case_dir/unrelated"
    write_meta "$case_dir" no-mistakes ship
    land_shippable_commit "$case_dir"
    seed_backlog_in_flight "$case_dir"
    fm_write_meta "$case_dir/state/unrelated.meta" "worktree=$case_dir/unrelated" "kind=ship"
    cp "$case_dir/state/task-x1.meta" "$case_dir/task-x1.meta.before"
    cp "$case_dir/state/unrelated.meta" "$case_dir/unrelated.meta.before"
    cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ -f "$case_dir/state/task-x1.backlog-close" ] || exit 79
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 1
SH
    cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = kill-window ]; then
  printf '%s\n' "\$*" >> "$case_dir/endpoint-close.log"
fi
exit 0
SH
    chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/tmux"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/initial.stdout" 2> "$case_dir/initial.stderr" || rc=$?
    printf 'initial_rc=%s\n' "$rc" > "$case_dir/initial.observations"
    expect_code 1 "$rc" "exempt-retry-$scenario: initial return must fail"
    assert_present "$case_dir/treehouse.log" "exempt-retry-$scenario: initial teardown did not publish before return"
    assert_present "$case_dir/state/task-x1.backlog-close" "exempt-retry-$scenario: initial failure did not retain close authority"
    cp "$case_dir/state/task-x1.backlog-close" "$case_dir/close.before"
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "exempt-retry-$scenario: initial failure changed incarnation metadata"
    [ "$(backlog_row_state "$case_dir")" = in_flight ] \
      || fail "exempt-retry-$scenario: initial failure closed backlog"
    rm -f "$case_dir/treehouse.log" "$case_dir/endpoint-close.log"
    case "$scenario" in
      manual) printf '%s\n' manual > "$case_dir/config/backlog-backend" ;;
      missing-backlog) mv "$case_dir/data/backlog.md" "$case_dir/backlog.before" ;;
    esac
    mkdir "$case_dir/wt/dist"
    teardown_fixture_start "$case_dir/wt/dist" KILL sleep 300
    pid=$TEARDOWN_FIXTURE_PID
    birth=$(teardown_fixture_birth "$pid") || fail "exempt-retry-$scenario: missing target birth"
    teardown_fixture_start "$case_dir/unrelated" KILL sleep 300
    other_pid=$TEARDOWN_FIXTURE_PID
    other_birth=$(teardown_fixture_birth "$other_pid") || fail "exempt-retry-$scenario: missing unrelated birth"
    cat > "$case_dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != "$case_dir/state/task-x1.backlog-close" ] || exit 1
done
exec "$real_rm" "\$@"
SH
    chmod +x "$case_dir/fakebin/rm"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/clear.stdout" 2> "$case_dir/clear.stderr" || rc=$?
    printf 'clear_rc=%s target_pid=%s target_birth=%s unrelated_pid=%s unrelated_birth=%s\n' \
      "$rc" "$pid" "$birth" "$other_pid" "$other_birth" > "$case_dir/clear.observations"
    expect_code 1 "$rc" "exempt-retry-$scenario: failed invalidation must refuse"
    assert_grep "pending-close record could not be removed" "$case_dir/clear.stderr" \
      "exempt-retry-$scenario: failed invalidation did not reach shared boundary"
    cmp "$case_dir/close.before" "$case_dir/state/task-x1.backlog-close" \
      || fail "exempt-retry-$scenario: failed invalidation changed old marker"
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "exempt-retry-$scenario: failed invalidation changed metadata"
    assert_absent "$case_dir/treehouse.log" "exempt-retry-$scenario: failed invalidation returned worktree"
    assert_absent "$case_dir/endpoint-close.log" "exempt-retry-$scenario: failed invalidation closed endpoint"
    assert_absent "$case_dir/state/task-x1.teardown-processes" "exempt-retry-$scenario: failed invalidation audited signal"
    teardown_fixture_live "$pid" "$birth" || fail "exempt-retry-$scenario: failed invalidation changed target"
    teardown_fixture_live "$other_pid" "$other_birth" || fail "exempt-retry-$scenario: failed invalidation changed unrelated process"
    rm -f "$case_dir/fakebin/rm"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "exempt-retry-$scenario: descendant process must refuse"
    assert_grep "REFUSED: process $pid" "$case_dir/stderr" "exempt-retry-$scenario: process gate not reached"
    assert_absent "$case_dir/state/task-x1.backlog-close" "exempt-retry-$scenario: exempt retry retained old authority"
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "exempt-retry-$scenario: process refusal changed same-incarnation metadata"
    teardown_fixture_live "$pid" "$birth" || fail "exempt-retry-$scenario: refusal changed target"
    teardown_fixture_live "$other_pid" "$other_birth" || fail "exempt-retry-$scenario: refusal changed unrelated process"
    case "$scenario" in
      manual) rm -f "$case_dir/config/backlog-backend" ;;
      missing-backlog) mv "$case_dir/backlog.before" "$case_dir/data/backlog.md" ;;
    esac
    [ "$(backlog_row_state "$case_dir")" = in_flight ] \
      || fail "exempt-retry-$scenario: refused backlog changed before replay"
    FM_STATE_OVERRIDE="$case_dir/state" bash -c '
      . "$1/bin/fm-tasks-axi-lib.sh"
      . "$1/bin/fm-backlog-transition-lib.sh"
      fm_backlog_close_marker_replay "$2/state" "$2/state/task-x1.backlog-close" "$2/data"
    ' _ "$ROOT" "$case_dir" > "$case_dir/replay.stdout" 2> "$case_dir/replay.stderr" \
      || fail "exempt-retry-$scenario: supported replay failed after restoration"
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "exempt-retry-$scenario: retry or replay changed same-incarnation metadata"
    cmp "$case_dir/unrelated.meta.before" "$case_dir/state/unrelated.meta" \
      || fail "exempt-retry-$scenario: unrelated metadata changed"
    [ "$(backlog_row_state "$case_dir")" = in_flight ] \
      || fail "exempt-retry-$scenario: replay closed refused task"
    assert_present "$case_dir/wt" "exempt-retry-$scenario: worktree removed"
    assert_present "$case_dir/wt/dist" "exempt-retry-$scenario: descendant root removed"
    assert_absent "$case_dir/treehouse.log" "exempt-retry-$scenario: refusal returned worktree"
    assert_absent "$case_dir/endpoint-close.log" "exempt-retry-$scenario: refusal closed endpoint"
    assert_absent "$case_dir/state/task-x1.teardown-processes" "exempt-retry-$scenario: refusal audited signal"
    teardown_fixture_live "$pid" "$birth" || fail "exempt-retry-$scenario: target PID/birth changed"
    teardown_fixture_live "$other_pid" "$other_birth" || fail "exempt-retry-$scenario: unrelated PID/birth changed"
    target_alive=0
    other_alive=0
    teardown_fixture_live "$pid" "$birth" && target_alive=1
    teardown_fixture_live "$other_pid" "$other_birth" && other_alive=1
    printf 'mode=%s rc=%s target_pid=%s target_birth=%s target_alive=%s unrelated_pid=%s unrelated_birth=%s unrelated_alive=%s term_audit=0 kill_audit=0\n' \
      "$scenario" "$rc" "$pid" "$birth" "$target_alive" "$other_pid" "$other_birth" "$other_alive" \
      > "$case_dir/observations"
    teardown_fixture_stop "$pid"
    teardown_fixture_stop "$other_pid"
  done
  pass "manual and missing-backlog retries revoke old close authority before process refusal and restored replay"
}

test_process_audit_collection_exit_races() {
  local signal field outcome case_dir pid birth other_pid other_birth journal rc i term_audit kill_audit target_alive other_alive
  for signal in TERM KILL; do
    for field in command lstart; do
      for outcome in exit live-failure uncertain-live-failure control; do
        [ "$outcome" != uncertain-live-failure ] || [ "$field" = lstart ] || continue
        [ "$outcome" != control ] || { [ "$signal" = TERM ] && [ "$field" = command ]; } || continue
        case_dir=$(make_case "audit-collection-$signal-$field-$outcome")
        mkdir -p "$case_dir/home/state" "$case_dir/unrelated"
        write_meta "$case_dir" no-mistakes ship
        land_shippable_commit "$case_dir"
        journal="$case_dir/state/task-x1.teardown-processes"
        cp "$case_dir/state/task-x1.meta" "$case_dir/task-x1.meta.before"
        teardown_fixture_start "$case_dir/wt" KILL perl -e "$(cat <<'PERL'
          my ($ready, $exit, $journal, $seen) = @ARGV;
          $SIG{TERM} = sub {
            open my $in, "<", $journal or die "TERM without durable audit";
            local $/; my $audit = <$in>; close $in;
            open my $out, ">", $seen or die "signal observation";
            print {$out} $audit; close $out;
          };
          open my $f, ">", $ready or die "ready"; close $f;
          until (-e $exit) { select undef, undef, undef, 0.01; }
PERL
        )" "$case_dir/ready" "$case_dir/finite-exit" "$journal" "$case_dir/term-observed"
        pid=$TEARDOWN_FIXTURE_PID
        birth=$(teardown_fixture_birth "$pid") || fail "audit-collection: missing target birth"
        i=0
        while [ ! -f "$case_dir/ready" ] && [ "$i" -lt 1000 ]; do sleep 0.01; i=$((i + 1)); done
        [ -f "$case_dir/ready" ] || fail "audit-collection: finite process not ready"
        teardown_fixture_start "$case_dir/unrelated" KILL sleep 300
        other_pid=$TEARDOWN_FIXTURE_PID
        other_birth=$(teardown_fixture_birth "$other_pid") || fail "audit-collection: missing unrelated birth"
        fm_write_meta "$case_dir/state/unrelated.meta" "worktree=$case_dir/unrelated" "kind=ship"
        cp "$case_dir/state/unrelated.meta" "$case_dir/unrelated.meta.before"
        cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
args=" $* "
boundary=0
if [[ "$args" == *" -p $FM_AUDIT_TARGET "* ]]; then
  if [[ "$args" == *" -o lstart= "* ]] && [ -f "$FM_AUDIT_CASE/lstart-failed" ]; then
    exit 1
  fi
  if [[ "$args" == *" -o command= "* ]]; then
    n=0
    [ ! -f "$FM_AUDIT_CASE/command-count" ] || read -r n < "$FM_AUDIT_CASE/command-count"
    n=$((n + 1))
    printf '%s\n' "$n" > "$FM_AUDIT_CASE/command-count"
    round=1
    [ "$FM_AUDIT_SIGNAL" != KILL ] || round=2
    if [ "$n" -eq "$round" ]; then
      if [ "$FM_AUDIT_FIELD" = command ]; then
        boundary=1
      else
        command_output=$(LC_ALL=C "$REAL_PS_FOR_TEST" "$@") || exit 76
        [ -n "$command_output" ] || exit 77
        : > "$FM_AUDIT_CASE/lstart-armed"
        printf '%s\n' "$command_output"
        exit 0
      fi
    fi
  elif [[ "$args" == *" -o lstart= "* ]] && [ -f "$FM_AUDIT_CASE/lstart-armed" ]; then
    rm -f "$FM_AUDIT_CASE/lstart-armed"
    boundary=1
  fi
fi
if [ "$boundary" -eq 1 ]; then
  teardown_fixture_live "$FM_AUDIT_TARGET" "$FM_AUDIT_BIRTH" || exit 78
  printf '%s\t%s\t%s\n' "$FM_AUDIT_SIGNAL" "$FM_AUDIT_FIELD" "$FM_AUDIT_BIRTH" \
    >> "$FM_AUDIT_CASE/boundary.log"
  case "$FM_AUDIT_OUTCOME" in
    live-failure) exit 1 ;;
    uncertain-live-failure) : > "$FM_AUDIT_CASE/lstart-failed"; exit 1 ;;
    exit)
      : > "$FM_AUDIT_CASE/finite-exit"
      for ((i=0; i<1000; i++)); do
        state=$("$REAL_PS_FOR_TEST" -p "$FM_AUDIT_TARGET" -o stat= 2>/dev/null) || break
        [ -n "$state" ] || break
        sleep 0.01
      done
      [ "$i" -lt 1000 ] || exit 79
      printf 'exited\n' >> "$FM_AUDIT_CASE/exit-confirmed"
      ;;
  esac
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
        cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf 'returned\n' >> "$case_dir/treehouse.log"
exit 0
SH
        chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"
        rc=0
        FM_HOME="$case_dir/home" FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
        FM_AUDIT_CASE="$case_dir" FM_AUDIT_TARGET="$pid" FM_AUDIT_BIRTH="$birth" \
        FM_AUDIT_SIGNAL="$signal" FM_AUDIT_FIELD="$field" FM_AUDIT_OUTCOME="$outcome" \
          run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        term_audit=0
        kill_audit=0
        if [ -f "$journal" ]; then
          grep -q $'\tTERM\t'"$pid"$'\t' "$journal" && term_audit=1
          grep -q $'\tKILL\t'"$pid"$'\t' "$journal" && kill_audit=1
        fi
        target_alive=0
        other_alive=0
        teardown_fixture_live "$pid" "$birth" && target_alive=1
        teardown_fixture_live "$other_pid" "$other_birth" && other_alive=1
        printf 'signal=%s field=%s outcome=%s rc=%s target_pid=%s target_birth=%s target_alive=%s unrelated_pid=%s unrelated_birth=%s unrelated_alive=%s term_audit=%s kill_audit=%s\n' \
          "$signal" "$field" "$outcome" "$rc" "$pid" "$birth" "$target_alive" \
          "$other_pid" "$other_birth" "$other_alive" "$term_audit" "$kill_audit" \
          > "$case_dir/observations"
        assert_grep "$signal"$'\t'"$field"$'\t'"$birth" "$case_dir/boundary.log" \
          "audit-collection-$signal-$field-$outcome: collection boundary not reached with original birth"
        case "$outcome" in
          live-failure|uncertain-live-failure)
            expect_code 1 "$rc" "audit-collection-$signal-$field: live collection failure must refuse"
            teardown_fixture_live "$pid" "$birth" || fail "audit-collection-$signal-$field: live failure signalled target"
            cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
              || fail "audit-collection-$signal-$field: live failure changed task metadata"
            assert_present "$case_dir/wt" "audit-collection-$signal-$field: live failure removed worktree"
            assert_absent "$case_dir/treehouse.log" "audit-collection-$signal-$field: live failure returned worktree"
            assert_grep "cannot durably record leaked process $pid identity" "$case_dir/stderr" \
              "audit-collection-$signal-$field: live failure did not name audit refusal"
            ;;
          exit|control)
            expect_code 0 "$rc" "audit-collection-$signal-$field-$outcome: cleanup should complete"
            if teardown_fixture_live "$pid" "$birth"; then
              fail "audit-collection-$signal-$field-$outcome: target survived"
            fi
            assert_absent "$case_dir/state/task-x1.meta" "audit-collection-$signal-$field-$outcome: task metadata retained"
            assert_present "$case_dir/treehouse.log" "audit-collection-$signal-$field-$outcome: worktree return not reached"
            [ "$outcome" != exit ] || assert_present "$case_dir/exit-confirmed" \
              "audit-collection-$signal-$field: wrapper did not synchronize natural exit"
            ;;
        esac
        if [ "$outcome" = control ]; then
          [ "$term_audit" -eq 1 ] && [ "$kill_audit" -eq 1 ] \
            || fail "audit-collection-$signal-$field: control lacks durable TERM/KILL"
        else
          [ "$kill_audit" -eq 0 ] || fail "audit-collection-$signal-$field-$outcome: failed collection audited KILL"
          if [ "$signal" = TERM ]; then
            [ "$term_audit" -eq 0 ] || fail "audit-collection-$signal-$field-$outcome: failed collection audited TERM"
            assert_absent "$case_dir/term-observed" "audit-collection-$signal-$field-$outcome: TERM reached target"
          else
            [ "$term_audit" -eq 1 ] || fail "audit-collection-KILL-$field-$outcome: prior TERM was not audited"
          fi
        fi
        if [ "$term_audit" -eq 1 ]; then
          assert_grep $'\tTERM\t'"$pid"$'\t' "$case_dir/term-observed" \
            "audit-collection-$signal-$field-$outcome: TERM preceded durable audit"
        fi
        teardown_fixture_live "$other_pid" "$other_birth" \
          || fail "audit-collection-$signal-$field-$outcome: unrelated PID/birth changed"
        cmp "$case_dir/unrelated.meta.before" "$case_dir/state/unrelated.meta" \
          || fail "audit-collection-$signal-$field-$outcome: unrelated metadata changed"
        teardown_fixture_stop "$pid"
        teardown_fixture_stop "$other_pid"
      done
    done
  done
  pass "TERM and KILL audit collection tolerates synchronized real exits, refuses live failures, and preserves unrelated identities"
}

test_process_audit_failure_refuses_before_signal() {
  local case_dir rc pid survived=0
  case_dir=$(make_case process-audit-failure)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  mkdir "$case_dir/state/task-x1.teardown-processes"
  teardown_fixture_start "$case_dir/wt" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill -0 "$pid" 2>/dev/null && survived=1
  teardown_fixture_stop "$pid"
  expect_code 1 "$rc" "process-audit-failure: teardown must refuse"
  [ "$survived" -eq 1 ] || fail "process-audit-failure: signal sent without durable audit"
  assert_present "$case_dir/state/task-x1.meta" "process-audit-failure: task record removed"
  assert_grep "cannot durably record leaked process $pid identity" "$case_dir/stderr" \
    "process-audit-failure: missing refusal reason"
  pass "an unwritable process audit refuses before signalling a real leaked process"
}


teardown_test_cases=(
test_fixture_cleanup_leaves_no_home_summary_refresh_worker
test_process_refusal_has_no_close_replay_authority
test_exempt_retry_clears_prior_close_replay_authority
test_local_only_force_overrides_unpushed
test_secondmate_pr_registration_publishes_ready_line
test_secondmate_home_teardown_delivers_final_line_or_refuses
test_secondmate_home_teardown_unknown_acceptance_is_a_retry
test_secondmate_home_teardown_shows_report_diagnostics
test_teardown_missing_busy_sidecar_completes
test_herdr_teardown_clears_escalation_marker
test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes
test_herdr_flat_teardown_refuses_records_on_unparseable_presence
test_herdr_flat_teardown_preflight_refuses_before_changes
test_herdr_teardown_presentation_lock_namespace_is_per_account
test_forced_secondmate_herdr_child_preflight_refuses_before_changes
test_forced_secondmate_teardown_holds_descendant_lifecycle_locks
test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed
test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup
test_teardown_retires_task_watcher_markers_and_orphan_journal
test_teardown_retains_journal_bound_to_another_pane
test_teardown_retires_v1_journal_when_projected_workspace_gone
test_teardown_retains_v1_journal_when_projected_workspace_present
test_teardown_retains_v1_journal_when_workspace_query_ambiguous
test_teardown_records_the_task_pipeline_spend
test_teardown_skips_pipeline_spend_when_disabled
test_teardown_records_unavailable_spend_for_a_gone_worktree
test_parked_own_run_is_aborted_before_teardown
test_parked_own_run_concludes_on_passed_with_override_after_abort
test_parked_own_run_concludes_on_passed_with_skips_after_abort
test_parked_run_advanced_past_unfetched_head_is_still_aborted
test_parked_run_with_mismatched_ledger_head_is_never_aborted
test_parked_run_with_malformed_ledger_row_is_never_aborted
test_parked_run_with_impossible_ledger_date_is_never_aborted
test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback
test_parked_run_advanced_head_locally_fetched_is_still_aborted
test_parked_advanced_run_without_anchor_is_never_aborted
test_parked_advanced_run_ancestor_anchor_is_never_aborted
test_parked_terminal_unfetched_row_is_never_aborted
test_parked_run_terminal_newest_row_at_own_head_is_never_aborted
test_parked_run_behind_diverged_newer_row_is_never_aborted
test_parked_advanced_run_ambiguous_rows_are_never_aborted
test_ledger_proven_continuation_never_aborts_active_run
test_parked_own_run_refuses_when_abort_is_unconfirmed
test_silent_daemon_leaves_the_parked_run_unknown
test_slow_working_daemon_still_finds_the_parked_run
test_silent_confirmation_after_abort_is_unknown
test_forced_teardown_goes_on_past_a_silent_daemon
test_forced_teardown_goes_on_past_a_silent_confirmation
test_mismatched_run_after_abort_refuses_unconfirmed
test_empty_status_after_abort_refuses_unconfirmed
test_not_found_status_after_abort_confirms_completion
test_another_branchs_parked_run_is_never_touched
test_own_autonomous_run_is_left_alone
test_leaked_worktree_process_is_reaped
test_process_identity_is_recorded_before_term_and_kill
test_process_audit_collection_exit_races
test_nested_registered_worktree_process_is_not_reaped
test_sibling_clone_nested_lane_process_is_not_reaped
test_registered_lane_missing_git_process_is_not_reaped
test_deleted_registered_lane_process_is_not_reaped
test_sibling_clone_missing_git_lane_process_is_not_reaped
test_sibling_clone_deleted_lane_process_is_not_reaped
test_own_deleted_cwd_process_is_not_reaped
test_ordinary_descendant_process_is_not_reaped
test_process_audit_failure_refuses_before_signal
)

# Restore errexit before the first case of this slice to match the original combined run.
errexit_restored=false
fm_test_before_case() {
  if [ "$errexit_restored" = false ] && [ "$1" = test_local_only_force_overrides_unpushed ]; then
    set -e
    errexit_restored=true
  fi
}
fm_test_run_cases "${teardown_test_cases[@]}" -- "$@"
