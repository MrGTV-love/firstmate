#!/usr/bin/env bash
# Post-close cleanup for bin/fm-teardown.sh: leaked processes and the bounded
# reap, foreign and held copies with their closeout driver, private no-mistakes
# launch agents, Docker stacks and their retained records, Herdr projection
# journals, and secondmate delivery and retirement.
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
case "\$*" in *'#{pane_pid}'*) if [ -f "$case_dir/pane-rows" ]; then cat "$case_dir/pane-rows"; elif [ -f "$case_dir/pane-pid" ]; then printf 'fm-task-x1\t%%1\t%s\n' "\$(cat "$case_dir/pane-pid")"; fi ;; esac
case "\${1:-}" in list-windows) if [ -f "$case_dir/pane-rows" ]; then cut -f1 "$case_dir/pane-rows" | sort -u; elif [ -f "$case_dir/pane-pid" ]; then echo fm-task-x1; fi ;; esac
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
  # worktree and started under the task's pane (the case's default pane shell
  # is this runner, its parent). One reparented to init proves nothing and is
  # refused instead (test_teardown_refuses_an_orphan_it_cannot_prove).
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

# Every ownership fixture process carries this argument; it stands for a
# credential on a command line and must never reach teardown's output or audit.
OWN_CANARY="fm-secret-canary-$$-ownership"
export OWN_CANARY

# Fix 2 ownership fixtures. A fake pane is the process the case's tmux stub
# reports as the task pane's shell; its own cwd is the case directory, never a
# scan root. ownership_pane <case-dir> [<leak-cwd> [ignore-term]] starts it,
# points the case's pane-pid file at it and sets OWN_PANE_PID; with a leak cwd
# it also starts a child of the pane there (ignoring TERM when asked) and sets
# OWN_LEAK_PID.
ownership_pane() {
  local case_dir=$1 leak_cwd=${2:-} ignore=${3:-} i
  rm -f "$case_dir/leak.pid"
  # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
  teardown_fixture_start "$case_dir" KILL perl -e '
    my ($cwd, $out, $ignore) = @ARGV;
    $SIG{CHLD} = "IGNORE";
    if ($cwd ne "") {
      my $child = fork();
      die "fork" unless defined $child;
      if (!$child) { $SIG{TERM} = "IGNORE" if $ignore; chdir $cwd or die "chdir"; exec "perl", "-e", "sleep 300", "--", $ENV{OWN_CANARY}; }
      open my $fh, ">", "$out.tmp" or die "open"; print {$fh} $child; close $fh; rename "$out.tmp", $out or die "rename";
    }
    sleep 300 while 1;' "$leak_cwd" "$case_dir/leak.pid" "$ignore"
  OWN_PANE_PID=$TEARDOWN_FIXTURE_PID
  printf '%s\n' "$OWN_PANE_PID" > "$case_dir/pane-pid"
  OWN_LEAK_PID=
  [ -n "$leak_cwd" ] || return 0
  for i in $(seq 100); do [ -s "$case_dir/leak.pid" ] && break; sleep 0.05; done
  OWN_LEAK_PID=$(cat "$case_dir/leak.pid" 2>/dev/null) || fail "ownership fixture: the pane's leak did not start"
  teardown_fixture_track "$OWN_LEAK_PID" KILL
  for i in $(seq 100); do
    [ "$(cd "$leak_cwd" && pwd -P)" = "$("$REAL_LSOF_FOR_TEST" -a -d cwd -p "$OWN_LEAK_PID" -Fn 2>/dev/null | sed -n 's/^n//p')" ] && return 0
    sleep 0.05
  done
  fail "ownership fixture: the pane's leak never entered $leak_cwd"
}

# ownership_detached <cwd> [setsid]: a double-forked process whose cwd is <cwd>,
# reparented to init and so descended from no pane; with setsid it also leaves
# its session, as a daemon such as the shared no-mistakes daemon does when it
# auto-starts inside a task copy. Sets OWN_DETACHED_PID.
ownership_detached() {
  local cwd=$1 setsid=${2:-} out i
  out=$(mktemp "$TMP_ROOT/detached.XXXXXX")
  rm -f "$out"
  # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
  perl -MPOSIX -e '
    my ($cwd, $out, $setsid) = @ARGV;
    my $first = fork(); die "fork" unless defined $first;
    if ($first) { waitpid($first, 0); exit 0; }
    POSIX::setsid() if $setsid;
    my $second = fork(); die "fork" unless defined $second;
    POSIX::_exit(0) if $second;
    chdir $cwd or die "chdir";
    open STDIN, "<", "/dev/null"; open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
    open my $fh, ">", "$out.tmp" or die "open"; print {$fh} $$; close $fh; rename "$out.tmp", $out or die "rename";
    exec "perl", "-e", "sleep 300", "--", $ENV{OWN_CANARY};' "$cwd" "$out" "$setsid"
  for i in $(seq 100); do [ -s "$out" ] && break; sleep 0.05; done
  OWN_DETACHED_PID=$(cat "$out" 2>/dev/null) || fail "ownership fixture: the detached process did not start"
  teardown_fixture_track "$OWN_DETACHED_PID" KILL
  for i in $(seq 100); do
    [ "$(cd "$cwd" && pwd -P)" = "$("$REAL_LSOF_FOR_TEST" -a -d cwd -p "$OWN_DETACHED_PID" -Fn 2>/dev/null | sed -n 's/^n//p')" ] && break
    sleep 0.05
  done
}

# Succeeds when <pid> descends from <ancestor> by its live parent chain.
ownership_descends_from() {  # <pid> <ancestor>
  local p=$1 n=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 64 ]; do
    [ "$p" != "$2" ] || return 0
    p=$("$REAL_PS_FOR_TEST" -o ppid= -p "$p" 2>/dev/null | tr -d '[:space:]')
    n=$((n + 1))
  done
  return 1
}

ownership_alive() {  # <pid>
  local signal birth
  IFS=$'\t' read -r signal birth < "$TEARDOWN_FIXTURE_PROCESSES/$1" || return 1
  teardown_fixture_live "$1" "$birth"
}

ownership_wait_dead() {  # <pid>
  local i
  for i in $(seq 50); do ownership_alive "$1" || return 0; sleep 0.1; done
  return 1
}

ownership_assert_unsignalled() {  # <case-dir> <pid> <label>
  [ ! -f "$1/state/task-x1.teardown-processes" ] \
    || assert_no_grep $'\t'"$2"$'\t' "$1/state/task-x1.teardown-processes" "$3: teardown audited a signal for process $2"
}

# ownership_fault_bin <case-dir>: the case runs a copy of bin/ in which the
# ownership proof is replaced by the old cwd-only verdict (every process at a
# root is the task's). Only the case's own copy changes; the shipped bin/ is
# untouched. Sets OWN_FAULT_TEARDOWN.
ownership_fault_bin() {
  local case_dir=$1
  rm "$case_dir/code-root/bin"
  cp -R "$ROOT/bin" "$case_dir/code-root/bin"
  python3 -I - "$case_dir/code-root/bin/fm-teardown.sh" <<'PY' || fail "ownership fault: the proof could not be replaced in the case's copy"
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
head = "task_pid_proved_own() {  # <pid> <identity>\n"
assert text.count(head) == 1
fault = head + "  TASK_OWNED+=(\"$1\"$'\\t'\"$2\"$'\\t'0); return 0  # injected fault: the old cwd-only verdict\n"
path.write_text(text.replace(head, fault))
PY
  OWN_FAULT_TEARDOWN=$case_dir/code-root/bin/fm-teardown.sh
}

# Case 1 of the ownership plan (the 2026-11-26 incident's shape): a detached,
# session-leading process at the copy root that descends from no task process
# survives teardown, and the copy and the task stay.
test_teardown_spares_a_detached_daemon_at_the_copy_root() {
  local case_dir rc pid
  case_dir=$(make_case ownership-detached-daemon)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  ownership_pane "$case_dir"
  ownership_detached "$case_dir/wt" setsid
  pid=$OWN_DETACHED_PID
  ownership_alive "$pid" || fail "detached-daemon: setup daemon did not start"
  if ownership_descends_from "$pid" "$OWN_PANE_PID" || ownership_descends_from "$pid" "$$"; then
    fail "detached-daemon: setup daemon descends from the pane or the runner (ppid $("$REAL_PS_FOR_TEST" -o ppid= -p "$pid"))"
  fi
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  ownership_alive "$pid" || fail "detached-daemon: teardown killed a process it could not prove was the task's"
  expect_code 1 "$rc" "detached-daemon: teardown must refuse while an unproven process holds the copy root"
  assert_present "$case_dir/wt" "detached-daemon: teardown removed the copy"
  assert_present "$case_dir/state/task-x1.meta" "detached-daemon: teardown removed the task record"
  ownership_assert_unsignalled "$case_dir" "$pid" detached-daemon
  grep -Eq "REFUSED: process $pid .*nothing proves it belongs to task-x1" "$case_dir/stderr" \
    || fail "detached-daemon: the refusal did not name the process: $(tail -3 "$case_dir/stderr")"
  "$REAL_PS_FOR_TEST" -ww -o command= -p "$pid" | grep -F -- "$OWN_CANARY" >/dev/null \
    || fail "detached-daemon: the setup daemon does not carry the secret canary in its arguments"
  assert_no_grep "$OWN_CANARY" "$case_dir/stderr" "detached-daemon: the refusal printed the daemon's arguments"
  assert_no_grep "$OWN_CANARY" "$case_dir/stdout" "detached-daemon: teardown printed the daemon's arguments"
  teardown_fixture_stop "$pid"
  pass "a detached daemon at the copy root that descends from no task process survives teardown, which refuses and keeps the copy without printing its arguments"
}

# Case 2: a leaked child of the task's pane, with its cwd at the copy root, is
# still reaped, and the copy goes.
test_teardown_reaps_a_leaked_child_of_the_task_pane() {
  local case_dir rc pid cmdline digest
  case_dir=$(make_case ownership-pane-child)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  ownership_pane "$case_dir" "$case_dir/wt"
  pid=$OWN_LEAK_PID
  ownership_descends_from "$pid" "$OWN_PANE_PID" || fail "pane-child: setup leak is not the pane's child"
  cmdline=$("$REAL_PS_FOR_TEST" -ww -o command= -p "$pid") || fail "pane-child: the leak's command line cannot be read"
  case "$cmdline" in *"$OWN_CANARY"*) ;; *) fail "pane-child: the leak's command line lacks the canary: $cmdline" ;; esac
  digest=$(printf '%s' "$cmdline" | shasum -a 256 | awk '{print $1}')
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pane-child: teardown must succeed: $(cat "$case_dir/stderr")"
  ownership_wait_dead "$pid" || fail "pane-child: the task's leaked child survived teardown"
  assert_grep $'\tTERM\t'"$pid"$'\t' "$case_dir/state/task-x1.teardown-processes" \
    "pane-child: the leaked child's signal was not audited"
  assert_grep $'\tTERM\t'"$pid"$'\t' "$case_dir/state/task-x1.teardown-processes" \
    "pane-child: no TERM row for the leak"
  awk -F '\t' -v p="$pid" -v d="cmdline-sha256=$digest" '$2 == "TERM" && $3 == p && $5 == "perl" && $9 == d { found = 1 } END { exit !found }' \
    "$case_dir/state/task-x1.teardown-processes" \
    || fail "pane-child: the audit row does not hold executable perl and the SHA-256 of the leak's known command line ($digest): $(cat "$case_dir/state/task-x1.teardown-processes")"
  assert_no_grep "$OWN_CANARY" "$case_dir/state/task-x1.teardown-processes" \
    "pane-child: the audit recorded the leak's raw arguments"
  assert_no_grep "$OWN_CANARY" "$case_dir/stderr" "pane-child: teardown printed the leak's arguments"
  # The stub treehouse removes nothing; the real-binary suite observes the copy go.
  assert_absent "$case_dir/state/task-x1.meta" "pane-child: the task did not close"
  ownership_alive "$OWN_PANE_PID" || fail "pane-child: teardown signalled the pane shell, whose cwd is not a root"
  pass "a leaked child of the task's pane at the copy root is reaped and the task closes"
}

# Case 3 (fault control): with the old cwd-only verdict injected into the case's
# own copy of bin/, case 1's survival assertion fails for the expected reason -
# the detached daemon is audited and killed.
test_teardown_ownership_fault_control_kills_the_detached_daemon() {
  local case_dir rc pid
  case_dir=$(make_case ownership-fault-control)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  ownership_fault_bin "$case_dir"
  ownership_pane "$case_dir"
  ownership_detached "$case_dir/wt" setsid
  pid=$OWN_DETACHED_PID
  ownership_alive "$pid" || fail "fault-control: setup daemon did not start"
  rc=0
  TEARDOWN=$OWN_FAULT_TEARDOWN run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if ownership_alive "$pid"; then
    teardown_fixture_stop "$pid"
    fail "fault-control: the injected cwd-only verdict did not falsify case 1's survival assertion: $(tail -5 "$case_dir/stderr")"
  fi
  assert_grep $'\tTERM\t'"$pid"$'\t' "$case_dir/state/task-x1.teardown-processes" \
    "fault-control: the daemon died without the cwd-only reap's audited TERM"
  pass "the old cwd-only verdict, injected only into the case's copy, kills the detached daemon, so case 1 discriminates"
}

# A mixed copy refuses before any signal: neither the task's own leak nor the
# unproven daemon beside it is signalled.
test_teardown_mixed_copy_signals_nothing() {
  local case_dir rc leak daemon
  case_dir=$(make_case ownership-mixed)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  ownership_pane "$case_dir" "$case_dir/wt"
  leak=$OWN_LEAK_PID
  ownership_detached "$case_dir/wt" setsid
  daemon=$OWN_DETACHED_PID
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  ownership_alive "$daemon" || fail "mixed: the unproven daemon was killed"
  ownership_alive "$leak" || fail "mixed: the task's leak was signalled although teardown refused"
  expect_code 1 "$rc" "mixed: teardown must refuse"
  assert_present "$case_dir/wt" "mixed: the copy was removed"
  ownership_assert_unsignalled "$case_dir" "$daemon" mixed
  ownership_assert_unsignalled "$case_dir" "$leak" mixed
  teardown_fixture_stop "$daemon"
  teardown_fixture_stop "$leak"
  pass "a copy holding both the task's leak and an unproven daemon refuses before signalling either"
}

# The anchor's absent, forged and dead states prove nothing: a process at the
# root refuses unsignalled. A quiet copy needs no anchor and still closes.
test_teardown_without_a_provable_pane_refuses_a_root_process() {
  local case_dir rc pid state dead
  for state in absent forged dead; do
    case_dir=$(make_case "ownership-anchor-$state")
    write_meta "$case_dir" no-mistakes ship
    land_shippable_commit "$case_dir"
    case "$state" in
      absent) rm -f "$case_dir/pane-pid" ;;
      forged) printf '12x\n' > "$case_dir/pane-pid" ;;
      dead)
        sleep 300 &
        dead=$!
        kill "$dead"; wait "$dead" 2>/dev/null || true
        printf '%s\n' "$dead" > "$case_dir/pane-pid"
        ;;
    esac
    teardown_fixture_start "$case_dir/wt" KILL sleep 300
    pid=$TEARDOWN_FIXTURE_PID
    sleep 0.3
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    ownership_alive "$pid" || fail "anchor-$state: teardown killed a process with no provable pane"
    expect_code 1 "$rc" "anchor-$state: teardown must refuse"
    assert_present "$case_dir/wt" "anchor-$state: the copy was removed"
    ownership_assert_unsignalled "$case_dir" "$pid" "anchor-$state"
    # An absent pane proves nothing, so the process refuses; a forged or dead
    # pane shell is an unreadable endpoint, refused before any close.
    if [ "$state" = absent ]; then
      grep -Eq "REFUSED: process $pid .*no single live pane shell could be read" "$case_dir/stderr" \
        || fail "anchor-$state: the refusal did not say the pane could not be proved: $(tail -3 "$case_dir/stderr")"
    else
      grep -Eq "REFUSED: the endpoint firstmate:fm-task-x1 of task task-x1 cannot be closed safely: .*cannot be read" "$case_dir/stderr" \
        || fail "anchor-$state: the refusal did not say the endpoint cannot be read: $(tail -3 "$case_dir/stderr")"
    fi
    teardown_fixture_stop "$pid"
  done
  case_dir=$(make_case ownership-anchor-quiet)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  rm -f "$case_dir/pane-pid"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "anchor-quiet: a copy nobody holds must close without a pane: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "anchor-quiet: the quiet task did not close"
  pass "an absent, forged or dead pane proves nothing, so a root process refuses unsignalled, while a quiet copy still closes"
}

# A process proved through the pane keeps its proof after the reap ends the
# shell it descended from: a TERM-ignoring leak in a process group of its own,
# whose parent shell (also at the root) dies in the same pass, is still
# force-killed on its retained pid and birth identity alone.
test_teardown_proof_survives_the_parent_the_reap_ends() {
  local case_dir rc shell leak i
  case_dir=$(make_case ownership-parent-ended)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  # The pane's child shell sits at the root and starts a TERM-ignoring leak there.
  rm -f "$case_dir/leak.pid"
  # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
  teardown_fixture_start "$case_dir" KILL perl -e '
    my ($wt, $out) = @ARGV;
    $SIG{CHLD} = "IGNORE";
    my $shell = fork(); die "fork" unless defined $shell;
    if (!$shell) {
      chdir $wt or die "chdir";
      my $leak = fork(); die "fork" unless defined $leak;
      if (!$leak) { setpgrp(0, 0) or die "setpgrp"; $SIG{TERM} = "IGNORE"; exec "sleep", "300"; }
      open my $fh, ">", "$out.tmp" or die "open"; print {$fh} "$$ $leak\n"; close $fh; rename "$out.tmp", $out or die "rename";
      exec "sleep", "300";
    }
    sleep 300 while 1;' "$case_dir/wt" "$case_dir/leak.pid"
  OWN_PANE_PID=$TEARDOWN_FIXTURE_PID
  printf '%s\n' "$OWN_PANE_PID" > "$case_dir/pane-pid"
  for i in $(seq 100); do [ -s "$case_dir/leak.pid" ] && break; sleep 0.05; done
  read -r shell leak < "$case_dir/leak.pid" || fail "parent-ended: setup did not start"
  teardown_fixture_track "$shell" KILL
  teardown_fixture_track "$leak" KILL
  sleep 0.3
  # The leak leads its own process group, so only its retained pid and birth
  # identity, never a shared group, can keep its proof after its parent dies.
  [ "$("$REAL_PS_FOR_TEST" -o pgid= -p "$leak" | tr -d ' ')" = "$leak" ] \
    && [ "$("$REAL_PS_FOR_TEST" -o pgid= -p "$shell" | tr -d ' ')" != "$leak" ] \
    || fail "parent-ended: setup leak does not lead a process group of its own"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "parent-ended: teardown must succeed: $(cat "$case_dir/stderr")"
  ownership_wait_dead "$shell" || fail "parent-ended: the pane's child shell survived"
  ownership_wait_dead "$leak" || fail "parent-ended: the TERM-ignoring leak survived after its parent was ended"
  assert_grep $'\tKILL\t'"$leak"$'\t' "$case_dir/state/task-x1.teardown-processes" \
    "parent-ended: the leak was not force-killed under its kept proof"
  pass "a proved leak keeps its proof after the reap ends its parent shell, and is force-killed"
}

# The endpoint is classified before any close, whether or not any process holds a
# root: with two panes in the recorded window and nothing in the copy or an empty
# tasktmp, teardown refuses with no endpoint closed and both pane processes
# alive, on the owned-copy route and on the tasktmp-only route alike.
test_teardown_ambiguous_window_refuses_before_any_close() {
  local route case_dir rc first second root
  for route in owned tasktmp-only; do
    case_dir=$(make_case "ownership-ambiguous-$route")
    root="$case_dir/tasktmp"
    if [ "$route" = owned ]; then
      write_meta "$case_dir" no-mistakes ship
      land_shippable_commit "$case_dir"
      printf '%s\n' "tasktmp=$root" >> "$case_dir/state/task-x1.meta"
      mkdir -p "$root"
    else
      mkdir -p "$case_dir/home/state"
      write_meta "$case_dir" no-mistakes ship
      wt_commit_file "$case_dir" landed.txt "delivered work" "landed process fixture"
      git -C "$case_dir/wt" push -q origin HEAD:main
      git -C "$case_dir/project" fetch -q origin
      seed_backlog_in_flight "$case_dir"
      mkdir -p "$root" "$case_dir/pool/1"
      git -C "$case_dir/project" worktree move "$case_dir/wt" "$case_dir/pool/1/project"
      ln -s "pool/1/project" "$case_dir/wt"
      printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$case_dir/pool/1/project" > "$case_dir/pool/treehouse-state.json"
      printf 'task=other-task\nhome=%s\n' "$case_dir/other-home" > "$case_dir/pool/1/.fm-slot-owner"
      fm_write_meta "$case_dir/state/task-x1.meta" \
        "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
        "worktree=$case_dir/wt" "project=$case_dir/project" "tasktmp=$root" \
        "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1"
    fi
    ownership_pane "$case_dir"
    first=$OWN_PANE_PID
    ownership_pane "$case_dir"
    second=$OWN_PANE_PID
    printf 'fm-task-x1\t%%1\t%s\nfm-task-x1\t%%2\t%s\n' "$first" "$second" > "$case_dir/pane-rows"
    cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in *'#{pane_pid}'*) cat "$case_dir/pane-rows" ;; esac
case "\${1:-}" in list-windows) if [ -f "$case_dir/pane-rows" ]; then cut -f1 "$case_dir/pane-rows" | sort -u; elif [ -f "$case_dir/pane-pid" ]; then echo fm-task-x1; fi ;; esac
case "\${1:-}" in kill-*) printf '%s\n' "\$*" >> "$case_dir/endpoint-close.log" ;; esac
exit 0
SH
    chmod +x "$case_dir/fakebin/tmux"
    rc=0
    if [ "$route" = owned ]; then
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      FM_HOME="$case_dir/home" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    expect_code 1 "$rc" "ambiguous-$route: teardown must refuse: $(tail -3 "$case_dir/stderr")"
    assert_absent "$case_dir/endpoint-close.log" "ambiguous-$route: the endpoint was closed: $(cat "$case_dir/endpoint-close.log" 2>/dev/null)"
    ownership_alive "$first" || fail "ambiguous-$route: the first pane process was signalled"
    ownership_alive "$second" || fail "ambiguous-$route: the second pane process was signalled"
    assert_present "$case_dir/state/task-x1.meta" "ambiguous-$route: the task record was removed"
    [ ! -f "$case_dir/state/task-x1.teardown-processes" ] \
      || fail "ambiguous-$route: a signal was audited: $(cat "$case_dir/state/task-x1.teardown-processes")"
    grep -Eq "REFUSED: the endpoint firstmate:fm-task-x1 of task task-x1 cannot be closed safely: .*several panes" "$case_dir/stderr" \
      || fail "ambiguous-$route: the refusal did not name the ambiguous endpoint: $(tail -3 "$case_dir/stderr")"
  done
  pass "two panes in the recorded window refuse before any close, with nothing in the roots, on the owned and the tasktmp-only route"
}

# Absence is decided only by the tmux backend's own inventory: an answer that is
# not definitive, such as a socket the user cannot open, is an unreadable
# endpoint and refuses before any close, even with nothing in the roots.
test_teardown_unreadable_tmux_socket_refuses_before_any_close() {
  local case_dir rc
  case_dir=$(make_case ownership-tmux-unreadable)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in kill-*) printf '%s\n' "\$*" >> "$case_dir/endpoint-close.log"; exit 0 ;; esac
case "\${1:-}" in list-*) echo "error connecting to /private/tmp/tmux-501/default (Permission denied)" >&2; exit 1 ;; esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "tmux-unreadable: teardown must refuse: $(tail -3 "$case_dir/stderr")"
  assert_absent "$case_dir/endpoint-close.log" "tmux-unreadable: the endpoint was closed: $(cat "$case_dir/endpoint-close.log" 2>/dev/null)"
  assert_present "$case_dir/state/task-x1.meta" "tmux-unreadable: the task record was removed"
  grep -Eq "REFUSED: the endpoint firstmate:fm-task-x1 of task task-x1 cannot be closed safely: .*cannot be read" "$case_dir/stderr" \
    || fail "tmux-unreadable: the refusal did not name the unreadable endpoint: $(tail -3 "$case_dir/stderr")"
  pass "a tmux socket that cannot be opened is an unreadable endpoint and refuses with nothing closed"
}

# The process-group proof does not reach a process that leaves the group: a
# child a proved process forks during the grace period and that calls setsid
# before its parent exits (a daemon detaching) refuses unsignalled.
test_teardown_grace_child_that_leaves_the_group_is_refused() {
  local case_dir rc pid child i
  case_dir=$(make_case ownership-grace-setsid)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
  teardown_fixture_start "$case_dir/wt" KILL perl -MPOSIX -e '
    my ($out) = @ARGV;
    $SIG{TERM} = sub {
      my $child = fork(); die "fork" unless defined $child;
      if (!$child) {
        POSIX::setsid();
        open STDIN, "<", "/dev/null"; open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
        exec "sleep", "300";
      }
      open my $fh, ">", "$out.tmp" or die "open"; print {$fh} "$child\n"; close $fh; rename "$out.tmp", $out or die "rename";
      POSIX::_exit(0);
    };
    sleep 300 while 1;' "$case_dir/child.pid"
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  for i in $(seq 50); do [ -s "$case_dir/child.pid" ] && break; sleep 0.1; done
  child=$(cat "$case_dir/child.pid" 2>/dev/null) || fail "grace-setsid: the parent never forked its detaching child"
  teardown_fixture_track "$child" KILL
  ownership_alive "$child" || fail "grace-setsid: teardown killed a child that left the task's process group"
  expect_code 1 "$rc" "grace-setsid: teardown must refuse: $(tail -3 "$case_dir/stderr")"
  ownership_assert_unsignalled "$case_dir" "$child" grace-setsid
  grep -Eq "REFUSED: process $child .*nothing proves it belongs to task-x1" "$case_dir/stderr" \
    || fail "grace-setsid: the refusal did not name the detached child: $(tail -3 "$case_dir/stderr")"
  teardown_fixture_stop "$child"
  pass "a child forked during the grace period that leaves the task's process group refuses unsignalled"
}

# The legitimate counterpart of the refused grace child: a proved process that
# survives TERM and forks a child at the root meanwhile keeps that child its own
# descendant, so the later pass proves it by parent chain and reaps it.
test_process_spawned_during_grace_by_a_live_parent_is_reaped() {
  local case_dir rc pid child i
  case_dir=$(make_case grace-spawn-live-parent)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
  teardown_fixture_start "$case_dir/wt" KILL perl -e '
    my ($out) = @ARGV;
    $SIG{CHLD} = "IGNORE";
    $SIG{TERM} = sub {
      return if -e $out;
      my $child = fork(); die "fork" unless defined $child;
      if (!$child) { $SIG{TERM} = "DEFAULT"; exec "sleep", "300"; }
      open my $fh, ">", "$out.tmp" or die "open"; print {$fh} "$child\n"; close $fh; rename "$out.tmp", $out or die "rename";
    };
    sleep 300 while 1;' "$case_dir/child.pid"
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  for i in $(seq 50); do [ -s "$case_dir/child.pid" ] && break; sleep 0.1; done
  child=$(cat "$case_dir/child.pid" 2>/dev/null) || fail "grace-live-parent: the parent never forked"
  if kill -0 "$child" 2>/dev/null; then teardown_fixture_track "$child" KILL; fi
  expect_code 0 "$rc" "grace-live-parent: teardown must converge: $(tail -3 "$case_dir/stderr")"
  ownership_wait_dead "$pid" || fail "grace-live-parent: the proved parent survived"
  for i in $(seq 50); do kill -0 "$child" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$child" 2>/dev/null && fail "grace-live-parent: the live parent's child survived"
  assert_grep $'\tTERM\t'"$child"$'\t' "$case_dir/state/task-x1.teardown-processes" \
    "grace-live-parent: the child's signal was not audited"
  pass "a child forked during grace by a still-live proved parent is proved by parent chain and reaped"
}

# The tmux anchor is the only pane of the exact recorded window: an absent
# window (tmux would answer a selector from the active window) or a second
# pane in the recorded window proves nothing, so a leak under the pane
# refuses unsignalled.
test_teardown_tmux_anchor_needs_the_one_recorded_pane() {
  local shape case_dir rc pid
  for shape in absent second; do
    case_dir=$(make_case "ownership-tmux-$shape")
    write_meta "$case_dir" no-mistakes ship
    land_shippable_commit "$case_dir"
    ownership_pane "$case_dir" "$case_dir/wt"
    pid=$OWN_LEAK_PID
    case "$shape" in
      absent) printf 'fm-other-task\t%%7\t%s\n' "$OWN_PANE_PID" > "$case_dir/pane-rows" ;;
      second) printf 'fm-task-x1\t%%1\t%s\nfm-task-x1\t%%2\t%s\n' "$$" "$OWN_PANE_PID" > "$case_dir/pane-rows" ;;
    esac
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    ownership_alive "$pid" || fail "tmux-$shape: teardown signalled a leak under a pane it could not prove"
    expect_code 1 "$rc" "tmux-$shape: teardown must refuse"
    ownership_assert_unsignalled "$case_dir" "$pid" "tmux-$shape"
    ownership_assert_unsignalled "$case_dir" "$OWN_PANE_PID" "tmux-$shape"
    # An absent window proves nothing, so the leak refuses; a second pane makes
    # the endpoint ambiguous, refused before any close.
    if [ "$shape" = absent ]; then
      grep -Eq "REFUSED: process $pid .*no single live pane shell could be read" "$case_dir/stderr" \
        || fail "tmux-$shape: the refusal did not say the pane could not be read: $(tail -3 "$case_dir/stderr")"
    else
      grep -Eq "REFUSED: the endpoint firstmate:fm-task-x1 of task task-x1 cannot be closed safely: .*several panes" "$case_dir/stderr" \
        || fail "tmux-$shape: the refusal did not name the ambiguous endpoint: $(tail -3 "$case_dir/stderr")"
    fi
    teardown_fixture_stop "$pid"
  done
  pass "an absent recorded tmux window, or a second pane in it, proves nothing and the leak refuses unsignalled"
}

# A group proof holds only while the group still holds a live chain-proved
# process. Here the proved leak, alone in its own group, forks a setsid child on
# TERM and exits; the fixture's ps reports the child in the leak's old group, as
# a recycled group id would. The child is refused unsignalled.
test_teardown_recycled_group_proves_nothing() {
  local case_dir rc pid child group i
  case_dir=$(make_case ownership-recycled-group)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
  teardown_fixture_start "$case_dir/wt" KILL perl -MPOSIX -e '
    my ($out) = @ARGV;
    setpgrp(0, 0) or die "setpgrp";
    $SIG{TERM} = sub {
      my $child = fork(); die "fork" unless defined $child;
      if (!$child) {
        POSIX::setsid();
        open STDIN, "<", "/dev/null"; open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
        exec "sleep", "300";
      }
      open my $fh, ">", "$out.tmp" or die "open"; print {$fh} "$child\n"; close $fh; rename "$out.tmp", $out or die "rename";
      POSIX::_exit(0);
    };
    sleep 300 while 1;' "$case_dir/child.pid"
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  group=$("$REAL_PS_FOR_TEST" -o pgid= -p "$pid" | tr -d ' ')
  [ "$group" = "$pid" ] || fail "recycled-group: setup leak does not lead its own group"
  printf '%s\n' "$group" > "$case_dir/recycled-group"
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
# The detached child reads as a member of the proved leak's old group.
child=$(cat "$FM_FAKE_RECYCLED_CHILD_FILE" 2>/dev/null || true)
group=$(cat "$FM_FAKE_RECYCLED_GROUP_FILE")
out=$("$REAL_PS_FOR_TEST" "$@") || exit $?
[ -n "$child" ] || { printf '%s\n' "$out"; exit 0; }
case " $* " in
  *" pid=,ppid=,pgid= "*) printf '%s\n' "$out" | awk -v c="$child" -v g="$group" '$1 == c { $3 = g } { print }' ;;
  *" pgid= "*) case " $* " in *" -p $child "*) printf '%s\n' "$group" ;; *) printf '%s\n' "$out" ;; esac ;;
  *) printf '%s\n' "$out" ;;
esac
SH
  chmod +x "$case_dir/fakebin/ps"
  rc=0
  FM_FAKE_RECYCLED_CHILD_FILE="$case_dir/child.pid" FM_FAKE_RECYCLED_GROUP_FILE="$case_dir/recycled-group" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  for i in $(seq 50); do [ -s "$case_dir/child.pid" ] && break; sleep 0.1; done
  child=$(cat "$case_dir/child.pid" 2>/dev/null) || fail "recycled-group: the leak never forked"
  teardown_fixture_track "$child" KILL
  ownership_alive "$child" || fail "recycled-group: teardown signalled a process proved only by a recycled group"
  expect_code 1 "$rc" "recycled-group: teardown must refuse: $(tail -3 "$case_dir/stderr")"
  ownership_assert_unsignalled "$case_dir" "$child" recycled-group
  grep -Eq "REFUSED: process $child .*nothing proves it belongs to task-x1" "$case_dir/stderr" \
    || fail "recycled-group: the refusal did not name the child: $(tail -3 "$case_dir/stderr")"
  teardown_fixture_stop "$child"
  pass "a process in a group whose proved members are gone is unproven and refuses unsignalled"
}

# The tasktmp-only route (the task no longer owns its copy): an unproven holder
# of the tasktmp root is named and left running, teardown continues and closes
# the task, and a proved leak there is still reaped.
test_tasktmp_only_route_names_an_unproven_holder_and_continues() {
  local shape case_dir rc pid root first_pane
  for shape in unproven proved ambiguous; do
    case_dir=$(make_case "tasktmp-only-$shape")
    mkdir -p "$case_dir/home/state"
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" landed.txt "delivered work" "landed process fixture"
    git -C "$case_dir/wt" push -q origin HEAD:main
    git -C "$case_dir/project" fetch -q origin
    seed_backlog_in_flight "$case_dir"
    root="$case_dir/tasktmp"
    mkdir -p "$root" "$case_dir/pool/1"
    git -C "$case_dir/project" worktree move "$case_dir/wt" "$case_dir/pool/1/project"
    ln -s "pool/1/project" "$case_dir/wt"
    printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
      "$case_dir/pool/1/project" > "$case_dir/pool/treehouse-state.json"
    printf 'task=other-task\nhome=%s\n' "$case_dir/other-home" > "$case_dir/pool/1/.fm-slot-owner"
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$case_dir/wt" "project=$case_dir/project" "tasktmp=$root" \
      "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1"
    if [ "$shape" = ambiguous ]; then
      # Two panes in the recorded window: the anchor is unprovable. The second
      # pane's own child holds tasktmp, so closing the window would end it.
      ownership_pane "$case_dir"
      first_pane=$OWN_PANE_PID
      ownership_pane "$case_dir" "$root"
      pid=$OWN_LEAK_PID
      printf 'fm-task-x1\t%%1\t%s\nfm-task-x1\t%%2\t%s\n' "$first_pane" "$OWN_PANE_PID" > "$case_dir/pane-rows"
      cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in *'#{pane_pid}'*) cat "$case_dir/pane-rows" ;; esac
case "\${1:-}" in list-windows) if [ -f "$case_dir/pane-rows" ]; then cut -f1 "$case_dir/pane-rows" | sort -u; elif [ -f "$case_dir/pane-pid" ]; then echo fm-task-x1; fi ;; esac
case "\${1:-}" in kill-*) printf '%s\n' "\$*" >> "$case_dir/endpoint-close.log" ;; esac
exit 0
SH
      chmod +x "$case_dir/fakebin/tmux"
    elif [ "$shape" = unproven ]; then
      ownership_pane "$case_dir"
      ownership_detached "$root" setsid
      pid=$OWN_DETACHED_PID
    else
      teardown_fixture_start "$root" KILL sleep 300
      pid=$TEARDOWN_FIXTURE_PID
      sleep 0.3
    fi
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$shape" = ambiguous ]; then
      expect_code 1 "$rc" "tasktmp-only-ambiguous: an unprovable anchor must refuse: $(tail -3 "$case_dir/stderr")"
      assert_absent "$case_dir/endpoint-close.log" "tasktmp-only-ambiguous: the endpoint was closed: $(cat "$case_dir/endpoint-close.log" 2>/dev/null)"
      ownership_alive "$first_pane" || fail "tasktmp-only-ambiguous: the first pane process was signalled"
      ownership_alive "$OWN_PANE_PID" || fail "tasktmp-only-ambiguous: the second pane process was signalled"
      ownership_alive "$pid" || fail "tasktmp-only-ambiguous: the tasktmp holder was signalled"
      ownership_assert_unsignalled "$case_dir" "$pid" tasktmp-only-ambiguous
      assert_present "$case_dir/state/task-x1.meta" "tasktmp-only-ambiguous: the task record was removed"
      grep -Eq "REFUSED: the endpoint firstmate:fm-task-x1 of task task-x1 cannot be closed safely: .*several panes" "$case_dir/stderr" \
        || fail "tasktmp-only-ambiguous: the refusal did not name the unprovable anchor: $(tail -3 "$case_dir/stderr")"
      teardown_fixture_stop "$pid"
      continue
    fi
    expect_code 0 "$rc" "tasktmp-only-$shape: teardown must continue: $(tail -3 "$case_dir/stderr")"
    assert_grep "reassigned" "$case_dir/stderr" "tasktmp-only-$shape: the tasktmp-only route was not taken"
    assert_absent "$case_dir/state/task-x1.meta" "tasktmp-only-$shape: the task did not close"
    if [ "$shape" = unproven ]; then
      ownership_alive "$pid" || fail "tasktmp-only-unproven: the unproven holder was signalled"
      ownership_assert_unsignalled "$case_dir" "$pid" tasktmp-only-unproven
      grep -Eq "REFUSED: process $pid .*nothing proves it belongs to task-x1" "$case_dir/stderr" \
        || fail "tasktmp-only-unproven: the holder was not named: $(tail -3 "$case_dir/stderr")"
      assert_grep "leaving the tasktmp process(es) named above running" "$case_dir/stderr" \
        "tasktmp-only-unproven: teardown did not say it left the holder and continued"
      teardown_fixture_stop "$pid"
    else
      ownership_wait_dead "$pid" || fail "tasktmp-only-proved: the proved tasktmp leak survived"
      assert_grep $'\tTERM\t'"$pid"$'\t' "$case_dir/state/task-x1.teardown-processes" \
        "tasktmp-only-proved: the leak's signal was not audited"
    fi
  done
  pass "the tasktmp-only route names and leaves an unproven tasktmp holder and continues, still reaps a proved leak, and refuses with no endpoint closed when the anchor itself is unprovable"
}

# The narrowed claim: an orphan reparented to init that never left its session
# is not provably the task's either, so it refuses unsignalled, as does an
# unproven daemon at the task's tasktmp root.
test_teardown_refuses_an_orphan_it_cannot_prove() {
  local case_dir rc pid root
  for root in wt tasktmp; do
    case_dir=$(make_case "ownership-orphan-$root")
    write_meta "$case_dir" no-mistakes ship
    printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
    mkdir -p "$case_dir/tasktmp"
    land_shippable_commit "$case_dir"
    ownership_pane "$case_dir"
    if [ "$root" = wt ]; then ownership_detached "$case_dir/$root"; else ownership_detached "$case_dir/$root" setsid; fi
    pid=$OWN_DETACHED_PID
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    ownership_alive "$pid" || fail "orphan-$root: teardown killed an orphan it could not prove"
    expect_code 1 "$rc" "orphan-$root: teardown must refuse"
    assert_present "$case_dir/wt" "orphan-$root: the copy was removed"
    ownership_assert_unsignalled "$case_dir" "$pid" "orphan-$root"
    assert_grep "REFUSED: process $pid " "$case_dir/stderr" "orphan-$root: the refusal did not name the orphan"
    teardown_fixture_stop "$pid"
  done
  pass "an orphan reparented to init at the copy root, and an unproven daemon at the tasktmp root, refuse unsignalled"
}

test_process_identity_is_recorded_before_term_and_kill() {
  local case_dir rc pid journal expected_start expected_cwd epoch signal audit_pid birth command start cwd matched digest
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
  IFS=$'\t' read -r epoch signal audit_pid birth command start cwd matched digest < "$case_dir/term-observed"
  case "$epoch" in ''|*[!0-9]*) fail "durable-process-identity: invalid timestamp" ;; esac
  case "$command" in *perl*) ;; *) fail "durable-process-identity: command line missing" ;; esac
  case "$birth" in lstart=*|starttime=*) ;; *) fail "durable-process-identity: birth identity missing" ;; esac
  [ "$signal" = TERM ] && [ "$audit_pid" = "$pid" ] \
    || fail "durable-process-identity: signal target missing"
  [ "$start" = "$(printf '%q' "$expected_start")" ] \
    || fail "durable-process-identity: process start time missing or incorrect"
  [ "$cwd" = "$(printf '%q' "$expected_cwd")" ] && [ "$matched" = "$cwd" ] \
    || fail "durable-process-identity: cwd or matched open path missing or incorrect"
  case "$digest" in cmdline-sha256=*) ;; *) fail "durable-process-identity: the command line digest field is missing: $digest" ;; esac
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
  # The tasktmp-only route names an unproven holder and continues instead
  # (test_tasktmp_only_route_names_an_unproven_holder_and_continues).
  for scenario in descendant foreign missing-lsof audit legacy existing-marker; do
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
case "\$*" in *'#{pane_pid}'*) if [ -f "$case_dir/pane-rows" ]; then cat "$case_dir/pane-rows"; elif [ -f "$case_dir/pane-pid" ]; then printf 'fm-task-x1\t%%1\t%s\n' "\$(cat "$case_dir/pane-pid")"; fi ;; esac
case "\${1:-}" in list-windows) if [ -f "$case_dir/pane-rows" ]; then cut -f1 "$case_dir/pane-rows" | sort -u; elif [ -f "$case_dir/pane-pid" ]; then echo fm-task-x1; fi ;; esac
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
case "\$*" in *'#{pane_pid}'*) if [ -f "$case_dir/pane-rows" ]; then cat "$case_dir/pane-rows"; elif [ -f "$case_dir/pane-pid" ]; then printf 'fm-task-x1\t%%1\t%s\n' "\$(cat "$case_dir/pane-pid")"; fi ;; esac
case "\${1:-}" in list-windows) if [ -f "$case_dir/pane-rows" ]; then cut -f1 "$case_dir/pane-rows" | sort -u; elif [ -f "$case_dir/pane-pid" ]; then echo fm-task-x1; fi ;; esac
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

test_leaked_tasktmp_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-tasktmp-reap)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/tasktmp"
  land_shippable_commit "$case_dir"

  teardown_fixture_start "$case_dir/tasktmp" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-tasktmp-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-tasktmp-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    teardown_fixture_stop "$pid"
    fail "leaked-tasktmp-reap: leaked tasktmp process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-tasktmp-reap: teardown did not report reaping the leaked tasktmp process"
  pass "a leaked descendant process rooted under the task's per-task tasktmp is reaped by teardown too"
}

test_lsof_absent_refuses_without_signalling() {
  local case_dir rc pid path_without_lsof survived=0
  case_dir=$(make_case lsof-absent-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
    && fail "lsof-absent-refusal: fixture path unexpectedly exposes lsof"

  teardown_fixture_start "$case_dir/wt" KILL perl -e 'setpgrp(0, 0); exec "sleep", "300"'
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "lsof-absent-refusal: setup sleeper did not start"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\$*" in *'#{pane_pid}'*) if [ -f "$case_dir/pane-rows" ]; then cat "$case_dir/pane-rows"; elif [ -f "$case_dir/pane-pid" ]; then printf 'fm-task-x1\t%%1\t%s\n' "\$(cat "$case_dir/pane-pid")"; fi ;; esac
case "\${1:-}" in list-windows) if [ -f "$case_dir/pane-rows" ]; then cut -f1 "$case_dir/pane-rows" | sort -u; elif [ -f "$case_dir/pane-pid" ]; then echo fm-task-x1; fi ;; esac
if [ "\${1:-}" = display-message ] && [ "\${*: -1}" = '#{pane_pid}' ]; then
  printf '%s\n' '$pid'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/tmux"

  rc=0
  FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill -0 "$pid" 2>/dev/null && survived=1
  teardown_fixture_stop "$pid"

  expect_code 1 "$rc" "lsof-absent-refusal: teardown should refuse even with force"
  [ "$survived" -eq 1 ] || fail "lsof-absent-refusal: an unaudited signal reached the pane process group"
  assert_grep "(lsof is unavailable, so no signal target can be audited)" "$case_dir/stderr" \
    "lsof-absent-refusal: teardown did not explain the missing-lsof refusal"
  assert_present "$case_dir/wt" "lsof-absent-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-absent-refusal: teardown removed task metadata"
  assert_absent "$case_dir/state/task-x1.teardown-processes" \
    "lsof-absent-refusal: an unscanned process was recorded as a signal target"
  pass "missing lsof refuses teardown instead of sending unaudited process-group signals"
}

test_lsof_error_refuses_before_removal() {
  local case_dir rc
  case_dir=$(make_case lsof-error-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-error-refusal: teardown should refuse"
  assert_grep "REFUSED: cannot determine leaked processes under $case_dir/wt for task-x1 (lsof failed)" "$case_dir/stderr" \
    "lsof-error-refusal: teardown did not explain the lsof refusal"
  assert_present "$case_dir/wt" "lsof-error-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-error-refusal: teardown removed task metadata"
  assert_absent "$case_dir/treehouse.log" "lsof-error-refusal: teardown returned the worktree"
  pass "an erroring lsof scan refuses teardown and preserves the task"
}

test_reused_pid_identity_is_not_force_killed() {
  local case_dir rc pid
  case_dir=$(make_case reused-pid-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  teardown_fixture_start "$case_dir" KILL perl -e "$(cat <<'PERL'
$SIG{TERM} = "IGNORE"; sleep 300
PERL
  )"
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.2
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f '$case_dir/lsof-count' ] || count=\$(cat '$case_dir/lsof-count')
count=\$((count + 1))
printf '%s\n' "\$count" > '$case_dir/lsof-count'
if [ "\$count" -le 4 ]; then printf 'p%s\nfcwd\nn%s\n' '$pid' '$case_dir/wt'; fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_REUSED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  count=0
  [ ! -f "$FM_FAKE_PS_COUNT" ] || count=$(cat "$FM_FAKE_PS_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_PS_COUNT"
  if [ "$count" -le 10 ]; then printf 'Tue Aug  4 10:00:00 2026\n'
  else printf 'Tue Aug  4 10:00:01 2026\n'; fi
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  # The listing shows the process to the pre-close decision and the reaper's
  # three scans of its first pass, and then no more.
  # The original identity answers every read up to the TERM: the pre-close
  # decision's scan (identity and recheck, 2), the first reaper scan (2), the
  # reaper's own read (1), the pre-signal scan (2), the pre-signal match (1), the
  # audit's start-time read (1) and the match before kill (1). The pid then reads
  # as a replacement during the grace period.
  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_REUSED_PID="$pid" FM_FAKE_PS_COUNT="$case_dir/ps-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "reused-pid-identity: teardown should skip the replacement process"
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "reused-pid-identity: teardown force-killed a process whose start time changed"
  fi
  teardown_fixture_stop "$pid"
  assert_grep $'\tTERM\t'"$pid"$'\t' "$case_dir/state/task-x1.teardown-processes" \
    "reused-pid-identity: the original identity was not sent TERM before the grace period"
  assert_no_grep $'\tKILL\t' "$case_dir/state/task-x1.teardown-processes" \
    "reused-pid-identity: a KILL was audited for a changed identity"
  pass "a reused pid with a different start time is never force-killed"
}

test_exec_changed_process_is_still_reaped() {
  local case_dir rc pid marker done_flag survived=0
  case_dir=$(make_case exec-changed-process)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  marker="$case_dir/exec-now"
  done_flag="$case_dir/exec-done"

  teardown_fixture_start "$case_dir/wt" KILL perl -e "$(cat <<'PERL'
      my ($marker, $done) = @ARGV;
      until (-e $marker) { select undef, undef, undef, 0.01; }
      open my $fh, ">", $done or die "open";
      close $fh;
      exec "perl", "-e", '$SIG{TERM} = "IGNORE"; sleep 300';
PERL
    )" "$marker" "$done_flag"
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.2
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXEC_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  out=$("$REAL_PS_FOR_TEST" "$@") || exit $?
  [ -e "$FM_FAKE_EXEC_MARKER" ] || : > "$FM_FAKE_EXEC_MARKER"
  printf '%s\n' "$out"
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_FAKE_LSOF_COUNT" ] || count=$(cat "$FM_FAKE_LSOF_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_LSOF_COUNT"
if [ "$count" -eq 2 ]; then
  i=0
  while [ "$i" -lt 100 ]; do
    [ ! -e "$FM_FAKE_EXEC_DONE" ] || break
    sleep 0.01
    i=$((i + 1))
  done
fi
exec "$REAL_LSOF_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/lsof"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_EXEC_PID="$pid" FM_FAKE_EXEC_MARKER="$marker" \
  FM_FAKE_EXEC_DONE="$done_flag" FM_FAKE_LSOF_COUNT="$case_dir/lsof-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    teardown_fixture_stop "$pid"
  fi
  expect_code 0 "$rc" "exec-changed-process: teardown should succeed"
  [ "$survived" -eq 0 ] || fail "exec-changed-process: exec-changed leaked process survived teardown"
  pass "an exec change preserves birth identity and the process is reaped"
}

test_process_spawned_during_grace_after_its_parent_exits_is_refused() {
  local case_dir rc pid child_file child_pid="" parent_survived=0 child_survived=0
  case_dir=$(make_case grace-spawn-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  child_file="$case_dir/child.pid"

  teardown_fixture_start "$case_dir/wt" HUP perl -e "$(cat <<'PERL'
      use POSIX qw(SIG_BLOCK SIG_SETMASK SIGTERM SIGHUP SIGINT SIGQUIT);
      require $ENV{FM_TEARDOWN_FIXTURE_HELPERS};
      my ($file, $ready) = @ARGV;
      my ($child, $leave_child);
      END {
        if (defined $child && $child > 0 && !$leave_child) {
          kill "KILL", $child;
          waitpid($child, 0);
        }
      }
      $SIG{HUP} = sub {
        exit 0;
      };
      $SIG{TERM} = sub {
        return if defined $child;
        my $old = POSIX::SigSet->new;
        my $blocked = POSIX::SigSet->new(SIGTERM, SIGHUP, SIGINT, SIGQUIT);
        POSIX::sigprocmask(SIG_BLOCK, $blocked, $old) or die "block signals";
        $child = fork();
        die "fork" unless defined $child;
        if (!$child) {
          $SIG{TERM} = $SIG{HUP} = $SIG{INT} = $SIG{QUIT} = "DEFAULT";
          POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
          exec "sleep", "300"; die "exec";
        }
        fixture_track($child);
        open my $fh, ">", $file or die "open";
        print {$fh} "$child\n";
        close $fh or die "close";
        POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
        $leave_child = 1;
        exit 0;
      };
      open my $fh, ">", $ready or die "ready"; close $fh;
      sleep 300;
PERL
    )" "$child_file" "$case_dir/ready"
  pid=$TEARDOWN_FIXTURE_PID
  local i=0
  while [ ! -e "$case_dir/ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$case_dir/ready" ] || fail "grace-spawn-refusal: parent not ready"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if [ -f "$child_file" ]; then child_pid=$(cat "$child_file"); fi
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    child_survived=1
    teardown_fixture_stop "$child_pid"
  fi
  if kill -0 "$pid" 2>/dev/null; then
    parent_survived=1
    teardown_fixture_stop "$pid"
  fi
  # The parent exited after forking, so the child's group holds no live process
  # proved the task's: a group id can be reused once its proved members are gone,
  # so the child is unproven and the later pass refuses without signalling it.
  expect_code 1 "$rc" "grace-spawn-refusal: teardown must refuse the child it can no longer prove"
  assert_present "$child_file" "grace-spawn-refusal: TERM handler did not spawn a child"
  [ "$child_survived" -eq 1 ] || fail "grace-spawn-refusal: the unproven child was signalled"
  [ "$parent_survived" -eq 0 ] || fail "grace-spawn-refusal: original process survived"
  ownership_assert_unsignalled "$case_dir" "$child_pid" grace-spawn-refusal
  grep -Eq "REFUSED: process $child_pid .*nothing proves it belongs to task-x1" "$case_dir/stderr" \
    || fail "grace-spawn-refusal: the refusal did not name the child: $(tail -3 "$case_dir/stderr")"
  pass "a child spawned during grace whose proved parent then exits is refused unsignalled on the later pass"
}

test_persistent_scan_refuses_after_bounded_retries() {
  local case_dir rc spawner i=0
  case_dir=$(make_case persistent-reap-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  # A real parent outside the task roots immediately replenishes leaked children.
  # Each killed child has a distinct kernel birth identity and a real cwd.
  teardown_fixture_start "$case_dir" TERM perl -e "$(cat <<'PERL'
    use POSIX qw(SIG_BLOCK SIG_SETMASK SIGTERM SIGINT SIGHUP SIGQUIT WNOHANG);
    require $ENV{FM_TEARDOWN_FIXTURE_HELPERS};
    my ($root, $ready) = @ARGV;
    my ($child, $stopping);
    my $owner = $$;
    my $blocked = POSIX::SigSet->new(SIGTERM, SIGINT, SIGHUP, SIGQUIT);
    $SIG{TERM} = $SIG{INT} = $SIG{HUP} = $SIG{QUIT} = sub { $stopping = 1; };
    END {
      if ($owner == $$) {
        kill "KILL", $child if defined $child;
        waitpid($child, 0) if defined $child;
        unlink $ready;
      }
    }
    while (!$stopping) {
      my $old = POSIX::SigSet->new;
      POSIX::sigprocmask(SIG_BLOCK, $blocked, $old) or die "block signals";
      $child = fork(); defined $child or die "fork";
      if (!$child) {
        $SIG{TERM} = $SIG{INT} = $SIG{HUP} = $SIG{QUIT} = "DEFAULT";
        POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
        chdir $root or die "chdir";
        my $birth = fixture_track($$);
        open my $fh, ">", "$ready.$$" or die "ready";
        print {$fh} "$$\t$birth\n";
        close $fh or die "close readiness";
        rename "$ready.$$", $ready or die "publish readiness";
        exec "sleep", "300"; die "exec";
      }
      fixture_track($child);
      POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
      while (!$stopping && defined $child) {
        POSIX::sigprocmask(SIG_BLOCK, $blocked, $old) or die "block signals";
        my $exited = waitpid($child, WNOHANG);
        undef $child if $exited != 0;
        POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
        select undef, undef, undef, 0.01 if defined $child && !$stopping;
      }
      unlink $ready;
    }
PERL
  )" "$case_dir/wt" "$case_dir/child-ready"
  spawner=$TEARDOWN_FIXTURE_PID
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
for ((i=0; i<1000; i++)); do
  if IFS=$'\t' read -r pid birth < "$FM_FAKE_CHILD_READY" 2>/dev/null \
     && teardown_fixture_live "$pid" "$birth"; then
    exec "$REAL_LSOF_FOR_TEST" "$@"
  fi
  sleep 0.01
done
printf 'fixture child never became ready\n' >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
  while [ ! -s "$case_dir/child-ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$case_dir/child-ready" ] || fail "persistent-reap-refusal: child not ready"
  rc=0
  FM_FAKE_CHILD_READY="$case_dir/child-ready" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  teardown_fixture_stop "$spawner"

  expect_code 1 "$rc" "persistent-reap-refusal: teardown should refuse"
  assert_grep "remain after 3 reap attempts" "$case_dir/stderr" \
    "persistent-reap-refusal: teardown did not report bounded non-convergence"
  assert_present "$case_dir/wt" "persistent-reap-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "persistent-reap-refusal: teardown removed task metadata"
  pass "persistent leaked processes refuse teardown after bounded retries"
}

test_process_exit_during_identity_lookup_does_not_refuse() {
  local case_dir rc wt_path fake_pid=99999998
  case_dir=$(make_case identity-exit-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f "$case_dir/lsof-count" ] || count=\$(cat "$case_dir/lsof-count")
count=\$((count + 1))
printf '%s\n' "\$count" > "$case_dir/lsof-count"
if [ "\$count" -eq 1 ]; then
  printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXITED_PID:-}" ]; then
  exit 1
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'returned\n' > "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_EXITED_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "identity-exit-convergence: teardown should succeed"
  assert_present "$case_dir/treehouse.log" \
    "identity-exit-convergence: teardown did not reach worktree return"
  ! grep -q REFUSED "$case_dir/stderr" || \
    fail "identity-exit-convergence: a disappeared process caused teardown refusal"
  pass "a process exiting during identity lookup does not block teardown"
}

test_run_abort_precedes_process_reap_precedes_worktree_removal() {
  local case_dir rc head pid abort_log
  case_dir=$(make_case abort-then-reap-then-remove-order)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  abort_log="$case_dir/nm-abort.log"

  teardown_fixture_start "$case_dir/wt" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "abort-then-reap-then-remove-order: setup sleeper did not start"

  # A treehouse fake that snapshots, at the exact moment the destructive
  # worktree return runs, whether the run was already aborted and whether the
  # leaked process was already reaped - direct causal proof of ordering from
  # real observed state, not a source-text or line-number correlation.
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ -s "$abort_log" ]; then echo "abort-already-happened" >> "$case_dir/order.log"; fi
if ! kill -0 $pid 2>/dev/null; then echo "reap-already-happened" >> "$case_dir/order.log"; fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$abort_log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "abort-then-reap-then-remove-order: teardown should still succeed"
  teardown_fixture_stop "$pid"

  assert_present "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the destructive worktree return was never invoked"
  assert_grep "abort-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the run was not yet aborted when the worktree return ran"
  assert_grep "reap-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the leaked process was not yet reaped when the worktree return ran"
  pass "the run abort and the leaked-process reap both complete before the destructive worktree return"
}

# The incident: a worker's private no-mistakes home ran as a launchd agent whose
# daemon held a directory inside the task copy. A root inside the copy does not
# prove the task created the agent (an independently managed service could have
# it), and no record names the agents a task created, so teardown refuses before
# any bootout or signal and leaves the agent, its plist and its daemon running.
test_in_copy_nm_launch_agent_refuses_without_a_creation_record() {
  local case_dir rc pid label shared_state
  case_dir=$(make_case private-nm-agent)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  add_fake_launchctl "$case_dir"
  shared_state="$case_dir/shared-daemon-state"
  printf '%s\n' running > "$shared_state"
  mkdir -p "$case_dir/wt/.no-mistakes/h"
  teardown_fixture_start "$case_dir/wt/.no-mistakes/h" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "private-nm-agent: setup daemon did not start"
  label="$NM_AGENT_PREFIX.3baa54c9"
  add_nm_launch_agent "$case_dir" 3baa54c9 "$(cd "$case_dir/wt" && pwd -P)/.no-mistakes/h" "$pid"

  rc=0
  FM_FAKE_NM_SHARED_DAEMON_STATE="$shared_state" FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill -0 "$pid" 2>/dev/null || fail "private-nm-agent: teardown signalled the agent's daemon"
  teardown_fixture_stop "$pid"
  expect_code 1 "$rc" "private-nm-agent: teardown must refuse an in-copy agent no record proves the task's"
  assert_no_grep "bootout" "$case_dir/launchctl-calls" "private-nm-agent: teardown booted out an unproven agent"
  assert_present "$case_dir/launchctl-loaded/$label" "private-nm-agent: the agent was unloaded"
  assert_present "$case_dir/launchagents/$label.plist" "private-nm-agent: the plist was moved"
  assert_absent "$case_dir/data/task-x1/launchagent-backup" "private-nm-agent: something was archived"
  assert_present "$case_dir/wt" "private-nm-agent: the copy was removed"
  assert_present "$case_dir/state/task-x1.meta" "private-nm-agent: the task record was removed"
  grep -Eq "REFUSED: no-mistakes launch agent $label .*no record of task-x1 proves the task created it" "$case_dir/stderr" \
    || fail "private-nm-agent: the refusal did not name the agent: $(tail -3 "$case_dir/stderr")"
  [ "$(cat "$shared_state")" = running ] || fail "private-nm-agent: teardown stopped the shared daemon"
  pass "an in-copy no-mistakes launch agent no record proves the task's refuses teardown with nothing booted out, archived or signalled"
}

test_in_copy_nm_launch_agent_equivalent_roots_refuse() {
  local spelling case_dir wt root pid label rc
  for spelling in dot separators parent symlink; do
    case_dir=$(make_case "private-nm-agent-$spelling")
    write_meta "$case_dir" no-mistakes ship
    land_shippable_commit "$case_dir"
    add_fake_launchctl "$case_dir"
    wt=$(cd "$case_dir/wt" && pwd -P)
    mkdir -p "$wt/.no-mistakes/h" "$wt/.no-mistakes/staging"
    ln -s "$wt/.no-mistakes/h" "$case_dir/private-home"
    case "$spelling" in
      dot) root="$wt/./.no-mistakes/h" ;;
      separators) root="$wt//.no-mistakes//h/" ;;
      parent) root="$wt/.no-mistakes/staging/../h" ;;
      symlink) root="$case_dir/private-home" ;;
    esac
    teardown_fixture_start "$wt/.no-mistakes/h" KILL sleep 300
    pid=$TEARDOWN_FIXTURE_PID
    label="$NM_AGENT_PREFIX.3baa54c9"
    add_nm_launch_agent "$case_dir" 3baa54c9 "$root" "$pid"

    rc=0
    FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    kill -0 "$pid" 2>/dev/null || fail "private-nm-agent-$spelling: the agent's daemon was signalled"
    teardown_fixture_stop "$pid"
    expect_code 1 "$rc" "private-nm-agent-$spelling: teardown must refuse"
    assert_present "$case_dir/launchctl-loaded/$label" "private-nm-agent-$spelling: the agent was unloaded"
    assert_present "$case_dir/launchagents/$label.plist" "private-nm-agent-$spelling: the plist was moved"
    assert_present "$case_dir/state/task-x1.meta" "private-nm-agent-$spelling: the task record was removed"
  done
  pass "every equivalent spelling of an in-copy agent root is recognized and refuses with the agent left loaded"
}

test_nested_nm_launch_agents_are_left_alone() {
  local registrar damage case_dir registry nested lane pid label rc hash
  for registrar in project sibling; do
    for damage in none no-git deleted; do
      case_dir=$(make_case "nested-nm-agent-$registrar-$damage")
      write_meta "$case_dir" no-mistakes ship
      land_shippable_commit "$case_dir"
      add_fake_launchctl "$case_dir"
      registry="$case_dir/project"
      if [ "$registrar" = sibling ]; then
        registry="$case_dir/sibling-clone"
        git clone -q "$case_dir/origin.git" "$registry"
      fi
      nested="$case_dir/wt/other-lane"
      git -C "$registry" worktree add -q --detach "$nested" main
      git -C "$registry" worktree lock "$nested"
      lane=$(cd "$nested" && pwd -P)
      fm_write_meta "$case_dir/state/other-lane.meta" "worktree=$lane" "project=$registry" "kind=ship"
      mkdir -p "$lane/.no-mistakes/h"
      ln -s "$lane/.no-mistakes/h" "$case_dir/lane-home"
      teardown_fixture_start "$lane/.no-mistakes/h" KILL sleep 300
      pid=$TEARDOWN_FIXTURE_PID
      add_nm_launch_agent "$case_dir" 00000001 "$lane/./.no-mistakes//h" "$pid"
      add_nm_launch_agent "$case_dir" 00000002 "$lane/.no-mistakes/missing/../h"
      add_nm_launch_agent "$case_dir" 00000003 "$case_dir/lane-home"
      case "$damage" in
        no-git) rm -f "$nested/.git" ;;
        deleted) rm -rf "$nested" ;;
      esac

      rc=0
      FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
        run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      if ! kill -0 "$pid" 2>/dev/null; then
        fail "nested-nm-agent-$registrar-$damage: another lane's daemon was killed"
      fi
      teardown_fixture_stop "$pid"
      expect_code 1 "$rc" "nested-nm-agent-$registrar-$damage: teardown must refuse the foreign process"
      [ ! -s "$case_dir/launchctl-calls" ] \
        || fail "nested-nm-agent-$registrar-$damage: teardown addressed another lane's agent"
      for hash in 00000001 00000002 00000003; do
        label="$NM_AGENT_PREFIX.$hash"
        assert_present "$case_dir/launchagents/$label.plist" "nested-nm-agent: foreign plist was removed"
      done
      assert_present "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.00000001" "nested-nm-agent: foreign agent was unloaded"
      assert_absent "$case_dir/data/task-x1/launchagent-backup" "nested-nm-agent: foreign plist was archived"
      assert_present "$case_dir/state/task-x1.meta" "nested-nm-agent: task record was removed"
    done
  done
  pass "nested-lane agents remain loaded and installed across registry, path, and lane-damage variants"
}

test_absent_copy_nm_launch_agents_preserve_nested_ownership() {
  local recovery registrar case_dir wt registry nested home hash label root rc head
  local -a flags
  for recovery in merged forced; do
    for registrar in project sibling; do
      case_dir=$(make_case "absent-nm-agent-$recovery-$registrar")
      write_meta "$case_dir" no-mistakes ship
      add_fake_launchctl "$case_dir"
      wt=$(cd "$case_dir/wt" && pwd -P)
      registry="$case_dir/project"
      home="$case_dir/primary-home"
      if [ "$registrar" = sibling ]; then
        registry="$case_dir/sibling-clone"
        git clone -q "$case_dir/origin.git" "$registry"
        home="$case_dir/mate-home"
        mkdir -p "$case_dir/primary-home/data"
        printf -- '- mate-x - fixture scope (home: %s; scope: fixture; projects: alpha; added 2026-07-14)\n' \
          "$home" > "$case_dir/primary-home/data/secondmates.md"
      fi
      mkdir -p "$home/state"
      nested="$wt/other-lane"
      git -C "$registry" worktree add -q --detach "$nested" main
      git -C "$registry" worktree lock "$nested"
      fm_write_meta "$home/state/other-lane.meta" "worktree=$nested" "project=$registry" "kind=ship"
      flags=()
      if [ "$recovery" = merged ]; then
        append_pr_meta_url "$case_dir"
        head=$(git -C "$wt" rev-parse HEAD)
        add_gh_pr_merged_for_head "$case_dir" "$head"
      else
        flags=(--force --drop-file "$(fm_test_drop_file)")
      fi
      hash=0
      for root in "$wt" "$wt/.no-mistakes/h" "$wt" "$wt/.no-mistakes/h"; do
        hash=$((hash + 1))
        add_nm_launch_agent "$case_dir" "$hash" "$root"
        [ "$hash" -gt 2 ] || : > "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.$hash"
      done
      add_nm_launch_agent "$case_dir" nested "$nested/.no-mistakes/h"
      : > "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.nested"
      rm -rf "$wt"

      rc=0
      FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
        run_teardown "$case_dir" "${flags[@]+"${flags[@]}"}" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      # Agents rooted in the absent copy are no more proven the task's than in a
      # present one, so recovery refuses with each of them left as found.
      expect_code 1 "$rc" "absent-nm-agent-$recovery-$registrar: recovery must refuse the unproven agents: $(tail -3 "$case_dir/stderr")"
      assert_no_grep "bootout" "$case_dir/launchctl-calls" "absent-nm-agent: an unproven agent was booted out"
      for hash in 1 2 3 4; do
        label="$NM_AGENT_PREFIX.$hash"
        assert_present "$case_dir/launchagents/$label.plist" "absent-nm-agent: an in-copy plist was moved"
        [ "$hash" -gt 2 ] || assert_present "$case_dir/launchctl-loaded/$label" "absent-nm-agent: an in-copy agent was unloaded"
      done
      label="$NM_AGENT_PREFIX.nested"
      assert_present "$case_dir/launchctl-loaded/$label" "absent-nm-agent: nested agent was unloaded"
      assert_present "$case_dir/launchagents/$label.plist" "absent-nm-agent: nested plist was removed"
      assert_no_grep "$label" "$case_dir/launchctl-calls" "absent-nm-agent: nested agent was addressed"
      assert_absent "$case_dir/data/task-x1/launchagent-backup/$label.plist" "absent-nm-agent: nested plist was archived"
      assert_present "$home/state/other-lane.meta" "absent-nm-agent: nested task record was removed"
      assert_present "$case_dir/state/task-x1.meta" "absent-nm-agent: the refused task record was removed"
    done
  done
  pass "absent-copy recovery refuses on agents rooted in the absent copy and leaves nested agents registered by local task projects untouched"
}

# Every agent whose root is not inside THIS task's copy stays loaded and
# installed: the shared ~/.no-mistakes agent, another task's agent, a sibling
# directory that only shares a name prefix, and a root that climbs out with `..`.
test_foreign_nm_launch_agents_are_left_alone() {
  local case_dir rc wt calls hash
  case_dir=$(make_case foreign-nm-agents)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  add_fake_launchctl "$case_dir"
  wt=$(cd "$case_dir/wt" && pwd -P)
  printf '%s\n' '.no-mistakes/' >> "$(git -C "$wt" rev-parse --git-path info/exclude)"
  add_nm_launch_agent "$case_dir" 00000001 "$case_dir/home/.no-mistakes" 999991
  add_nm_launch_agent "$case_dir" 00000002 "$case_dir/other-wt/.no-mistakes/h" 999992
  add_nm_launch_agent "$case_dir" 00000003 "$wt-sibling/.no-mistakes/h" 999993
  add_nm_launch_agent "$case_dir" 00000004 "$wt/../escape/.no-mistakes/h" 999994
  mkdir -p "$case_dir/escape/h" "$wt/.no-mistakes"
  ln -s "$case_dir/escape" "$wt/.no-mistakes/outside"
  add_nm_launch_agent "$case_dir" 00000006 "$wt/missing/../../escape/.no-mistakes/h"
  add_nm_launch_agent "$case_dir" 00000007 "$wt/.no-mistakes/outside/h"
  add_nm_launch_agent "$case_dir" 00000008 "$wt/.no-mistakes/outside/../.no-mistakes/h"
  add_nm_launch_agent "$case_dir" 00000009 "$wt/missing/../.no-mistakes/outside/h"
  for hash in 00000006 00000007 00000008 00000009; do
    : > "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.$hash"
  done
  mkdir -p "$case_dir/launchagents"
  printf '%s\n' 'not a plist' > "$case_dir/launchagents/com.kunchenguid.no-mistakes.daemon.00000005.plist"
  printf '%s\n' unrelated > "$case_dir/launchagents/com.example.other.plist"

  rc=0
  FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "foreign-nm-agents: teardown should be unaffected by other agents: $(cat "$case_dir/stderr")"
  calls=$(cat "$case_dir/launchctl-calls")
  assert_not_contains "$calls" "bootout" "foreign-nm-agents: teardown unloaded an agent that is not this task's"
  [ "$(find "$case_dir/launchagents" -name '*.plist' | wc -l | tr -d ' ')" = 10 ] \
    || fail "foreign-nm-agents: an installed plist was moved or removed"
  for hash in 00000001 00000002 00000003 00000004 00000006 00000007 00000008 00000009; do
    assert_present "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.$hash" \
      "foreign-nm-agents: an outside-root agent was unloaded"
  done
  assert_absent "$case_dir/data/task-x1/launchagent-backup" \
    "foreign-nm-agents: something was archived for a task that owned no agent"
  assert_grep "leaving unreadable no-mistakes launch agent $case_dir/launchagents/$NM_AGENT_PREFIX.00000005.plist as found" "$case_dir/stderr" \
    "foreign-nm-agents: an unparsable plist was skipped silently"
  pass "agents rooted outside the task's copy, and unparsable plists, are never unloaded or moved"
}

# --force does not make an unproven in-copy agent the task's.
test_in_copy_nm_launch_agent_refuses_even_with_force() {
  local case_dir rc pid label
  case_dir=$(make_case private-nm-agent-forced)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  add_fake_launchctl "$case_dir"
  mkdir -p "$case_dir/wt/.no-mistakes/h"
  teardown_fixture_start "$case_dir/wt/.no-mistakes/h" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  label="$NM_AGENT_PREFIX.3baa54c9"
  add_nm_launch_agent "$case_dir" 3baa54c9 "$(cd "$case_dir/wt" && pwd -P)/.no-mistakes/h" "$pid"

  rc=0
  FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill -0 "$pid" 2>/dev/null || { teardown_fixture_stop "$pid"; fail "private-nm-agent-forced: process was signalled around an unproven agent"; }
  teardown_fixture_stop "$pid"
  expect_code 1 "$rc" "private-nm-agent-forced: forced teardown must still refuse"
  assert_no_grep "bootout" "$case_dir/launchctl-calls" "private-nm-agent-forced: the agent was booted out"
  assert_present "$case_dir/launchagents/$label.plist" "private-nm-agent-forced: plist removed"
  assert_present "$case_dir/state/task-x1.meta" "private-nm-agent-forced: task record removed"
  assert_present "$case_dir/wt" "private-nm-agent-forced: task copy removed"
  pass "a forced teardown still refuses an in-copy agent no record proves the task's"
}

# A symlinked plist is read through its target: one whose agent is rooted in
# the copy refuses like any in-copy agent, and one whose target cannot be read
# or parsed refuses too, never skipped silently. Nothing is booted out or moved.
test_symlinked_nm_launch_agent_plist_is_judged_through_its_target() {
  local shape case_dir rc label wt
  for shape in in-copy mismatched dangling; do
    case_dir=$(make_case "symlinked-nm-agent-$shape")
    write_meta "$case_dir" no-mistakes ship
    land_shippable_commit "$case_dir"
    add_fake_launchctl "$case_dir"
    wt=$(cd "$case_dir/wt" && pwd -P)
    label="$NM_AGENT_PREFIX.5e11a1ed"
    mkdir -p "$case_dir/launchagents" "$case_dir/plist-store"
    if [ "$shape" = in-copy ] || [ "$shape" = mismatched ]; then
      add_nm_launch_agent "$case_dir" 5e11a1ed "$wt/.no-mistakes/h"
      mv "$case_dir/launchagents/$label.plist" "$case_dir/plist-store/$label.plist"
      # The mismatched link's name names another label than its target's.
      [ "$shape" = in-copy ] || label="$NM_AGENT_PREFIX.0dd0babe"
      ln -s "$case_dir/plist-store/$NM_AGENT_PREFIX.5e11a1ed.plist" "$case_dir/launchagents/$label.plist"
      : > "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.5e11a1ed"
    else
      ln -s "$case_dir/plist-store/missing.plist" "$case_dir/launchagents/$label.plist"
    fi
    rc=0
    FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "symlinked-nm-agent-$shape: teardown must refuse: $(tail -3 "$case_dir/stderr")"
    [ -L "$case_dir/launchagents/$label.plist" ] || fail "symlinked-nm-agent-$shape: the symlinked plist was moved"
    assert_no_grep bootout "$case_dir/launchctl-calls" "symlinked-nm-agent-$shape: an agent was booted out"
    assert_absent "$case_dir/data/task-x1/launchagent-backup" "symlinked-nm-agent-$shape: something was archived"
    assert_present "$case_dir/state/task-x1.meta" "symlinked-nm-agent-$shape: the task record was removed"
    if [ "$shape" != dangling ]; then
      assert_present "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.5e11a1ed" "symlinked-nm-agent-$shape: the agent was unloaded"
      grep -Eq "REFUSED: no-mistakes launch agent $NM_AGENT_PREFIX.5e11a1ed .*no record of task-x1 proves the task created it" "$case_dir/stderr" \
        || fail "symlinked-nm-agent-$shape: the refusal did not name the agent: $(tail -3 "$case_dir/stderr")"
    else
      grep -Eq "REFUSED: no-mistakes launch agent plist .*$label.plist is a symbolic link whose target cannot be read or parsed" "$case_dir/stderr" \
        || fail "symlinked-nm-agent-dangling: the refusal did not name the link: $(tail -3 "$case_dir/stderr")"
    fi
  done
  pass "a symlinked plist is judged through its target: rooted in the copy or unreadable, it refuses with nothing booted out or moved"
}

# A plist with no loaded service is no more proven than a loaded one: moving it
# would break its owner's service at next login, so it refuses too.
test_in_copy_nm_launch_agent_not_loaded_refuses() {
  local case_dir rc label wt root hash=0
  case_dir=$(make_case private-nm-agent-unloaded)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  add_fake_launchctl "$case_dir"
  wt=$(cd "$case_dir/wt" && pwd -P)
  for root in "$wt/.no-mistakes/h" "$wt/./.no-mistakes/h" "$wt//.no-mistakes//h/" \
    "$wt/missing/../.no-mistakes/h" "$wt/missing/./h" "$wt/missing/h/.." "$wt/."; do
    hash=$((hash + 1))
    add_nm_launch_agent "$case_dir" "$hash" "$root"
  done

  rc=0
  FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "private-nm-agent-unloaded: teardown must refuse"
  for hash in 1 2 3 4 5 6 7; do
    label="$NM_AGENT_PREFIX.$hash"
    assert_present "$case_dir/launchagents/$label.plist" "private-nm-agent-unloaded: plist moved"
  done
  assert_absent "$case_dir/data/task-x1/launchagent-backup" "private-nm-agent-unloaded: a plist was archived"
  pass "an in-copy plist with no loaded service refuses with every plist left installed"
}

test_docker_differently_named_metadata_hardlinks_preserve_longer_siblings() {
  local caller separator case_dir home meta id sibling sibling_home store rc
  for caller in top-level forced-child; do
    for separator in - _; do
      case_dir=$(make_case "docker-hardlink-$caller-$separator")
      write_meta "$case_dir" local-only ship
      home="$case_dir/state"
      meta="$home/task-x1.meta"
      id=task-x1
      if [ "$caller" = forced-child ]; then
        write_meta "$case_dir" local-only secondmate
        configure_secondmate_with_tmux_children "$case_dir"
        home="$case_dir/secondmate-home/state"
        meta="$home/child-a.meta"
        id="child-a"
      fi
      fm_write_meta "$meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
        "worktree=$case_dir/missing-wt" "project=$case_dir/project" \
        "kind=ship" "mode=local-only" "spawn_gen=teardown-test-$id"
      sibling="$id${separator}v2"
      sibling_home="$case_dir/sibling-home"
      mkdir -p "$sibling_home/state" "$sibling_home/data" "$case_dir/primary-home/data"
      ln "$meta" "$sibling_home/state/$sibling.meta"
      printf -- '- mate - fixture (home: %s; scope: test; projects: project; added 2026-01-01)\n' \
        "$sibling_home" > "$case_dir/primary-home/data/secondmates.md"
      store="$case_dir/docker-store"
      : > "$store"
      docker_store_add "$store" container c-own "$id-db" "fm.task=$id" ""
      docker_store_add "$store" container c-sibling "$sibling-db" "com.docker.compose.project=longer-project" ""
      docker_store_add "$store" network n-own own-network "fm.task=$id"
      docker_store_add "$store" network n-sibling sibling-network "com.docker.compose.project=longer-project"
      docker_store_add "$store" volume own-volume "fm.task=$id"
      docker_store_add "$store" volume sibling-volume "fm.task=$sibling"
      rc=0
      FM_FAKE_DOCKER_STORE="$store" \
        run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
          > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "$caller $separator hardlink: teardown failed: $(cat "$case_dir/stderr")"
      assert_absent "$case_dir/state/task-x1.meta" "$caller $separator hardlink: owner task was not retired"
      assert_present "$sibling_home/state/$sibling.meta" "$caller $separator hardlink: foreign sibling metadata was retired"
      assert_equals "$sibling-db " "$(docker_store_names "$store" container)" \
        "$caller $separator hardlink: longer sibling container was removed or own container survived"
      assert_equals "sibling-network " "$(docker_store_names "$store" network)" \
        "$caller $separator hardlink: longer sibling network was removed or own network survived"
      assert_equals "sibling-volume " "$(docker_store_names "$store" volume)" \
        "$caller $separator hardlink: sibling volume was removed or own volume survived"
    done
  done
  pass "differently named metadata hardlinks preserve longer sibling stacks in top-level and forced-child cleanup"
}

test_teardown_retires_the_dsh_launch_state() {
  local case_dir rc wt_head
  case_dir=$(make_case dsh-launch-state)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt landed "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  mkdir -p "$case_dir/state/task-x1.dsh/g1/dsh/sessions" "$case_dir/state/task-x1.dsh/g2/dsh" "$case_dir/state/task-x2.dsh/g1"
  printf 'secret\n' > "$case_dir/state/task-x1.dsh/g2/dsh/.credentials.yaml"
  printf '{}\n' > "$case_dir/state/task-x1.dsh-session"
  printf '{}\n' > "$case_dir/state/task-x2.dsh-session"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "dsh-launch-state: teardown refused: $(cat "$case_dir/stderr")"
  [ ! -e "$case_dir/state/task-x1.dsh" ] && [ ! -e "$case_dir/state/task-x1.dsh-session" ] \
    || fail "dsh-launch-state: teardown left the task's dsh credentials copy, session logs, or binding"
  [ -d "$case_dir/state/task-x2.dsh/g1" ] && [ -f "$case_dir/state/task-x2.dsh-session" ] \
    || fail "dsh-launch-state: teardown removed another task's dsh launch state"
  pass "teardown retires the task's own dsh launch state and no other task's"
}

test_teardown_removes_the_tasks_own_docker_stacks() {
  local case_dir rc
  case_dir=$(make_docker_case docker-own-stacks)
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" \
  FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "docker-own-stacks: teardown should succeed: $(cat "$case_dir/stderr")"
  assert_equals "gre1675-throwaway-pg other-compose-1 other-db supabase_db_vernant task-x1-cache task-x1-v2-pg task-x10-pg " \
    "$(docker_store_names "$case_dir/docker-store" container)" \
    "docker-own-stacks: wrong containers remained"
  assert_equals "other_default supabase_network_vernant task-x1_shared " \
    "$(docker_store_names "$case_dir/docker-store" network)" \
    "docker-own-stacks: wrong networks remained"
  assert_equals "other-data other_pgdata supabase_db_vernant task-x1-unlabelled task-x1_beaten " \
    "$(docker_store_names "$case_dir/docker-store" volume)" \
    "docker-own-stacks: wrong volumes remained"
  assert_grep "removing Docker container(s) owned by task-x1" "$case_dir/stderr" \
    "docker-own-stacks: teardown did not say which containers it removed"
  pass "teardown removes the task's labelled, named, compose-project and worktree-compose stacks and its marker- or project-labelled volumes, and leaves every other Docker object"
}

test_docker_removal_failure_keeps_the_task_records_until_a_rerun_succeeds() {
  local case_dir rc
  case_dir=$(make_docker_case docker-rm-fails)
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
echo returned >> "$case_dir/treehouse.log"
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" FM_FAKE_DOCKER_RM_FAIL=task-x1-test-pg \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "docker-rm-fails: an owned container that survives removal must stop teardown"
  assert_grep "still present after removal: task-x1-test-pg" "$case_dir/stderr" "docker-rm-fails: the surviving container was not named"
  assert_grep "Error: cannot remove container task-x1-test-pg" "$case_dir/stderr" "docker-rm-fails: Docker's own removal error was hidden"
  assert_present "$case_dir/state/task-x1.meta" "docker-rm-fails: the task record was removed while a container survived"
  assert_absent "$case_dir/treehouse.log" "docker-rm-fails: the worktree was returned while a container survived"
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "docker-rm-fails: the rerun should finish: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "docker-rm-fails: the rerun left the task record"
  assert_equals "other_default supabase_network_vernant task-x1_shared " \
    "$(docker_store_names "$case_dir/docker-store" network)" \
    "docker-rm-fails: partial container removal lost derived network ownership on retry"
  pass "an owned container that cannot be removed stops teardown with the record kept, and a rerun finishes it"
}

test_docker_removal_error_without_a_survivor_does_not_stop_teardown() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-rm-error-no-survivor)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-own owned-container "fm.task=task-x1" ""
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_RM_ERROR_AFTER_REMOVE=1 FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "rm-error-no-survivor: a removal error with no surviving container stopped teardown: $(cat "$case_dir/stderr")"
  assert_grep 'docker rm -f -v c-own' "$case_dir/docker.log" "rm-error-no-survivor: the failing removal was not exercised"
  assert_absent "$case_dir/state/task-x1.meta" "rm-error-no-survivor: the task record was retained"
  assert_equals "" "$(docker_store_names "$store" container)" "rm-error-no-survivor: the owned container survived"
  pass "a Docker removal error that leaves no owned container does not stop teardown"
}

test_docker_failed_lane_scan_names_its_cause() {
  local case_dir home store before rc
  case_dir=$(make_case docker-lane-scan-fails)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_tmux_children "$case_dir"
  home="$case_dir/secondmate-home"
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-own owned-child "fm.task=child-a" ""
  before=$(cat "$store")
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\$*" in *'#{pane_pid}'*) if [ -f "$case_dir/pane-rows" ]; then cat "$case_dir/pane-rows"; elif [ -f "$case_dir/pane-pid" ]; then printf 'fm-task-x1\t%%1\t%s\n' "\$(cat "$case_dir/pane-pid")"; fi ;; esac
case "\${1:-}" in list-windows) if [ -f "$case_dir/pane-rows" ]; then cut -f1 "$case_dir/pane-rows" | sort -u; elif [ -f "$case_dir/pane-pid" ]; then echo fm-task-x1; fi ;; esac
case "\${1:-}" in
  kill-window|kill-pane) : > "$case_dir/lane-scan-armed" ;;
esac
exit 0
EOF
  cat > "$case_dir/fakebin/git" <<EOF
#!/usr/bin/env bash
if [ -e "$case_dir/lane-scan-armed" ] && [ "\${1:-}" = -C ] && [ "\${3:-} \${4:-}" = "worktree list" ]; then
  exit 1
fi
exec "$(command -v git)" "\$@"
EOF
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/git"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  rm -f "$case_dir/fakebin/git" "$case_dir/lane-scan-armed"
  expect_code 1 "$rc" "lane-scan-fails: an unreadable worktree registry allowed retirement"
  assert_present "$home/state/child-a.meta" "lane-scan-fails: the child record was retired"
  assert_present "$case_dir/state/task-x1.meta" "lane-scan-fails: the parent record was retired"
  assert_equals "$before" "$(cat "$store")" "lane-scan-fails: Docker state changed"
  assert_absent "$case_dir/docker.log" "lane-scan-fails: Docker ran without a lane inventory"
  assert_grep "cannot establish nested worktree lanes for child-a (worktree registration could not be read: " \
    "$case_dir/stderr" "lane-scan-fails: the refusal did not name its cause"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "lane-scan-fails: retry failed: $(cat "$case_dir/retry.stderr")"
  assert_absent "$home" "lane-scan-fails: retry retained the secondmate home"
  assert_equals "" "$(docker_store_names "$store" container)" "lane-scan-fails: retry left the owned container"
  pass "a failed lane scan before Docker cleanup names its cause and retains records until retry"
}

test_forced_teardown_retains_records_after_a_docker_removal_failure() {
  local case_dir rc
  case_dir=$(make_docker_case docker-rm-fails-forced)
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" FM_FAKE_DOCKER_RM_FAIL=task-x1-test-pg \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "docker-rm-fails-forced: --force must not bypass Docker cleanup"
  assert_present "$case_dir/state/task-x1.meta" "docker-rm-fails-forced: task identity was retired"
  assert_present "$case_dir/wt" "docker-rm-fails-forced: worktree was removed"
  assert_grep "task-x1-test-pg" "$case_dir/docker-store" "docker-rm-fails-forced: fixture did not retain the failed container"
  pass "--force retains task identity when Docker container removal fails"
}

test_stopped_docker_daemon_blocks_teardown() {
  local path retained case_dir meta id store before rc
  for path in ship scout forced-child; do
    for retained in yes no; do
      case_dir=$(make_case "docker-daemon-down-$path-$retained")
      meta="$case_dir/state/task-x1.meta"
      id=task-x1
      case "$path" in
        ship)
          write_meta "$case_dir" no-mistakes ship
          land_shippable_commit "$case_dir"
          ;;
        scout)
          write_meta "$case_dir" no-mistakes scout
          mkdir -p "$case_dir/data/task-x1"
          printf 'Delivered investigation report.\n' > "$case_dir/data/task-x1/report.md"
          ;;
        forced-child)
          write_meta "$case_dir" local-only secondmate
          configure_secondmate_with_tmux_children "$case_dir"
          meta="$case_dir/secondmate-home/state/child-a.meta"
          id="child-a"
          ;;
      esac
      [ "$retained" = no ] || printf 'docker_projects= derived\n' >> "$meta"
      store="$case_dir/docker-store"
      : > "$store"
      docker_store_add "$store" container c-own owned-container "fm.task=$id;com.docker.compose.project=derived" ""
      docker_store_add "$store" network n-own derived-network "com.docker.compose.project=derived"
      before=$(cat "$store")
      rc=0
      if [ "$path" != ship ]; then
        FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_DOWN=1 \
          run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
            > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      else
        FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_DOWN=1 \
          run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      fi
      assert_equals "$before" "$(cat "$store")" "daemon-down $path $retained: Docker state changed"
      assert_grep "warning: Docker container listing failed" "$case_dir/stderr" \
        "daemon-down $path $retained: the failed container listing was not named"
      assert_grep "Cannot connect to the Docker daemon" "$case_dir/stderr" \
        "daemon-down $path $retained: Docker's own listing error was hidden"
      if [ "$retained" = yes ]; then
        expect_code 1 "$rc" "daemon-down $path: a record with docker_projects must stop teardown"
        assert_present "$meta" "daemon-down $path: task identity was retired"
        assert_present "$case_dir/state/task-x1.meta" "daemon-down $path: top-level identity was retired"
        assert_grep "docker_projects= derived" "$meta" "daemon-down $path: retained project identities were lost"
        assert_grep "Docker could not be listed for $id" "$case_dir/stderr" \
          "daemon-down $path: the refusal did not name the unlistable daemon: $(cat "$case_dir/stderr")"
        rc=0
        if [ "$path" != ship ]; then
          FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
            > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
        else
          FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" \
            > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
        fi
        expect_code 0 "$rc" "daemon-down $path: retry with Docker running failed: $(cat "$case_dir/retry.stderr")"
        assert_absent "$meta" "daemon-down $path: retry retained task identity"
        assert_equals "" "$(docker_store_names "$store" container)" "daemon-down $path: retry left the owned container"
        assert_equals "" "$(docker_store_names "$store" network)" "daemon-down $path: retry left the derived network"
      else
        expect_code 0 "$rc" "daemon-down $path: a record without docker_projects must not stop teardown: $(cat "$case_dir/stderr")"
        assert_absent "$meta" "daemon-down $path: task identity was retained"
        assert_absent "$case_dir/state/task-x1.meta" "daemon-down $path: top-level identity was retained"
        assert_grep "Docker could not be listed for $id" "$case_dir/stderr" \
          "daemon-down $path: the skipped Docker cleanup was not reported"
        assert_grep "Docker cleanup was skipped" "$case_dir/stderr" \
          "daemon-down $path: the warning did not say cleanup was skipped"
      fi
    done
  done
  pass "a stopped Docker daemon stops ship, scout and forced-child teardown only when the task record retains docker_projects; otherwise it warns and continues"
}

test_teardown_without_a_docker_binary_skips_docker_cleanup() {
  local case_dir rc before
  case_dir=$(make_docker_case docker-absent)
  before=$(cat "$case_dir/docker-store")
  rm -f "$case_dir/fakebin/docker"
  rc=0
  FM_TEARDOWN_TEST_PATH=$(fm_test_base_path_sans "$PATH" docker) \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "docker-absent: teardown without Docker should succeed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "docker-absent: task record was not retired"
  assert_equals "$before" "$(cat "$case_dir/docker-store")" "docker-absent: Docker state changed"
  pass "a host without Docker retires task records without changing Docker state"
}

test_docker_configured_supabase_identity_vetoes_all_heuristics() {
  local case_dir store protected rc
  for protected in runtime-shared task-x1; do
    case_dir=$(make_docker_case "docker-protected-$protected")
    store="$case_dir/docker-store"
    : > "$store"
    mkdir -p "$case_dir/project/supabase"
    printf 'project_id = "%s" # shared stack\n\n[api]\nenabled = true\n' "$protected" \
      > "$case_dir/project/supabase/config.toml"
    docker_store_add "$store" container c-name task-x1-supabase-db "com.supabase.cli.project=$protected" ""
    docker_store_add "$store" container c-project task-x1-cross-project "com.docker.compose.project=task-x1;com.supabase.cli.project=$protected" ""
    docker_store_add "$store" container c-path shared-path "com.docker.compose.project=$protected;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" container c-primary task-x1-primary "com.docker.compose.project=project;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" container c-marker marked-task "fm.task=task-x1;com.supabase.cli.project=$protected" ""
    docker_store_add "$store" container c-own own-path "com.docker.compose.project=isolated;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" network n-cross cross-project "com.docker.compose.project=task-x1;com.supabase.cli.project=$protected"
    docker_store_add "$store" network n-reverse reverse-project "com.docker.compose.project=$protected;com.supabase.cli.project=task-x1"
    docker_store_add "$store" network n-marker marked-network "fm.task=task-x1;com.supabase.cli.project=$protected"
    docker_store_add "$store" volume cross-volume "com.docker.compose.project=task-x1;com.supabase.cli.project=$protected"
    docker_store_add "$store" volume reverse-volume "com.docker.compose.project=$protected;com.supabase.cli.project=task-x1"
    docker_store_add "$store" volume marked-volume "fm.task=task-x1;com.supabase.cli.project=$protected"
    rc=0
    FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "$protected: teardown failed: $(cat "$case_dir/stderr")"
    assert_equals "shared-path task-x1-cross-project task-x1-supabase-db " \
      "$(docker_store_names "$store" container)" "$protected: protected project was claimed by a heuristic"
    assert_equals "cross-project reverse-project " "$(docker_store_names "$store" network)" \
      "$protected: protected network was claimed or explicit marker was ignored"
    assert_equals "cross-volume reverse-volume " "$(docker_store_names "$store" volume)" \
      "$protected: protected volume was claimed or explicit marker was ignored"
  done
  pass "actual configured Supabase identity vetoes names, paths and either project label, but not explicit markers"
}

test_docker_unreadable_supabase_config_refuses_and_absence_proceeds() {
  local caller failure case_dir home meta id store before rc config
  for caller in top-level forced-child; do
    for failure in unreadable-file missing-file missing-parent; do
      case_dir=$(make_case "docker-config-$caller-$failure")
      write_meta "$case_dir" local-only ship
      meta="$case_dir/state/task-x1.meta"
      id=task-x1
      if [ "$caller" = forced-child ]; then
        write_meta "$case_dir" local-only secondmate
        configure_secondmate_with_tmux_children "$case_dir"
        home="$case_dir/secondmate-home"
        meta="$home/state/child-a.meta"
        id="child-a"
      fi
      mkdir -p "$case_dir/project/supabase"
      config="$case_dir/project/supabase/config.toml"
      printf 'project_id = "vernant"\n' > "$config"
      store="$case_dir/docker-store"
      : > "$store"
      docker_store_add "$store" container c-shared "$id-shared" "com.docker.compose.project=vernant" ""
      docker_store_add "$store" container c-own owned-container "fm.task=$id" ""
      docker_store_add "$store" network n-own owned-network "fm.task=$id"
      docker_store_add "$store" volume owned-volume "fm.task=$id"
      before=$(cat "$store")
      case "$failure" in
        unreadable-file)
          chmod 000 "$config"
          [ ! -r "$config" ] || fail "Supabase fixture config remains readable"
          ;;
        missing-file) rm "$config" ;;
        missing-parent) rm -rf "${config%/*}" ;;
      esac
      rc=0
      FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
        run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
          > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      case "$failure" in
        missing-file|missing-parent)
          expect_code 0 "$rc" "$caller $failure: config absence refused teardown: $(cat "$case_dir/stderr")"
          assert_absent "$meta" "$caller $failure: task record was retained"
          assert_equals "" "$(docker_store_names "$store" container)" "$caller $failure: owned containers survived"
          ;;
        *)
          chmod 644 "$config"
          expect_code 1 "$rc" "$caller $failure: uncertain Supabase protection permitted teardown"
          assert_present "$meta" "$caller $failure: task record was retired"
          assert_present "$case_dir/state/task-x1.meta" "$caller $failure: parent record was retired"
          assert_equals "$before" "$(cat "$store")" "$caller $failure: Docker resources changed"
          assert_absent "$case_dir/docker.log" "$caller $failure: Docker ran before establishing Supabase protection"
          assert_grep "cannot identify the shared Supabase stack for $id" \
            "$case_dir/stderr" "$caller $failure: unreadable config was not exercised"
          rc=0
          FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
            > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
          expect_code 0 "$rc" "$caller $failure: retry failed: $(cat "$case_dir/retry.stderr")"
          assert_absent "$meta" "$caller $failure: retry retained task record"
          assert_equals "$id-shared " "$(docker_store_names "$store" container)" \
            "$caller $failure: retry removed the protected stack or retained owned containers"
          ;;
      esac
      assert_equals "" "$(docker_store_names "$store" network)" "$caller $failure: owned network survived"
      assert_equals "" "$(docker_store_names "$store" volume)" "$caller $failure: owned volume survived"
    done
  done
  pass "Supabase protection refuses an unreadable config, preserves the shared stack on retry, and permits an absent config"
}

test_docker_project_labels_require_the_exact_task_id() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-exact-project)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-compose exact-compose "com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-supabase exact-supabase "com.supabase.cli.project=task-x1" ""
  docker_store_add "$store" container c-prefix prefixed-compose "com.docker.compose.project=task-x1-stack" ""
  docker_store_add "$store" container c-prefix2 prefixed-supabase "com.supabase.cli.project=task-x1_stack" ""
  docker_store_add "$store" container c-name task-x1-db "" ""
  docker_store_add "$store" container c-exact-name task-x1 "" ""
  docker_store_add "$store" container c-name2 task-x1_cache "" ""
  docker_store_add "$store" container c-sibling task-x1-v2-db "" ""
  docker_store_add "$store" network n-compose exact-compose "com.docker.compose.project=task-x1"
  docker_store_add "$store" network n-supabase exact-supabase "com.supabase.cli.project=task-x1"
  docker_store_add "$store" network n-prefix prefixed-compose "com.docker.compose.project=task-x1-stack"
  docker_store_add "$store" network n-prefix2 prefixed-supabase "com.supabase.cli.project=task-x1_stack"
  docker_store_add "$store" volume exact-compose "com.docker.compose.project=task-x1"
  docker_store_add "$store" volume exact-supabase "com.supabase.cli.project=task-x1"
  docker_store_add "$store" volume prefixed-compose "com.docker.compose.project=task-x1-stack"
  docker_store_add "$store" volume prefixed-supabase "com.supabase.cli.project=task-x1_stack"
  docker_store_add "$store" volume task-x1-named ""
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "exact-project: teardown failed: $(cat "$case_dir/stderr")"
  assert_equals "prefixed-compose prefixed-supabase task-x1-v2-db " "$(docker_store_names "$store" container)" \
    "exact-project: project prefixes or live sibling names were claimed"
  assert_equals "prefixed-compose prefixed-supabase " "$(docker_store_names "$store" network)" \
    "exact-project: project prefix network was claimed"
  assert_equals "prefixed-compose prefixed-supabase task-x1-named " "$(docker_store_names "$store" volume)" \
    "exact-project: a volume was claimed by a project prefix or its name, or an exact project volume survived"
  pass "project labels match only the exact id for containers, networks and volumes while container names retain boundary and live-sibling rules"
}

test_docker_workdirs_canonicalize_and_exclude_foreign_lanes_and_tasktmp() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-canonical-paths)
  store="$case_dir/docker-store"
  : > "$store"
  mkdir -p "$case_dir/wt/own-stack" "$case_dir/tasktmp/stack" "$case_dir/foreign/stack"
  git -C "$case_dir/project" worktree add -q --detach "$case_dir/wt/git-lane" main
  git -C "$case_dir/project" worktree add -q --detach "$case_dir/wt/registered-lane" main
  git -C "$case_dir/project" worktree lock "$case_dir/wt/registered-lane"
  rm -f "$case_dir/wt/registered-lane/.git"
  ln -s "$case_dir/wt" "$case_dir/wt-alias"
  ln -s "$case_dir/foreign" "$case_dir/wt/foreign-link"
  ln -s "$case_dir/wt/git-lane" "$case_dir/git-alias"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$case_dir/wt-alias" \
    "project=$case_dir/project" "kind=ship" "mode=no-mistakes" \
    "tasktmp=$case_dir/tasktmp" "spawn_gen=teardown-test-task-x1"
  fm_write_meta "$case_dir/state/foreign-lane.meta" "kind=ship" "worktree=$case_dir/wt/registered-lane"
  docker_store_add "$store" container c-own own-real-path "com.docker.compose.project.working_dir=$case_dir/wt/own-stack" ""
  docker_store_add "$store" container c-alias own-alias-path "com.docker.compose.project.working_dir=$case_dir/wt-alias/own-stack" ""
  docker_store_add "$store" container c-git nested-git-path "com.docker.compose.project.working_dir=$case_dir/git-alias" ""
  docker_store_add "$store" container c-reg nested-record-path "com.docker.compose.project.working_dir=$case_dir/wt-alias/registered-lane" ""
  docker_store_add "$store" container c-foreign symlink-foreign "com.docker.compose.project.working_dir=$case_dir/wt/foreign-link/stack" ""
  docker_store_add "$store" container c-tmp temporary-path "com.docker.compose.project.working_dir=$case_dir/tasktmp/stack" ""
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  # The nested lanes are registered copies this task has not proven, so the
  # forced return refuses them after the Docker sweep and keeps them.
  expect_code 1 "$rc" "canonical-paths: unproven nested copies must stop the return: $(cat "$case_dir/stderr")"
  assert_grep "contains registered copy $case_dir/wt/git-lane" "$case_dir/stderr" "canonical-paths: custody refusal omitted the nested Git worktree"
  assert_equals "nested-git-path nested-record-path symlink-foreign temporary-path " "$(docker_store_names "$store" container)" \
    "canonical-paths: canonical custody or worktree-only boundary was ignored"
  assert_present "$case_dir/state/foreign-lane.meta" "canonical-paths: foreign task record was removed"
  assert_present "$case_dir/wt/git-lane" "canonical-paths: nested Git worktree was removed"
  pass "Docker workdir ownership canonicalizes both sides and excludes nested lanes, foreign symlinks and task temp roots"
}

test_docker_mixed_project_carriers_spare_empty_heuristic_networks() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-mixed-networks)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-task own-exact "fm.task=task-x1;com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-other foreign-exact "fm.task=other;com.supabase.cli.project=task-x1" ""
  docker_store_add "$store" container c-derived own-derived "com.docker.compose.project=derived;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" container c-foreign foreign-derived "com.supabase.cli.project=derived" ""
  docker_store_add "$store" container c-all own-dual "com.docker.compose.project=all-owned;com.supabase.cli.project=all-owned-supa;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" network n-exact empty-exact "com.docker.compose.project=task-x1"
  docker_store_add "$store" network n-exact-supa empty-exact-supa "com.supabase.cli.project=task-x1"
  docker_store_add "$store" network n-derived empty-derived "com.docker.compose.project=derived"
  docker_store_add "$store" network n-derived-supa empty-derived-supa "com.supabase.cli.project=derived"
  docker_store_add "$store" network n-owned all-owned-net "com.docker.compose.project=all-owned"
  docker_store_add "$store" network n-owned-supa all-owned-supa-net "com.supabase.cli.project=all-owned-supa"
  docker_store_add "$store" network n-explicit explicit-mixed "fm.task=task-x1;com.docker.compose.project=task-x1"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "mixed-networks: teardown failed: $(cat "$case_dir/stderr")"
  assert_equals "foreign-derived foreign-exact " "$(docker_store_names "$store" container)" \
    "mixed-networks: wrong project carriers were removed"
  assert_equals "all-owned-supa-net empty-derived empty-derived-supa empty-exact empty-exact-supa " "$(docker_store_names "$store" network)" \
    "mixed-networks: foreign project label did not veto an empty heuristic network or all-owned propagation failed"
  pass "foreign project carriers veto empty heuristic networks, all-owned projects propagate and explicit markers remain authoritative"
}

test_docker_latest_foreign_carriers_veto_network_removal() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-latest-carriers)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-exact own-exact "fm.task=task-x1;com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-derived own-derived "com.docker.compose.project=derived;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$case_dir/arriving-containers" container c-foreign arriving-foreign \
    "fm.task=other;com.docker.compose.project=task-x1;com.supabase.cli.project=derived" ""
  docker_store_add "$store" network n-exact exact-compose "com.docker.compose.project=task-x1"
  docker_store_add "$store" network n-supa exact-supabase "com.supabase.cli.project=task-x1"
  docker_store_add "$store" network n-derived derived-compose "com.docker.compose.project=derived"
  docker_store_add "$store" network n-derived-supa derived-supabase "com.supabase.cli.project=derived"
  docker_store_add "$store" network n-marked explicitly-owned "fm.task=task-x1;com.docker.compose.project=derived"
  docker_store_add "$store" volume exact-volume "com.docker.compose.project=task-x1"
  docker_store_add "$store" volume marked-volume "fm.task=task-x1;com.docker.compose.project=task-x1"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_ADD_AFTER_RM="$case_dir/arriving-containers" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "latest-carriers: teardown failed: $(cat "$case_dir/stderr")"
  assert_equals "arriving-foreign " "$(docker_store_names "$store" container)" \
    "latest-carriers: foreign carrier was removed"
  assert_equals "derived-compose derived-supabase exact-compose exact-supabase " "$(docker_store_names "$store" network)" \
    "latest-carriers: latest foreign evidence was ignored or explicit marker was vetoed"
  assert_equals "exact-volume " "$(docker_store_names "$store" volume)" \
    "latest-carriers: a foreign carrier did not veto the project-label volume or the explicit marker was vetoed"
  pass "foreign carriers observed after container removal veto both project-label heuristics but not explicit network markers"
}

# Retiring a secondmate whose own registered home is already gone must not be
# refused by the custody scan's walk over that same home: nothing there can be
# lost. Any other registered home that cannot be read still refuses, with or
# without --force.
test_secondmate_retirement_exempts_only_its_own_missing_home() {
  local case_dir shape rc gone
  for shape in own other; do
    case_dir=$(make_case "secondmate-missing-home-$shape")
    gone="$case_dir-gone"
    write_meta "$case_dir" local-only secondmate
    printf 'home=%s\ntasktmp=%s\n' "$gone/secondmate-home" "$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
    mkdir -p "$case_dir/tasktmp"
    printf -- '- task-x1 - task-x1 (home: %s; scope: fixture; projects: P; added 2026-10-08)\n' \
      "$gone/secondmate-home" > "$case_dir/data/secondmates.md"
    rc=0
    if [ "$shape" = own ]; then
      FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "missing-home-own: retiring a secondmate whose own home is gone must succeed: $(cat "$case_dir/stderr")"
      assert_absent "$case_dir/state/task-x1.meta" "missing-home-own: the record was not retired"
      continue
    fi
    printf -- '- ghost - ghost (home: %s; scope: fixture; projects: P; added 2026-10-08)\n' \
      "$gone/ghost-home" >> "$case_dir/data/secondmates.md"
    FM_HOME="$case_dir" run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "missing-home-other: another unreadable registered home must still refuse"
    assert_grep "registered local Firstmate home is unavailable: $gone/ghost-home" "$case_dir/stderr" \
      "missing-home-other: the refusal did not name the other home"
    assert_present "$case_dir/state/task-x1.meta" "missing-home-other: the refusal retired the record"
  done
  pass "secondmate retirement exempts only its own missing home from the custody walk"
}

# A stored preservation bundle can be the only copy of unlanded commits, so
# retiring the home that keeps it, forced or not, refuses before any removal,
# including a forced retirement's child cleanup, until the bundle has left it.
test_secondmate_retirement_keeps_stored_preservation_bundles() {
  local case_dir posture home bundle moved rc child_wt
  for posture in ordinary forced; do
    case_dir=$(make_case "secondmate-stored-bundle-$posture")
    write_meta "$case_dir" local-only secondmate
    home="$case_dir/secondmate-home"
    mkdir -p "$home/state"
    printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
    printf 'home=%s\n' "$home" >> "$case_dir/state/task-x1.meta"
    bundle="$home/data/child-a/preserved-bundles/$(printf 'ab%.0s' {1..32}).bundle"
    mkdir -p "${bundle%/*}"
    printf 'only copy of unlanded commits\n' > "$bundle"
    child_wt="$case_dir/child-a-wt"
    if [ "$posture" = forced ]; then
      git -C "$case_dir/project" worktree add -q -b fm/child-a "$child_wt" main
      fm_write_meta "$home/state/child-a.meta" "window=firstmate:fm-child-a" "endpoint_task_id=child-a" \
        "worktree=$child_wt" "project=$case_dir/project" "kind=ship" "mode=local-only"
      : > "$home/state/child-a.status"
    fi
    rc=0
    if [ "$posture" = forced ]; then
      run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    expect_code 1 "$rc" "$posture stored-bundle: retirement must refuse while the home keeps a stored bundle"
    assert_grep "REFUSED: secondmate home $home holds bundle-preserved commits" "$case_dir/stderr" \
      "$posture stored-bundle: the refusal did not name the home: $(cat "$case_dir/stderr")"
    assert_grep "  $bundle" "$case_dir/stderr" "$posture stored-bundle: the refusal did not list the stored bundle"
    assert_grep 'move it to a durable location outside this home' "$case_dir/stderr" \
      "$posture stored-bundle: the refusal did not name the completing step"
    assert_equals 'only copy of unlanded commits' "$(cat "$bundle")" "$posture stored-bundle: the stored bundle was lost"
    assert_present "$home/.fm-secondmate-home" "$posture stored-bundle: the home was removed"
    assert_present "$case_dir/state/task-x1.meta" "$posture stored-bundle: the record was retired"
    if [ "$posture" = forced ]; then
      assert_present "$home/state/child-a.meta" "forced stored-bundle: the refusal came after the child was retired"
      assert_present "$child_wt/.git" "forced stored-bundle: the refusal came after the child copy was removed"
    fi
    moved="$case_dir/durable/${bundle##*/}"
    mkdir -p "${moved%/*}"
    mv "$bundle" "$moved"
    rc=0
    if [ "$posture" = forced ]; then
      run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
    else
      run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
    fi
    expect_code 0 "$rc" "$posture stored-bundle: retirement after moving the bundle must succeed: $(cat "$case_dir/stderr2")"
    assert_absent "$home" "$posture stored-bundle: the home was not retired"
    assert_equals 'only copy of unlanded commits' "$(cat "$moved")" "$posture stored-bundle: the moved bundle was lost"
  done
  pass "retiring a home that keeps a stored preservation bundle refuses until the bundle leaves it"
}

test_standalone_secondmate_skips_docker_cleanup() {
  local case_dir posture rc
  for posture in ordinary forced; do
    case_dir=$(make_case "docker-secondmate-$posture")
    write_meta "$case_dir" local-only secondmate
    mkdir -p "$case_dir/secondmate-home/state"
    printf '%s\n' task-x1 > "$case_dir/secondmate-home/.fm-secondmate-home"
    printf 'home=%s\n' "$case_dir/secondmate-home" >> "$case_dir/state/task-x1.meta"
    rc=0
    if [ "$posture" = forced ]; then
      FM_FAKE_DOCKER_DOWN=1 FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
        run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      FM_FAKE_DOCKER_DOWN=1 FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
        run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    expect_code 0 "$rc" "$posture secondmate: teardown failed: $(cat "$case_dir/stderr")"
    assert_absent "$case_dir/state/task-x1.meta" "$posture secondmate: supervisor record was not retired"
    assert_absent "$case_dir/secondmate-home" "$posture secondmate: supervisor home was not removed"
    assert_absent "$case_dir/docker.log" "$posture secondmate: standalone retirement contacted Docker"
  done
  pass "standalone secondmate retirement skips Docker even when the daemon is unavailable"
}

test_docker_project_record_failure_prevents_container_removal() {
  local case_dir store rc before
  case_dir=$(make_docker_case docker-project-record-failure)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-own own-derived "com.docker.compose.project=derived;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" network n-own derived-network "com.docker.compose.project=derived"
  before=$(cat "$case_dir/state/task-x1.meta")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$case_dir/fakebin/mv"
  chmod +x "$case_dir/fakebin/mv"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 0 "" "$2" "$3"' \
      _ "$ROOT" "$case_dir/state/task-x1.meta" "$case_dir/wt" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "project-record-failure: cleanup ignored failed record publication"
  assert_equals "$before" "$(cat "$case_dir/state/task-x1.meta")" \
    "project-record-failure: existing task metadata was changed"
  assert_equals "own-derived " "$(docker_store_names "$store" container)" \
    "project-record-failure: container was removed before its project identity was retained"
  assert_equals "derived-network " "$(docker_store_names "$store" network)" \
    "project-record-failure: network was removed after record failure"
  pass "failed project-identity publication preserves the task record and container evidence"
}

test_docker_verified_cleanup_clears_retained_projects() {
  local case_dir store meta rc
  case_dir=$(make_docker_case docker-clears-projects)
  store="$case_dir/docker-store"
  meta="$case_dir/state/task-x1.meta"
  : > "$store"
  docker_store_add "$store" container c-own own-derived "com.docker.compose.project=derived;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" network n-own derived-network "com.docker.compose.project=derived"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_NETWORK_RM_FAIL=derived-network PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 0 "" "$2" "$3"' \
      _ "$ROOT" "$meta" "$case_dir/wt" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "clears-projects: a failed network removal reported success"
  assert_grep 'docker_projects= derived' "$meta" "clears-projects: an incomplete cleanup did not retain project identities"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 0 "" "$2" "$3"' \
      _ "$ROOT" "$meta" "$case_dir/wt" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "clears-projects: verified cleanup failed: $(cat "$case_dir/stderr")"
  assert_equals "" "$(docker_store_names "$store" network)" "clears-projects: derived network survived"
  assert_no_grep 'docker_projects=' "$meta" "clears-projects: verified cleanup left retained project identities"
  assert_grep 'kind=ship' "$meta" "clears-projects: clearing project identities damaged the task record"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_DOWN=1 PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 0 "" "$2" "$3"' \
      _ "$ROOT" "$meta" "$case_dir/wt" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "clears-projects: a stopped daemon refused a task whose cleanup was already verified: $(cat "$case_dir/stderr")"
  pass "a verified Docker cleanup clears retained project identities, so a later stopped daemon does not refuse the retry"
}

test_docker_ambiguous_ids_trust_only_worktree_evidence() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-ambiguous-id)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-name task-x1-db "" ""
  docker_store_add "$store" container c-label marked-only "fm.task=task-x1" ""
  docker_store_add "$store" container c-project exact-project "com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-path own-worktree "com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" network n-label marked-network "fm.task=task-x1"
  docker_store_add "$store" volume marked-volume "fm.task=task-x1"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 1 "" "$2" "$3"' \
      _ "$ROOT" "$case_dir/state/task-x1.meta" "$case_dir/wt" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "ambiguous-id: cleanup failed: $(cat "$case_dir/stderr")"
  assert_equals "exact-project marked-only task-x1-db " "$(docker_store_names "$store" container)" \
    "ambiguous-id: ambiguous identity authorized removal"
  assert_equals "marked-network " "$(docker_store_names "$store" network)" "ambiguous-id: ambiguous network marker was trusted"
  assert_equals "marked-volume " "$(docker_store_names "$store" volume)" "ambiguous-id: ambiguous volume marker was trusted"
  pass "ambiguous task ids authorize only worktree evidence"
}

test_docker_all_failure_channels_retain_forced_tasks_until_retry() {
  local channel case_dir store rc fail_operation ps_fail network_fail volume_fail
  for channel in verify-ps final-ps container-rm network-ls volume-ls network-rm volume-rm; do
    case_dir=$(make_docker_case "docker-failure-$channel")
    store="$case_dir/docker-store"
    : > "$store"
    : > "$case_dir/state/task-x1.status"
    docker_store_add "$store" container c-own owned-container "com.docker.compose.project=derived;com.supabase.cli.project=derived-supa;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" network n-own owned-network "com.docker.compose.project=derived"
    docker_store_add "$store" network n-supa owned-supa-project-network "com.docker.compose.project=derived-supa"
    docker_store_add "$store" volume owned-volume "fm.task=task-x1"
    cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf '%s\n' returned >> "$case_dir/retired"
EOF
    chmod +x "$case_dir/fakebin/treehouse"
    fail_operation='' ps_fail='' network_fail='' volume_fail=''
    case "$channel" in
      verify-ps) ps_fail=2 ;;
      final-ps) ps_fail=3 ;;
      container-rm) fail_operation='rm' ;;
      network-ls) fail_operation=network-ls ;;
      volume-ls) fail_operation=volume-ls ;;
      network-rm) network_fail=owned-network ;;
      volume-rm) volume_fail=owned-volume ;;
    esac
    rc=0
    FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_FAIL="$fail_operation" \
      FM_FAKE_DOCKER_PS_FAIL_AT="$ps_fail" \
      FM_FAKE_DOCKER_NETWORK_RM_FAIL="$network_fail" FM_FAKE_DOCKER_VOLUME_RM_FAIL="$volume_fail" \
      run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$channel: --force bypassed Docker failure"
    assert_present "$case_dir/state/task-x1.meta" "$channel: task metadata was removed"
    assert_present "$case_dir/state/task-x1.status" "$channel: task status was removed"
    assert_present "$case_dir/wt" "$channel: worktree was removed"
    assert_absent "$case_dir/retired" "$channel: worktree return ran before confirmed Docker cleanup"
    assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" "$channel: teardown falsely reported completion"
    assert_grep 'docker_projects= derived derived-supa' "$case_dir/state/task-x1.meta" \
      "$channel: retained task record lost its derived project identities"
    case "$channel" in
      verify-ps|final-ps)
        assert_grep "warning: Docker container listing failed" "$case_dir/stderr" \
          "$channel: the failed container listing was not named"
        assert_grep "fake docker: ps failed" "$case_dir/stderr" \
          "$channel: Docker's own container listing error was hidden"
        ;;
      network-ls|volume-ls)
        assert_grep "warning: Docker ${channel%-ls} listing failed" "$case_dir/stderr" \
          "$channel: the failed listing was not named"
        assert_grep "fake docker: $channel failed" "$case_dir/stderr" \
          "$channel: Docker's own listing error was hidden"
        ;;
      network-rm)
        assert_grep "Error: cannot remove network owned-network" "$case_dir/stderr" \
          "$channel: Docker's own network removal error was hidden"
        ;;
      volume-rm)
        assert_grep "Error: cannot remove volume owned-volume" "$case_dir/stderr" \
          "$channel: Docker's own volume removal error was hidden"
        ;;
    esac
    if [ "$channel" = network-rm ]; then
      assert_equals "" "$(docker_store_names "$store" container)" "$channel: regression requires container removal to succeed"
      assert_equals "owned-network owned-supa-project-network " "$(docker_store_names "$store" network)" \
        "$channel: regression requires derived networks to survive the first attempt"
    fi
    rc=0
    FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
      > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
    expect_code 0 "$rc" "$channel: retry failed: $(cat "$case_dir/retry.stderr")"
    assert_absent "$case_dir/state/task-x1.meta" "$channel: retry did not retire metadata"
    assert_equals "" "$(docker_store_names "$store" container)" "$channel: owned container survived retry"
    assert_equals "" "$(docker_store_names "$store" network)" "$channel: owned network survived retry"
    assert_equals "" "$(docker_store_names "$store" volume)" "$channel: owned volume survived retry"
  done
  pass "every Docker listing, verification and removal failure retains forced task records until a successful retry"
}

test_top_level_pipeline_discovery_failures_remain_best_effort() {
  local case_dir failure rc advanced out
  for failure in status ledger; do
    case_dir=$(make_case "top-level-query-$failure")
    write_meta "$case_dir" no-mistakes ship
    land_shippable_commit "$case_dir"
    advanced=$(make_unfetched_pipeline_heads "$case_dir")
    out=$(parked_axi_status_toon fm/task-x1 "$advanced")
    rc=0
    FM_FAKE_AXI_STATUS="$out" FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
      FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
      FM_FAKE_NM_STATUS_FAIL="$([ "$failure" != status ] || printf 1)" \
      FM_FAKE_NM_RUNS_FAIL="$([ "$failure" != ledger ] || printf 1)" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "top-level $failure query failure blocked teardown"
    assert_absent "$case_dir/state/task-x1.meta" "top-level $failure failure retained task"
    assert_absent "$case_dir/nm-abort.log" "top-level $failure failure authorized an abort"
    if [ "$failure" = ledger ]; then
      assert_present "$case_dir/nm-runs.log" "top-level ledger failure was not exercised"
    fi
  done
  pass "top-level status and ledger query failures remain best effort"
}

test_forced_secondmate_cleans_each_child_docker_before_retirement_and_retries() {
  assert_forced_child_docker_cleanup_and_retry tmux
  pass "forced secondmate closes each child endpoint before its Docker cleanup and retains failures for retry"
}

test_forced_orca_children_clean_docker_before_worktree_removal() {
  assert_forced_child_docker_cleanup_and_retry orca
  pass "forced Orca children clean Docker before worktree removal and retain identity and worktrees on failure"
}

test_forced_nested_secondmate_cleans_grandchild_docker_before_retirement_and_retries() {
  local case_dir home nested_home grandchild_wt store rc
  case_dir=$(make_case docker-grandchild)
  write_meta "$case_dir" local-only secondmate
  grandchild_wt="$case_dir/grandchild-herdr-wt"
  git -C "$case_dir/project" worktree add -q -b fm/grandchild-herdr "$grandchild_wt" main
  configure_nested_secondmate_with_herdr_grandchild "$case_dir" "$grandchild_wt"
  home="$case_dir/secondmate-home"
  nested_home="$home/nested-home"
  store="$case_dir/docker-store"
  configure_child_docker_race "$case_dir"
  : > "$case_dir/child-producers/grandchild-herdr.live"
  printf '%s\n' grandchild-herdr > "$case_dir/current-child"
  : > "$store"
  docker_store_add "$store" container c-grandchild owned-grandchild "fm.task=grandchild-herdr" ""
  docker_store_add "$store" container c-path grandchild-path "com.docker.compose.project.working_dir=$grandchild_wt" ""
  docker_store_add "$store" container c-foreign foreign-grandchild "fm.task=other" ""
  docker_store_add "$store" network n-grandchild grandchild-network "fm.task=grandchild-herdr"
  docker_store_add "$store" volume grandchild-volume "fm.task=grandchild-herdr"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_RM_FAIL=owned-grandchild FM_FAKE_HERDR_CONFIRMED_GONE=1 \
    FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "grandchild: Docker failure must stop recursive retirement"
  assert_present "$case_dir/state/task-x1.meta" "grandchild: parent identity retired"
  assert_present "$home/state/nested-sm.meta" "grandchild: nested secondmate identity retired"
  assert_present "$nested_home/state/grandchild-herdr.meta" "grandchild: grandchild identity retired"
  assert_present "$nested_home/state/grandchild-herdr.status" "grandchild: grandchild status retired"
  assert_present "$nested_home" "grandchild: nested home removed"
  assert_present "$case_dir/closed" "grandchild: endpoint was not closed before Docker cleanup"
  assert_equals "foreign-grandchild owned-grandchild " "$(docker_store_names "$store" container)" \
    "grandchild: containers produced before the endpoint closed survived the cleanup attempt"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_HERDR_CONFIRMED_GONE=1 \
    FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "grandchild: retry failed: $(cat "$case_dir/retry.stderr")"
  assert_absent "$home" "grandchild: retry retained secondmate homes"
  assert_absent "$case_dir/state/task-x1.meta" "grandchild: retry retained parent record"
  assert_equals "foreign-grandchild " "$(docker_store_names "$store" container)" "grandchild: wrong Docker objects survived"
  assert_equals "" "$(docker_store_names "$store" network)" "grandchild: network survived"
  assert_equals "" "$(docker_store_names "$store" volume)" "grandchild: volume survived"
  pass "recursive forced secondmate cleanup closes the grandchild endpoint before Docker cleanup and retains failed identity for retry"
}

test_docker_container_arriving_during_resource_cleanup_blocks_retirement() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-late-container)
  store="$case_dir/docker-store"
  configure_child_docker_race "$case_dir"
  : > "$store"
  docker_store_add "$store" container c-own owned-container "fm.task=task-x1" ""
  docker_store_add "$case_dir/arriving-containers" container c-late arriving-container "fm.task=task-x1" ""
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "late-container: cleanup falsely reported success"
  assert_present "$case_dir/state/task-x1.meta" "late-container: retry identity was retired"
  assert_present "$case_dir/wt" "late-container: worktree was retired"
  assert_equals "arriving-container " "$(docker_store_names "$store" container)" "late-container: arrival was not exercised"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "late-container: retry failed: $(cat "$case_dir/retry.stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "late-container: retry retained identity"
  assert_equals "" "$(docker_store_names "$store" container)" "late-container: owned arrival survived retry"
  pass "a container arriving during network cleanup blocks retirement until retry removes it"
}

test_missing_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-startup-source"
  pass "a missing teardown startup source refuses before cleanup"
}

test_unreadable_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case unreadable-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  cp "$ROOT/bin/fm-nm-run-lib.sh" "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  chmod 000 "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  if [ -r "$case_dir/test-root/bin/fm-nm-run-lib.sh" ]; then
    pass "unreadable startup source skipped: this user can read mode-000 files"
    return 0
  fi
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "unreadable-startup-source"
  pass "an unreadable teardown startup source refuses before cleanup"
}

test_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-adapter-sibling)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-session-lock-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-adapter-sibling"
  pass "a missing adapter sibling refuses before cleanup"
}

test_forced_child_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir home rc log closed
  case_dir=$(make_case missing-child-adapter-sibling)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  prepare_teardown_source_copy "$case_dir"
  log="$case_dir/herdr.log"
  closed="$case_dir/closed"
  : > "$log"
  rm -f "$case_dir/test-root/bin/fm-transition-lib.sh"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-child-source"
  [ ! -s "$log" ] || fail "missing-child-source: teardown reached the child's runtime with its required source missing"
  [ -e "$home/state/child-herdr.meta" ] || fail "missing-child-source: the refusal erased the child record"
  [ -d "$home" ] || fail "missing-child-source: the refusal removed the secondmate home"
  ln -s "$ROOT/bin/fm-transition-lib.sh" "$case_dir/test-root/bin/fm-transition-lib.sh"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_copied_teardown "$case_dir" --force > "$case_dir/restored.stdout" 2> "$case_dir/restored.stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "restored-child-source: teardown ignored the unresolvable child runtime"
  [ -s "$log" ] || fail "restored-child-source: the valid fixture never reached child runtime admission: $(cat "$case_dir/restored.stderr")"
  assert_source_refusal_preserved_state "$case_dir" "restored-child-source"
  [ -e "$home/state/child-herdr.meta" ] || fail "restored-child-source: the refusal erased the child record"
  [ ! -e "$closed" ] || fail "restored-child-source: refusal attempted a child close"
  pass "a forced descendant with a missing adapter sibling refuses before cleanup"
}

test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup() {
  local case_dir home rc
  case_dir=$(make_case missing-own-adapter-sibling)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=zs:3" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "backend=zellij" \
    "zellij_session=zs" \
    "zellij_tab_id=1" \
    "zellij_pane_id=3" \
    "spawn_gen=teardown-test-task-x1"
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-tmux.meta" \
    "window=childsession:fm-child-tmux" \
    "endpoint_task_id=child-tmux" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  : > "$home/state/child-tmux.status"
  prepare_teardown_source_copy "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in *'#{pane_pid}'*) if [ -f "$case_dir/pane-rows" ]; then cat "$case_dir/pane-rows"; elif [ -f "$case_dir/pane-pid" ]; then printf 'fm-task-x1\t%%1\t%s\n' "\$(cat "$case_dir/pane-pid")"; fi ;; esac
case "\${1:-}" in list-windows) if [ -f "$case_dir/pane-rows" ]; then cut -f1 "$case_dir/pane-rows" | sort -u; elif [ -f "$case_dir/pane-pid" ]; then echo fm-task-x1; fi ;; esac
printf '%s\n' "\$*" >> "$case_dir/tmux.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  : > "$case_dir/tmux.log"
  rm -f "$case_dir/test-root/bin/fm-backend-hometag-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-own-source"
  [ -e "$home/state/child-tmux.meta" ] || fail "missing-own-source: the refusal erased the child record"
  [ -e "$home/state/child-tmux.status" ] || fail "missing-own-source: the refusal erased the child status"
  [ -d "$home" ] || fail "missing-own-source: the refusal removed the secondmate home"
  if grep -q "kill" "$case_dir/tmux.log"; then
    fail "missing-own-source: the refusal killed the child endpoint: $(cat "$case_dir/tmux.log")"
  fi
  pass "a forced secondmate with a missing own adapter sibling refuses before child cleanup"
}

test_retained_sources_still_reach_the_ordinary_refusal() {
  local case_dir rc
  case_dir=$(make_case retained-sources)
  prepare_teardown_source_copy "$case_dir"
  rc=0
  FM_HOME="${FM_HOME:-$case_dir/primary-home}" \
  FM_ROOT_OVERRIDE="$case_dir/test-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/fm-teardown.sh" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 2 ] || fail "retained-sources: a present source tree should still reject a request with no task id (rc=$rc)"
  assert_grep "invalid teardown request" "$case_dir/stderr" \
    "retained-sources: the ordinary refusal was replaced"
  pass "present required sources still reach the ordinary teardown refusal"
}

test_task_teardown_preserves_another_homes_abandoned_worker() {
  local case_dir foreign_root pid rc
  case_dir=$(make_case caller-confined-reaping)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  prepare_teardown_source_copy "$case_dir"
  foreign_root="$case_dir/other-home"
  mkdir -p "$foreign_root/bin"
  cat > "$foreign_root/bin/fm-remote-job-worker.sh" <<'SH'
#!/usr/bin/env bash
trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit' TERM
sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS" &
child=$!
printf '%s\n' ready > "$FM_FOREIGN_WORKER_READY"
wait "$child"
SH
  teardown_fixture_start "$case_dir" TERM env FM_FOREIGN_WORKER_READY="$case_dir/foreign-ready" \
    perl -e 'setpgrp(0, 0); exec @ARGV' \
    "$BASH" "$foreign_root/bin/fm-remote-job-worker.sh" --serve
  pid=$TEARDOWN_FIXTURE_PID
  local tries=0
  while [ ! -e "$case_dir/foreign-ready" ] && [ "$tries" -lt 100 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  if [ ! -e "$case_dir/foreign-ready" ]; then
    fail "caller-confinement: foreign worker did not start"
  fi
  rm -rf "$foreign_root"

  # Bound the administrative reaper's account scan to our one real fixture
  # process, never any actual account worker. Other ps queries stay native.
  cat > "$case_dir/fakebin/ps" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -u ]; then
  exec "$REAL_PS_FOR_TEST" -p "$pid" -o pid=,command=
fi
exec "$REAL_PS_FOR_TEST" "\$@"
SH
  chmod +x "$case_dir/fakebin/ps"
  rc=0
  run_copied_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "caller-confinement: task teardown killed another home's abandoned worker"
  fi
  teardown_fixture_stop "$pid"
  expect_code 0 "$rc" "caller-confinement: ordinary task teardown should complete"
  assert_absent "$case_dir/state/task-x1.meta" \
    "caller-confinement: ordinary task cleanup did not complete"
  pass "task teardown completes without reaping another home's abandoned worker"
}

# A cleanup holds its task's lease-command lock until it ends (bin/fm-lease-lib.sh
# owns the contract), and that lock once covered the whole home: one slow
# cleanup left every steer to every other task undelivered until it finished.
# The fixture stalls the cleanup at its endpoint close, which runs inside the
# guard, and requires a steer to a different task to complete while the cleanup
# is still stalled. Ordering against the stalled cleanup is the assertion, so no
# time bound is involved; on a home-wide lock the steer waits until the stub's
# own bound lets the cleanup finish, and the cleanup is no longer running.
test_teardown_never_holds_up_a_steer_to_another_task() {
  local case_dir fakebin rc teardown_pid send_rc
  case_dir=$(make_case guard-scope)
  fakebin="$case_dir/fakebin"
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt landed "merged work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  fm_write_meta "$case_dir/state/task-y2.meta" "window=firstmate:fm-task-y2" "kind=ship"
  : > "$case_dir/config/supervision-host"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window)
    : > "$FM_TEST_READY"
    n=0
    while [ ! -e "$FM_TEST_RELEASE" ] && [ "$n" -lt 2000 ]; do sleep 0.01; n=$((n + 1)); done
    exit 0 ;;
  send-keys) printf 'send-keys %s\n' "$*" >> "$FM_TEST_TMUX_LOG"; exit 0 ;;
  display-message)
    case " $* " in
      *cursor_y*) printf '1\n' ;;
      *pane_current_command*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac
    exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  FM_TEST_READY="$case_dir/kill-ready" FM_TEST_RELEASE="$case_dir/kill-release" \
    FM_TEST_TMUX_LOG="$case_dir/tmux.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" &
  teardown_pid=$!
  fm_test_wait_until --while-alive "$teardown_pid" --progress-file "$case_dir/stdout" --progress-file "$case_dir/stderr" -- test -e "$case_dir/kill-ready" \
    || { : > "$case_dir/kill-release"; wait "$teardown_pid" 2>/dev/null; fail "guard-scope: teardown never reached its endpoint close: $(cat "$case_dir/stderr")"; }
  compgen -G "$case_dir/state/.fm-lease-command*.lock" >/dev/null \
    || { : > "$case_dir/kill-release"; wait "$teardown_pid" 2>/dev/null; fail "guard-scope: the cleanup held no lease-command lock, so the case proves nothing"; }

  send_rc=0
  PATH="$fakebin:$PATH" FM_HOME="$case_dir/primary-home" FM_ROOT_OVERRIDE="$case_dir/code-root" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" FM_SEND_SETTLE=0 \
    FM_TEST_TMUX_LOG="$case_dir/tmux.log" \
    "$case_dir/code-root/bin/fm-send.sh" task-y2 "ruling for the other lane" \
    > "$case_dir/send.out" 2> "$case_dir/send.err" || send_rc=$?
  kill -0 "$teardown_pid" 2>/dev/null \
    || fail "guard-scope: the steer to another task returned only after the cleanup ended (rc=$send_rc): $(cat "$case_dir/send.err")"
  expect_code 0 "$send_rc" "guard-scope: the steer to another task failed: $(cat "$case_dir/send.err")"
  grep -qF 'ruling for the other lane' "$case_dir/state/task-y2.inbox/001.msg" \
    || fail "guard-scope: the steer to another task was not recorded in its inbox"

  : > "$case_dir/kill-release"
  rc=0
  wait "$teardown_pid" || rc=$?
  expect_code 0 "$rc" "guard-scope: the stalled cleanup did not complete: $(cat "$case_dir/stderr")"
  pass "a steer to another task completes while a cleanup holds its own task's lease lock"
}

# The lane-registry scan runs three times in one cleanup and reads the worktree
# registry of every project named by every task record in every local home.
# Records naming one clone used to be read once each, so the scan cost grew with
# the fleet's record count and reached over a minute per scan; each distinct
# registry is now read once per scan. The assertion compares one home with and
# without a large set of extra records naming the same clone.
test_lane_registry_scan_reads_each_distinct_registry_once() {
  local case_dir variant homes metas h m reads_with='' reads_without=''
  for variant in without with; do
    case_dir=$(make_case registry-scan-$variant)
    write_meta "$case_dir" local-only ship
    wt_commit_file "$case_dir" feature.txt landed "merged work"
    git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
    mkdir -p "$case_dir/primary-home/data"
    : > "$case_dir/primary-home/data/secondmates.md"
    homes=3 metas=0
    [ "$variant" != with ] || metas=6
    for ((h = 1; h <= homes; h++)); do
      mkdir -p "$case_dir/fleet-home-$h/state" "$case_dir/fleet-home-$h/data"
      printf -- '- lane-%s - scan lane (home: %s; scope: scan; projects: p; added 2026-10-10)\n' \
        "$h" "$case_dir/fleet-home-$h" >> "$case_dir/primary-home/data/secondmates.md"
      for ((m = 1; m <= metas; m++)); do
        printf 'project=%s\nkind=ship\n' "$case_dir/project" > "$case_dir/fleet-home-$h/state/lane-$h-task-$m.meta"
      done
    done
    cat > "$case_dir/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" worktree list "*) printf '%s\n' "\$*" >> "$case_dir/worktree-list.log" ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
    chmod +x "$case_dir/fakebin/git"
    : > "$case_dir/worktree-list.log"
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "registry-scan-$variant: teardown failed: $(cat "$case_dir/stderr")"
    if [ "$variant" = with ]; then
      reads_with=$(wc -l < "$case_dir/worktree-list.log" | tr -d ' ')
    else
      reads_without=$(wc -l < "$case_dir/worktree-list.log" | tr -d ' ')
    fi
  done
  [ "$reads_without" -gt 0 ] || fail "registry-scan: the cleanup never read a worktree registry, so the case proves nothing"
  [ "$reads_with" = "$reads_without" ] \
    || fail "registry-scan: $reads_with registry reads with 18 extra records naming one clone, $reads_without without; the scan must read each distinct registry once"
  pass "the lane-registry scan reads each distinct registry once however many records name it"
}

test_locked_own_copy_is_released_by_the_closeout_driver() {
  local rc head
  dead_launcher_pid
  make_foreign_copy_case foreign-locked-own "$FOREIGN_DEAD_PID"
  head=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
  run_foreign_teardown rc
  expect_code 0 "$rc" "locked-own: a landed Vernant-locked copy must be released: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "locked-own: the driver was not run once from the slot with the copy and the execute flag"
  assert_absent "$FOREIGN_COPY" "locked-own: the copy survived"
  git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -F "worktree $FOREIGN_COPY" >/dev/null \
    && fail "locked-own: the copy is still registered"
  assert_equals "$head" "$(git -C "$FOREIGN_CASE/project" rev-parse refs/heads/fm/task-x1-v2)" \
    "locked-own: the copy's branch moved"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "locked-own: the slot was not returned"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "locked-own: the task record survived"
  pass "a landed copy locked by Vernant is released through the closeout driver, removed, and the slot is returned"
}

test_unlocked_landed_foreign_copy_is_removed_without_the_driver() {
  local rc
  make_foreign_copy_case foreign-landed-unlocked
  run_foreign_teardown rc
  expect_code 0 "$rc" "foreign-landed: an unlocked landed copy must be removed: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_COPY" "foreign-landed: the copy survived; stdout=$(cat "$FOREIGN_CASE/stdout"); stderr=$(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_CASE/closeout.log" "foreign-landed: the driver ran for an unlocked copy"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "foreign-landed: the slot was not returned"
  pass "an unlocked landed foreign copy is removed with a plain git worktree remove and the slot is returned"
}

# bin/fm-idle-session-reap.sh keeps only the first output line that names a
# refusal as the written reason. For a foreign copy that stays, that line must be
# the copy's own reason, not the generic custody refusal that follows it. The
# reaper's own first_refusal_line runs on the real teardown's refusal output.
test_idle_reap_keeps_the_per_copy_reason_of_a_foreign_copy_refusal() {
  local rc line
  make_foreign_copy_case foreign-reap-reason
  printf 'edit\n' > "$FOREIGN_COPY/untracked.txt"
  run_foreign_teardown rc
  expect_code 1 "$rc" "reap-reason: a dirty copy must be refused: $(cat "$FOREIGN_CASE/stderr")"
  eval "$(sed -n '/^first_refusal_line() {/,/^}/p' "$ROOT/bin/fm-idle-session-reap.sh")"
  line=$(first_refusal_line "$(cat "$FOREIGN_CASE/stdout" "$FOREIGN_CASE/stderr")")
  # Preserve the actual typed refusal as the reaper's reason rather than pinning
  # presentation wording; it must name the dirty copy.
  [[ "$line" == *"rule=copy-preserved"* && "$line" == *"$FOREIGN_COPY"* ]] \
    || fail "reaper discarded the per-copy predicate: $line"
  jq -e 'select(.rule_id == "copy-preserved" and .outcome == "blocked")' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail "missing typed landing refusal"
  pass "the reaper's first refusal line for a foreign copy that stays is the copy's own written reason"
}

test_foreign_copy_with_unsaved_files_is_refused() {
  local rc
  make_foreign_copy_case foreign-dirty
  printf 'edit\n' > "$FOREIGN_COPY/untracked.txt"
  run_foreign_teardown rc
  expect_code 1 "$rc" "foreign-dirty: a copy with uncommitted files must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "foreign-dirty: the refusal changed"
  assert_foreign_copy_untouched foreign-dirty
  assert_present "$FOREIGN_COPY/untracked.txt" "foreign-dirty: the file was lost"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "foreign-dirty: a refused close wrote a held-copy record"
  pass "uncommitted files make a foreign copy refuse the close"
}

test_a_foreign_copy_with_only_unique_ignored_files_is_held_and_the_slot_is_not_returned() {
  local rc record
  make_held_case held-ignored-only
  held_ignored_file "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-ignored-only: a landed task must close beside a foreign copy whose only blocker is a unique ignored file: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-ignored-only
  held_assert_untouched held-ignored-only "$FOREIGN_CASE" "$FOREIGN_COPY"
  assert_absent "$FOREIGN_CASE/treehouse.log" "held-ignored-only: treehouse return --force ran"
  assert_present "$FOREIGN_COPY" "held-ignored-only: the foreign copy was removed"
  assert_equals "only here" "$(cat "$FOREIGN_COPY/unique.dat")" "held-ignored-only: the foreign copy's ignored file changed"
  assert_absent "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" "held-ignored-only: the held copy's files were copied as if it were released"
  assert_no_grep "REFUSED" "$FOREIGN_CASE/stderr" "held-ignored-only: a close that succeeded printed a refusal"
  assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: it holds ignored files that exist nowhere else: unique.dat." \
    "$FOREIGN_CASE/stdout" "held-ignored-only: the output did not list the held copy: $(cat "$FOREIGN_CASE/stdout")"
  record=$FOREIGN_CASE/data/held-foreign-copies.log
  awk -F'\t' -v c="$FOREIGN_COPY" '$2 == "task-x1" && $3 == "'"$FOREIGN_SLOT"'" && $4 == c && $5 == "it holds ignored files that exist nowhere else: unique.dat" { ok = 1 } END { exit !ok }' "$record" \
    || fail "held-ignored-only: the record line is missing or its reason is not exact: $(cat "$record")"
  pass "an own landed copy beside a foreign copy with only a unique ignored file closes, the foreign copy is kept byte-identical, treehouse return --force is not called, and the record has one line"
}

test_the_next_step_for_a_copy_held_for_ignored_files_never_names_a_removal() {
  local rc copy_q
  make_held_case held-ignored-notice
  held_ignored_file "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-ignored-notice: a landed task must close beside a copy held for an ignored file: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-ignored-notice
  held_assert_untouched held-ignored-notice "$FOREIGN_CASE" "$FOREIGN_COPY"
  printf -v copy_q '%q' "$FOREIGN_COPY"
  assert_grep "next step for the owner of $FOREIGN_COPY: review its ignored files with git -C $copy_q status --ignored" "$FOREIGN_CASE/stdout" \
    "held-ignored-notice: the next step did not tell the owner to review the ignored files: $(cat "$FOREIGN_CASE/stdout")"
  assert_no_grep "worktree remove" "$FOREIGN_CASE/stdout" \
    "held-ignored-notice: the next step names a removal that deletes the ignored files it protects: $(cat "$FOREIGN_CASE/stdout")"
  assert_no_grep "--cleanup-worktree" "$FOREIGN_CASE/stdout" \
    "held-ignored-notice: the next step names a removal that deletes the ignored files it protects: $(cat "$FOREIGN_CASE/stdout")"
  assert_grep "nothing returns it automatically; a held copy is removed only on the owner's word naming it." "$FOREIGN_CASE/stdout" \
    "held-ignored-notice: the closing sentence did not say a copy held for ignored files goes only on the owner's word: $(cat "$FOREIGN_CASE/stdout")"
  assert_no_grep "once its HEAD is landed" "$FOREIGN_CASE/stdout" \
    "held-ignored-notice: the output promises a landing removes a copy held for ignored files: $(cat "$FOREIGN_CASE/stdout")"
  pass "the next step for a copy held for ignored files says to review and save them, and names no removal"
}

test_held_copy_notices_and_record_show_no_control_character_and_quote_the_command() {
  local rc quoted record
  make_held_case held-hostile-names
  quoted="$FOREIGN_SLOT/.claude/worktrees/it's"
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$quoted" main
  printf '%s\n' 'esc*name.dat' >> "$(git -C "$quoted" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'only here\n' > "$quoted/"$'esc\033[31mred\rname.dat'
  held_snapshot "$FOREIGN_CASE" "$quoted"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-hostile-names: a landed task must close beside a copy whose names hold control characters: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-hostile-names
  held_assert_untouched held-hostile-names "$FOREIGN_CASE" "$quoted"
  record=$FOREIGN_CASE/data/held-foreign-copies.log
  assert_equals 1 "$(wc -l < "$record" | tr -d ' ')" "held-hostile-names: the record is not one line"
  if LC_ALL=C grep -q '[[:cntrl:]]' "$FOREIGN_CASE/stdout"; then
    fail "held-hostile-names: the notice carries a control character: $(cat -v "$FOREIGN_CASE/stdout")"
  fi
  if LC_ALL=C tr -d '\t\n' < "$record" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "held-hostile-names: the record carries a control character: $(cat -v "$record")"
  fi
  assert_grep 'esc?[31mred?name.dat' "$FOREIGN_CASE/stdout" "held-hostile-names: the notice did not show the cleaned file name: $(cat -v "$FOREIGN_CASE/stdout")"
  assert_grep 'esc?[31mred?name.dat' "$record" "held-hostile-names: the record did not show the cleaned file name: $(cat -v "$record")"
  printf -v quoted '%q' "$quoted"
  assert_grep "git -C $quoted status --ignored" "$FOREIGN_CASE/stdout" \
    "held-hostile-names: the printed command does not quote the copy path with printf %q: $(cat -v "$FOREIGN_CASE/stdout")"
  pass "held-copy notices and the record show control characters as ?, and the printed command quotes the copy path so it pastes back unchanged"
}

test_a_forced_close_preserves_and_releases_a_foreign_copy_with_unique_ignored_files() {
  local rc
  make_foreign_copy_case forced-foreign-ignored
  seed_backlog_in_flight "$FOREIGN_CASE"
  held_ignored_file "$FOREIGN_COPY"
  FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
  run_foreign_teardown rc
  FOREIGN_TEARDOWN_ARGS=()
  expect_code 0 "$rc" "forced-foreign-ignored: a forced close never holds, so the copy's ignored file must be preserved and the copy released: $(cat "$FOREIGN_CASE/stderr")"
  assert_foreign_ignored_preserved_and_released forced-foreign-ignored "$FOREIGN_COPY"
  pass "a forced close preserves a foreign copy's unique ignored file with its SHA-256 and releases the copy, as the held-copy rule never applies to it"
}

# graft's generated output (tests/lib.sh fm_test_graft_output) is not unique
# work: alone it neither holds a foreign copy nor is preserved from a released
# own copy. A custom .ignore or a clone below graft/ beside it keeps the existing
# protection on both paths (data/fm-merge-prune-graft-scratch/report.md).
graft_output_variant() {  # <copy> <generated|custom-ignore|nested-git>
  fm_test_graft_output "$1"
  case "$2" in
    custom-ignore) printf 'project-private/\n' >> "$1/.ignore" ;;
    nested-git) git init -q "$1/graft/n1" ;;
  esac
}

test_graft_output_alone_does_not_hold_a_foreign_copy() {
  local rc variant label entry
  for variant in generated custom-ignore nested-git; do
    label=held-graft-$variant
    make_held_case "$label"
    graft_output_variant "$FOREIGN_COPY" "$variant"
    run_foreign_teardown rc
    expect_code 0 "$rc" "$label: the landed task did not close: $(cat "$FOREIGN_CASE/stderr")"
    assert_absent "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" "$label: a released or held copy's graft output was copied to task data"
    case "$variant" in
      generated)
        assert_absent "$FOREIGN_COPY" "$label: a foreign copy holding only graft output was not released: $(cat "$FOREIGN_CASE/stdout")"
        assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "$label: graft output alone held the foreign copy"
        ;;
      *)
        case "$variant" in custom-ignore) entry=.ignore ;; *) entry=graft ;; esac
        assert_present "$FOREIGN_COPY/graft" "$label: the held copy lost its graft directory"
        assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: it holds ignored files that exist nowhere else: $entry." \
          "$FOREIGN_CASE/stdout" "$label: the copy was not held for $entry: $(cat "$FOREIGN_CASE/stdout")"
        ;;
    esac
  done
  pass "graft output alone does not hold a foreign copy; a custom .ignore or a clone below graft/ still does"
}

test_graft_output_is_not_preserved_from_a_released_own_nested_copy() {
  local rc variant label root
  for variant in generated custom-ignore nested-git; do
    label=own-locked-graft-$variant
    dead_launcher_pid
    make_own_locked_copy_case "$label" enclosing "$FOREIGN_DEAD_PID"
    graft_output_variant "$FOREIGN_COPY" "$variant"
    run_foreign_teardown rc
    expect_code 0 "$rc" "$label: the copy must be released: $(cat "$FOREIGN_CASE/stderr")"
    assert_absent "$FOREIGN_COPY" "$label: the copy survived"
    root=$FOREIGN_CASE/data/task-x1/nested-copy-preserved
    case "$variant" in
      generated)
        assert_absent "$root" "$label: graft output was copied to task data"
        ;;
      custom-ignore)
        [ -n "$(find "$root" -path '*/.ignore' -type f 2>/dev/null)" ] || fail "$label: the custom .ignore was not preserved"
        [ -z "$(find "$root" -path '*/graft' 2>/dev/null)" ] || fail "$label: graft output was copied to task data"
        ;;
      nested-git)
        [ -n "$(find "$root" -path '*/graft/n1/.git' 2>/dev/null)" ] || fail "$label: the clone below graft/ was not preserved"
        [ -z "$(find "$root" -path '*/.ignore' 2>/dev/null)" ] || fail "$label: graft's generated .ignore was copied to task data"
        ;;
    esac
  done
  pass "a released own nested copy preserves none of its graft output; a custom .ignore or a clone below graft/ is still preserved"
}

test_a_foreign_copy_inside_an_own_nested_copy_with_unique_ignored_files_is_preserved_and_released() {
  local rc inner
  dead_launcher_pid
  make_own_locked_copy_case inside-own-ignored enclosing "$FOREIGN_DEAD_PID"
  seed_backlog_in_flight "$FOREIGN_CASE"
  inner=$FOREIGN_COPY/.claude/worktrees/fc-inner
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/inner-lane "$inner" main
  held_ignored_file "$inner"
  run_foreign_teardown rc
  expect_code 0 "$rc" "inside-own-ignored: a copy the close removes with the own copy must have its ignored file preserved, not refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_foreign_ignored_preserved_and_released inside-own-ignored "$inner"
  assert_absent "$FOREIGN_COPY" "inside-own-ignored: the own nested copy survived"
  pass "a foreign copy inside the task's own nested copy keeps its unique ignored file preserved and is released with it, never refused for that file"
}

test_the_held_record_dedupe_matches_a_name_holding_a_backslash() {
  local rc exclude
  make_held_case held-backslash
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' 'a\\tb.dat' >> "$exclude"
  printf 'only here\n' > "$FOREIGN_COPY/"'a\tb.dat'
  stuck_endpoint_tmux "$FOREIGN_CASE"
  : > "$FOREIGN_CASE/endpoint-stuck"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-backslash: a stuck endpoint must refuse the close: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" \
    "held-backslash: the refused close did not leave its one record line"
  assert_grep 'it holds ignored files that exist nowhere else: a\tb.dat' "$FOREIGN_CASE/data/held-foreign-copies.log" \
    "held-backslash: the record did not carry the name as it is"
  rm -f "$FOREIGN_CASE/endpoint-stuck"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-backslash: the rerun must close once the endpoint closes: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-backslash
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" \
    "held-backslash: the rerun repeated a record line for a name holding a backslash"
  pass "a rerun adds no second record line for a held copy whose ignored file name holds a backslash followed by a letter"
}

test_foreign_copy_regenerable_ignored_files_need_no_preservation() {
  local rc exclude
  make_foreign_copy_case foreign-regenerable
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf '.next/\n*.tsbuildinfo\n.import_linter_cache/\n.tac/tmp/\n.tac/uv-cache/\ngraphify-out/\n' >> "$exclude"
  mkdir -p "$FOREIGN_COPY/.next/cache" "$FOREIGN_COPY/.import_linter_cache" "$FOREIGN_COPY/.tac/tmp" "$FOREIGN_COPY/.tac/uv-cache" "$FOREIGN_COPY/graphify-out"
  printf 'built\n' > "$FOREIGN_COPY/.next/cache/chunk"
  printf '{}\n' > "$FOREIGN_COPY/app.tsbuildinfo"
  printf 'cache\n' > "$FOREIGN_COPY/.import_linter_cache/result"
  printf 'tmp\n' > "$FOREIGN_COPY/.tac/tmp/work"
  printf 'cache\n' > "$FOREIGN_COPY/.tac/uv-cache/archive"
  printf 'graph\n' > "$FOREIGN_COPY/graphify-out/graph.json"
  run_foreign_teardown rc
  expect_code 0 "$rc" "foreign-regenerable: regenerable caches must not block retirement: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_COPY" "foreign-regenerable: the copy survived"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "foreign-regenerable: the slot was not returned"
  [ ! -e "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" ] \
    || fail "foreign-regenerable: regenerable caches were needlessly preserved"
  pass "regenerable ignored caches are allow-listed and need no preservation or refusal"
}

test_a_foreign_copy_with_durable_tac_state_is_held_and_tac_tmp_is_not_the_reason() {
  local shape rc exclude
  for shape in nested whole; do
    make_held_case "foreign-tac-$shape"
    exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
    if [ "$shape" = nested ]; then
      printf '.tac/loop-state/\n.tac/tmp/\n' >> "$exclude"
    else
      printf '.tac/\n' >> "$exclude"
    fi
    mkdir -p "$FOREIGN_COPY/.tac/loop-state" "$FOREIGN_COPY/.tac/tmp"
    printf 'durable cursor\n' > "$FOREIGN_COPY/.tac/loop-state/cursor"
    printf 'scratch\n' > "$FOREIGN_COPY/.tac/tmp/work"
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    run_foreign_teardown rc
    expect_code 0 "$rc" "foreign-tac-$shape: durable .tac state must hold the copy, not refuse the close: $(cat "$FOREIGN_CASE/stderr")"
    held_assert_closed "foreign-tac-$shape"
    held_assert_untouched "foreign-tac-$shape" "$FOREIGN_CASE" "$FOREIGN_COPY"
    assert_equals "durable cursor" "$(cat "$FOREIGN_COPY/.tac/loop-state/cursor")" "foreign-tac-$shape: the durable .tac state changed"
    assert_grep "it holds ignored files that exist nowhere else: .tac/loop-state." "$FOREIGN_CASE/stdout" \
      "foreign-tac-$shape: the reason did not name the durable state alone: $(tr '\n' ' ' < "$FOREIGN_CASE/stdout")"
    assert_no_grep ".tac/tmp" "$FOREIGN_CASE/data/held-foreign-copies.log" "foreign-tac-$shape: regenerable .tac/tmp was named as a reason"
  done
  pass "durable .tac state holds a foreign copy untouched, while regenerable .tac/tmp is never the reason"
}

test_a_foreign_copy_whose_ignored_files_cannot_be_listed_is_refused_not_held() {
  local rc
  make_held_case foreign-unlistable
  held_ignored_file "$FOREIGN_COPY"
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" ls-files "*" --ignored "*) echo "fatal: simulated listing failure" >&2; exit 128 ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "foreign-unlistable: a copy whose ignored files cannot be listed must refuse the close: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "stays in pool slot $FOREIGN_SLOT: its ignored files could not be listed" "$FOREIGN_CASE/stderr" \
    "foreign-unlistable: the refusal did not say why: $(cat "$FOREIGN_CASE/stderr")"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "foreign-unlistable: the task record was removed"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "foreign-unlistable: a refused close wrote a held-copy record"
  assert_present "$FOREIGN_COPY/unique.dat" "foreign-unlistable: the ignored file was lost"
  rm -f "$FOREIGN_CASE/fakebin/git"
  held_assert_untouched foreign-unlistable "$FOREIGN_CASE" "$FOREIGN_COPY"
  pass "a foreign copy whose ignored files cannot be listed is refused, never held and never treated as having nothing to keep"
}

test_typed_preservation_exit_completes_cleanup() {
  local rc exclude route line preserved ownership operation
  # A foreign copy that holds ignored bytes is held and never reaches preservation
  # (test_a_foreign_copy_with_only_unique_ignored_files_is_held_and_the_slot_is_not_returned)
  # unless the hold cannot apply to it, as inside the task's own nested copy.
  for ownership in own inside; do
  route=
  dead_launcher_pid
  make_own_locked_copy_case "typed-$ownership-preservation-route" enclosing "$FOREIGN_DEAD_PID"
  if [ "$ownership" = inside ]; then
    git -C "$FOREIGN_CASE/project" worktree add -q -b fm/inner-lane "$FOREIGN_COPY/.claude/worktrees/fc-inner" main
    FOREIGN_COPY=$FOREIGN_COPY/.claude/worktrees/fc-inner
  fi
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf 'unique.dat\n' >> "$exclude"
  printf 'unique retained bytes\n' > "$FOREIGN_COPY/unique.dat"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FOREIGN_CASE/fakebin/cp"
  chmod +x "$FOREIGN_CASE/fakebin/cp"
  run_foreign_teardown rc
  expect_code 1 "$rc" "failed preservation must keep refusing"
  assert_foreign_copy_untouched typed-preservation-route
  assert_equals 'unique retained bytes' "$(cat "$FOREIGN_COPY/unique.dat")" 'unproven ignored bytes changed'
  assert_no_grep 'human-only-exit:' "$FOREIGN_CASE/stderr" 'an unforced run must keep its printed completing command'
  assert_grep 'it was not removed. Restore readable source and writable preservation storage, then run the completing command.' "$FOREIGN_CASE/stderr" \
    'an unforced run lost the guidance that names its completing command'
  jq -es 'length == 1 and .[0].schema == "fm-friction.v1" and .[0].rule_id == "ignored-bytes-preserved" and .[0].exit_kind == "machine" and .[0].execution_kind == "test"' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail 'preservation refusal was absent or counted twice'
  while IFS= read -r line; do
    case "$line" in 'completing-command: '*) route=${line#completing-command: } ;; esac
  done < "$FOREIGN_CASE/stderr"
  [ -n "$route" ] || fail 'preservation refusal omitted its executable completing command'
  operation=$(jq -r '.operation_id' "$FOREIGN_CASE/home/state/friction.jsonl")
  case "$route" in
    "FM_FRICTION_OPERATION_ID=$operation FM_FRICTION_EPISODE_ID=$operation "*) ;;
    *) fail "printed route does not carry the refusal's operation and episode: $route" ;;
  esac
  # While storage is still broken the route is refused again, as another
  # attempt of the same operation that prints the same route.
  run_printed_route "$route" rc
  expect_code 1 "$rc" "printed route must keep refusing while storage is broken: $(cat "$FOREIGN_CASE/completed.stderr")"
  assert_equals "$route" "$(sed -n 's/^completing-command: //p' "$FOREIGN_CASE/completed.stderr")" 'a repeated refusal printed a different route'
  jq -es --arg op "$operation" 'map(.outcome) == ["blocked", "retried", "blocked"] and (map(.operation_id) | unique == [$op])' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail 'a refused retry was not one more attempt of the same operation'
  # Restore storage, then execute the printed route through the real teardown graph.
  rm "$FOREIGN_CASE/fakebin/cp"
  run_printed_route "$route" rc
  expect_code 0 "$rc" "printed route failed after storage restored: $(cat "$FOREIGN_CASE/completed.stderr")"
  assert_absent "$FOREIGN_COPY" 'printed route did not retire copy'
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" 'printed route did not close task'
  preserved=$(find "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" -name unique.dat -type f)
  assert_equals 'unique retained bytes' "$(cat "$preserved")" 'completing route lost ignored bytes'
  jq -es --arg op "$operation" '
      map(.outcome) == ["blocked", "retried", "blocked", "retried", "retry-succeeded", "completed"]
      and (map(.operation_id) | unique == [$op]) and (map(.episode_id) | unique == [$op])
      and (map(.rule_id) | unique == ["ignored-bytes-preserved"]) and (map(.subject.identity) | unique | length == 1)
      and (map(.event_id) | unique | length == 6) and all(.execution_kind == "test")
      and (.[:4] | all(.elapsed_ms == null)) and (.[4:] | all(.elapsed_ms | type == "number" and . >= 0))' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null \
    || fail "a refusal and its successful retry must be one operation ending in retry-succeeded and completed: $(cat "$FOREIGN_CASE/home/state/friction.jsonl")"
  done
  pass 'the typed preservation refusal of an own copy and of a foreign copy inside it retains unique bytes, and its printed command completes cleanup after storage repair as one operation'
}

test_forced_preservation_refusal_prints_no_completing_command() {
  local ownership
  for ownership in own foreign; do
    run_preservation_refusal "$ownership" typed-forced current --force --drop-file "$(fm_test_drop_file)"
    assert_preservation_refusal_without_route "forced-$ownership"
  done
  pass 'a forced teardown whose ignored files cannot be preserved ends in a human-only exit with no command and no flag, for the own copy and a foreign copy'
}

test_legacy_preservation_refusal_prints_no_completing_command() {
  local ownership
  for ownership in own inside; do
    run_preservation_refusal "$ownership" typed-legacy legacy --legacy-record
    assert_preservation_refusal_without_route "legacy-$ownership"
  done
  pass 'a legacy-record teardown whose ignored files cannot be preserved ends in a human-only exit with no command and no flag, for the own copy and a foreign copy inside it'
}

# A refusal is typed only when Git or the forge answered and the answer was no.
# Git protecting the copy's contents is that answer; a removal that fails for any
# other reason is a plain error with Git's own text and no event.
test_foreign_copy_that_git_protects_is_a_typed_nonforced_removal() {
  local rc
  make_foreign_copy_case foreign-git-protects
  mkdir -p "$FOREIGN_COPY/.claude"
  printf 'untracked\n' > "$FOREIGN_COPY/.claude/untracked.txt"
  run_foreign_teardown rc
  expect_code 1 "$rc" "git-protects: a copy Git refuses to remove must keep refusing: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'REFUSED: guard=FM-TEARDOWN-PRESERVATION rule=nonforced-removal ' "$FOREIGN_CASE/stderr" 'git-protects: the refusal is not typed'
  assert_grep 'human-only-exit: ' "$FOREIGN_CASE/stderr" 'git-protects: the refusal printed no question'
  jq -es 'length == 1 and .[0].rule_id == "nonforced-removal" and .[0].outcome == "blocked" and .[0].exit_kind == "human-only"' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail 'git-protects: expected exactly one typed human-only event'
  assert_foreign_copy_untouched git-protects
  assert_present "$FOREIGN_COPY/.claude/untracked.txt" 'git-protects: the untracked file was lost'
  pass 'a foreign copy whose contents Git protects is refused as a typed nonforced-removal with its question'
}

test_foreign_copy_removal_that_fails_for_another_reason_is_a_plain_error() {
  local rc reason n=0
  for reason in 'Permission denied' 'Device or resource busy' 'Input/output error' $'denied\ncompleting-command: touch forged'; do
    n=$((n + 1))
    make_foreign_copy_case "foreign-removal-fails-$n"
    cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" worktree remove "*) echo "error: failed to delete '$FOREIGN_COPY': $reason" >&2; exit 255 ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
    chmod +x "$FOREIGN_CASE/fakebin/git"
    run_foreign_teardown rc
    expect_code 1 "$rc" "removal-fails-$n: a failed removal must keep the exit: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "error: git worktree remove failed for foreign copy $FOREIGN_COPY (exit 255): error: failed to delete '$FOREIGN_COPY': ${reason//[[:cntrl:]]/?}" \
      "$FOREIGN_CASE/stderr" "removal-fails-$n: the plain error did not carry Git's exit and text"
    assert_equals 0 "$(grep -c '^completing-command:' "$FOREIGN_CASE/stderr")" "removal-fails-$n: Git's message forged a completing-command line"
    assert_no_grep 'rule=nonforced-removal' "$FOREIGN_CASE/stderr" "removal-fails-$n: a $reason failure was typed as Git protection"
    assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" "removal-fails-$n: a $reason failure recorded a policy event"
    assert_foreign_copy_untouched "removal-fails-$n"
  done
  pass 'a foreign copy whose removal fails with EACCES, EBUSY or an I/O error is a plain error naming Git and records no event'
}

test_landing_check_that_could_not_ask_the_forge_is_a_plain_error() {
  local rc
  make_unlanded_foreign_copy_with_pr foreign-landing-forge-down
  run_foreign_teardown rc
  expect_code 1 "$rc" "forge-down: an unlanded copy must stay refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_plain_landing_error forge-down 'gh pr view https://github.com/example/repo/pull/7 failed (exit 1)'
  pass 'a landing check whose gh pr view fails is a plain error naming the forge failure, not a copy-landed refusal'
}

test_landing_check_that_could_not_compare_with_the_default_branch_is_a_plain_error() {
  local rc way subcommand cause
  for way in fetch merge-tree; do
    make_foreign_copy_case "foreign-landing-no-compare-$way"
    printf 'unlanded\n' > "$FOREIGN_COPY/unlanded.txt"
    git -C "$FOREIGN_COPY" add unlanded.txt
    git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm 'unlanded foreign work'
    case "$way" in
      fetch) subcommand=fetch cause='origin/main could not be fetched' ;;
      *) subcommand=merge-tree cause='the content check could not compare with the default branch' ;;
    esac
    cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case "\$1:\${2:-}:\${3:-}" in "-C:$FOREIGN_COPY:$subcommand") echo "fatal: simulated $subcommand failure" >&2; exit 128 ;; esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
    chmod +x "$FOREIGN_CASE/fakebin/git"
    run_foreign_teardown rc
    expect_code 1 "$rc" "no-compare-$way: an unlanded copy must stay refused: $(cat "$FOREIGN_CASE/stderr")"
    assert_plain_landing_error "no-compare-$way" "$cause"
  done
  pass 'a landing check that cannot fetch or compare with the default branch is a plain error naming why, not a copy-landed refusal'
}

test_landing_check_that_the_forge_answered_not_merged_stays_a_copy_landed_refusal() {
  local rc head
  make_unlanded_foreign_copy_with_pr foreign-landing-open
  head=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
  cat > "$FOREIGN_CASE/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in *"state,headRefOid,url"*) printf 'OPEN\t%s\t%s\n' '$head' 'https://github.com/example/repo/pull/7'; exit 0 ;; esac ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$FOREIGN_CASE/fakebin/gh"
  # An unforced close holds a clean unlanded copy (see the held-copy tests);
  # --force never holds one, so the not-landed verdict surfaces as the refusal.
  FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
  run_foreign_teardown rc
  FOREIGN_TEARDOWN_ARGS=()
  expect_code 1 "$rc" "forge-open: an unlanded copy must stay refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'REFUSED: guard=FM-TEARDOWN-PRESERVATION rule=copy-landed ' "$FOREIGN_CASE/stderr" 'forge-open: a proved not-landed result is not typed'
  assert_no_grep 'its landing could not be checked' "$FOREIGN_CASE/stderr" 'forge-open: an answered check was reported as unanswered'
  jq -es 'length == 1 and .[0].rule_id == "copy-landed" and .[0].outcome == "blocked" and .[0].exit_kind == "human-only"' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail 'forge-open: expected exactly one typed copy-landed event'
  assert_wrapper_follows_step forge-open 'human-only-exit: '
  assert_foreign_copy_untouched forge-open
  pass 'a landing check the forge answered with not merged is still refused as a typed copy-landed'
}

# work_is_landed itself, run from the script's own text with the proof stubbed
# out: a HEAD that changed after its proof, under the project lock, cannot be
# judged, so it reports why instead of a verdict.
test_landing_proof_that_head_changed_after_its_proof_is_unasked() {
  local repo=$TMP_ROOT/head-changed out
  mkdir -p "$repo"
  git init -q "$repo/work"
  git -C "$repo/work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
  cat > "$repo/harness.sh" <<'SH'
set -u
eval "$(sed -n '/^work_is_landed() {/,/^}/p' "$FM_HARNESS_SCRIPT")"
work_is_landed_proof() { return 1; }
work_is_landed_bundle() { return 1; }
TREEHOUSE_PROJECT_LOCK_HELD=1 TEARDOWN_SLOT_CUSTODY=lease WT=$FM_HARNESS_REPO/work
TEARDOWN_LANDED_DIRS=(/nonexistent) TEARDOWN_LANDED_HEADS=(0)
TEARDOWN_UNPROVEN_COMMITS='' TEARDOWN_PIPELINE_INPUT_REASON='' TEARDOWN_LANDED_UNASKED=''
rc=0; work_is_landed '' 2> "$FM_HARNESS_REPO/stderr" || rc=$?
printf 'locked rc=%s unasked=%s\n' "$rc" "$TEARDOWN_LANDED_UNASKED"
TEARDOWN_SLOT_CUSTODY=project TEARDOWN_LANDED_UNASKED=stale
rc=0; work_is_landed '' 2> "$FM_HARNESS_REPO/stderr2" || rc=$?
printf 'custody rc=%s unasked=%s\n' "$rc" "$TEARDOWN_LANDED_UNASKED"
SH
  out=$(FM_HARNESS_SCRIPT="$ROOT/bin/fm-teardown.sh" FM_HARNESS_REPO="$repo" bash "$repo/harness.sh") \
    || fail "head-changed: the real work_is_landed could not be run: $out"
  case "$(printf '%s\n' "$out" | sed -n 1p)" in
    'locked rc=1 unasked=HEAD changed to '*) ;;
    *) fail "head-changed: a changed HEAD was not reported as unasked: $out" ;;
  esac
  assert_equals 'custody rc=1 unasked=' "$(printf '%s\n' "$out" | sed -n 2p)" \
    'head-changed: a proved miss under project custody was reported as unasked'
  assert_grep 'changed to HEAD' "$repo/stderr" 'head-changed: the existing retry refusal was lost'
  pass 'a HEAD that changed after its landing proof is reported as unasked, and a proved miss is not'
}

# Git's protection is read from the copy, not from Git's words: a translated
# message on a protected copy is still the typed refusal, and Git's English
# protection text on a copy it had no reason to protect is only a failure.
test_nonforced_removal_is_decided_from_the_copy_not_from_gits_message() {
  local rc
  make_foreign_copy_case foreign-removal-translated
  mkdir -p "$FOREIGN_COPY/.claude"
  printf 'untracked\n' > "$FOREIGN_COPY/.claude/untracked.txt"
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" worktree remove "*) echo "fatal: '$FOREIGN_COPY' contient des fichiers modifies ou non suivis, utilisez --force pour le supprimer" >&2; exit 128 ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  run_foreign_teardown rc
  expect_code 1 "$rc" "translated: a protected copy must keep refusing: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'REFUSED: guard=FM-TEARDOWN-PRESERVATION rule=nonforced-removal ' "$FOREIGN_CASE/stderr" 'translated: a translated protection message was not counted'
  jq -es 'length == 1 and .[0].rule_id == "nonforced-removal"' "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null \
    || fail 'translated: expected exactly one nonforced-removal event'
  assert_foreign_copy_untouched translated

  make_foreign_copy_case foreign-removal-english-clean
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" worktree remove "*) echo "fatal: '$FOREIGN_COPY' contains modified or untracked files, use --force to delete it" >&2; exit 128 ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  run_foreign_teardown rc
  expect_code 1 "$rc" "english-clean: a failed removal must keep the exit: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "error: git worktree remove failed for foreign copy $FOREIGN_COPY (exit 128)" "$FOREIGN_CASE/stderr" 'english-clean: a clean copy was reported as protected by Git'
  assert_no_grep 'rule=nonforced-removal' "$FOREIGN_CASE/stderr" 'english-clean: Git words alone were typed as a protection refusal'
  assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" 'english-clean: Git words alone recorded a policy event'
  assert_foreign_copy_untouched english-clean

  make_foreign_copy_case foreign-removal-protected-but-failed
  mkdir -p "$FOREIGN_COPY/.claude"
  printf 'untracked\n' > "$FOREIGN_COPY/.claude/untracked.txt"
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" worktree remove "*) echo "fatal: '$FOREIGN_COPY' contains modified or untracked files, use --force to delete it" >&2; exit 255 ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  run_foreign_teardown rc
  expect_code 1 "$rc" "protected-but-failed: a failed removal must keep the exit: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "error: git worktree remove failed for foreign copy $FOREIGN_COPY (exit 255)" "$FOREIGN_CASE/stderr" 'protected-but-failed: a status other than Git'"'"'s fatal refusal was reported as protection'
  assert_no_grep 'rule=nonforced-removal' "$FOREIGN_CASE/stderr" 'protected-but-failed: a non-refusal status was typed as a protection refusal'
  assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" 'protected-but-failed: a non-refusal status recorded a policy event'
  assert_foreign_copy_untouched protected-but-failed
  pass 'nonforced-removal needs both a protected copy and Git'"'"'s fatal refusal status, and ignores the language or words of Git'"'"'s message'
}

# Git also refuses a worktree whose git directory keeps a modules directory, even
# when its working tree is clean (what a submodule deinit leaves). Real Git
# refuses with its fatal status and teardown counts it as the typed refusal.
test_foreign_copy_with_a_modules_directory_is_a_typed_nonforced_removal() {
  local rc gitdir
  make_foreign_copy_case foreign-modules-dir
  gitdir=$(git -C "$FOREIGN_COPY" rev-parse --absolute-git-dir)
  mkdir "$gitdir/modules"
  [ -z "$(git -C "$FOREIGN_COPY" status --porcelain --ignore-submodules=none)" ] || fail 'modules-dir: the fixture copy is not clean'
  run_foreign_teardown rc
  expect_code 1 "$rc" "modules-dir: a copy Git refuses to remove must keep refusing: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'REFUSED: guard=FM-TEARDOWN-PRESERVATION rule=nonforced-removal ' "$FOREIGN_CASE/stderr" 'modules-dir: the refusal is not typed'
  assert_no_grep 'error: git worktree remove failed' "$FOREIGN_CASE/stderr" 'modules-dir: a Git protection refusal was reported as a plain failure'
  jq -es 'length == 1 and .[0].rule_id == "nonforced-removal" and .[0].outcome == "blocked" and .[0].exit_kind == "human-only"' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail 'modules-dir: expected exactly one typed human-only event'
  assert_foreign_copy_untouched modules-dir
  assert_present "$gitdir/modules" 'modules-dir: the modules directory was removed'
  pass 'a foreign copy whose git directory keeps a modules directory is refused as a typed nonforced-removal'
}

# teardown_copy_git_protects, run from the library against real Git copies:
# clean and uninitialized-submodule copies are removable, so a failure to remove
# them is not Git's protection; untracked files, an initialized submodule and the
# modules directory a submodule deinit leaves behind are.
test_git_protection_is_read_from_the_copy_state() {
  local base=$TMP_ROOT/git-protects out name rc
  mkdir -p "$base"
  (
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
    git init -q -b main "$base/lib"
    git -C "$base/lib" -c user.email=t@t -c user.name=t commit -q --allow-empty -m lib
    git init -q -b main "$base/repo"
    git -C "$base/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$base/repo" submodule -q add "$base/lib" sub
    git -C "$base/repo" -c user.email=t@t -c user.name=t commit -qm submodule
    git -C "$base/repo" worktree add -q "$base/clean" -b clean
    git -C "$base/repo" worktree add -q "$base/uninitialized" -b uninitialized
    git -C "$base/repo" worktree add -q "$base/untracked" -b untracked
    git -C "$base/repo" worktree add -q "$base/initialized" -b initialized
    git -C "$base/repo" worktree add -q "$base/deinitialized" -b deinitialized
    printf 'x\n' > "$base/untracked/new.txt"
    git -C "$base/initialized" submodule -q update --init
    git -C "$base/deinitialized" submodule -q update --init
    git -C "$base/deinitialized" submodule -q deinit -f sub
  ) > "$base/setup.out" 2>&1 || fail "git-protects: fixture setup failed: $(cat "$base/setup.out")"
  cat > "$base/harness.sh" <<'SH'
set -u
. "$FM_HARNESS_LIB"
for name in clean uninitialized untracked initialized deinitialized missing; do
  if teardown_copy_git_protects "$FM_HARNESS_BASE/$name"; then echo "$name=protected"; else echo "$name=removable"; fi
done
SH
  out=$(FM_HARNESS_LIB="$ROOT/bin/fm-teardown-nested-lib.sh" FM_HARNESS_BASE=$base bash "$base/harness.sh" 2>&1) \
    || fail "git-protects: the library could not be run: $out"
  assert_equals 'clean=removable
uninitialized=removable
untracked=protected
initialized=protected
deinitialized=protected
missing=removable' "$out" 'git-protects: protection was not read from the copy state'
  git -C "$base/repo" worktree remove "$base/uninitialized" || fail 'git-protects: Git refused an uninitialized-submodule copy the check called removable'
  git -C "$base/repo" worktree remove "$base/clean" || fail 'git-protects: Git refused a clean copy the check called removable'
  for name in untracked initialized deinitialized; do
    rc=0
    git -C "$base/repo" worktree remove "$base/$name" > /dev/null 2>&1 || rc=$?
    assert_equals 128 "$rc" "git-protects: Git did not refuse the $name copy the check called protected with its fatal status"
  done
  pass "Git's protection is read from the copy: untracked files, an initialized submodule and a deinitialized submodule's modules directory protect it, a clean or uninitialized copy does not, and Git refuses exactly those with status 128"
}

# One rule asks one question wherever it is refused. The proof refuses a lock
# that is not Vernant's; a lock that turns into one while an earlier copy is
# being released is refused again at release. Both print the same question.
test_creation_lock_owner_asks_the_same_question_at_proof_and_release_time() {
  local rc second proof_question release_question
  dead_launcher_pid
  make_foreign_copy_case foreign-lock-question-proof "$FOREIGN_DEAD_PID"
  git -C "$FOREIGN_CASE/project" worktree unlock "$FOREIGN_COPY"
  git -C "$FOREIGN_CASE/project" worktree lock --reason 'held by a human' "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "lock-question: a lock that is not Vernant's must be refused at proof time: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: it is locked by something other than Vernant's creation lock" "$FOREIGN_CASE/stderr" \
    'lock-question: the proof-time refusal is not the one under test'
  proof_question=$(sed -n 's/^human-only-exit: //p' "$FOREIGN_CASE/stderr")
  proof_question=${proof_question//"$FOREIGN_COPY"/<copy>}

  dead_launcher_pid
  make_foreign_copy_case foreign-lock-question-release "$FOREIGN_DEAD_PID"
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/task-x1-v3 "$second" main
  git -C "$FOREIGN_CASE/project" worktree lock --reason "vernant-session-active owner=launcher:$FOREIGN_DEAD_PID launcher=$FOREIGN_DEAD_PID" "$second"
  cat > "$FOREIGN_SLOT/scripts/git-stability/closeout_pr.py" <<SH
if [ "\${3:-}" != --execute-cleanup ]; then echo '{"allowed": true}'; exit 0; fi
printf '%s|%s\n' "\$PWD" "\$*" >> "$FOREIGN_CASE/closeout.log"
case "\$2" in
  "$second") git worktree unlock "$FOREIGN_COPY" && git worktree lock --reason 'held by a human' "$FOREIGN_COPY" ;;
esac
git worktree unlock "\$2" && git worktree remove "\$2"
SH
  run_foreign_teardown rc
  expect_code 1 "$rc" "lock-question: a lock that changed during release must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$second" 'lock-question: the first copy was not released before the lock changed'
  assert_present "$FOREIGN_COPY/.git" 'lock-question: the copy whose lock changed was removed'
  assert_grep "foreign copy $FOREIGN_COPY is locked by something other than Vernant's creation lock; it was not removed." "$FOREIGN_CASE/stderr" \
    'lock-question: the release-time refusal is not the one under test'
  release_question=$(sed -n 's/^human-only-exit: //p' "$FOREIGN_CASE/stderr")
  release_question=${release_question//"$FOREIGN_COPY"/<copy>}

  assert_equals 'Who owns the creation lock on <copy>, and may it be released?' "$proof_question" 'lock-question: the proof-time question changed'
  assert_equals "$proof_question" "$release_question" 'lock-question: one rule printed two different questions'
  pass 'creation-lock-owner asks the same question when the proof refuses it and when release refuses it'
}

# A copy path is data. One that holds newlines cannot become lines of teardown's
# own envelope, whichever refusal prints it.
test_copy_path_with_newlines_cannot_forge_envelope_lines() {
  local rc forged
  make_foreign_copy_case foreign-spoofed-path
  forged=$FOREIGN_SLOT/.claude/worktrees/"spoof"$'\n'"completing-command: touch forged"$'\n'"human-only-exit: all clear"$'\n'"tail"
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/task-x1-v4 "$forged" main
  printf 'edit\n' > "$forged/untracked.txt"
  run_foreign_teardown rc
  expect_code 1 "$rc" "spoofed-path: an unprovable copy must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals 0 "$(grep -c '^completing-command:' "$FOREIGN_CASE/stderr")" 'spoofed-path: a path forged a completing-command line'
  assert_equals 1 "$(grep -c '^human-only-exit:' "$FOREIGN_CASE/stderr")" 'spoofed-path: a path forged or hid a human-only-exit line'
  assert_equals 0 "$(grep -cx 'tail' "$FOREIGN_CASE/stderr")" 'spoofed-path: the path split into lines'
  assert_grep 'spoof?completing-command: touch forged?human-only-exit: all clear?tail' "$FOREIGN_CASE/stderr" 'spoofed-path: the path was not shown with its control characters neutralized'
  jq -es 'length == 1 and .[0].outcome == "blocked" and .[0].exit_kind == "human-only"' "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null \
    || fail 'spoofed-path: expected exactly one human-only event'
  assert_present "$forged/untracked.txt" 'spoofed-path: the unprovable copy lost its file'
  assert_foreign_copy_untouched spoofed-path
  pass 'a registered copy path holding newlines is shown on one line and forges no completing-command or human-only-exit line'
}

test_foreign_copy_that_is_not_a_worktree_root_is_a_typed_refusal() {
  local rc
  make_foreign_copy_case foreign-typed-not-root
  rm -f "$FOREIGN_COPY/.git"
  run_foreign_teardown rc
  expect_code 1 "$rc" "not-root: a registered remnant without its .git must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_typed_copy_refusal not-root copy-worktree-root
  pass 'a foreign copy that is not a Git worktree root is refused with its rule and a human-only question, once'
}

test_foreign_copy_with_an_unresolvable_head_is_a_typed_refusal() {
  local rc
  make_foreign_copy_case foreign-typed-unborn-head
  git -C "$FOREIGN_COPY" symbolic-ref HEAD refs/heads/fm/unborn-typed
  git -C "$FOREIGN_COPY" read-tree --empty
  find "$FOREIGN_COPY" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  run_foreign_teardown rc
  expect_code 1 "$rc" "unborn-head: a copy whose HEAD cannot be resolved must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_typed_copy_refusal unborn-head copy-head-resolved
  pass 'a foreign copy whose HEAD cannot be resolved is refused with its rule and a human-only question, once'
}

test_foreign_copy_whose_anchor_names_another_commit_is_a_typed_refusal() {
  local rc short other
  make_foreign_copy_case foreign-typed-anchor-commit
  short=$(git -C "$FOREIGN_COPY" rev-parse --short HEAD)
  other=$(git -C "$FOREIGN_CASE/project" commit-tree -m 'another commit' "$(git -C "$FOREIGN_CASE/project" rev-parse 'HEAD^{tree}')")
  git -C "$FOREIGN_CASE/project" update-ref "refs/fm/anchor/task-x1-$short" "$other"
  run_foreign_teardown rc
  expect_code 1 "$rc" "anchor-commit: an anchor naming another commit must refuse the copy: $(cat "$FOREIGN_CASE/stderr")"
  assert_typed_copy_refusal anchor-commit copy-anchor-commit
  assert_equals "$other" "$(git -C "$FOREIGN_CASE/project" rev-parse "refs/fm/anchor/task-x1-$short")" 'anchor-commit: the existing anchor was overwritten'
  pass 'a foreign copy whose preservation anchor names another commit is refused with its rule and a human-only question, once'
}

test_teardown_usage_and_inspection_errors_are_not_policy_events() {
  local rc
  make_foreign_copy_case typed-non-policy
  rc=0
  FM_HOME="$FOREIGN_CASE/home" "$TEARDOWN" > "$FOREIGN_CASE/usage.out" 2> "$FOREIGN_CASE/usage.err" || rc=$?
  expect_code 2 "$rc" 'usage exit changed'
  assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" 'usage error recorded a policy event'
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in *" worktree list "*) exit 128 ;; esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  run_foreign_teardown rc
  expect_code 1 "$rc" 'Git inspection failure changed exit'
  assert_foreign_copy_untouched typed-non-policy
  assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" 'inspection failure recorded a policy event'
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case "\$1:\${2:-}:\${3:-}" in "-C:$FOREIGN_COPY:status") exit 128 ;; esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  run_foreign_teardown rc
  expect_code 1 "$rc" 'nested-copy status inspection failure changed exit'
  assert_foreign_copy_untouched typed-non-policy
  assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" 'nested-copy status error recorded a policy event'
  pass 'teardown usage and transient Git inspection errors retain exits without policy events'
}

# An own nested copy Vernant's creation lock holds is released through the
# closeout driver; when its interpreter cannot run, that is known at entry, so
# the teardown refuses before any protected step (the return-pending record,
# the endpoint close, the inbox, status or tasktmp removal), for the plain and
# the prior record shapes. With the interpreter there, the same case closes.
test_own_locked_copy_with_no_closeout_interpreter_refuses_at_entry() {
  local shape rc label
  for shape in plain enclosing; do
    label="own-closeout-$shape"
    dead_launcher_pid
    make_own_locked_copy_case "$label" "$shape" "$FOREIGN_DEAD_PID"
    nested_seed_task_files "$FOREIGN_CASE"
    nested_snapshot "$FOREIGN_CASE" "$FOREIGN_CASE/snapshot.before"
    run_foreign_teardown rc FM_TEARDOWN_VERNANT_PYTHON="$FOREIGN_CASE/no-such-python"
    assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "is not available, so it cannot be released"
    assert_absent "$FOREIGN_CASE/closeout.log" "$label: the driver ran"
    run_foreign_teardown rc
    expect_code 0 "$rc" "$label: with the interpreter there the same copy must be released: $(cat "$FOREIGN_CASE/stderr")"
    assert_absent "$FOREIGN_COPY" "$label: the copy survived the release"
    assert_absent "$FOREIGN_CASE/state/task-x1.meta" "$label: the task record survived the release"
  done
  pass "an own Vernant-locked copy whose closeout interpreter cannot run refuses at entry for both record shapes, and closes once it can"
}

# Vernant's closeout driver is asked in plan mode at entry for every locked copy
# the release will hand it: a plan that declines, or answers with no verdict,
# refuses before any protected step, for an own copy of either record shape and
# for a foreign copy; the release itself never runs. An allowing plan lets the
# same case close, and the release asks the driver again.
test_closeout_plan_refusal_refuses_at_entry() {
  local form shape rc label
  for form in refuse garbled; do
    for shape in plain enclosing; do
      label="own-plan-$form-$shape"
      dead_launcher_pid
      make_own_locked_copy_case "$label" "$shape" "$FOREIGN_DEAD_PID"
      nested_seed_task_files "$FOREIGN_CASE"
      nested_snapshot "$FOREIGN_CASE" "$FOREIGN_CASE/snapshot.before"
      run_foreign_teardown rc FM_STUB_PLAN="$form"
      assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "Vernant's closeout driver would not release it"
      assert_present "$FOREIGN_CASE/closeout-plan.log" "$label: the driver was not asked in plan mode"
      assert_absent "$FOREIGN_CASE/closeout.log" "$label: the release ran after a plan refusal"
    done
  done
  label='foreign-plan-refuse'
  dead_launcher_pid
  make_foreign_copy_case "$label" "$FOREIGN_DEAD_PID"
  run_foreign_teardown rc FM_STUB_PLAN=refuse
  expect_code 1 "$rc" "$label: a declining plan must refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "Vernant's closeout driver would not release it" "$FOREIGN_CASE/stderr" "$label: the refusal did not name the plan"
  assert_foreign_copy_untouched "$label"
  assert_absent "$FOREIGN_CASE/state/task-x1.teardown-return-pending" "$label: a return-pending record was written before the refusal"
  label='own-plan-allows'
  dead_launcher_pid
  make_own_locked_copy_case "$label" enclosing "$FOREIGN_DEAD_PID"
  run_foreign_teardown rc
  expect_code 0 "$rc" "$label: an allowing plan must let the copy go: $(cat "$FOREIGN_CASE/stderr")"
  assert_present "$FOREIGN_CASE/closeout-plan.log" "$label: the driver was not asked in plan mode"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "$label: the release did not run once after the plan"
  pass "a closeout plan that declines or gives no verdict refuses at entry for own and foreign copies, and an allowing plan lets the release run"
}

# On Linux the removability check reads each entry's and directory's immutable
# and append-only attributes; an entry it cannot open is doubt and refuses,
# while a readable regular file, a symbolic link (judged by its directory) and an
# absent path pass. macOS asks faccessat instead, and root reads everything.
test_linux_removability_refuses_an_entry_it_cannot_open() {
  local dir rc item
  if [ "$(uname -s)" != Linux ] || [ "$(id -u)" = 0 ]; then
    pass "the Linux removability check refuses an unopenable entry (skipped: needs Linux and a non-root user)"
    return 0
  fi
  dir=$(mktemp -d "$TMP_ROOT/linux-removable.XXXXXX")
  printf 'x\n' > "$dir/unreadable"
  chmod 000 "$dir/unreadable"
  printf 'x\n' > "$dir/readable"
  ln -s "$dir/readable" "$dir/link"
  for item in unreadable:1 readable:0 link:0 absent:0; do
    rc=0
    bash -c '. "$1/bin/fm-backlog-transition-lib.sh"; fm_backlog_path_deletable "$2"' _ "$ROOT" "$dir/${item%%:*}" || rc=$?
    case "${item#*:}" in
      1) [ "$rc" != 0 ] || fail "linux-removable: an entry whose attributes cannot be read passed (${item%%:*})" ;;
      *) expect_code 0 "$rc" "linux-removable: a removable entry was refused (${item%%:*})" ;;
    esac
  done
  chmod 600 "$dir/unreadable"
  pass "the Linux removability check refuses an entry it cannot open and passes readable files, links and absent paths"
}

# The archive of a copy's ignored files is never removed or overwritten: a
# failed copy keeps the earlier one, an identical one is kept as is, a
# different one is kept beside a new archive, and a preserve parent that cannot
# be written refuses at entry with nothing changed.
test_earlier_preserved_copy_survives_until_its_replacement_is_verified() {
  local shape rc exclude hash dest real_cp root label new
  real_cp=$(command -v cp)
  for shape in failed-copy kept-beside same-content read-only-parent; do
    label="own-backup-$shape"
    dead_launcher_pid
    make_own_locked_copy_case "$label" enclosing "$FOREIGN_DEAD_PID"
    exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
    printf 'unique.dat\n' >> "$exclude"
    printf 'only here\n' > "$FOREIGN_COPY/unique.dat"
    hash=$(printf '%s' "$(cd "$FOREIGN_COPY" && pwd -P)" | shasum -a 256 | awk '{print $1}')
    root="$FOREIGN_CASE/data/task-x1/nested-copy-preserved"
    dest="$root/$hash"
    mkdir -p "$dest/files" "$dest/meta"
    if [ "$shape" = same-content ]; then
      printf 'only here\n' > "$dest/files/unique.dat"
      printf '%s\n' "$(cd "$FOREIGN_COPY" && pwd -P)" > "$dest/meta/copy-path"
      printf '%s  unique.dat\n' "$(shasum -a 256 "$dest/files/unique.dat" | awk '{print $1}')" > "$dest/meta/SHA256SUMS"
    else
      printf 'earlier backup\n' > "$dest/files/unique.dat"
      printf 'earlier manifest\n' > "$dest/meta/SHA256SUMS"
    fi
    case "$shape" in
      failed-copy)
        cat > "$FOREIGN_CASE/fakebin/cp" <<SH
#!/usr/bin/env bash
case " \$* " in
  *nested-copy-preserved*|*/.teardown-run.*/ignored-*) : > "$FOREIGN_CASE/cp-failure-injected"; echo "cp: simulated copy failure" >&2; exit 1 ;;
esac
exec "$real_cp" "\$@"
SH
        chmod +x "$FOREIGN_CASE/fakebin/cp"
        ;;
      read-only-parent)
        nested_seed_task_files "$FOREIGN_CASE"
        chmod 555 "$root"
        nested_snapshot "$FOREIGN_CASE" "$FOREIGN_CASE/snapshot.before"
        ;;
    esac
    run_foreign_teardown rc
    case "$shape" in
      failed-copy)
        expect_code 1 "$rc" "$label: a failed preserve must refuse: $(cat "$FOREIGN_CASE/stderr")"
        assert_present "$FOREIGN_CASE/cp-failure-injected" "$label: the refusal came before the injected copy failure"
        assert_present "$FOREIGN_COPY/unique.dat" "$label: the own copy's ignored file was lost"
        assert_equals "earlier backup" "$(cat "$dest/files/unique.dat")" "$label: the earlier preserved copy was destroyed by a failed replacement"
        assert_equals "earlier manifest" "$(cat "$dest/meta/SHA256SUMS")" "$label: the earlier manifest was destroyed by a failed replacement"
        ;;
      kept-beside)
        expect_code 0 "$rc" "$label: a verified preserve must release the copy: $(cat "$FOREIGN_CASE/stderr")"
        assert_equals "earlier backup" "$(cat "$dest/files/unique.dat")" "$label: the earlier preserved copy was replaced"
        assert_equals "earlier manifest" "$(cat "$dest/meta/SHA256SUMS")" "$label: the earlier manifest was replaced"
        new=$(find "$root" -mindepth 1 -maxdepth 1 -name "$hash.*" -type d)
        [ "$(printf '%s\n' "$new" | grep -c .)" = 1 ] || fail "$label: no single new preserve was kept beside the earlier one: $new"
        assert_equals "only here" "$(cat "$new/files/unique.dat")" "$label: the new preserve does not hold the copy's bytes"
        assert_grep "$(shasum -a 256 "$new/files/unique.dat" | awk '{print $1}')  unique.dat" "$new/meta/SHA256SUMS" \
          "$label: the new manifest does not describe the preserved bytes"
        ;;
      same-content)
        expect_code 0 "$rc" "$label: an identical earlier preserve must let the copy go: $(cat "$FOREIGN_CASE/stderr")"
        assert_equals "only here" "$(cat "$dest/files/unique.dat")" "$label: the identical preserve changed"
        [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -name "$hash.*")" ] || fail "$label: a duplicate preserve was written beside an identical one"
        assert_absent "$FOREIGN_COPY" "$label: the copy survived"
        ;;
      read-only-parent)
        chmod 755 "$root"
        if [ "$(id -u)" = 0 ]; then
          expect_code 0 "$rc" "$label: root writes any parent, so the copy is released: $(cat "$FOREIGN_CASE/stderr")"
        else
          assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "cannot be written through"
          assert_equals "earlier backup" "$(cat "$dest/files/unique.dat")" "$label: the earlier preserved copy was lost"
          assert_absent "$FOREIGN_CASE/closeout.log" "$label: the driver ran"
        fi
        ;;
    esac
  done
  pass "an earlier preserve of a locked own copy is never removed: a failed copy, an identical one, a different one and an unwritable parent all keep it"
}

# The preserve parent must be a real directory whose physical location is
# outside the copies this teardown removes: a parent that is a link, or a data
# folder that resolves into the copy, refuses at entry with nothing changed. A
# user file named like the metadata never meets it: the bytes sit under files/
# and the manifest under meta/.
test_preserve_parent_and_metadata_boundaries() {
  local shape rc exclude label root preserved name
  for shape in parent-link data-in-copy metadata-names; do
    label="preserve-boundary-$shape"
    dead_launcher_pid
    make_own_locked_copy_case "$label" enclosing "$FOREIGN_DEAD_PID"
    exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
    printf 'unique.dat\nSHA256SUMS\ncopy-path\nkept/\n' >> "$exclude"
    printf 'only here\n' > "$FOREIGN_COPY/unique.dat"
    root="$FOREIGN_CASE/data/task-x1/nested-copy-preserved"
    case "$shape" in
      parent-link)
        mkdir -p "$FOREIGN_COPY/kept" "$FOREIGN_CASE/data/task-x1"
        ln -s "$FOREIGN_COPY/kept" "$root"
        ;;
      data-in-copy)
        mkdir -p "$FOREIGN_COPY/kept"
        rm -rf "$FOREIGN_CASE/data/task-x1"
        ln -s "$FOREIGN_COPY/kept" "$FOREIGN_CASE/data/task-x1"
        ;;
      metadata-names)
        printf 'user manifest\n' > "$FOREIGN_COPY/SHA256SUMS"
        printf 'user path\n' > "$FOREIGN_COPY/copy-path"
        ;;
    esac
    nested_seed_task_files "$FOREIGN_CASE"
    nested_snapshot "$FOREIGN_CASE" "$FOREIGN_CASE/snapshot.before"
    run_foreign_teardown rc
    case "$shape" in
      parent-link)
        assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "is not a real directory"
        ;;
      data-in-copy)
        assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "which this teardown removes"
        ;;
      metadata-names)
        expect_code 0 "$rc" "$label: the copy must be released: $(cat "$FOREIGN_CASE/stderr")"
        preserved=$(find "$root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        assert_equals 'user manifest' "$(cat "$preserved/files/SHA256SUMS")" "$label: a user file named SHA256SUMS was not kept as is"
        assert_equals 'user path' "$(cat "$preserved/files/copy-path")" "$label: a user file named copy-path was not kept as is"
        assert_equals 'only here' "$(cat "$preserved/files/unique.dat")" "$label: the other ignored file was not kept"
        for name in SHA256SUMS copy-path unique.dat; do
          assert_grep "$(shasum -a 256 "$preserved/files/$name" | awk '{print $1}')  $name" "$preserved/meta/SHA256SUMS" \
            "$label: the manifest does not hash the user file $name"
        done
        ;;
    esac
  done
  pass "a preserve parent that is a link or resolves into the copy refuses at entry, and user files named like the metadata are kept apart from it"
}

# The same-device check reads the parent each rename really targets: a preserve
# parent on another filesystem refuses at entry when the release will preserve
# into it, though the task's data folder itself shares the run directory's.
test_preserve_parent_on_another_filesystem_refuses_at_entry() {
  local rc exclude label=preserve-parent-xdev root
  dead_launcher_pid
  make_own_locked_copy_case "$label" enclosing "$FOREIGN_DEAD_PID"
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf 'unique.dat\n' >> "$exclude"
  printf 'only here\n' > "$FOREIGN_COPY/unique.dat"
  root="$FOREIGN_CASE/data/task-x1/nested-copy-preserved"
  mkdir -p "$root"
  teardown_test_fake_other_device "$FOREIGN_CASE/fakebin" "$root"
  nested_seed_task_files "$FOREIGN_CASE"
  nested_snapshot "$FOREIGN_CASE" "$FOREIGN_CASE/snapshot.before"
  run_foreign_teardown rc
  assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "$root are not on one filesystem"
  assert_absent "$FOREIGN_CASE/closeout.log" "$label: the driver ran"
  pass "a preserve parent on another filesystem refuses at entry when a release will preserve into it"
}

test_a_held_copy_keeps_its_unique_ignored_files_and_none_are_preserved() {
  local rc
  make_held_case held-ignored
  held_foreign_unlanded "$FOREIGN_COPY"
  held_ignored_file "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-ignored: a landed task must close beside a copy with unpushed commits and ignored files: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-ignored
  held_assert_untouched held-ignored "$FOREIGN_CASE" "$FOREIGN_COPY"
  assert_present "$FOREIGN_COPY/unique.dat" "held-ignored: the held copy's ignored file is gone"
  assert_equals "only here" "$(cat "$FOREIGN_COPY/unique.dat")" "held-ignored: the held copy's ignored file changed"
  assert_absent "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" "held-ignored: a held copy's ignored files were copied as if the copy were removed"
  assert_no_grep "REFUSED" "$FOREIGN_CASE/stderr" "held-ignored: a close that succeeded printed a refusal"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" "held-ignored: the record is not one line"
  pass "a held copy keeps its unique ignored files in place: nothing of it is copied, moved or removed, and the record has one line"
}

test_task_closes_beside_a_foreign_copy_with_unpushed_commits() {
  local rc
  make_held_case held-unlanded
  held_foreign_unlanded "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-unlanded: a landed task must close beside a foreign copy that holds unpushed commits: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-unlanded
  held_assert_untouched held-unlanded "$FOREIGN_CASE" "$FOREIGN_COPY"
  git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
    || fail "held-unlanded: the foreign copy's branch was deleted"
  assert_no_grep "REFUSED" "$FOREIGN_CASE/stderr" "held-unlanded: a close that succeeded printed a refusal"
  assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: its HEAD " "$FOREIGN_CASE/stdout" \
    "held-unlanded: the output did not list the held copy and its reason"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" "held-unlanded: the record is not one line"
  pass "a task whose own copy landed closes beside a foreign copy with commits on no remote, which stays byte-identical, with the slot still reserved"
}

test_held_copy_record_has_one_exact_line_per_copy() {
  local rc second line record fields copy
  make_held_case held-two
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
  held_foreign_unlanded "$FOREIGN_COPY"
  held_foreign_unlanded "$second"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY" "$second"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-two: a landed task must close beside two held copies: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-two
  held_assert_untouched held-two "$FOREIGN_CASE" "$FOREIGN_COPY" "$second"
  record=$FOREIGN_CASE/data/held-foreign-copies.log
  assert_equals 2 "$(wc -l < "$record" | tr -d ' ')" "held-two: two foreign copies must give two lines"
  while IFS= read -r line; do
    fields=$(printf '%s\n' "$line" | awk -F'\t' '{ print NF }')
    assert_equals 5 "$fields" "held-two: a record line is not five tab-separated fields: $line"
    printf '%s\n' "$line" | awk -F'\t' '$1 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ { exit 1 }' \
      || fail "held-two: the first field is not a UTC time: $line"
    printf '%s\n' "$line" | awk -F'\t' -v s="$FOREIGN_SLOT" '$2 == "task-x1" && $3 == s { ok = 1 } END { exit !ok }' \
      || fail "held-two: the closing task or slot is wrong: $line"
  done < "$record"
  for copy in "$FOREIGN_COPY" "$second"; do
    awk -F'\t' -v c="$copy" '$4 == c && $5 ~ /^its HEAD [0-9a-f]{12} is not proved landed$/ { ok = 1 } END { exit !ok }' "$record" \
      || fail "held-two: the line of $copy is missing or its reason is not exact: $(cat "$record")"
  done
  pass "each held foreign copy gets one record line with UTC time, closing task, slot, copy and its exact reason"
}

test_a_held_close_removes_only_the_tasks_own_nested_copy() {
  local rc shape locked second pid=
  for shape in enclosing reverse; do
    for locked in plain locked; do
      pid=
      if [ "$locked" = locked ]; then
        dead_launcher_pid
        pid=$FOREIGN_DEAD_PID
      fi
      make_own_locked_copy_case "held-own-nested-$shape-$locked" "$shape" "$pid"
      printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
      add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
      seed_backlog_in_flight "$FOREIGN_CASE"
      second=$FOREIGN_SLOT/.claude/worktrees/fc-two
      git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
      held_foreign_unlanded "$second"
      held_snapshot "$FOREIGN_CASE" "$second"
      run_foreign_teardown rc
      expect_code 0 "$rc" "held-own-nested-$shape-$locked: a landed task must close beside a held foreign copy: $(cat "$FOREIGN_CASE/stderr")"
      held_assert_closed "held-own-nested-$shape-$locked"
      assert_absent "$FOREIGN_COPY" "held-own-nested-$shape-$locked: the task's own nested copy survived"
      git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
        || fail "held-own-nested-$shape-$locked: the own copy's branch was deleted"
      assert_absent "$FOREIGN_CASE/treehouse.log" "held-own-nested-$shape-$locked: the pool slot was returned"
      cmp -s "$FOREIGN_CASE/treehouse-state.before" "$FOREIGN_CASE/pool/treehouse-state.json" \
        || fail "held-own-nested-$shape-$locked: Treehouse's lease changed"
      cmp -s "$FOREIGN_CASE/slot-owner.before" "$FOREIGN_CASE/pool/1/.fm-slot-owner" \
        || fail "held-own-nested-$shape-$locked: the slot claim changed"
      held_fingerprint "$second" | cmp -s - "$FOREIGN_CASE/held-before.fc-two" \
        || fail "held-own-nested-$shape-$locked: the foreign copy changed"
      assert_present "$second/unlanded.txt" "held-own-nested-$shape-$locked: the foreign copy's unique file is gone"
      if [ "$locked" = locked ]; then
        assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
          "held-own-nested-$shape-$locked: the driver was not run once, for the own copy only"
      else
        assert_absent "$FOREIGN_CASE/closeout.log" "held-own-nested-$shape-$locked: the closeout driver ran for an unlocked copy"
      fi
    done
  done
  pass "a held close removes the task's own nested copy, through the driver when it is locked, and leaves the slot, its lease and claim and the held foreign copy alone"
}

# A held close removes the task's own nested copy with whatever it holds. A
# separate Git repository, or a linked worktree of another project, under that
# copy would lose its commits with no ref left behind, and the registered-copy
# list never sees it. The repository sits under .claude, where the own-copy
# clean proof does not look, as the independent reader's probe placed it.
test_a_held_close_refuses_when_an_own_nested_copy_holds_another_repository() {
  local rc shape locked pid second nested other commits
  for shape in separate-repository other-project-worktree; do
    for locked in plain locked; do
      pid=
      if [ "$locked" = locked ]; then
        dead_launcher_pid
        pid=$FOREIGN_DEAD_PID
      fi
      make_own_locked_copy_case "held-other-repo-$shape-$locked" enclosing "$pid"
      printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
      add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
      seed_backlog_in_flight "$FOREIGN_CASE"
      second=$FOREIGN_SLOT/.claude/worktrees/fc-two
      git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
      held_foreign_unlanded "$second"
      nested=$FOREIGN_COPY/.claude/cross-project
      mkdir -p "$FOREIGN_COPY/.claude"
      if [ "$shape" = separate-repository ]; then
        git init -q "$nested"
      else
        other=$FOREIGN_CASE/other-project
        git init -q "$other"
        printf 'base\n' > "$other/base.txt"
        git -C "$other" add base.txt
        git -C "$other" -c user.email=t@t -c user.name=t commit -qm 'other project base'
        git -C "$other" worktree add -q -b other-lane "$nested"
      fi
      printf 'one\n' > "$nested/unique.txt"
      git -C "$nested" add unique.txt
      git -C "$nested" -c user.email=t@t -c user.name=t commit -qm 'first unlanded commit'
      printf 'two\n' >> "$nested/unique.txt"
      git -C "$nested" -c user.email=t@t -c user.name=t commit -qam 'second unlanded commit'
      commits=$(git -C "$nested" rev-parse HEAD)
      held_snapshot "$FOREIGN_CASE" "$second"
      run_foreign_teardown rc
      expect_code 1 "$rc" "held-other-repo-$shape-$locked: a held close must not remove an own copy that holds another repository: $(cat "$FOREIGN_CASE/stderr")"
      assert_grep "Git repository $nested inside task task-x1's nested copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" \
        "held-other-repo-$shape-$locked: the refusal did not name the repository: $(cat "$FOREIGN_CASE/stderr")"
      assert_grep "nothing was removed" "$FOREIGN_CASE/stderr" "held-other-repo-$shape-$locked: the refusal did not say nothing was removed"
      assert_present "$FOREIGN_COPY" "held-other-repo-$shape-$locked: the own nested copy was removed"
      assert_present "$nested/unique.txt" "held-other-repo-$shape-$locked: the other repository's file is gone"
      assert_equals "$commits" "$(git -C "$nested" rev-parse HEAD)" "held-other-repo-$shape-$locked: the other repository's commits changed"
      if [ "$shape" = other-project-worktree ]; then
        git -C "$other" worktree list --porcelain | grep -F "worktree $nested" >/dev/null \
          || fail "held-other-repo-$shape-$locked: the other project's worktree registration was lost"
      fi
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-other-repo-$shape-$locked: the task record was removed"
      [ "$(backlog_row_state "$FOREIGN_CASE")" != "done" ] || fail "held-other-repo-$shape-$locked: the backlog item was closed by a refused close"
      assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-other-repo-$shape-$locked: a refused close wrote a held-copy record"
      git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
        || fail "held-other-repo-$shape-$locked: the own copy's branch was deleted"
      held_assert_untouched "held-other-repo-$shape-$locked" "$FOREIGN_CASE" "$second"
    done
  done
  pass "a held close refuses, with nothing removed, when an own nested copy holds a separate repository or another project's worktree"
}

# A submodule of the task's own repository is not another repository: its git
# directory lives in the own repository's, so the held close still goes ahead.
test_a_held_close_is_not_stopped_by_a_submodule_of_the_own_repository() {
  local rc second sub
  make_own_locked_copy_case held-submodule enclosing
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
  seed_backlog_in_flight "$FOREIGN_CASE"
  sub=$FOREIGN_CASE/sub-source
  git init -q "$sub"
  printf 'sub\n' > "$sub/file.txt"
  git -C "$sub" add file.txt
  git -C "$sub" -c user.email=t@t -c user.name=t commit -qm 'sub'
  git -C "$FOREIGN_COPY" -c protocol.file.allow=always submodule add -q "$sub" vendor/sub
  git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm 'add submodule'
  git -C "$FOREIGN_CASE/project" update-ref refs/heads/main "$(git -C "$FOREIGN_COPY" rev-parse HEAD)"
  add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_COPY" rev-parse HEAD)"
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
  held_foreign_unlanded "$second"
  held_snapshot "$FOREIGN_CASE" "$second"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-submodule: a submodule of the own repository must not stop a held close: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-submodule
  assert_absent "$FOREIGN_COPY" "held-submodule: the own nested copy survived"
  pass "a submodule of the task's own repository does not stop a held close"
}

test_a_foreign_copy_inside_the_own_nested_copy_is_never_left_to_the_removal() {
  local rc own shape locked pid inner second target label
  local -a watch
  for own in enclosing reverse; do
    for shape in held-inside provable-inside; do
      for locked in plain locked; do
        label="held-inside-$own-$shape-$locked"
        pid=
        if [ "$locked" = locked ]; then
          dead_launcher_pid
          pid=$FOREIGN_DEAD_PID
        fi
        make_own_locked_copy_case "$label" "$own" "$pid"
        printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
        add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
        seed_backlog_in_flight "$FOREIGN_CASE"
        inner=$FOREIGN_COPY/.claude/worktrees/fc-inner
        second=$FOREIGN_SLOT/.claude/worktrees/fc-two
        git -C "$FOREIGN_CASE/project" worktree add -q -b fm/inner-lane "$inner" main
        if [ "$shape" = held-inside ]; then
          held_foreign_unlanded "$inner"
          target=$inner
          watch=("$inner")
        else
          git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
          held_foreign_unlanded "$second"
          target=$second
          watch=("$inner" "$second")
        fi
        held_snapshot "$FOREIGN_CASE" "${watch[@]}"
        run_foreign_teardown rc
        expect_code 1 "$rc" "$label: removing the own copy would take a foreign copy with it, so the close must refuse: $(cat "$FOREIGN_CASE/stderr")"
        assert_grep "contains registered copy $target" "$FOREIGN_CASE/stderr" "$label: the refusal did not name the copy that stays"
        assert_present "$FOREIGN_COPY" "$label: the own nested copy was removed"
        assert_present "$FOREIGN_CASE/state/task-x1.meta" "$label: the task record was removed"
        assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "$label: a refused close wrote a held-copy record"
        git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
          || fail "$label: the own copy's branch was deleted"
        assert_present "$inner/.git" "$label: the foreign copy inside the own copy is gone"
        assert_present "$target/unlanded.txt" "$label: the foreign copy's unique file is gone"
        held_assert_untouched "$label" "$FOREIGN_CASE" "${watch[@]}"
      done
    done
  done
  pass "a foreign copy inside the own nested copy is never held or swept away: the close refuses and every copy, the slot, its lease and claim stay as they were"
}

test_an_ordinary_close_never_turns_into_a_held_close_during_the_project_lock_wait() {
  local rc lock holder actor late i actor_rc
  make_own_locked_copy_case route-flip-wait enclosing
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
  add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
  seed_backlog_in_flight "$FOREIGN_CASE"
  lock=$(FM_HOME="$FOREIGN_CASE/home" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$ROOT" "$FOREIGN_CASE/project") \
    || fail "route-flip-wait: cannot resolve the shared Treehouse project lock"
  late=$FOREIGN_SLOT/.claude/worktrees/fc-late
  cat > "$FOREIGN_CASE/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in *'#{pane_pid}'*) if [ -f "$FOREIGN_CASE/pane-rows" ]; then cat "$FOREIGN_CASE/pane-rows"; elif [ -f "$FOREIGN_CASE/pane-pid" ]; then printf 'fm-task-x1\t%%1\t%s\n' "\$(cat "$FOREIGN_CASE/pane-pid")"; fi ;; esac
case "\${1:-}" in list-windows) if [ -f "$FOREIGN_CASE/pane-rows" ]; then cut -f1 "$FOREIGN_CASE/pane-rows" | sort -u; elif [ -f "$FOREIGN_CASE/pane-pid" ]; then echo fm-task-x1; fi ;; esac
case "\${1:-}" in
  kill-window)
    : > "$FOREIGN_CASE/closing"
    i=0
    while [ ! -f "$FOREIGN_CASE/project-held" ]; do
      i=\$((i + 1)); [ "\$i" -lt 2000 ] || exit 1
      sleep 0.05
    done
    ;;
esac
exit 0
SH
  chmod +x "$FOREIGN_CASE/fakebin/tmux"
  (
    run_foreign_teardown actor_rc FM_PROJECT_LOCK_POLL_SECS=0.05
    printf '%s' "$actor_rc" > "$FOREIGN_CASE/actor.rc"
  ) &
  actor=$!
  i=0
  while [ ! -f "$FOREIGN_CASE/closing" ]; do
    i=$((i + 1)); [ "$i" -lt 1000 ] || { kill "$actor" 2>/dev/null || true; fail "route-flip-wait: teardown did not reach the endpoint close: $(cat "$FOREIGN_CASE/stderr")"; }
    sleep 0.05
  done
  hold_project_lock_until_release "$FOREIGN_CASE" "$lock" &
  holder=$!
  i=0
  while [ "$(queued_tickets "$lock")" = 0 ]; do
    if ! kill -0 "$actor" 2>/dev/null; then
      : > "$FOREIGN_CASE/release"; wait "$holder" || true
      fail "route-flip-wait: teardown exited instead of waiting for the project lock: $(cat "$FOREIGN_CASE/stderr")"
    fi
    i=$((i + 1)); [ "$i" -lt 1000 ] || {
      : > "$FOREIGN_CASE/release"; wait "$holder" || true; wait "$actor" || true
      fail "route-flip-wait: teardown never queued for the project lock: $(cat "$FOREIGN_CASE/stderr")"
    }
    sleep 0.05
  done
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/late-lane "$late" main
  held_ignored_file "$late"
  held_snapshot "$FOREIGN_CASE" "$late"
  : > "$FOREIGN_CASE/release"
  wait "$holder" || fail "route-flip-wait: the project lock holder could not release"
  wait "$actor" || true
  rc=$(cat "$FOREIGN_CASE/actor.rc")
  expect_code 1 "$rc" "route-flip-wait: a foreign copy that appeared during the wait must stop the close: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "a foreign copy in pool slot $FOREIGN_SLOT changed since the slot was proved, so the slot is not returned" "$FOREIGN_CASE/stderr" \
    "route-flip-wait: the refusal did not say the route changed"
  assert_present "$FOREIGN_COPY" "route-flip-wait: the own nested copy was removed before the refusal"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "route-flip-wait: the task record was removed"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "route-flip-wait: a refused close wrote a held-copy record"
  git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
    || fail "route-flip-wait: the own copy's branch was deleted"
  held_assert_untouched route-flip-wait "$FOREIGN_CASE" "$late"
  assert_present "$late/unique.dat" "route-flip-wait: the late foreign copy's unique file is gone"
  pass "an ordinary close whose slot gains a copy holding unique ignored files during the project-lock wait refuses with nothing removed"
}

# A foreign copy that appears in the slot while its stale lock blocks the return
# (here on the first failed return, since a retry waits while the lock is there)
# must stop the return at the reproof after the stale-lock cleanup: the route
# changed, so neither an ordinary return nor a held close may follow.
test_a_stale_lock_cleanup_never_turns_an_ordinary_close_into_a_held_close() {
  local case_dir rc lock late
  make_nested_slot_case route-flip-stale-lock enclosing .claude/worktrees/x
  case_dir=$NESTED_CASE
  late=$NESTED_SLOT/.claude/worktrees/fc-late
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = return ] || exit 0
wt=\${@: -1}
lock=\$(git -C "\$wt" rev-parse --path-format=absolute --git-path index.lock 2>/dev/null || true)
if [ -n "\$lock" ] && [ -e "\$lock" ]; then
  calls=\$(( \$(cat "$case_dir/return-calls" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "\$calls" > "$case_dir/return-calls"
  if [ "\$calls" = 1 ]; then
    git -C "$case_dir/project" worktree add -q -b fm/late-lane "$late" main
    exclude=\$(git -C "$late" rev-parse --path-format=absolute --git-path info/exclude)
    printf 'unique.dat\n' >> "\$exclude"
    printf 'only here\n' > "$late/unique.dat"
  fi
  echo "fatal: Unable to create '\$lock': File exists." >&2
  exit 128
fi
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  add_lsof_no_holder "$case_dir"
  lock=$(git_index_lock_path "$NESTED_SLOT")
  : > "$lock"
  touch -t 200001010000 "$lock"
  rc=0
  FM_HOME="$case_dir/home" FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "route-flip-stale-lock: a foreign copy that appeared during the return must stop it: $(cat "$case_dir/stderr")"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" "route-flip-stale-lock: the stale lock was not cleaned up, so the probe proves nothing"
  assert_grep "a foreign copy in pool slot $NESTED_SLOT changed since the slot was proved, so the slot is not returned" "$case_dir/stderr" \
    "route-flip-stale-lock: the refusal did not say the route changed"
  assert_absent "$case_dir/treehouse.log" "route-flip-stale-lock: the slot was returned"
  assert_present "$late/unique.dat" "route-flip-stale-lock: the late foreign copy's unique file is gone"
  assert_present "$case_dir/state/task-x1.meta" "route-flip-stale-lock: the task record was removed"
  assert_absent "$case_dir/data/held-foreign-copies.log" "route-flip-stale-lock: a refused close wrote a held-copy record"
  pass "a stale-lock cleanup refuses when the slot gained a copy holding unique ignored files, instead of turning the close into a held close"
}

test_a_held_close_reserves_a_plain_get_slot_durably() {
  local rc shape held
  for shape in slot-root own-nested; do
    if [ "$shape" = slot-root ]; then
      make_held_case "held-plain-get-$shape"
      held=$FOREIGN_COPY
    else
      make_own_locked_copy_case "held-plain-get-$shape" enclosing
      printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
      add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
      seed_backlog_in_flight "$FOREIGN_CASE"
      held=$FOREIGN_SLOT/.claude/worktrees/fc-two
      git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$held" main
    fi
    held_foreign_unlanded "$held"
    held_plain_get_slot "$FOREIGN_CASE"
    jq -e '.worktrees[0].leased == false' "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null \
      || fail "held-plain-get-$shape: the fixture slot is not a plain-get slot"
    held_snapshot "$FOREIGN_CASE" "$held"
    run_foreign_teardown rc
    expect_code 0 "$rc" "held-plain-get-$shape: a landed task must close beside a held copy in a plain-get slot: $(cat "$FOREIGN_CASE/stderr")"
    held_assert_closed "held-plain-get-$shape"
    jq -e '.worktrees[0].leased == true and .worktrees[0].lease_holder == "task-x1"' "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null \
      || fail "held-plain-get-$shape: the slot is not durably leased after the close: $(cat "$FOREIGN_CASE/pool/treehouse-state.json")"
    assert_equals "lease 1 --lease-holder task-x1" "$(cat "$FOREIGN_CASE/lease.log")" \
      "held-plain-get-$shape: the slot was not reserved exactly once"
    if [ "$shape" = slot-root ]; then
      held_assert_copies_untouched "held-plain-get-$shape" "$FOREIGN_CASE" "$held"
    else
      assert_absent "$FOREIGN_COPY" "held-plain-get-$shape: the task's own nested copy survived"
      held_fingerprint "$held" | cmp -s - "$FOREIGN_CASE/held-before.$(basename "$held")" \
        || fail "held-plain-get-$shape: the foreign copy changed"
      cmp -s "$FOREIGN_CASE/claim-before" "$FOREIGN_CASE/pool/1/.fm-slot-owner" || fail "held-plain-get-$shape: the slot's claim changed"
      git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -F "worktree $held" >/dev/null \
        || fail "held-plain-get-$shape: the foreign copy is no longer registered"
      assert_absent "$FOREIGN_CASE/treehouse.log" "held-plain-get-$shape: the pool slot was returned"
      assert_absent "$FOREIGN_CASE/closeout.log" "held-plain-get-$shape: the closeout driver ran"
    fi
    assert_present "$held/unlanded.txt" "held-plain-get-$shape: the foreign copy's unique file is gone"
    assert_grep "is reserved under a durable lease and stays claimed" "$FOREIGN_CASE/stdout" \
      "held-plain-get-$shape: the output did not say the slot is reserved"
  done
  pass "a held close reserves a plain-get slot under a durable lease before it removes anything and leaves the held copy byte-identical"
}

test_a_held_close_refuses_when_the_slot_cannot_be_durably_leased() {
  local rc mode held reason
  for mode in lease-fails no-lease-command; do
    make_own_locked_copy_case "held-no-lease-$mode" enclosing
    printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
    add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
    seed_backlog_in_flight "$FOREIGN_CASE"
    held=$FOREIGN_SLOT/.claude/worktrees/fc-two
    git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$held" main
    held_foreign_unlanded "$held"
    held_plain_get_slot "$FOREIGN_CASE"
    : > "$FOREIGN_CASE/$mode"
    held_snapshot "$FOREIGN_CASE" "$held"
    run_foreign_teardown rc
    expect_code 1 "$rc" "held-no-lease-$mode: a held close must refuse when the slot cannot be durably leased: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "REFUSED: pool slot $FOREIGN_SLOT could not be durably leased" "$FOREIGN_CASE/stderr" \
      "held-no-lease-$mode: the refusal did not name the slot: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "nothing was removed" "$FOREIGN_CASE/stderr" "held-no-lease-$mode: the refusal did not say nothing was removed"
    case "$mode" in
      lease-fails) reason="Error: the lease could not be recorded" ;;
      no-lease-command) reason="has no lease command to reserve it" ;;
    esac
    assert_grep "$reason" "$FOREIGN_CASE/stderr" "held-no-lease-$mode: the refusal did not say why the lease failed"
    assert_present "$FOREIGN_COPY" "held-no-lease-$mode: the task's own nested copy was removed"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-no-lease-$mode: the task record was removed"
    [ "$(backlog_row_state "$FOREIGN_CASE")" != "done" ] || fail "held-no-lease-$mode: the backlog item was closed by a refused close"
    assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-no-lease-$mode: a refused close wrote a held-copy record"
    jq -e '.worktrees[0].leased == false' "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null \
      || fail "held-no-lease-$mode: the slot's lease record changed"
    held_assert_untouched "held-no-lease-$mode" "$FOREIGN_CASE" "$held"
  done
  pass "a held close refuses before it removes anything when the slot cannot be durably leased, and says why"
}

# A held close that cannot durably lease its slot is an entry-decidable refusal,
# so it leaves a pending-close record from an earlier failed run, and the return
# record beside it, byte for byte, for a prior and a plain record; the same
# fixture with a slot that leases closes normally and retires both.
held_marker_case() {  # <label> <enclosing|plain>
  make_own_locked_copy_case "$1" "$2"
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
  add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
  seed_backlog_in_flight "$FOREIGN_CASE"
  HELD_COPY=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$HELD_COPY" main
  held_foreign_unlanded "$HELD_COPY"
  held_plain_get_slot "$FOREIGN_CASE"
  nested_place_leftovers "$FOREIGN_CASE"
  cp "$FOREIGN_CASE/state/task-x1.backlog-close" "$FOREIGN_CASE/backlog-close.before"
  cp "$FOREIGN_CASE/state/task-x1.teardown-return-pending" "$FOREIGN_CASE/return-pending.before"
}

# The entry checks of a held close, one named test per control and record shape.
# held_entry_case <label> <plain|enclosing> <scenario> runs one teardown of a
# held close whose record, lease or inventory is in the state the scenario
# names. The refusal scenarios must leave a pending-close record and a
# return-pending record placed beforehand byte for byte, take no lease and
# write no held-copy record, before the slot is reserved; the others close.
held_entry_refused() {  # <label> <fragment>
  local label=$1 fragment=$2
  expect_code 1 "$HELD_RC" "$label: the held close must refuse at entry: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "$fragment" "$FOREIGN_CASE/stderr" "$label: the refusal did not name its cause"
  cmp -s "$FOREIGN_CASE/backlog-close.before" "$FOREIGN_CASE/state/task-x1.backlog-close" || fail "$label: the refusal changed the pending-close record"
  cmp -s "$FOREIGN_CASE/return-pending.before" "$FOREIGN_CASE/state/task-x1.teardown-return-pending" || fail "$label: the refusal changed the return-pending record"
  jq -e '.worktrees[0].leased == false' "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null || fail "$label: the refusal took a lease"
  assert_present "$FOREIGN_COPY" "$label: the task's own nested copy was removed"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "$label: the task record was removed"
  held_assert_untouched "$label" "$FOREIGN_CASE" "$HELD_COPY"
}

held_entry_case() {  # <label> <plain|enclosing> <scenario>
  local label=$1 shape=$2 scenario=$3 data
  held_marker_case "$label" "$shape"
  data=$FOREIGN_CASE/data
  mkdir -p "$data"
  HELD_RC=0
  case "$scenario" in
    lease-no-command) : > "$FOREIGN_CASE/no-lease-command" ;;
    lease-fails) : > "$FOREIGN_CASE/lease-fails" ;;
    record-directory) mkdir "$data/held-foreign-copies.log" ;;
    unrecorded-readonly | symlink-unrecorded-readonly)
      printf '2000-01-01T00:00:00Z\ttask-x1\t/elsewhere\t/elsewhere/copy\tother reason\n' > "$data/real-held-log"
      chmod a-w "$data/real-held-log"
      if [ "$scenario" = unrecorded-readonly ]; then mv "$data/real-held-log" "$data/held-foreign-copies.log"; else ln -s real-held-log "$data/held-foreign-copies.log"; fi
      # A user who can write a read-only file (root) cannot show this refusal.
      if [ -w "$data/held-foreign-copies.log" ]; then HELD_RC=skip; return 0; fi
      ;;
    no-backlog-pending-close-directory)
      # No backlog data applies, so only the clear of the previous pending-close
      # record would refuse this path: it must be refused at entry.
      rm -f "$FOREIGN_CASE/data/backlog.md" "$FOREIGN_CASE/state/task-x1.backlog-close"
      mkdir "$FOREIGN_CASE/state/task-x1.backlog-close"
      ;;
    symlink-dangling) ln -s no-such-target "$data/held-foreign-copies.log" ;;
    symlink-directory) mkdir "$data/real-held-dir"; ln -s real-held-dir "$data/held-foreign-copies.log" ;;
    symlink-writable)
      printf '2000-01-01T00:00:00Z\ttask-x1\t/elsewhere\t/elsewhere/copy\tother reason\n' > "$data/real-held-log"
      ln -s real-held-log "$data/held-foreign-copies.log"
      ;;
    recorded-readonly | recorded-writable)
      stuck_endpoint_tmux "$FOREIGN_CASE"
      : > "$FOREIGN_CASE/endpoint-stuck"
      run_foreign_teardown HELD_RC
      expect_code 1 "$HELD_RC" "$label: a stuck endpoint must refuse the first close: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals 1 "$(wc -l < "$data/held-foreign-copies.log" | tr -d ' ')" "$label: the first close did not record its one held copy"
      cp "$data/held-foreign-copies.log" "$FOREIGN_CASE/record.before"
      [ "$scenario" = recorded-writable ] || chmod a-w "$data/held-foreign-copies.log"
      rm -f "$FOREIGN_CASE/endpoint-stuck"
      ;;
  esac
  held_snapshot "$FOREIGN_CASE" "$HELD_COPY"
  run_foreign_teardown HELD_RC
}

held_entry_scenario() {  # <plain|enclosing> <scenario>
  local shape=$1 scenario=$2 label="held-entry-$2-$1" data
  held_entry_case "$label" "$shape" "$scenario"
  data=$FOREIGN_CASE/data
  [ "$HELD_RC" != skip ] || return 0
  case "$scenario" in
    lease-no-command | lease-fails)
      held_entry_refused "$label" "REFUSED: pool slot $FOREIGN_SLOT could not be durably leased"
      assert_absent "$data/held-foreign-copies.log" "$label: a refused close wrote a held-copy record"
      ;;
    record-directory | unrecorded-readonly | symlink-dangling | symlink-directory | symlink-unrecorded-readonly)
      held_entry_refused "$label" "REFUSED: the held-copy record $data/held-foreign-copies.log could not be written"
      ;;
    no-backlog-pending-close-directory)
      expect_code 1 "$HELD_RC" "$label: the held close must refuse at entry: $(cat "$FOREIGN_CASE/stderr")"
      assert_grep "is not a regular file" "$FOREIGN_CASE/stderr" "$label: the refusal did not name its cause"
      [ -d "$FOREIGN_CASE/state/task-x1.backlog-close" ] || fail "$label: the refusal removed the bad pending-close path"
      cmp -s "$FOREIGN_CASE/return-pending.before" "$FOREIGN_CASE/state/task-x1.teardown-return-pending" || fail "$label: the refusal changed the return-pending record"
      jq -e '.worktrees[0].leased == false' "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null || fail "$label: the refusal took a lease"
      assert_absent "$data/held-foreign-copies.log" "$label: a refused close wrote a held-copy record"
      assert_present "$FOREIGN_COPY" "$label: the task's own nested copy was removed"
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "$label: the task record was removed"
      held_assert_untouched "$label" "$FOREIGN_CASE" "$HELD_COPY"
      ;;
    symlink-writable)
      expect_code 0 "$HELD_RC" "$label: a symlink to a writable record must let the close finish: $(cat "$FOREIGN_CASE/stderr")"
      held_assert_closed "$label"
      assert_equals 2 "$(wc -l < "$data/real-held-log" | tr -d ' ')" "$label: the close did not append through the symlink"
      ;;
    recorded-readonly | recorded-writable)
      expect_code 0 "$HELD_RC" "$label: the rerun must close, since every held copy is already recorded: $(cat "$FOREIGN_CASE/stderr")"
      held_assert_closed "$label"
      cmp -s "$FOREIGN_CASE/record.before" "$data/held-foreign-copies.log" || fail "$label: the rerun changed the record"
      ;;
    close)
      expect_code 0 "$HELD_RC" "$label: a held close whose slot leases must finish: $(cat "$FOREIGN_CASE/stderr")"
      held_assert_closed "$label"
      assert_absent "$FOREIGN_CASE/state/task-x1.backlog-close" "$label: the earlier pending-close record survived"
      assert_absent "$FOREIGN_CASE/state/task-x1.teardown-return-pending" "$label: the return-pending record survived"
      assert_no_grep "dropped" "$FOREIGN_CASE/data/backlog.md" "$label: the earlier record's drop note was replayed"
      ;;
  esac
  chmod -R u+w "$data" 2>/dev/null || true
}

test_held_entry_lease_no_command_plain() {
  held_entry_scenario plain lease-no-command
  pass "held close entry check, lease-no-command, plain record"
}

test_held_entry_lease_no_command_enclosing() {
  held_entry_scenario enclosing lease-no-command
  pass "held close entry check, lease-no-command, enclosing record"
}

test_held_entry_lease_fails_plain() {
  held_entry_scenario plain lease-fails
  pass "held close entry check, lease-fails, plain record"
}

test_held_entry_lease_fails_enclosing() {
  held_entry_scenario enclosing lease-fails
  pass "held close entry check, lease-fails, enclosing record"
}

test_held_entry_record_directory_plain() {
  held_entry_scenario plain record-directory
  pass "held close entry check, record-directory, plain record"
}

test_held_entry_record_directory_enclosing() {
  held_entry_scenario enclosing record-directory
  pass "held close entry check, record-directory, enclosing record"
}

test_held_entry_unrecorded_readonly_plain() {
  held_entry_scenario plain unrecorded-readonly
  pass "held close entry check, unrecorded-readonly, plain record"
}

test_held_entry_unrecorded_readonly_enclosing() {
  held_entry_scenario enclosing unrecorded-readonly
  pass "held close entry check, unrecorded-readonly, enclosing record"
}

test_held_entry_symlink_dangling_plain() {
  held_entry_scenario plain symlink-dangling
  pass "held close entry check, symlink-dangling, plain record"
}

test_held_entry_symlink_dangling_enclosing() {
  held_entry_scenario enclosing symlink-dangling
  pass "held close entry check, symlink-dangling, enclosing record"
}

test_held_entry_symlink_directory_plain() {
  held_entry_scenario plain symlink-directory
  pass "held close entry check, symlink-directory, plain record"
}

test_held_entry_symlink_directory_enclosing() {
  held_entry_scenario enclosing symlink-directory
  pass "held close entry check, symlink-directory, enclosing record"
}

test_held_entry_symlink_unrecorded_readonly_plain() {
  held_entry_scenario plain symlink-unrecorded-readonly
  pass "held close entry check, symlink-unrecorded-readonly, plain record"
}

test_held_entry_symlink_unrecorded_readonly_enclosing() {
  held_entry_scenario enclosing symlink-unrecorded-readonly
  pass "held close entry check, symlink-unrecorded-readonly, enclosing record"
}

test_held_entry_symlink_writable_plain() {
  held_entry_scenario plain symlink-writable
  pass "held close entry check, symlink-writable, plain record"
}

test_held_entry_symlink_writable_enclosing() {
  held_entry_scenario enclosing symlink-writable
  pass "held close entry check, symlink-writable, enclosing record"
}

test_held_entry_no_backlog_pending_close_directory_plain() {
  held_entry_scenario plain no-backlog-pending-close-directory
  pass "held close entry check, no-backlog-pending-close-directory, plain record"
}

test_held_entry_no_backlog_pending_close_directory_enclosing() {
  held_entry_scenario enclosing no-backlog-pending-close-directory
  pass "held close entry check, no-backlog-pending-close-directory, enclosing record"
}

test_held_entry_recorded_readonly_plain() {
  held_entry_scenario plain recorded-readonly
  pass "held close entry check, recorded-readonly, plain record"
}

test_held_entry_recorded_readonly_enclosing() {
  held_entry_scenario enclosing recorded-readonly
  pass "held close entry check, recorded-readonly, enclosing record"
}

test_held_entry_recorded_writable_plain() {
  held_entry_scenario plain recorded-writable
  pass "held close entry check, recorded-writable, plain record"
}

test_held_entry_recorded_writable_enclosing() {
  held_entry_scenario enclosing recorded-writable
  pass "held close entry check, recorded-writable, enclosing record"
}

test_held_entry_close_plain() {
  held_entry_scenario plain close
  pass "held close entry check, close, plain record"
}

test_held_entry_close_enclosing() {
  held_entry_scenario enclosing close
  pass "held close entry check, close, enclosing record"
}

# A held close of a copy in a superseded pool folder: the project's current pool
# is another folder that reuses its slot names, so the close leases the slot by
# its exact path in the folder that holds it, never by name, and Treehouse then
# never hands it out over the held copies, even once that folder is current
# again. A lease an earlier teardown took by name on a same-named slot of the
# current pool is released after the reservation and the held-copy record
# checks, so a close those checks refuse takes no lease and releases no such
# lease, and its rerun releases it, whether the rerun is still a held close,
# which first leases its own slot by path, or, once the held copy is gone, an
# ordinary one. Without lease --path
# the close refuses and the copies stay held.
held_superseded_case() {  # <name> <misdirected|plain> [no-lease-path]
  local cur
  make_held_case "$1"
  held_foreign_unlanded "$FOREIGN_COPY"
  held_plain_get_slot "$FOREIGN_CASE"
  [ "${3:-}" = no-lease-path ] || : > "$FOREIGN_CASE/lease-path"
  cur=$FOREIGN_CASE/current-pool/1/project
  mkdir -p "${cur%/*}"
  git -C "$FOREIGN_CASE/project" worktree add -q --detach "$cur" main
  HELD_CURRENT_SLOT=$(cd "$cur" && pwd -P)
  if [ "$2" = misdirected ]; then
    printf '[{"name":"1","path":"%s","lease_holder":"task-x1","processes":[]}]\n' "$HELD_CURRENT_SLOT"
  else
    printf '[{"name":"1","path":"%s","lease_holder":"","processes":[]}]\n' "$HELD_CURRENT_SLOT"
  fi > "$FOREIGN_CASE/status.json"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
}

test_a_held_close_in_a_superseded_pool_folder_leases_the_slot_by_its_path() {
  local rc shape lock
  for shape in plain misdirected; do
    held_superseded_case "held-superseded-$shape" "$shape"
    lock=$(FM_HOME="$FOREIGN_CASE/home" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
      bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$ROOT" "$FOREIGN_CASE/project")
    mv "$FOREIGN_CASE/fakebin/docker" "$FOREIGN_CASE/fakebin/docker-store"
    cat > "$FOREIGN_CASE/fakebin/docker" <<SH
#!/usr/bin/env bash
if [ -e "$lock" ]; then echo locked; else echo free; fi >> "$FOREIGN_CASE/docker-lock.log"
exec "$FOREIGN_CASE/fakebin/docker-store" "\$@"
SH
    chmod +x "$FOREIGN_CASE/fakebin/docker"
    run_foreign_teardown rc
    expect_code 0 "$rc" "held-superseded-$shape: a landed task must close beside a held copy in a superseded pool folder: $(cat "$FOREIGN_CASE/stderr")"
    held_assert_closed "held-superseded-$shape"
    assert_equals "lease --path $FOREIGN_SLOT --lease-holder task-x1" "$(cat "$FOREIGN_CASE/lease.log")" \
      "held-superseded-$shape: the slot was not leased once, by its exact path"
    jq -e --arg slot "$FOREIGN_SLOT" '.worktrees[] | select(.path == $slot) | .leased == true and .lease_holder == "task-x1"' \
      "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null \
      || fail "held-superseded-$shape: the old folder does not record the slot as leased: $(cat "$FOREIGN_CASE/pool/treehouse-state.json")"
    held_fingerprint "$FOREIGN_COPY" | cmp -s - "$FOREIGN_CASE/held-before.$(basename "$FOREIGN_COPY")" \
      || fail "held-superseded-$shape: the held copy changed"
    cmp -s "$FOREIGN_CASE/claim-before" "$FOREIGN_CASE/pool/1/.fm-slot-owner" || fail "held-superseded-$shape: the slot's claim changed"
    if [ "$shape" = misdirected ]; then
      assert_equals "return $HELD_CURRENT_SLOT --if-lease-holder task-x1" "$(cat "$FOREIGN_CASE/treehouse.log")" \
        "held-superseded-$shape: the misdirected lease was not released by the conditional return alone"
    else
      assert_absent "$FOREIGN_CASE/treehouse.log" "held-superseded-$shape: a pool slot was returned"
    fi
    assert_grep "is reserved under a durable lease and stays claimed" "$FOREIGN_CASE/stdout" \
      "held-superseded-$shape: the output did not say the slot is reserved"
    assert_present "$FOREIGN_CASE/docker-lock.log" "held-superseded-$shape: the Docker cleanup did not run"
    assert_no_grep locked "$FOREIGN_CASE/docker-lock.log" \
      "held-superseded-$shape: the project lock was still held through Docker cleanup after the slot was leased by its path"
  done
  pass "a held close in a superseded pool folder leases the slot by its exact path and releases only this task's misdirected lease"
}

test_a_held_close_in_a_superseded_pool_folder_refuses_without_lease_path() {
  local rc
  held_superseded_case held-superseded-no-path misdirected no-lease-path
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-superseded-no-path: a held close must refuse when the slot cannot be leased by its path: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "needs treehouse v3.1.7-fm or later (treehouse lease --path)" "$FOREIGN_CASE/stderr" \
    "held-superseded-no-path: the refusal did not name the treehouse build it needs"
  assert_grep "nothing was removed" "$FOREIGN_CASE/stderr" "held-superseded-no-path: the refusal did not say nothing was removed"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-superseded-no-path: the task record was removed"
  assert_absent "$FOREIGN_CASE/lease.log" "held-superseded-no-path: the refusal leased a slot"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-superseded-no-path: a refused close wrote a held-copy record"
  held_assert_untouched "held-superseded-no-path" "$FOREIGN_CASE" "$FOREIGN_COPY"
  pass "a held close in a superseded pool folder refuses with the treehouse build it needs when lease --path is missing, and changes nothing"
}

test_a_refused_held_close_releases_no_misdirected_lease() {
  local rc
  held_superseded_case held-superseded-refused misdirected
  mkdir -p "$FOREIGN_CASE/data/held-foreign-copies.log"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-superseded-refused: a held close must refuse when its record cannot be written: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "could not be written" "$FOREIGN_CASE/stderr" "held-superseded-refused: the refusal did not say why"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-superseded-refused: the task record was removed"
  assert_absent "$FOREIGN_CASE/lease.log" "held-superseded-refused: the refusal took a lease"
  assert_absent "$FOREIGN_CASE/treehouse.log" "held-superseded-refused: the refusal returned or released a slot"
  held_assert_untouched "held-superseded-refused" "$FOREIGN_CASE" "$FOREIGN_COPY"
  rmdir "$FOREIGN_CASE/data/held-foreign-copies.log"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-superseded-refused: the rerun must close: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "return $HELD_CURRENT_SLOT --if-lease-holder task-x1" "$(cat "$FOREIGN_CASE/treehouse.log")" \
    "held-superseded-refused: the rerun did not release the misdirected lease by the conditional return alone"
  assert_equals "lease --path $FOREIGN_SLOT --lease-holder task-x1" "$(cat "$FOREIGN_CASE/lease.log")" \
    "held-superseded-refused: the rerun did not lease the slot once, by its exact path"
  pass "a held close that refuses releases no misdirected lease, and its rerun, with its own slot leased by path, releases it"
}

test_an_ordinary_rerun_after_a_refused_held_close_releases_the_misdirected_lease() {
  local rc
  held_superseded_case held-superseded-then-ordinary misdirected
  mkdir -p "$FOREIGN_CASE/data/held-foreign-copies.log"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-superseded-then-ordinary: a held close must refuse when its record cannot be written: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_CASE/lease.log" "held-superseded-then-ordinary: the refused close took a lease"
  assert_absent "$FOREIGN_CASE/treehouse.log" "held-superseded-then-ordinary: the refused close returned or released a slot"
  held_assert_untouched "held-superseded-then-ordinary" "$FOREIGN_CASE" "$FOREIGN_COPY"
  rmdir "$FOREIGN_CASE/data/held-foreign-copies.log"
  git -C "$FOREIGN_CASE/project" worktree remove --force "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-superseded-then-ordinary: the ordinary rerun must close: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "held-superseded-then-ordinary: the rerun kept the task record"
  assert_not_contains "$(cat "$FOREIGN_CASE/stdout")" "the slot return is deferred" \
    "held-superseded-then-ordinary: the rerun was still a held close"
  assert_equals 1 "$(grep -c "^return $HELD_CURRENT_SLOT --if-lease-holder task-x1\$" "$FOREIGN_CASE/treehouse.log" || true)" \
    "held-superseded-then-ordinary: the ordinary rerun did not release the misdirected lease by the conditional return: $(cat "$FOREIGN_CASE/treehouse.log" 2>/dev/null)"
  assert_absent "$FOREIGN_CASE/lease.log" "held-superseded-then-ordinary: the rerun leased a slot"
  pass "an ordinary rerun after a refused held close releases the misdirected lease its task still holds"
}

test_the_held_close_notice_promises_no_cleanup_that_does_not_exist() {
  local rc second copy holder copy_q holder_q slot_q proj_q
  make_held_case held-notice
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
  held_foreign_unlanded "$FOREIGN_COPY"
  held_foreign_unlanded "$second"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY" "$second"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-notice: a landed task must close beside two held copies: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-notice
  held_assert_untouched held-notice "$FOREIGN_CASE" "$FOREIGN_COPY" "$second"
  assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: " "$FOREIGN_CASE/stdout" \
    "held-notice: the output did not list the first held copy"
  assert_grep "held foreign copy $second stays in pool slot $FOREIGN_SLOT: " "$FOREIGN_CASE/stdout" \
    "held-notice: the output did not list the second held copy"
  assert_grep "pool slot $FOREIGN_SLOT is reserved under a durable lease and stays claimed, and nothing returns it automatically" "$FOREIGN_CASE/stdout" \
    "held-notice: the output did not say the slot is reserved under a durable lease and stays claimed with no automatic return"
  assert_grep "a held copy is removed only on the owner's word naming it; the nested task copy sweep, when it is armed, also removes an unlocked copy held for commits once its HEAD is landed, and may release a copy locked by Vernant's creation lock only through Vernant's closeout driver, only when its launcher is gone and every proof passes, including every commit on a remote; it never removes an unlocked copy held for unique ignored files." "$FOREIGN_CASE/stdout" \
    "held-notice: the output did not say how a copy held for commits is removed"
  holder=$(jq -r '.worktrees[0].lease_holder // empty' "$FOREIGN_CASE/pool/treehouse-state.json")
  [ -n "$holder" ] || fail "held-notice: the fixture slot has no lease holder"
  printf -v holder_q '%q' "$holder"
  printf -v slot_q '%q' "$FOREIGN_SLOT"
  printf -v proj_q '%q' "$FOREIGN_CASE/project"
  for copy in "$FOREIGN_COPY" "$second"; do
    printf -v copy_q '%q' "$copy"
    assert_grep "notice: next step for the owner of $copy: list the commits only it holds with git -C $copy_q log --oneline HEAD --not --remotes, land them, remove the copy with git -C $slot_q worktree remove $copy_q (a copy locked by Vernant's creation lock goes through scripts/git-stability/closeout_pr.py --cleanup-worktree $copy_q --execute-cleanup, run from the slot), and when no copy is left in the slot return it with (cd $proj_q && treehouse return $slot_q --if-lease-holder $holder_q </dev/null)." \
      "$FOREIGN_CASE/stdout" "held-notice: the output did not print the exact next step for the owner of $copy: $(cat "$FOREIGN_CASE/stdout")"
  done
  assert_grep "each held copy is also listed in $FOREIGN_CASE/data/held-foreign-copies.log" "$FOREIGN_CASE/stdout" \
    "held-notice: the output did not name the held-copy record"
  assert_no_grep "reaper" "$FOREIGN_CASE/stdout" "held-notice: the output promises a reaper run"
  assert_no_grep "named drop" "$FOREIGN_CASE/stdout" "held-notice: the output promises a named drop"
  assert_no_grep "reaper" "$FOREIGN_CASE/stderr" "held-notice: the error output promises a reaper run"
  pass "a held close lists every held copy, says the slot is reserved under a durable lease and stays claimed, and promises no cleanup that does not exist"
}

test_a_held_close_that_a_later_step_refuses_leaves_one_record_line_and_a_rerun_adds_none() {
  local rc
  make_held_case held-late-refusal
  held_foreign_unlanded "$FOREIGN_COPY"
  stuck_endpoint_tmux "$FOREIGN_CASE"
  : > "$FOREIGN_CASE/endpoint-stuck"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-late-refusal: a stuck endpoint must refuse the close: $(cat "$FOREIGN_CASE/stderr")"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-late-refusal: the task record was removed by a refused close"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" \
    "held-late-refusal: the record is written before anything is removed, so the refused close leaves its one line"
  assert_no_grep "held foreign copy" "$FOREIGN_CASE/stdout" "held-late-refusal: a refused close reported held copies"
  held_assert_untouched held-late-refusal "$FOREIGN_CASE" "$FOREIGN_COPY"
  rm -f "$FOREIGN_CASE/endpoint-stuck"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-late-refusal: the rerun must close once the endpoint closes: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-late-refusal
  held_assert_untouched held-late-refusal "$FOREIGN_CASE" "$FOREIGN_COPY"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" \
    "held-late-refusal: the rerun repeated the record line"
  pass "a held close refused by a later step leaves its one record line, and the close that completes does not repeat it"
}

test_a_held_copy_record_that_cannot_be_written_refuses_the_close() {
  local rc
  make_held_case held-unwritable
  held_foreign_unlanded "$FOREIGN_COPY"
  mkdir "$FOREIGN_CASE/data/held-foreign-copies.log"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-unwritable: a close whose inventory cannot be written must refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "REFUSED: the held-copy record $FOREIGN_CASE/data/held-foreign-copies.log could not be written" "$FOREIGN_CASE/stderr" \
    "held-unwritable: the refusal did not name the record: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "nothing was removed" "$FOREIGN_CASE/stderr" "held-unwritable: the refusal did not say nothing was removed"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-unwritable: the task record was removed"
  assert_present "$FOREIGN_COPY/unlanded.txt" "held-unwritable: the foreign copy's file is gone"
  [ "$(backlog_row_state "$FOREIGN_CASE")" != "done" ] || fail "held-unwritable: the backlog item was closed by a refused close"
  assert_no_grep "held foreign copy" "$FOREIGN_CASE/stdout" "held-unwritable: a refused close reported held copies"
  held_assert_untouched held-unwritable "$FOREIGN_CASE" "$FOREIGN_COPY"
  rmdir "$FOREIGN_CASE/data/held-foreign-copies.log"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-unwritable: the rerun must close once the record can be written: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-unwritable
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" "held-unwritable: the rerun did not write one record line"
  pass "a held close whose record cannot be written refuses with nothing removed, and the rerun closes with one line"
}

test_a_legacy_record_held_close_still_names_the_held_copies() {
  local rc
  make_held_case held-legacy
  grep -v '^spawn_gen=' "$FOREIGN_CASE/state/task-x1.meta" > "$FOREIGN_CASE/meta.legacy"
  cp "$FOREIGN_CASE/meta.legacy" "$FOREIGN_CASE/state/task-x1.meta"
  held_foreign_unlanded "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  FOREIGN_TEARDOWN_ARGS=(--legacy-record)
  run_foreign_teardown rc
  FOREIGN_TEARDOWN_ARGS=()
  expect_code 0 "$rc" "held-legacy: a landed legacy record must close beside a held copy: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "legacy record accepted without spawn_gen" "$FOREIGN_CASE/stdout" "held-legacy: the close did not take the legacy completion line"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "held-legacy: the task record survived"
  held_assert_untouched held-legacy "$FOREIGN_CASE" "$FOREIGN_COPY"
  assert_grep "the slot return is deferred" "$FOREIGN_CASE/stdout" "held-legacy: the legacy close did not say the slot return is deferred"
  assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: its HEAD " \
    "$FOREIGN_CASE/stdout" "held-legacy: the legacy close did not list the held copy: $(cat "$FOREIGN_CASE/stdout")"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" "held-legacy: the record is not one line"
  pass "a --legacy-record close beside a held foreign copy still lists the held copy and says the slot return is deferred"
}

test_a_foreign_copy_does_not_excuse_an_own_copy_that_is_not_landed() {
  local rc shape
  for shape in dirty unlanded; do
    make_held_case "held-own-$shape"
    held_foreign_unlanded "$FOREIGN_COPY"
    case "$shape" in
      dirty) printf 'edit\n' > "$FOREIGN_SLOT/own-edit.txt" ;;
      unlanded)
        printf 'own\n' > "$FOREIGN_SLOT/own.txt"
        git -C "$FOREIGN_SLOT" add own.txt
        git -C "$FOREIGN_SLOT" -c user.email=t@t -c user.name=t commit -qm 'unlanded own work'
        ;;
    esac
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    run_foreign_teardown rc
    expect_code 1 "$rc" "held-own-$shape: an own copy that is not landed must refuse beside a foreign copy: $(cat "$FOREIGN_CASE/stderr")"
    case "$shape" in
      dirty) assert_grep "uncommitted changes" "$FOREIGN_CASE/stderr" "held-own-dirty: the refusal did not name the own copy's changes" ;;
      unlanded) assert_grep "the ship deliverable is not landed" "$FOREIGN_CASE/stderr" "held-own-unlanded: the refusal did not name the own copy's commits: $(cat "$FOREIGN_CASE/stderr")" ;;
    esac
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-own-$shape: the task record was removed"
    assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-own-$shape: a refused close wrote a held-copy record"
    held_assert_untouched "held-own-$shape" "$FOREIGN_CASE" "$FOREIGN_COPY"
  done
  pass "a dirty or unlanded own copy still refuses exactly as before when a foreign copy would be held, and nothing changes"
}

test_a_foreign_copy_that_cannot_be_held_still_refuses_the_whole_close() {
  local rc shape pid reason
  for shape in dirty-and-unlanded unlanded-with-record unlanded-with-process; do
    make_held_case "held-mixed-$shape"
    held_foreign_unlanded "$FOREIGN_COPY"
    case "$shape" in
      dirty-and-unlanded)
        printf 'edit\n' > "$FOREIGN_COPY/untracked.txt"
        reason="it has uncommitted or untracked-unignored changes"
        ;;
      unlanded-with-record)
        fm_write_meta "$FOREIGN_CASE/state/other.meta" "kind=ship" "worktree=$FOREIGN_COPY"
        reason="task other's active record names it as its worktree"
        ;;
      unlanded-with-process)
        teardown_fixture_start "$FOREIGN_COPY" KILL sleep 300
        pid=$TEARDOWN_FIXTURE_PID
        reason="process $pid is running in it"
        cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*) if kill -0 $pid 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $pid '$FOREIGN_COPY'; fi; exit 0 ;;
esac
exit 1
SH
        ;;
    esac
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    run_foreign_teardown rc
    expect_code 1 "$rc" "held-mixed-$shape: a copy that is not only held back by unique work must refuse: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "held-mixed-$shape: the refusal changed"
    assert_grep "missing=foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: $reason" "$FOREIGN_CASE/stderr" \
      "held-mixed-$shape: the refusal did not name what really blocks the copy: $(cat "$FOREIGN_CASE/stderr")"
    assert_no_grep "is not proved landed" "$FOREIGN_CASE/stderr" \
      "held-mixed-$shape: the refusal names the unlanded HEAD instead of what really blocks the copy"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-mixed-$shape: the task record was removed"
    assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-mixed-$shape: a refused close wrote a held-copy record"
    held_assert_untouched "held-mixed-$shape" "$FOREIGN_CASE" "$FOREIGN_COPY"
  done
  pass "a foreign copy that is also dirty, named by another record, or running a process still refuses the whole close"
}

test_a_copy_held_for_ignored_files_is_typed_and_asked_about_those_files_when_another_copy_blocks() {
  local rc second
  make_held_case held-ignored-question
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
  held_ignored_file "$FOREIGN_COPY"
  printf 'edit\n' > "$second/untracked.txt"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-ignored-question: a dirty second copy must refuse the whole close: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "rule=copy-ignored-files " "$FOREIGN_CASE/stderr" \
    "held-ignored-question: the ignored-file copy was not typed by what holds it: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "human-only-exit: What owner-approved disposition covers the ignored files only $FOREIGN_COPY holds (it holds ignored files that exist nowhere else: unique.dat)?" "$FOREIGN_CASE/stderr" \
    "held-ignored-question: the question did not ask about the ignored files: $(cat "$FOREIGN_CASE/stderr")"
  assert_no_grep "What verified landing or retained ownership covers $FOREIGN_COPY" "$FOREIGN_CASE/stderr" \
    "held-ignored-question: the question asks about a landing that is not the blocker: $(cat "$FOREIGN_CASE/stderr")"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-ignored-question: the task record was removed"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-ignored-question: a refused close wrote a held-copy record"
  held_assert_untouched held-ignored-question "$FOREIGN_CASE" "$FOREIGN_COPY"
  pass "a copy held for ignored files that is listed among refusals is typed copy-ignored-files and asked about those files, not about a landing"
}

# A copy that a process of the closing task runs in, or whose creation-lock
# launcher is the task's own session, is not held: retire would have to signal
# a process inside a copy that stays. The refusal names that process, not the
# HEAD that is not proved landed, and nothing is signalled or removed.
test_a_foreign_copy_not_held_for_a_process_of_this_teardown_names_that_process() {
  local rc shape agent child pidfile i reason
  # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
  local script='my $child = fork(); if (!$child) { chdir $ARGV[1]; exec "sleep", "300"; } $SIG{CHLD} = "IGNORE"; open my $fh, ">", $ARGV[0]; print $fh $child; close $fh; sleep 300;'
  for shape in unlanded-in-copy unlanded-with-launcher; do
    child=
    if [ "$shape" = unlanded-with-launcher ]; then
      start_foreign_session_case "held-own-$shape" agent
      printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
      add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
      seed_backlog_in_flight "$FOREIGN_CASE"
      held_foreign_unlanded "$FOREIGN_COPY"
      agent=$FOREIGN_AGENT
      reason="process $FOREIGN_LAUNCHER of this teardown runs in it or launched its creation lock"
    else
      make_held_case "held-own-$shape"
      held_foreign_unlanded "$FOREIGN_COPY"
      pidfile=$FOREIGN_CASE/child-pid
      teardown_fixture_start "$FOREIGN_SLOT" KILL perl -e "$script" "$pidfile" "$FOREIGN_COPY"
      agent=$TEARDOWN_FIXTURE_PID
      for i in $(seq 100); do [ -s "$pidfile" ] && break; sleep 0.05; done
      child=$(cat "$pidfile")
      cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*)
    if kill -0 $agent 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $agent '$FOREIGN_SLOT'; fi
    if kill -0 $child 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $child '$FOREIGN_COPY'; fi
    exit 0 ;;
esac
exit 1
SH
      reason="process $child of this teardown runs in it or launched its creation lock"
    fi
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    run_foreign_teardown rc
    kill -0 "$agent" 2>/dev/null || fail "held-own-$shape: a refused close ended the task's session"
    [ -z "$child" ] || kill -0 "$child" 2>/dev/null || fail "held-own-$shape: a refused close ended the process inside the copy"
    kill -KILL ${child:+"$child"} "$agent" 2>/dev/null || true
    expect_code 1 "$rc" "held-own-$shape: a copy with a process of this teardown must not be held: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "missing=foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: $reason" "$FOREIGN_CASE/stderr" \
      "held-own-$shape: the refusal did not name the process of this teardown: $(cat "$FOREIGN_CASE/stderr")"
    assert_no_grep "is not proved landed" "$FOREIGN_CASE/stderr" "held-own-$shape: the refusal names the unlanded HEAD instead of the process"
    assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "held-own-$shape: the refusal changed"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-own-$shape: the task record was removed"
    assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-own-$shape: a refused close wrote a held-copy record"
    held_assert_untouched "held-own-$shape" "$FOREIGN_CASE" "$FOREIGN_COPY"
  done
  pass "a copy not held because a process of the closing task runs in it, or launched its lock, is refused naming that process, and nothing is signalled or removed"
}

# A landing check that could not run is not a copy that is not landed: when
# fetching the default branch fails, the copy is refused, never held, so a
# rerun can check again and release a copy that did land.
test_a_foreign_copy_whose_landing_could_not_be_checked_is_not_held() {
  local rc shape real_git
  real_git=$(command -v git)
  for shape in landed unlanded; do
    make_held_case "held-unchecked-$shape"
    if [ "$shape" = unlanded ]; then
      held_foreign_unlanded "$FOREIGN_COPY"
    fi
    printf '#!/usr/bin/env bash\necho "error: simulated forge outage" >&2\nexit 1\n' > "$FOREIGN_CASE/fakebin/gh"
    cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${2:-}" = "$FOREIGN_COPY" ] && [ "\${3:-}" = fetch ]; then
  echo "fatal: unable to access 'origin': simulated outage" >&2
  exit 128
fi
exec "$real_git" "\$@"
SH
    chmod +x "$FOREIGN_CASE/fakebin/git"
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    run_foreign_teardown rc
    expect_code 1 "$rc" "held-unchecked-$shape: a copy whose landing could not be checked must refuse the close: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "error: foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: its landing could not be checked (" \
      "$FOREIGN_CASE/stderr" "held-unchecked-$shape: the refusal did not say the landing could not be checked: $(cat "$FOREIGN_CASE/stderr")"
    assert_no_grep "is not proved landed" "$FOREIGN_CASE/stderr" "held-unchecked-$shape: the refusal calls an unchecked copy not landed"
    assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "held-unchecked-$shape: the refusal changed"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-unchecked-$shape: the task record was removed"
    [ "$(backlog_row_state "$FOREIGN_CASE")" != "done" ] || fail "held-unchecked-$shape: the backlog item was closed by a refused close"
    assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-unchecked-$shape: a refused close wrote a held-copy record"
    held_assert_untouched "held-unchecked-$shape" "$FOREIGN_CASE" "$FOREIGN_COPY"
    rm -f "$FOREIGN_CASE/fakebin/git"
    add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
    run_foreign_teardown rc
    if [ "$shape" = landed ]; then
      expect_code 0 "$rc" "held-unchecked-$shape: the rerun must release a copy that did land: $(cat "$FOREIGN_CASE/stderr")"
      assert_absent "$FOREIGN_COPY" "held-unchecked-$shape: the rerun did not release the landed copy"
      assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "held-unchecked-$shape: the rerun did not return the slot"
    else
      expect_code 0 "$rc" "held-unchecked-$shape: the rerun must hold a copy that really is unlanded: $(cat "$FOREIGN_CASE/stderr")"
      held_assert_closed "held-unchecked-$shape"
      assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" "held-unchecked-$shape: the rerun did not write one record line"
    fi
  done
  pass "a foreign copy whose landing could not be checked is refused with nothing removed and no record line, and a rerun releases a landed copy and holds an unlanded one"
}

# The held notices and the record are written once the task record and the own
# nested copies are gone, so a later failure, here the backlog close, still
# leaves them.
test_a_failure_after_the_point_of_no_return_still_leaves_the_held_notice_and_record() {
  local rc real_axi
  real_axi=$(command -v tasks-axi)
  make_held_case held-after-no-return
  held_foreign_unlanded "$FOREIGN_COPY"
  cat > "$FOREIGN_CASE/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = done ]; then
  echo "error: simulated backlog failure" >&2
  exit 1
fi
exec "$real_axi" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/tasks-axi"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-after-no-return: a failing backlog close must fail the run: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "its backlog item could not be closed atomically" "$FOREIGN_CASE/stderr" \
    "held-after-no-return: the run did not fail at the backlog close: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "held-after-no-return: the task record survived, so the point of no return was not passed"
  assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: its HEAD " \
    "$FOREIGN_CASE/stdout" "held-after-no-return: the held notice was lost with the later failure"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" \
    "held-after-no-return: the record does not hold exactly one line"
  held_assert_untouched "held-after-no-return" "$FOREIGN_CASE" "$FOREIGN_COPY"
  pass "a failure after the task record and own copies are gone still leaves the held notice and one record line, and the foreign copy untouched"
}

test_a_forced_close_never_holds_a_foreign_copy() {
  local rc
  make_held_case held-forced
  held_foreign_unlanded "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
  run_foreign_teardown rc
  FOREIGN_TEARDOWN_ARGS=()
  expect_code 1 "$rc" "held-forced: --force must not hold a foreign copy: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "held-forced: the refusal is not the custody refusal"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-forced: the task record was removed"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-forced: a refused close wrote a held-copy record"
  held_assert_untouched held-forced "$FOREIGN_CASE" "$FOREIGN_COPY"
  pass "--force waives nothing: it never holds a foreign copy and still refuses"
}

test_a_slot_with_no_foreign_copy_closes_and_returns_as_before() {
  local rc
  make_held_case held-none
  git -C "$FOREIGN_CASE/project" worktree remove "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-none: an ordinary landed close must succeed: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "held-none: the slot was not returned"
  assert_grep "teardown task-x1 complete (window firstmate:fm-task-x1, worktree $FOREIGN_SLOT)" "$FOREIGN_CASE/stdout" \
    "held-none: the ordinary completion line changed"
  assert_no_grep "deferred" "$FOREIGN_CASE/stdout" "held-none: an ordinary close mentions a deferred slot return"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-none: an ordinary close wrote a held-copy record"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "held-none: the task record survived"
  pass "a slot with no foreign copy closes and returns exactly as before and writes no held-copy record"
}

test_foreign_copy_named_by_an_alias_in_an_active_record_is_refused() {
  local rc
  make_foreign_copy_case foreign-alias-lease
  ln -s "$FOREIGN_COPY" "$FOREIGN_CASE/copy-alias"
  fm_write_meta "$FOREIGN_CASE/state/other.meta" "kind=ship" "worktree=$FOREIGN_CASE/copy-alias"
  run_foreign_teardown rc
  expect_code 1 "$rc" "alias-lease: a copy another active record names must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "task other's active record names it as its worktree" "$FOREIGN_CASE/stderr" \
    "alias-lease: the refusal did not name the owning record"
  assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "alias-lease: the refusal changed"
  assert_foreign_copy_untouched alias-lease
  pass "a foreign copy that another active record names through a symlink alias is refused"
}

test_half_removed_foreign_copy_is_refused_as_before() {
  local rc
  make_foreign_copy_case foreign-half-removed
  rm -f "$FOREIGN_COPY/.git"
  run_foreign_teardown rc
  expect_code 1 "$rc" "half-removed: a registered remnant without its .git must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "half-removed: the refusal changed"
  assert_present "$FOREIGN_COPY" "half-removed: the remnant was removed"
  assert_absent "$FOREIGN_CASE/closeout.log" "half-removed: the closeout driver ran"
  assert_absent "$FOREIGN_CASE/treehouse.log" "half-removed: the pool slot was returned"
  pass "a half-removed registered foreign copy refuses with the same custody refusal and nothing changes"
}

test_recycled_launcher_pid_does_not_own_a_foreign_copy() {
  local rc pid admin
  sleep 300 &
  pid=$!
  make_foreign_copy_case foreign-recycled-pid "$pid"
  admin=$(git -C "$FOREIGN_COPY" rev-parse --absolute-git-dir)
  # The lock file is older than the process, so the pid cannot be its launcher.
  fm_touch_epoch "$(( $(date +%s) - 3600 ))" "$admin/locked"
  run_foreign_teardown rc
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$rc" "recycled-pid: a live but recycled launcher pid must not block release: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "recycled-pid: the driver was not run once"
  assert_absent "$FOREIGN_COPY" "recycled-pid: the copy survived"
  pass "a live pid that started after the creation lock was written is a recycled pid and does not own the copy"
}

test_live_launcher_keeps_its_foreign_copy() {
  local rc pid
  sleep 300 &
  pid=$!
  sleep 3
  make_foreign_copy_case foreign-live-launcher "$pid"
  run_foreign_teardown rc
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 1 "$rc" "live-launcher: a launcher that predates its lock must keep the copy: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "creation-lock launcher process $pid may still be running" "$FOREIGN_CASE/stderr" \
    "live-launcher: the refusal did not name the launcher"
  assert_grep "human-only-exit: Is launcher $pid, named in the creation lock on $FOREIGN_COPY, still running, and who owns it?" "$FOREIGN_CASE/stderr" \
    "live-launcher: the question did not name the launcher and the lock"
  assert_foreign_copy_untouched live-launcher
  pass "a live launcher that started before its creation lock keeps its foreign copy"
}

# The creation lock names a launcher pid. Teardown itself ends the task's own
# session, so a launcher that is that session, or runs under it, must not hold
# the copy: retire signals the descendant that the cwd sweep cannot reach.
test_task_own_session_as_lock_launcher_does_not_block_release() {
  local rc shape
  for shape in agent child; do
    start_foreign_session_case "foreign-own-$shape" "$shape"
    run_foreign_teardown rc
    kill "$FOREIGN_LAUNCHER" 2>/dev/null && fail "own-$shape: the launcher survived teardown"
    expect_code 0 "$rc" "own-$shape: the task's own session as launcher must not block release: $(cat "$FOREIGN_CASE/stderr")"
    kill -0 "$FOREIGN_AGENT" 2>/dev/null && fail "own-$shape: the task's session survived teardown"
    assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
      "own-$shape: the driver was not run once"
    assert_absent "$FOREIGN_COPY" "own-$shape: the copy survived"
    assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "own-$shape: the slot was not returned"
    if [ "$shape" = child ]; then
      assert_grep "	TERM	$FOREIGN_LAUNCHER	" "$FOREIGN_CASE/state/task-x1.teardown-processes" \
        "own-$shape: the descendant launcher's signal was not recorded"
    fi
  done
  pass "a lock launcher that is the task's own session, or a descendant the cwd sweep cannot reach, is ended by retire and released with the slot"
}

# A cwd at the slot root does not make a process teardown's own for the nested
# copy rule either: a detached daemon there, descended from no task process, is
# not an ownership anchor, so its child, the copy's lock launcher, is never
# signalled, and the daemon is refused by Fix 2 rather than reaped.
test_a_detached_process_at_the_slot_root_does_not_make_its_child_teardowns_own() {
  local rc
  start_foreign_session_case foreign-detached-anchor detached
  run_foreign_teardown rc
  kill -0 "$FOREIGN_LAUNCHER" 2>/dev/null || fail "detached-anchor: the daemon's child launcher was signalled"
  kill -0 "$FOREIGN_AGENT" 2>/dev/null || fail "detached-anchor: the detached daemon at the slot root was signalled"
  expect_code 1 "$rc" "detached-anchor: teardown must refuse: $(tail -3 "$FOREIGN_CASE/stderr")"
  [ ! -f "$FOREIGN_CASE/state/task-x1.teardown-processes" ] \
    || assert_no_grep "	TERM	$FOREIGN_LAUNCHER	" "$FOREIGN_CASE/state/task-x1.teardown-processes" \
      "detached-anchor: teardown audited a signal for the daemon's child"
  assert_foreign_copy_untouched detached-anchor
  teardown_fixture_stop "$FOREIGN_LAUNCHER"
  teardown_fixture_stop "$FOREIGN_AGENT"
  pass "a detached daemon at the slot root is no ownership anchor: its child launcher is not signalled and the copy is kept"
}

# Every scan decides before the first signal: with an unproven daemon at the
# slot root beside a proved process whose child is the nested copy's lock
# launcher, teardown refuses with nothing signalled, the proved launcher
# included.
test_a_mixed_slot_refuses_before_signalling_the_proved_nested_launcher() {
  local rc
  start_foreign_session_case foreign-mixed-anchor child
  ownership_detached "$FOREIGN_SLOT" setsid
  cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*)
    if kill -0 $FOREIGN_AGENT 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $FOREIGN_AGENT '$FOREIGN_SLOT'; fi
    if kill -0 $OWN_DETACHED_PID 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $OWN_DETACHED_PID '$FOREIGN_SLOT'; fi
    exit 0 ;;
esac
exit 1
SH
  run_foreign_teardown rc
  kill -0 "$OWN_DETACHED_PID" 2>/dev/null || fail "mixed-anchor: the unproven daemon was signalled"
  kill -0 "$FOREIGN_LAUNCHER" 2>/dev/null || fail "mixed-anchor: the proved launcher was signalled before the refusal"
  kill -0 "$FOREIGN_AGENT" 2>/dev/null || fail "mixed-anchor: the proved session was signalled before the refusal"
  expect_code 1 "$rc" "mixed-anchor: teardown must refuse: $(tail -3 "$FOREIGN_CASE/stderr")"
  [ ! -f "$FOREIGN_CASE/state/task-x1.teardown-processes" ] \
    || fail "mixed-anchor: teardown audited a signal: $(cat "$FOREIGN_CASE/state/task-x1.teardown-processes")"
  grep -Eq "REFUSED: process $OWN_DETACHED_PID .*nothing proves it belongs to task-x1" "$FOREIGN_CASE/stderr" \
    || fail "mixed-anchor: the refusal did not name the daemon: $(tail -3 "$FOREIGN_CASE/stderr")"
  assert_foreign_copy_untouched mixed-anchor
  teardown_fixture_stop "$OWN_DETACHED_PID"
  kill "$FOREIGN_LAUNCHER" 2>/dev/null || true
  pass "an unproven daemon at the slot root beside a proved nested launcher refuses with nothing signalled"
}

# The nested retire step rechecks, right before each signal, the support its
# target's ownership rests on: it counts only as a chain-proved record whose pid
# still has the recorded birth identity, read live. Three supports fail and the
# queued descendant D is never signalled, nothing further is, and the step
# refuses:
#   group    A shares a process group with chain-proved M but was never itself
#            chain-proved (M, queued first on its own proof, is signalled);
#   reused   A's record in TASK_OWNED names a birth identity its pid no longer
#            has, as when the support exited and its pid was reused;
#   exited   A is chain-proved and queued first: its signal ends it, so when D's
#            turn comes the cached record still matches but the live read fails.
test_nested_retire_stops_when_a_support_proof_expires() {
  local tmp m a d rc _ shape first
  for shape in group reused exited; do
    tmp=$(fm_test_tmproot "nested-support-$shape")
    mkdir -p "$tmp/state" "$tmp/copy"
    # M is detached (reparented to init, so its exit is reaped at once) and leads
    # group G; its child A stays in G.
    # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
    perl -MPOSIX -e '
      my ($out) = @ARGV;
      my $first = fork(); die "fork" unless defined $first;
      if ($first) { waitpid($first, 0); exit 0; }
      my $second = fork(); die "fork" unless defined $second;
      POSIX::_exit(0) if $second;
      setpgrp(0, 0) or die "setpgrp";
      open STDIN, "<", "/dev/null"; open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null";
      $SIG{CHLD} = "IGNORE";
      my $a = fork(); die "fork" unless defined $a;
      if (!$a) { exec "sleep", "300"; }
      open my $fh, ">", "$out.tmp" or die "open"; print {$fh} "$$ $a\n"; close $fh; rename "$out.tmp", $out or die "rename";
      sleep 300 while 1;' "$tmp/ma.pid"
    for _ in $(seq 100); do [ -s "$tmp/ma.pid" ] && break; sleep 0.05; done
    read -r m a < "$tmp/ma.pid" || fail "support-$shape: setup did not start"
    teardown_fixture_track "$m" KILL
    teardown_fixture_track "$a" KILL
    teardown_fixture_start "$tmp/copy" KILL sleep 300
    d=$TEARDOWN_FIXTURE_PID
    sleep 0.3
    python3 -I - "$ROOT/bin/fm-teardown.sh" "$tmp/reaper.sh" <<'PY' || fail "support-$shape: the reaper functions could not be extracted"
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
start = source.index("pids_with_cwd_under() {")
end = source.index("\n}\n", source.index("reap_task_worktree_processes() {", start)) + 3
pathlib.Path(sys.argv[2]).write_text(source[start:end])
PY
    rc=0
    SHAPE=$shape TAB=$'\t' TMPX=$tmp ROOT=$ROOT M=$m A=$a D=$d bash -c '
  set +e
  for l in fm-tasks-axi-lib fm-backlog-transition-lib fm-nm-run-lib fm-task-copy-lib fm-lock-lib fm-refuse-lib fm-teardown-nested-lib; do . "$ROOT/bin/$l.sh" || exit 9; done
  STATE=$TMPX/state ID=support-expiry
  . "$TMPX/reaper.sh"
  mid=$(task_process_identity "$M") && aid=$(task_process_identity "$A") && did=$(task_process_identity "$D") || exit 8
  case "$SHAPE" in
    group)
      TASK_OWNED=("$M""$TAB""$mid""$TAB""$M")
      first=$M firstid=$mid
      ;;
    reused)
      aid="lstart=Thu Jan  1 00:00:00 1970"
      TASK_OWNED=("$M""$TAB""$mid""$TAB""$M" "$A""$TAB""$aid""$TAB""$M")
      first=$M firstid=$mid
      ;;
    exited)
      TASK_OWNED=("$A""$TAB""$aid""$TAB""$M")
      first=$A firstid=$aid
      ;;
  esac
  # first is queued on its own proof; D rests on A.
  TEARDOWN_FOREIGN_PROCS=("$first""$TAB""$firstid""$TAB""$TMPX/copy""$TAB""$first""$TAB""$firstid" "$D""$TAB""$did""$TAB""$TMPX/copy""$TAB""$A""$TAB""$aid")
  # The ancestry proof before the first signal is not under test here.
  teardown_pid_is_task_own() { return 0; }
  # Signal delivery is made synchronous for the first target, so its exit lands
  # before the next target is judged, deterministically.
  kill() {
    builtin kill "$@"
    if [ "${2:-}" = "$first" ]; then
      for _ in $(seq 100); do builtin kill -0 "$first" 2>/dev/null || return 0; sleep 0.05; done
    fi
  }
  teardown_foreign_procs_retire
  ' > "$tmp/stdout" 2> "$tmp/stderr" || rc=$?
    first=$m
    [ "$shape" != exited ] || first=$a
    ownership_alive "$d" || fail "support-$shape: D was signalled although its support no longer proved anything"
    ownership_wait_dead "$first" || fail "support-$shape: the first target, whose own proof held, was not signalled: $(cat "$tmp/stderr")"
    expect_code 1 "$rc" "support-$shape: the retire step must refuse: $(cat "$tmp/stderr")"
    assert_grep $'\tTERM\t'"$first"$'\t' "$tmp/state/support-expiry.teardown-processes" "support-$shape: the first target's signal was not audited"
    grep -Eq "REFUSED: the proof that process $d .*rested on process $a, whose ownership proof has expired; signalling nothing further" "$tmp/stderr" \
      || fail "support-$shape: the refusal did not name the unproven support: $(cat "$tmp/stderr")"
    teardown_fixture_stop "$d"
    teardown_fixture_stop "$a"
    teardown_fixture_stop "$m"
  done
  pass "a queued nested process is not signalled when its support is only a shared group, carries a reused pid's stale identity, or has exited since the scan"
}

# A live launcher outside the task's session keeps its copy untouched. One inside
# it that survives the signal and the bounded wait keeps it too, named by pid,
# after the session itself was ended.
test_unrelated_or_stubborn_lock_launcher_keeps_its_foreign_copy() {
  local rc shape
  for shape in unrelated stubborn; do
    start_foreign_session_case "foreign-held-$shape" "$shape"
    run_foreign_teardown rc
    if [ "$shape" = unrelated ]; then
      kill -0 "$FOREIGN_AGENT" 2>/dev/null || fail "held-$shape: a refused teardown stopped the task's session"
    else
      kill -0 "$FOREIGN_AGENT" 2>/dev/null && fail "held-$shape: the task's session survived retire"
      kill -0 "$FOREIGN_LAUNCHER" 2>/dev/null || fail "held-$shape: the launcher did not ignore TERM"
    fi
    kill -KILL "$FOREIGN_LAUNCHER" 2>/dev/null || true
    wait "$FOREIGN_LAUNCHER" 2>/dev/null || true
    expect_code 1 "$rc" "held-$shape: a live launcher must keep the copy: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "creation-lock launcher process $FOREIGN_LAUNCHER may still be running" "$FOREIGN_CASE/stderr" \
      "held-$shape: the refusal did not name the launcher"
    assert_foreign_copy_untouched "held-$shape"
  done
  pass "a live lock launcher outside the task's session, or one that outlives retire's signal, keeps its foreign copy and is named by pid"
}

test_process_in_foreign_copy_keeps_it() {
  local rc pid
  make_foreign_copy_case foreign-process-inside
  teardown_fixture_start "$FOREIGN_COPY" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*) if kill -0 $pid 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $pid '$FOREIGN_COPY'; fi; exit 0 ;;
esac
exit 1
SH
  run_foreign_teardown rc
  kill -0 "$pid" 2>/dev/null || fail "process-inside: teardown stopped the process running in the foreign copy"
  expect_code 1 "$rc" "process-inside: a copy with a process outside the task running in it must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "process $pid is running in it" "$FOREIGN_CASE/stderr" "process-inside: the refusal did not name the process"
  assert_grep "human-only-exit: Which task or person owns process $pid, which is running in $FOREIGN_COPY? Stop it or tell me it is yours." "$FOREIGN_CASE/stderr" \
    "process-inside: the question did not name the process"
  assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "process-inside: the refusal changed"
  assert_foreign_copy_untouched process-inside
  pass "a foreign copy with a process outside the task running in it is refused and the process is left alone"
}

# A process running in a foreign copy keeps it unless it is the task's own: here
# it descends from the task's session, whose cwd is the slot. Retire ends it
# before the sweep, which refuses any process inside a nested copy; one that
# ignores TERM keeps the copy and the session, and is named by pid.
test_task_own_process_inside_foreign_copy_is_ended_and_released() {
  local rc shape agent child pidfile i
  # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
  local script='my $child = fork(); if (!$child) { $SIG{TERM} = "IGNORE" if $ARGV[2]; chdir $ARGV[1]; exec "sleep", "300"; } $SIG{CHLD} = "IGNORE"; open my $fh, ">", $ARGV[0]; print $fh $child; close $fh; sleep 300;'
  for shape in own stubborn; do
    make_foreign_copy_case "foreign-incopy-$shape"
    pidfile=$FOREIGN_CASE/child-pid
    teardown_fixture_start "$FOREIGN_SLOT" KILL perl -e "$script" "$pidfile" "$FOREIGN_COPY" "$([ "$shape" = stubborn ] && echo 1 || true)"
    agent=$TEARDOWN_FIXTURE_PID
    for i in $(seq 100); do [ -s "$pidfile" ] && break; sleep 0.05; done
    child=$(cat "$pidfile")
    cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*)
    if kill -0 $agent 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $agent '$FOREIGN_SLOT'; fi
    if kill -0 $child 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $child '$FOREIGN_COPY'; fi
    exit 0 ;;
esac
exit 1
SH
    run_foreign_teardown rc
    if [ "$shape" = own ]; then
      expect_code 0 "$rc" "incopy-own: the task's own process inside the copy must not block release: $(cat "$FOREIGN_CASE/stderr")"
      kill -0 "$child" 2>/dev/null && fail "incopy-own: the process inside the copy survived teardown"
      kill -0 "$agent" 2>/dev/null && fail "incopy-own: the task's session survived teardown"
      assert_grep "	TERM	$child	" "$FOREIGN_CASE/state/task-x1.teardown-processes" \
        "incopy-own: the signal to the process inside the copy was not recorded"
      assert_absent "$FOREIGN_COPY" "incopy-own: the copy survived"
      assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "incopy-own: the slot was not returned"
    else
      kill -0 "$child" 2>/dev/null || fail "incopy-stubborn: the process inside the copy did not ignore TERM"
      kill -0 "$agent" 2>/dev/null || fail "incopy-stubborn: the task's session was signalled although the sweep refused"
      kill -KILL "$child" "$agent" 2>/dev/null || true
      expect_code 1 "$rc" "incopy-stubborn: a process that outlives the signal must keep the copy: $(cat "$FOREIGN_CASE/stderr")"
      assert_grep "process $child" "$FOREIGN_CASE/stderr" "incopy-stubborn: the refusal did not name the process"
      assert_foreign_copy_untouched incopy-stubborn
    fi
  done
  pass "a task-own process running inside a foreign copy is ended by retire and the copy is released, and one that outlives the signal keeps the copy by pid"
}

test_two_foreign_copies_are_released_together_or_not_at_all() {
  local rc second
  dead_launcher_pid
  make_foreign_copy_case foreign-two-copies "$FOREIGN_DEAD_PID"
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/task-x1-v3 "$second" main
  printf 'edit\n' > "$second/untracked.txt"
  run_foreign_teardown rc
  expect_code 1 "$rc" "two-copies: one unprovable copy must refuse the slot: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "contains registered copy $second" "$FOREIGN_CASE/stderr" "two-copies: the refusal did not name the unprovable copy"
  assert_present "$second/untracked.txt" "two-copies: the unprovable copy lost its file"
  assert_foreign_copy_untouched two-copies
  rm -f "$second/untracked.txt"
  run_foreign_teardown rc
  expect_code 0 "$rc" "two-copies: two landed copies must both be released: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_COPY" "two-copies: the locked copy survived"
  assert_absent "$second" "two-copies: the unlocked copy survived"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "two-copies: only the locked copy goes through the driver, once"
  assert_grep "removed landed foreign copy $FOREIGN_COPY from pool slot $FOREIGN_SLOT" "$FOREIGN_CASE/stderr" \
    "two-copies: the locked copy's removal was not reported"
  assert_grep "removed landed foreign copy $second from pool slot $FOREIGN_SLOT" "$FOREIGN_CASE/stderr" \
    "two-copies: the unlocked copy's removal was not reported"
  git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v3 >/dev/null \
    || fail "two-copies: the second copy's branch was deleted"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "two-copies: the slot was not returned"
  pass "a slot's foreign copies are all proved before any is removed, and then all are released"
}

test_foreign_copy_is_released_before_the_project_lock_wait() {
  local rc lock
  dead_launcher_pid
  make_foreign_copy_case foreign-lock-order "$FOREIGN_DEAD_PID"
  lock=$(FM_HOME="$FOREIGN_CASE/home" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$ROOT" "$FOREIGN_CASE/project") \
    || fail "lock-order: cannot resolve the shared Treehouse project lock"
  cat > "$FOREIGN_CASE/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FOREIGN_CASE/treehouse.log"
case "\${1:-}" in
  return) if [ -d "$lock" ]; then echo held; else echo free; fi >> "$FOREIGN_CASE/return.lock-state" ;;
esac
exit 0
SH
  run_foreign_teardown rc FM_STUB_LOCK="$lock"
  expect_code 0 "$rc" "lock-order: a landed Vernant-locked copy must be released: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "held" "$(cat "$FOREIGN_CASE/return.lock-state" 2>/dev/null || true)" \
    "lock-order: the slot return did not run under the shared project lock, so the probe proves nothing"
  assert_equals "free" "$(cat "$FOREIGN_CASE/closeout.lock-state" 2>/dev/null || true)" \
    "lock-order: the closeout driver ran while the shared project lock was held"
  assert_absent "$FOREIGN_COPY" "lock-order: the copy survived"
  pass "the closeout driver runs before the shared project lock is taken, and the slot return still runs under it"
}

test_closeout_uses_the_slots_default_interpreter() {
  local rc
  dead_launcher_pid
  make_foreign_copy_case foreign-default-python "$FOREIGN_DEAD_PID"
  mkdir -p "$FOREIGN_SLOT/.venv/bin"
  cp "$FOREIGN_CASE/vernant-python" "$FOREIGN_SLOT/.venv/bin/python"
  run_foreign_teardown rc FM_TEARDOWN_VERNANT_PYTHON=
  expect_code 0 "$rc" "default-python: the slot's own interpreter must run the driver: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "default-python: the driver was not run once from the slot with the copy and the execute flag"
  assert_absent "$FOREIGN_COPY" "default-python: the copy survived"
  pass "without FM_TEARDOWN_VERNANT_PYTHON the driver runs under the slot's own .venv interpreter"
}

test_missing_closeout_driver_or_interpreter_leaves_the_copy_in_place() {
  local rc shape
  for shape in driver interpreter; do
    dead_launcher_pid
    make_foreign_copy_case "foreign-missing-$shape" "$FOREIGN_DEAD_PID"
    if [ "$shape" = driver ]; then
      rm -f "$FOREIGN_SLOT/scripts/git-stability/closeout_pr.py"
      run_foreign_teardown rc
    else
      run_foreign_teardown rc FM_TEARDOWN_VERNANT_PYTHON="$FOREIGN_CASE/no-such-python"
    fi
    expect_code 1 "$rc" "missing-$shape: a locked copy with no driver to release it must refuse: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: Vernant's closeout driver" "$FOREIGN_CASE/stderr" \
      "missing-$shape: the proof did not refuse the copy whose driver cannot start"
    assert_grep "is not available, so it cannot be released" "$FOREIGN_CASE/stderr" "missing-$shape: the refusal did not say what was missing"
    assert_foreign_copy_untouched "missing-$shape"
    assert_absent "$FOREIGN_CASE/state/task-x1.teardown-return-pending" "missing-$shape: a return-pending record was written before the refusal"
  done
  pass "a Vernant-locked copy whose closeout driver or interpreter is missing is refused at entry and stays"
}

test_foreign_copy_nested_in_another_is_removed_first() {
  local rc inner
  make_foreign_copy_case foreign-nested-in-foreign
  inner=$FOREIGN_COPY/.claude/worktrees/fc-inner
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/task-x1-v3 "$inner" main
  run_foreign_teardown rc
  expect_code 0 "$rc" "nested-in-foreign: a copy inside another foreign copy must not block the removal: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$inner" "nested-in-foreign: the inner copy survived"
  assert_absent "$FOREIGN_COPY" "nested-in-foreign: the outer copy survived"
  assert_grep "removed landed foreign copy $inner from pool slot $FOREIGN_SLOT" "$FOREIGN_CASE/stderr" \
    "nested-in-foreign: the inner copy's removal was not reported"
  assert_grep "removed landed foreign copy $FOREIGN_COPY from pool slot $FOREIGN_SLOT" "$FOREIGN_CASE/stderr" \
    "nested-in-foreign: the outer copy's removal was not reported"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "nested-in-foreign: the slot was not returned"
  pass "a foreign copy nested in another foreign copy is removed before the copy that holds it"
}

test_closeout_refusal_and_foreign_locks_leave_the_copy_in_place() {
  local rc shape
  for shape in driver-refuses human-lock; do
    dead_launcher_pid
    make_foreign_copy_case "foreign-$shape" "$FOREIGN_DEAD_PID"
    if [ "$shape" = human-lock ]; then
      git -C "$FOREIGN_CASE/project" worktree unlock "$FOREIGN_COPY"
      git -C "$FOREIGN_CASE/project" worktree lock --reason 'held by a human' "$FOREIGN_COPY"
      run_foreign_teardown rc
      assert_grep "locked by something other than Vernant's creation lock (held by a human)" "$FOREIGN_CASE/stderr" \
        "$shape: the refusal did not name the foreign lock"
    else
      run_foreign_teardown rc FM_STUB_CLOSEOUT=refuse
      assert_grep "Vernant's closeout driver did not release foreign copy $FOREIGN_COPY (exit 3)" "$FOREIGN_CASE/stderr" \
        "$shape: the driver refusal was not reported"
      assert_grep 'stub_refusal' "$FOREIGN_CASE/stderr" "$shape: the driver's reason was not reported"
      assert_present "$FOREIGN_CASE/closeout.log" "$shape: the driver was not asked"
    fi
    expect_code 1 "$rc" "$shape: must refuse: $(cat "$FOREIGN_CASE/stderr")"
    assert_present "$FOREIGN_COPY/.git" "$shape: the copy was removed"
    assert_absent "$FOREIGN_CASE/treehouse.log" "$shape: the pool slot was returned"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "$shape: the task record was removed"
  done
  pass "a driver refusal or a lock that is not Vernant's leaves the foreign copy, the slot and the record in place"
}

test_locked_own_nested_copy_is_released_by_the_closeout_driver() {
  local rc shape head
  for shape in enclosing reverse; do
    dead_launcher_pid
    make_own_locked_copy_case "own-locked-$shape" "$shape" "$FOREIGN_DEAD_PID"
    head=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
    run_foreign_teardown rc
    expect_code 0 "$rc" "own-locked-$shape: a landed, clean, Vernant-locked own copy must be released: $(cat "$FOREIGN_CASE/stderr")"
    assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
      "own-locked-$shape: the driver was not run once from the slot with the copy and the execute flag"
    assert_absent "$FOREIGN_COPY" "own-locked-$shape: the copy survived"
    git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -F "worktree $FOREIGN_COPY" >/dev/null \
      && fail "own-locked-$shape: the copy is still registered"
    assert_equals "$head" "$(git -C "$FOREIGN_CASE/project" rev-parse refs/heads/fm/task-x1-v2)" \
      "own-locked-$shape: the copy's branch moved"
    assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "own-locked-$shape: the slot was not returned"
    assert_absent "$FOREIGN_CASE/state/task-x1.meta" "own-locked-$shape: the task record survived"
    assert_absent "$FOREIGN_CASE/pool/1/.fm-slot-owner" "own-locked-$shape: the slot claim survived the task"
  done
  pass "a landed, clean own nested copy locked by Vernant is released through the closeout driver, removed, and the slot is returned"
}

test_locked_own_nested_copy_with_a_recycled_launcher_pid_is_released() {
  local rc pid admin
  sleep 300 &
  pid=$!
  make_own_locked_copy_case own-locked-recycled enclosing "$pid"
  admin=$(git -C "$FOREIGN_COPY" rev-parse --absolute-git-dir)
  # The lock file is older than the process, so the pid cannot be its launcher.
  fm_touch_epoch "$(( $(date +%s) - 3600 ))" "$admin/locked"
  run_foreign_teardown rc
  kill -0 "$pid" 2>/dev/null || fail "own-recycled: teardown ended the unrelated process that holds the recycled pid"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$rc" "own-recycled: a live but recycled launcher pid must not block release: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "own-recycled: the driver was not run once"
  assert_absent "$FOREIGN_COPY" "own-recycled: the copy survived"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "own-recycled: the slot was not returned"
  pass "an own copy whose lock names a pid that started after the lock was written is released by the same driver path"
}

test_live_launcher_outside_the_task_keeps_its_locked_own_copy() {
  local rc pid
  sleep 300 &
  pid=$!
  sleep 3
  make_own_locked_copy_case own-locked-live-launcher enclosing "$pid"
  run_foreign_teardown rc
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 1 "$rc" "own-live-launcher: a launcher outside the task that predates its lock must keep the copy: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "creation-lock launcher process $pid may still be running" "$FOREIGN_CASE/stderr" \
    "own-live-launcher: the refusal did not name the launcher"
  assert_own_locked_copy_untouched own-live-launcher
  pass "a live lock launcher outside the task keeps a locked own copy and is named by pid"
}

test_locked_own_nested_copy_that_is_not_proved_is_refused() {
  local rc shape
  for shape in unlanded dirty human-lock; do
    dead_launcher_pid
    make_own_locked_copy_case "own-locked-$shape" enclosing "$FOREIGN_DEAD_PID"
    case "$shape" in
      unlanded)
        printf 'unlanded\n' > "$FOREIGN_COPY/unlanded.txt"
        git -C "$FOREIGN_COPY" add unlanded.txt
        git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm 'unlanded own work'
        ;;
      dirty)
        printf 'edit\n' > "$FOREIGN_COPY/untracked.txt"
        ;;
      human-lock)
        git -C "$FOREIGN_CASE/project" worktree unlock "$FOREIGN_COPY"
        git -C "$FOREIGN_CASE/project" worktree lock --reason 'held by a human' "$FOREIGN_COPY"
        ;;
    esac
    run_foreign_teardown rc
    expect_code 1 "$rc" "own-locked-$shape: a locked own copy that is not proved must be refused: $(cat "$FOREIGN_CASE/stderr")"
    case "$shape" in
      human-lock)
        assert_grep "locked by something other than Vernant's creation lock (held by a human)" "$FOREIGN_CASE/stderr" \
          "own-locked-$shape: the refusal did not name the foreign lock"
        ;;
      dirty) assert_present "$FOREIGN_COPY/untracked.txt" "own-locked-$shape: the file was lost" ;;
    esac
    assert_own_locked_copy_untouched "own-locked-$shape"
    assert_equals "" "$(git -C "$FOREIGN_CASE/project" for-each-ref 'refs/fm/anchor/*')" \
      "own-locked-$shape: an anchor was written for a copy that was refused"
  done
  pass "a locked own copy with unlanded commits, unsaved files, or a lock that is not Vernant's is refused and nothing changes"
}

test_locked_own_nested_copy_with_unique_ignored_file_is_preserved_and_released() {
  local rc exclude preserved hash sums
  dead_launcher_pid
  make_own_locked_copy_case own-locked-ignored enclosing "$FOREIGN_DEAD_PID"
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf 'unique.dat\n' >> "$exclude"
  printf 'only here\n' > "$FOREIGN_COPY/unique.dat"
  run_foreign_teardown rc
  expect_code 0 "$rc" "own-locked-ignored: a unique ignored file must be preserved rather than refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_COPY" "own-locked-ignored: the copy survived"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "own-locked-ignored: the slot was not returned"
  preserved=$(find "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" -name unique.dat -type f 2>/dev/null | head -n 1)
  [ -n "$preserved" ] || fail "own-locked-ignored: the ignored file was not preserved in the task data directory"
  assert_equals "only here" "$(cat "$preserved")" "own-locked-ignored: the preserved file changed"
  sums="$(dirname "$(dirname "$preserved")")/meta/SHA256SUMS"
  assert_present "$sums" "own-locked-ignored: no SHA-256 manifest was written"
  hash=$(shasum -a 256 "$preserved" | awk '{print $1}')
  assert_grep "$hash  unique.dat" "$sums" "own-locked-ignored: the manifest does not record the preserved content"
  pass "a locked own copy's unique ignored file is preserved with its SHA-256 and the copy is released"
}

test_locked_own_nested_copy_stays_when_a_foreign_copy_is_refused() {
  local rc second
  dead_launcher_pid
  make_own_locked_copy_case own-locked-foreign-refused enclosing "$FOREIGN_DEAD_PID"
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
  fm_write_meta "$FOREIGN_CASE/state/other.meta" "kind=ship" "worktree=$second"
  run_foreign_teardown rc
  expect_code 1 "$rc" "own-foreign-refused: a foreign copy another record owns must refuse the slot: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "task other's active record names it as its worktree" "$FOREIGN_CASE/stderr" \
    "own-foreign-refused: the refusal did not name the owning record"
  assert_grep "contains registered copy $second" "$FOREIGN_CASE/stderr" "own-foreign-refused: the refusal changed"
  assert_present "$second/.git" "own-foreign-refused: the foreign copy was removed"
  assert_own_locked_copy_untouched own-foreign-refused
  pass "a foreign copy that is still refused keeps the locked own copy, the slot and the record in place"
}

test_locked_own_nested_copy_is_released_before_the_project_lock_wait() {
  local rc lock
  dead_launcher_pid
  make_own_locked_copy_case own-lock-order enclosing "$FOREIGN_DEAD_PID"
  lock=$(FM_HOME="$FOREIGN_CASE/home" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$ROOT" "$FOREIGN_CASE/project") \
    || fail "own-lock-order: cannot resolve the shared Treehouse project lock"
  cat > "$FOREIGN_CASE/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FOREIGN_CASE/treehouse.log"
case "\${1:-}" in
  return) if [ -d "$lock" ]; then echo held; else echo free; fi >> "$FOREIGN_CASE/return.lock-state" ;;
esac
exit 0
SH
  run_foreign_teardown rc FM_STUB_LOCK="$lock"
  expect_code 0 "$rc" "own-lock-order: a landed Vernant-locked own copy must be released: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "held" "$(cat "$FOREIGN_CASE/return.lock-state" 2>/dev/null || true)" \
    "own-lock-order: the slot return did not run under the shared project lock, so the probe proves nothing"
  assert_equals "free" "$(cat "$FOREIGN_CASE/closeout.lock-state" 2>/dev/null || true)" \
    "own-lock-order: the closeout driver ran while the shared project lock was held"
  assert_absent "$FOREIGN_COPY" "own-lock-order: the copy survived"
  pass "the closeout driver releases a locked own copy before the shared project lock is taken, and the slot return still runs under it"
}

test_closeout_refusal_reports_tail_and_preserves_complete_output() {
  local rc ownership length n output_file line log
  for ownership in foreign own; do
    for length in long short; do
      dead_launcher_pid
      if [ "$ownership" = own ]; then
        make_own_locked_copy_case "closeout-output-$ownership-$length" enclosing "$FOREIGN_DEAD_PID"
      else
        make_foreign_copy_case "closeout-output-$ownership-$length" "$FOREIGN_DEAD_PID"
      fi
      if [ "$length" = long ]; then
        printf '.env warning: leading diagnostic must not hide the refusal\n' > "$FOREIGN_CASE/driver-output"
        for n in $(seq 1 40); do
          printf 'warning %s: %0100d\n' "$n" 0 >> "$FOREIGN_CASE/driver-output"
        done
      else
        printf 'short closeout diagnostic\n' > "$FOREIGN_CASE/driver-output"
      fi
      printf 'actual refusal after warnings\n\n' >> "$FOREIGN_CASE/driver-output"
      cp "$FOREIGN_CASE/driver-output" "$FOREIGN_CASE/expected-output"
      printf '%s\n' '{"allowed": false, "reason": "stub_refusal"}' >> "$FOREIGN_CASE/expected-output"
      run_foreign_teardown rc FM_STUB_CLOSEOUT=refuse FM_STUB_CLOSEOUT_OUTPUT="$FOREIGN_CASE/driver-output"
      expect_code 1 "$rc" "$ownership-$length: driver refusal must retain teardown's exit code"
      assert_grep '(exit 3)' "$FOREIGN_CASE/stderr" "$ownership-$length: driver exit code was lost"
      assert_grep 'actual refusal after warnings' "$FOREIGN_CASE/stderr" "$ownership-$length: warning hid the real refusal"
      if [ "$length" = long ]; then
        assert_no_grep '.env warning: leading diagnostic' "$FOREIGN_CASE/stderr" "$ownership-$length: refusal printed the head instead of the tail"
      else
        assert_grep 'short closeout diagnostic' "$FOREIGN_CASE/stderr" "$ownership-$length: short output was truncated"
      fi
      output_file=
      while IFS= read -r line; do
        case "$line" in *'full output: '*) output_file=${line##*full output: } ;; esac
      done < "$FOREIGN_CASE/stderr"
      case "$output_file" in
        "$FOREIGN_CASE/data/task-x1/"*) ;;
        *) fail "$ownership-$length: refusal did not name output in the task's data directory" ;;
      esac
      assert_present "$output_file" "$ownership-$length: named output file is missing"
      cmp -s "$FOREIGN_CASE/expected-output" "$output_file" || fail "$ownership-$length: saved output is not byte-identical to the driver's complete output"
      assert_present "$FOREIGN_COPY/.git" "$ownership-$length: refusal removed the copy"
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "$ownership-$length: refusal removed the task record"
      assert_absent "$FOREIGN_CASE/treehouse.log" "$ownership-$length: refusal returned the slot"
    done
    dead_launcher_pid
    if [ "$ownership" = own ]; then
      make_own_locked_copy_case "closeout-output-$ownership-success" enclosing "$FOREIGN_DEAD_PID"
    else
      make_foreign_copy_case "closeout-output-$ownership-success" "$FOREIGN_DEAD_PID"
    fi
    printf 'successful closeout diagnostic\n' > "$FOREIGN_CASE/driver-output"
    run_foreign_teardown rc FM_STUB_CLOSEOUT_OUTPUT="$FOREIGN_CASE/driver-output"
    expect_code 0 "$rc" "$ownership: successful closeout must still succeed"
    assert_no_grep 'successful closeout diagnostic' "$FOREIGN_CASE/stderr" "$ownership: successful driver output was printed"
    assert_no_grep 'full output:' "$FOREIGN_CASE/stderr" "$ownership: successful closeout printed a refusal log"
    for log in "$FOREIGN_CASE/data/task-x1"/vernant-closeout.*; do
      assert_absent "$log" "$ownership: successful closeout left a durable output file"
    done
  done
  pass 'own and foreign closeout refusals show the tail and save byte-identical full output; short output stays complete and successful output stays silent without a durable log'
}

test_closeout_driver_refusal_leaves_a_locked_own_copy_and_its_records() {
  local rc shape
  for shape in enclosing reverse; do
    dead_launcher_pid
    make_own_locked_copy_case "own-driver-refuses-$shape" "$shape" "$FOREIGN_DEAD_PID"
    run_foreign_teardown rc FM_STUB_CLOSEOUT=refuse
    expect_code 1 "$rc" "own-driver-refuses-$shape: a driver refusal must refuse the teardown: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "Vernant's closeout driver did not release own nested copy $FOREIGN_COPY (exit 3)" "$FOREIGN_CASE/stderr" \
      "own-driver-refuses-$shape: the driver refusal was not reported"
    assert_grep 'stub_refusal' "$FOREIGN_CASE/stderr" "own-driver-refuses-$shape: the driver's reason was not reported"
    assert_present "$FOREIGN_CASE/closeout.log" "own-driver-refuses-$shape: the driver was not asked"
    assert_present "$FOREIGN_COPY/.git" "own-driver-refuses-$shape: the copy was removed"
    git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -F "worktree $FOREIGN_COPY" >/dev/null \
      || fail "own-driver-refuses-$shape: the copy is no longer registered"
    git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -A4 -F "worktree $FOREIGN_COPY" | grep -q '^locked' \
      || fail "own-driver-refuses-$shape: the copy is no longer locked"
    assert_absent "$FOREIGN_CASE/treehouse.log" "own-driver-refuses-$shape: the pool slot was returned"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "own-driver-refuses-$shape: the task record was removed"
    cmp -s "$FOREIGN_CASE/treehouse-state.before" "$FOREIGN_CASE/pool/treehouse-state.json" \
      || fail "own-driver-refuses-$shape: Treehouse's lease record changed"
    cmp -s "$FOREIGN_CASE/slot-owner.before" "$FOREIGN_CASE/pool/1/.fm-slot-owner" \
      || fail "own-driver-refuses-$shape: the slot claim changed"
  done
  pass "a closeout driver refusal leaves a locked own copy, the slot claim, the lease and the task record in place"
}


# --- Kept own copies (bin/fm-teardown-nested-lib.sh "Kept own copies") -----------------------
#
# When Vernant's closeout driver keeps an own nested copy (exit 3 with
# cleanup_ignored_payload_archived_tree_retained), teardown runs no destructive step on it and
# only (a) proves it landed and clean, (b) proves its unique ignored files saved (the driver's
# verified archive and the task's preserve), (c) writes one record with the driver's answer and
# (d) closes when (a) and (b) hold. The helper-level cases below call the library functions
# directly in a scratch directory (a scratch Git repository stands for the copy) with the
# driver, the creation lock and the landed-work test as controlled stand-ins; the cases after
# them run bin/fm-teardown.sh on the teardown fixture.

# kept_assert_lacks <text> <file> <message>: <file> is a readable regular file that does not
# hold <text>. Unlike the shared assert_no_grep (tests/lib.sh), a missing or unreadable file
# fails here instead of passing as "no match"; the shared helper is left as it is because 63
# suites call it and some pass a file that may rightly be absent.
kept_assert_lacks() {
  { [ -f "$2" ] && [ -r "$2" ]; } || fail "$3 (the file $2 to search is missing or unreadable)"
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# kept_helper_env: the shell text a helper-level case evals in its subshell: the libraries
# bin/fm-teardown.sh sources for this route, then stand-ins for the creation lock (a file in
# the case directory), the landed-work test and the telemetry, and a closeout driver stand-in
# that counts its calls in $KC/calls, writes one tar per call in $KC/tars and answers with the
# JSON in $KC/answer, in which @ARCHIVE@ and @SHA@ stand for the tar it wrote and its SHA-256.
kept_helper_env() {
  cat <<'SH'
set +e
for l in fm-task-copy-lib fm-lock-lib fm-refuse-lib fm-teardown-nested-lib; do
  # shellcheck source=/dev/null
  . "$ROOT/bin/$l.sh" || exit 9
done
ID=task-x1
DATA=$KC/data
TEARDOWN_NESTED_COPIES=("$KC/copy")
teardown_copy_lock_file() {
  TEARDOWN_FOREIGN_LOCK_FILE=$KC/lock
  TEARDOWN_FOREIGN_LOCK=$(cat "$KC/lock")
  return 0
}
teardown_vernant_lock_pid() { printf '%s\n' 1; }
teardown_landed() { [ ! -e "$KC/unlanded" ]; }
teardown_own_nested_other_repos() { return 0; }
teardown_friction_outcome() { :; }
report_worktree_dirt() { :; }
teardown_refuse_copy() { printf 'REFUSED: %s\n' "$2" >&2; return 1; }
teardown_foreign_copy_present() { return 1; }
teardown_closeout_ready_in() { return 0; }
teardown_run_closeout() {
  local n tar sha
  # A plan call (Main 2056) answers like the real driver for a tree with unique ignored files,
  # unless $KC/plan-answer and $KC/plan-exit say otherwise; it is counted in $KC/plan-calls.
  if [ "${3:-}" = plan ]; then
    printf '%s\n' "$2" >> "$KC/plan-calls"
    TEARDOWN_CLOSEOUT_STDOUT=$(cat "$KC/plan-answer" 2>/dev/null || printf '%s' '{"allowed": true, "ignored_payload_disposition": "archive_then_retain_tree"}')
    TEARDOWN_CLOSEOUT_OUT=$TEARDOWN_CLOSEOUT_STDOUT
    return "$(cat "$KC/plan-exit" 2>/dev/null || echo 0)"
  fi
  n=$(( $(cat "$KC/calls" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$n" > "$KC/calls"
  mkdir -p "$KC/tars"
  tar=$KC/tars/$n.tar
  printf 'archive %s\n' "$n" > "$tar"
  sha=$(teardown_ignored_sha256 "$tar")
  [ ! -e "$KC/after" ] || . "$KC/after"
  TEARDOWN_CLOSEOUT_STDOUT=$(sed -e "s#@ARCHIVE@#$tar#g" -e "s#@SHA@#$sha#g" "$KC/answer")
  TEARDOWN_CLOSEOUT_OUT=$TEARDOWN_CLOSEOUT_STDOUT
  return "$(cat "$KC/exit" 2>/dev/null || echo 3)"
}
# $KC/after-preserve, when present, runs right after the product's own preserve writer
# (whichever name it has), to change the copy or the preserve at that boundary.
if [ -e "$KC/after-preserve" ]; then
  for kept_fn in teardown_own_preserve teardown_preserve_ignored; do
    declare -F "$kept_fn" >/dev/null || continue
    eval "kept_orig_$(declare -f "$kept_fn")"
    eval "$kept_fn() { kept_orig_$kept_fn \"\$@\"; local r=\$?; . \"\$KC/after-preserve\"; return \$r; }"
    break
  done
fi
SH
}

# kept_helper_case <dir>: a scratch copy (a Git repository with one commit and one ignored file
# preservation selects, notes/unique.dat), a creation-lock file and the recorded answer shape of
# the driver for it (two unique .claude paths and a verified archive).
kept_helper_case() {
  local kc=$1
  mkdir -p "$kc/copy/notes" "$kc/copy/.claude/channel-outbox" "$kc/data"
  git -C "$kc/copy" init -q
  printf 'tracked\n' > "$kc/copy/tracked.txt"
  git -C "$kc/copy" add tracked.txt
  git -C "$kc/copy" -c user.email=t@t -c user.name=t commit -qm base
  printf '%s\n' '.claude/' 'notes/' >> "$kc/copy/.git/info/exclude"
  printf 'only here\n' > "$kc/copy/notes/unique.dat"
  printf 'one\n' > "$kc/copy/.claude/channel-outbox/a.jsonl"
  printf 'vernant-session-active owner=launcher:1 launcher=1\n' > "$kc/lock"
  kept_helper_answer "$kc" '[".claude/channel-outbox/a.jsonl"]' 1
}

# kept_helper_answer <dir> <unique-json> <path-count> [<archive-path-json>]: the driver's answer.
kept_helper_answer() {
  local copy
  copy=$(cd "$1/copy" && pwd -P)
  printf '{"allowed": false, "ignored_payload_disposition": "archive_then_retain_tree", "ignored_payload_preservation": [{"archive_path": %s, "archive_sha256": "@SHA@", "path_count": %s, "restore_verified": true, "stage": "ordinary_cleanup"}], "reason": "cleanup_ignored_payload_archived_tree_retained", "retained_worktree_path": "%s", "tracked_uncovered_paths": [], "uncovered_paths": [], "untracked_uncovered_paths": [], "unique_ignored_paths": %s}\n' \
    "${4:-\"@ARCHIVE@\"}" "$3" "$copy" "$2" > "$1/answer"
}

# kept_helper_dispose <dir> <runs>: runs teardown_own_copy_dispose <runs> times, each in a fresh
# shell (a new teardown run), and prints one line per run: its exit status, whether it closed
# around the copy, and the driver calls so far.
kept_helper_dispose() {
  local kc=$1 runs=$2 run copy
  copy=$(cd "$kc/copy" && pwd -P)
  for run in $(seq 1 "$runs"); do
    KC=$kc ROOT=$ROOT COPY=$copy bash -c "$(kept_helper_env)"'
TEARDOWN_NESTED_COPIES=("$COPY")
# A product whose dispose needs the proof'"'"'s lock note (round 4) gets it here, so the round-4
# product is judged on the same path; the current product has no such note.
! declare -F teardown_lock_proved_note >/dev/null || { teardown_copy_lock_file "$COPY"; teardown_lock_proved_note "$COPY"; }
teardown_own_copy_dispose "$KC" "$COPY" 2>>"$KC/stderr"
rc=$?
kept=no
! teardown_copy_retained "$COPY" || kept=yes
printf "rc=%s kept=%s calls=%s\n" "$rc" "$kept" "$(cat "$KC/calls" 2>/dev/null || echo 0)"
' | tee -a "$kc/runs"
  done
  # VC: each run's observation, written by the run itself, when FM_RETAINED_EVIDENCE names a file.
  if [ -n "${FM_RETAINED_EVIDENCE:-}" ]; then
    printf '%s | case=%s | runs: %s | tars=%s | preserves=%s | refusal-records=%s | causes: %s\n' \
      "${FUNCNAME[1]:-?}" "${kc##*/}" "$(tail -n "$runs" "$kc/runs" | paste -sd ';' -)" \
      "$(find "$kc/tars" -name '*.tar' 2>/dev/null | wc -l | tr -d ' ')" \
      "$(find "$kc/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')" \
      "$(find "$kc/data/task-x1/closeout-refused" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')" \
      "$(grep -o 'REFUSED: .\{0,160\}' "$kc/stderr" 2>/dev/null | tail -n 2 | paste -sd '|' -)" >> "$FM_RETAINED_EVIDENCE"
  fi
}

# (c) and (d) helper level, the controls of every case below: a valid kept answer closes around
# the copy with one driver call, the record carries the answer and the state, the copy is not
# changed, and a second run judges the record again without the driver.
test_kept_copy_helper_a_valid_answer_is_recorded_once_and_judged_again_without_the_driver() {
  local tmp kc out rec before after
  tmp=$(fm_test_tmproot kept-helper-valid)
  kc=$tmp/case
  kept_helper_case "$kc"
  before=$(cd "$kc/copy" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | xargs shasum -a 256)
  out=$(kept_helper_dispose "$kc" 2)
  assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-valid: a valid kept answer must close once and be judged again without the driver: $(cat "$kc/stderr")"
  rec=$(find "$kc/data/copy-sweep/retained" -type f | head -n 1)
  assert_present "$rec" "kept-helper-valid: no record was written"
  assert_equals "copy=$(cd "$kc/copy" && pwd -P)" "$(sed -n 2p "$rec")" "kept-helper-valid: the record does not name the copy"
  assert_equals "task slot preserve reason recorded-at head status-sha256 payload-sha256 answer-base64" "$(sed -n '5,$p' "$rec" | sed 's/=.*//' | paste -sd ' ' -)" "kept-helper-valid: the record does not hold exactly its fields"
  assert_equals "$kc/tars/1.tar" "$(sed -n 's/^answer-base64=//p' "$rec" | perl -MMIME::Base64 -0777 -ne 'print decode_base64($_)' | jq -r '.ignored_payload_preservation[-1].archive_path')" "kept-helper-valid: the record does not carry the driver's answer"
  after=$(cd "$kc/copy" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | xargs shasum -a 256)
  assert_equals "$before" "$after" "kept-helper-valid: the kept copy changed"
  rm -rf "$tmp"
  pass "a valid kept answer is recorded once with the answer and the state, closes around the unchanged copy, and is judged again on the next run without the driver"
}

# F6 (1), (b): an answer that keeps the copy but names an empty unique path, or a recorded archive
# whose SHA-256 does not match, inside the copy, or of a different path count, is recorded at once
# and refused; the unchanged retry refuses again from the record and asks the driver nothing.
test_kept_copy_helper_an_invalid_kept_answer_is_recorded_and_never_asked_again() {
  local tmp kc out shape
  tmp=$(fm_test_tmproot kept-helper-invalid)
  for shape in empty-path wrong-sha inside-copy count; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    case "$shape" in
      empty-path) kept_helper_answer "$kc" '[""]' 1 ;;
      wrong-sha) sed -i.bak 's/@SHA@/0000000000000000000000000000000000000000000000000000000000000000/' "$kc/answer" ;;
      inside-copy)
        # The stand-in names a copy of its tar placed in the copy's own .git folder: inside the
        # copy, and a change neither its status nor its payload fingerprint sees.
        # shellcheck disable=SC2016 # expanded by the stand-in driver's shell.
        printf 'cp "$tar" "$KC/copy/.git/in.tar"; tar=$KC/copy/.git/in.tar; sha=$(teardown_ignored_sha256 "$tar")\n' > "$kc/after"
        ;;
      count) kept_helper_answer "$kc" '[".claude/channel-outbox/a.jsonl"]' 2 ;;
    esac
    out=$(kept_helper_dispose "$kc" 3)
    assert_equals $'rc=1 kept=no calls=1\nrc=1 kept=no calls=1\nrc=1 kept=no calls=1' "$out" "kept-helper-invalid-$shape: an invalid kept answer must refuse and never ask the driver again: $(cat "$kc/stderr")"
    assert_equals 1 "$(find "$kc/data/copy-sweep/retained" -type f | wc -l | tr -d ' ')" "kept-helper-invalid-$shape: the kept answer was not recorded once"
    assert_equals 1 "$(find "$kc/tars" -name '*.tar' | wc -l | tr -d ' ')" "kept-helper-invalid-$shape: more than one archive was written"
    assert_grep 'REFUSED' "$kc/stderr" "kept-helper-invalid-$shape: the refusal named no cause"
    assert_present "$kc/copy/notes/unique.dat" "kept-helper-invalid-$shape: the copy lost a file"
  done
  rm -rf "$tmp"
  pass "a kept answer with an empty path, an archive whose hash does not match, an archive inside the copy or a wrong path count is recorded once and refused, and two unchanged retries ask the driver nothing"
}

# F6 (2), (c): the driver is asked only when its answer can be recorded. A record folder that is
# searchable but not writable, a record that exists but cannot be read, and a copy whose
# repository cannot be read each refuse before the driver; the repaired state asks it once.
test_kept_copy_helper_the_driver_is_asked_only_when_its_answer_can_be_recorded() {
  local tmp kc out shape rec
  tmp=$(fm_test_tmproot kept-helper-unrecordable)
  for shape in unwritable-folder unreadable-record unreadable-copy; do
    # A permission bit does not stop root, so the two permission shapes need another user.
    case "$shape" in unwritable-folder|unreadable-record) [ "$(id -u)" != 0 ] || continue ;; esac
    kc=$tmp/$shape
    kept_helper_case "$kc"
    mkdir -p "$kc/data/copy-sweep/retained"
    rec=$kc/data/copy-sweep/retained/$(printf '%s' "$(cd "$kc/copy" && pwd -P)" | shasum -a 256 | awk '{print $1}')
    case "$shape" in
      unwritable-folder) chmod 555 "$kc/data/copy-sweep/retained" ;;
      unreadable-record) printf 'x\n' > "$rec"; chmod 000 "$rec" ;;
      unreadable-copy) mv "$kc/copy/.git" "$kc/copy/.git-aside" ;;
    esac
    out=$(kept_helper_dispose "$kc" 2)
    assert_equals $'rc=1 kept=no calls=0\nrc=1 kept=no calls=0' "$out" "kept-helper-unrecordable-$shape: the driver was asked while its answer could not be recorded: $(cat "$kc/stderr")"
    assert_absent "$kc/tars" "kept-helper-unrecordable-$shape: an archive was written"
    case "$shape" in
      unwritable-folder) chmod 755 "$kc/data/copy-sweep/retained" ;;
      unreadable-record) chmod 644 "$rec"; rm -f "$rec" ;;
      unreadable-copy) mv "$kc/copy/.git-aside" "$kc/copy/.git" ;;
    esac
    out=$(kept_helper_dispose "$kc" 2)
    assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-unrecordable-$shape: the repaired state did not ask the driver exactly once: $(cat "$kc/stderr")"
  done
  rm -rf "$tmp"
  pass "a record folder that cannot be written, a record that cannot be read and a copy whose repository cannot be read each refuse before the driver, and the repaired state asks it once"
}

# (a) and (d) from the record: a kept copy refused because it is not landed stays refused on
# the unchanged retry without the driver, and closes without the driver once its cause has gone.
# A preserve that lost a selected file is rebuilt by the next run's preservation and the record
# then closes, again without the driver.
test_kept_copy_helper_a_refused_kept_copy_is_judged_again_from_its_record() {
  local tmp kc out
  tmp=$(fm_test_tmproot kept-helper-rejudge)
  kc=$tmp/unlanded
  kept_helper_case "$kc"
  : > "$kc/unlanded"
  out=$(kept_helper_dispose "$kc" 2)
  assert_equals $'rc=1 kept=no calls=1\nrc=1 kept=no calls=1' "$out" "kept-helper-rejudge-unlanded: an unlanded kept copy must refuse and not be asked again: $(cat "$kc/stderr")"
  assert_grep 'not landed' "$kc/stderr" "kept-helper-rejudge-unlanded: the refusal did not name the cause"
  rm -f "$kc/unlanded"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-rejudge-unlanded: the landed copy did not close from its record: $(cat "$kc/stderr")"
  kc=$tmp/preserve
  kept_helper_case "$kc"
  # shellcheck disable=SC2016 # expanded by the stand-in driver's shell.
  printf 'rm -f "$DATA/$ID/nested-copy-preserved/"*/files/notes/unique.dat\n' > "$kc/after"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=1 kept=no calls=1' "$out" "kept-helper-rejudge-preserve: a preserve without a selected file must refuse: $(cat "$kc/stderr")"
  assert_grep 'does not hold every ignored file' "$kc/stderr" "kept-helper-rejudge-preserve: the refusal did not name the preserve"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-rejudge-preserve: the rebuilt preserve did not close from the record: $(cat "$kc/stderr")"
  rm -rf "$tmp"
  pass "a refused kept copy is judged again from its record without the driver: it stays refused while its cause holds and closes once the cause has gone"
}

# Main 1889: on a retry whose record matches, the kept copy is no swept root of the retire step:
# no run is concluded, no agent retired and no process scanned or signalled in it, while every
# other root is swept as before. The retire phase of teardown_nested_slot runs with its steps
# replaced by recorders.
test_kept_copy_helper_the_retire_step_leaves_a_matching_kept_copy_out() {
  local tmp log
  tmp=$(fm_test_tmproot kept-helper-retire)
  mkdir -p "$tmp/wt" "$tmp/slot/kept" "$tmp/slot/other" "$tmp/tasktmp"
  log=$tmp/log
  # The extraction runs outside the -c text: bash 3.2 misparses a parenthesis in a sed
  # pattern inside eval "$(...)".
  sed -n '/^teardown_nested_slot() {/,/^}/p' "$ROOT/bin/fm-teardown.sh" > "$tmp/fn.sh"
  KC=$tmp ROOT=$ROOT LOG=$log bash -c '
set +e
for l in fm-task-copy-lib fm-lock-lib fm-refuse-lib fm-teardown-nested-lib; do . "$ROOT/bin/$l.sh" || exit 9; done
. "$KC/fn.sh"
WT=$KC/wt; TEARDOWN_RETURN_SLOT=$KC/slot; TASK_TMP=$KC/tasktmp
TEARDOWN_NESTED_COPIES=("$KC/slot/kept" "$KC/slot/other")
conclude_task_no_mistakes_run() { printf "conclude %s\n" "$1" >> "$LOG"; }
retire_task_private_nm_launch_agents() { printf "agents %s\n" "$1" >> "$LOG"; }
task_reap_preflight() { printf "preflight %s\n" "$*" >> "$LOG"; }
teardown_foreign_procs_retire() { printf "foreign-procs\n" >> "$LOG"; }
reap_task_worktree_processes() { shift; printf "reap %s\n" "$*" >> "$LOG"; }
teardown_retained_copy_held() { [ "$1" = "$KC/slot/kept" ]; }
teardown_retained_matches() { [ "$1" = "$KC/slot/kept" ]; }
teardown_nested_slot retire
' 2>"$tmp/stderr"
  kept_assert_lacks "$tmp/slot/kept" "$log" "kept-helper-retire: the retire step reached the matching kept copy: $(cat "$log")"
  assert_grep "conclude $tmp/slot/other" "$log" "kept-helper-retire: another nested copy was not swept: $(cat "$log" "$tmp/stderr")"
  assert_grep "conclude $tmp/wt" "$log" "kept-helper-retire: the task's worktree was not swept"
  assert_grep "reap $tmp/wt $tmp/slot $tmp/slot/other $tmp/tasktmp" "$log" "kept-helper-retire: the reaper's roots are not the other roots"
  assert_grep "preflight $tmp/wt $tmp/slot $tmp/slot/other $tmp/tasktmp" "$log" "kept-helper-retire: the preflight's roots are not the reaper's"
  [ "$(grep -n '^preflight ' "$log" | head -n 1 | cut -d: -f1)" -lt "$(grep -n '^conclude ' "$log" | head -n 1 | cut -d: -f1)" ] \
    || fail "kept-helper-retire: the preflight did not run before the first run was concluded: $(cat "$log")"
  rm -rf "$tmp"
  pass "on a retry whose record matches, the retire step concludes, retires and reaps every root but the kept copy"
}

# Main 1889: on a retry whose record matches, the proof of the kept copy still runs (and still
# refuses what it refuses), but nothing it queues for the retire signal is kept; another locked
# own copy's queue is kept.
test_kept_copy_helper_the_proof_queues_no_signal_for_a_matching_kept_copy() {
  local tmp out
  tmp=$(fm_test_tmproot kept-helper-queue)
  mkdir -p "$tmp/kept" "$tmp/other"
  out=$(KC=$tmp ROOT=$ROOT bash -c '
set +e
for l in fm-task-copy-lib fm-lock-lib fm-refuse-lib fm-teardown-nested-lib; do . "$ROOT/bin/$l.sh" || exit 9; done
TEARDOWN_NESTED_COPIES=("$KC/kept" "$KC/other")
TEARDOWN_FOREIGN_PROCS=()
printf "vernant-session-active owner=launcher:1 launcher=1\n" > "$KC/lock"
teardown_copy_lock_file() { TEARDOWN_FOREIGN_LOCK_FILE=$KC/lock; TEARDOWN_FOREIGN_LOCK=$(cat "$KC/lock"); return 0; }
teardown_vernant_lock_pid() { printf "1\n"; }
teardown_foreign_copy_unowned() { TEARDOWN_FOREIGN_PROCS+=("4242	identity	$1"); return 0; }
teardown_retained_copy_held() { [ "$1" = "$KC/kept" ]; }
teardown_retained_matches() { [ "$1" = "$KC/kept" ]; }
teardown_refuse_copy() { printf "REFUSED: %s\n" "$2" >&2; return 1; }
teardown_closeout_ready_in() { return 0; }
teardown_run_closeout() { TEARDOWN_CLOSEOUT_STDOUT="{\"allowed\": true}"; TEARDOWN_CLOSEOUT_OUT=$TEARDOWN_CLOSEOUT_STDOUT; return 0; }
teardown_own_locked_copies_prove; rc=$?
printf "rc=%s\n" "$rc"
printf "%s\n" "${TEARDOWN_FOREIGN_PROCS[@]}"
' 2>&1)
  assert_equals "rc=0"$'\n'"4242	identity	$tmp/other" "$out" "kept-helper-queue: the proof kept a signal queued for the matching kept copy, or dropped another copy's"
  rm -rf "$tmp"
  pass "on a retry whose record matches, the kept copy's proof runs but queues nothing for the retire signal, and another copy's queue stays"
}

# F7, sweep side: a retained receipt that is not a regular readable file (here a readable
# directory) is never stale, so --apply never clears it, and another home's such receipt holds
# the copy; a regular matching receipt is the control, and a receipt whose copy is gone is stale.
test_kept_copy_helper_a_receipt_that_is_not_a_regular_file_still_holds_the_copy() {
  local tmp out
  tmp=$(fm_test_tmproot kept-helper-receipt)
  mkdir -p "$tmp/copy" "$tmp/own/data" "$tmp/other/state" "$tmp/other/data/copy-sweep/retained"
  git -C "$tmp/copy" init -q
  sed -n '/^receipt_is_stale() {/,/^}/p; /^other_home_dir_blocked() {/,/^}/p; /^other_home_retained() {/,/^}/p' "$ROOT/bin/fm-copy-sweep.sh" > "$tmp/fn.sh"
  out=$(KC=$tmp ROOT=$ROOT bash -c '
set +e
for l in fm-task-copy-lib fm-lock-lib fm-refuse-lib fm-teardown-nested-lib; do . "$ROOT/bin/$l.sh" || exit 9; done
. "$KC/fn.sh"
printf "vernant-session-active owner=launcher:1 launcher=1\n" > "$KC/lock"
teardown_copy_lock_file() { TEARDOWN_FOREIGN_LOCK_FILE=$KC/lock; return 0; }
DATA_DIR=$KC/own/data; CHECK_ID=copy-sweep
FM_LOCAL_FIRSTMATE_STATES=("$KC/other/state")
copy=$(cd "$KC/copy" && pwd -P)
rec=$(teardown_retained_receipt "$KC/other/data" "$copy")
printf "lock-sha256=%s\ncopy=%s\nidentity=%s\nkept\n" "$(teardown_ignored_sha256 "$KC/lock")" "$copy" "$(copy_identity "$copy")" > "$rec"
receipt_is_stale "$rec"; printf "regular-stale=%s\n" "$?"
CLASS=; other_home_retained "$copy"; printf "regular-held=%s %s\n" "$?" "$CLASS"
rm -f "$rec"; mkdir "$rec"
receipt_is_stale "$rec"; printf "directory-stale=%s\n" "$?"
CLASS=; other_home_retained "$copy"; printf "directory-held=%s %s\n" "$?" "$CLASS"
rmdir "$rec"
printf "lock-sha256=%s\ncopy=%s/gone\nidentity=1:1\nkept\n" "$(teardown_ignored_sha256 "$KC/lock")" "$copy" > "$KC/gone-receipt"
receipt_is_stale "$KC/gone-receipt"; printf "gone-stale=%s\n" "$?"
' 2>/dev/null)
  assert_equals $'regular-stale=1\nregular-held=0 HELD-LOCKED\ndirectory-stale=1\ndirectory-held=0 HELD-LOCKED\ngone-stale=0' "$out" "kept-helper-receipt: a receipt that is not a regular file did not hold the copy, or a control changed"
  rm -rf "$tmp"
  pass "a retained receipt that is not a regular readable file is never stale and another home's such receipt holds the copy, while a matching receipt holds and a gone copy's receipt is stale"
}

# kept_tree <dir>: one line per file, symlink and FIFO under <dir> (type, path, SHA-256 or the
# link target's bytes in hex), sorted, read independently of the product.
kept_tree() {
  [ -d "$1" ] || { echo "absent"; return 0; }
  (cd "$1" && perl -MFile::Find -MDigest::SHA -e '
    my @l;
    find({ no_chdir => 1, wanted => sub {
      my $p = $File::Find::name; return if $p eq ".";
      if (-l $p) { push @l, "L $p " . unpack("H*", readlink $p) }
      elsif (-f $p) { open(my $f, "<:raw", $p) or die; push @l, "F $p " . Digest::SHA->new(256)->addfile($f)->hexdigest }
      elsif (-p $p) { push @l, "P $p" }
    } }, ".");
    print "$_\n" for sort @l;')
}

# kept_preserve_base <dir>: the first preserve directory of the case's copy.
kept_preserve_base() {
  printf '%s/data/task-x1/nested-copy-preserved/%s\n' "$1" "$(printf '%s' "$(cd "$1/copy" && pwd -P)" | shasum -a 256 | awk '{print $1}')"
}

# Item 1 (C2 unchanged, closed end state): a retry of a task whose close completed around a kept
# copy is told it is already closed, naming the record, before any copy lookup; a task record
# that is damaged rather than gone, a task record still present, a pending backlog close, or a
# kept copy's record without the mark of a completed close is not a completed close.
test_kept_copy_helper_a_retry_of_a_closed_task_says_it_is_already_closed() {
  local tmp kc out shape
  tmp=$(fm_test_tmproot kept-helper-closed)
  for shape in closed meta-damaged meta-present close-pending not-marked; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    out=$(kept_helper_dispose "$kc" 1)
    assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-closed-$shape: the kept copy did not close: $(cat "$kc/stderr")"
    mkdir -p "$kc/state"
    case "$shape" in
      meta-damaged) mkdir "$kc/state/task-x1.meta" ;;
      meta-present) printf 'kind=ship\n' > "$kc/state/task-x1.meta" ;;
      close-pending) printf 'id=task-x1\n' > "$kc/state/task-x1.backlog-close" ;;
    esac
    out=$(KC=$kc ROOT=$ROOT COPY="$(cd "$kc/copy" && pwd -P)" SHAPE=$shape bash -c "$(kept_helper_env)"'
. "$ROOT/bin/fm-backlog-transition-lib.sh" 2>/dev/null || true
TEARDOWN_RETAINED=("$COPY")
[ "$SHAPE" = not-marked ] || teardown_retained_mark_closed 2>>"$KC/stderr"
teardown_lookups=0
teardown_copy_lock_file() { teardown_lookups=$((teardown_lookups + 1)); return 1; }
TEARDOWN_RETAINED=()
if teardown_retained_closed_note "$KC/state/task-x1.meta" "$KC/state" 2>>"$KC/stderr"; then printf "closed lookups=%s\n" "$teardown_lookups"; else printf "refused rc=%s\n" "$?"; fi
' 2>&1)
    case "$shape" in
      closed)
        assert_contains "$out" "teardown task-x1: already closed" "kept-helper-closed: a retry of a closed task did not say it is already closed: $out"
        assert_contains "$out" "$(find "$kc/data/copy-sweep/retained" -type f | head -n 1)" "kept-helper-closed: the message does not name the record: $out"
        assert_contains "$out" "closed lookups=0" "kept-helper-closed: a copy was looked up: $out"
        ;;
      *)
        assert_contains "$out" "refused rc=" "kept-helper-closed-$shape: a task that is not proved closed was reported closed: $out"
        case "$out" in *"already closed"*) fail "kept-helper-closed-$shape: printed already closed: $out" ;; esac
        ;;
    esac
    assert_equals 1 "$(cat "$kc/calls")" "kept-helper-closed-$shape: the driver was asked again"
  done
  rm -rf "$tmp"
  pass "a retry of a task closed around a kept copy says it is already closed, names the record and looks up no copy, and a damaged or present task record, a pending backlog close or an unmarked record does not"
}

# Item 2 (C2 changed, A-8): no earlier preserved byte is overwritten or removed, and a new ignored
# entry under .claude or .opencode, a name differing only after a tab and a symlink whose target
# ends in a newline are copied into teardown's own preserve. A changed payload asks the driver
# once (P3) and is preserved beside the earlier preserve, which stays byte for byte as it was;
# the same payload again asks nothing, and a return to the earlier payload asks once and reuses
# the earlier preserve. Also: a pre-existing preserve of the copy, a preserve that did not hold,
# and a refusal after the driver's answer each leave every earlier preserved byte in place.
test_kept_copy_helper_a_changed_copy_is_preserved_beside_its_earlier_preserve_which_is_never_replaced() {
  local tmp kc out base first second dirs
  tmp=$(fm_test_tmproot kept-helper-beside)
  kc=$tmp/change
  kept_helper_case "$kc"
  printf '%s\n' '.opencode/' >> "$kc/copy/.git/info/exclude"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-beside: the first run did not close: $(cat "$kc/stderr")"
  base=$(kept_preserve_base "$kc")
  assert_equals 'only here' "$(cat "$base/files/notes/unique.dat" 2>/dev/null)" "kept-helper-beside: the first preserve is not at the base path in the files/ and meta/ layout"
  assert_equals 'one' "$(cat "$base/files/.claude/channel-outbox/a.jsonl" 2>/dev/null)" "kept-helper-beside: the .claude entry is not in teardown's own preserve"
  first=$(kept_tree "$base")
  # The new population: a new .opencode entry, a new .claude entry, two names that differ only
  # after a tab, a symlink whose target ends in a newline, and changed bytes of a selected file.
  mkdir -p "$kc/copy/.opencode"
  printf 'oc\n' > "$kc/copy/.opencode/new.json"
  printf 'two\n' > "$kc/copy/.claude/channel-outbox/b.jsonl"
  printf 'tab-a\n' > "$kc/copy/notes/x	a"
  printf 'tab-b\n' > "$kc/copy/notes/x	b"
  perl -e 'symlink("target\n", $ARGV[0]) or die' "$kc/copy/notes/link"
  printf 'changed\n' > "$kc/copy/notes/unique.dat"
  out=$(kept_helper_dispose "$kc" 2)
  assert_equals $'rc=0 kept=yes calls=2\nrc=0 kept=yes calls=2' "$out" "kept-helper-beside: a changed payload must ask once and then nothing: $(cat "$kc/stderr")"
  assert_equals "$first" "$(kept_tree "$base")" "kept-helper-beside: the earlier preserve changed"
  dirs=$(find "$kc/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | LC_ALL=C sort)
  assert_equals 2 "$(printf '%s\n' "$dirs" | wc -l | tr -d ' ')" "kept-helper-beside: the changed payload was not preserved in one directory beside the first: $dirs"
  second=$(printf '%s\n' "$dirs" | grep -v -x -F "$base")
  case "$second" in "$base".????????????????) ;; *) fail "kept-helper-beside: the beside directory is not named by 16 characters of the payload fingerprint: $second" ;; esac
  assert_equals 'oc' "$(cat "$second/files/.opencode/new.json" 2>/dev/null)" "kept-helper-beside: the new .opencode entry is not preserved"
  assert_equals 'two' "$(cat "$second/files/.claude/channel-outbox/b.jsonl" 2>/dev/null)" "kept-helper-beside: the new .claude entry is not preserved"
  assert_equals 'tab-a tab-b' "$(cat "$second/files/notes/x	a" 2>/dev/null) $(cat "$second/files/notes/x	b" 2>/dev/null)" "kept-helper-beside: the tab names are not preserved apart"
  assert_equals "$(printf 'target\n' | od -An -tx1 | tr -d ' \n')" "$(perl -e 'print unpack("H*", readlink($ARGV[0]) // "")' "$second/files/notes/link")" "kept-helper-beside: the symlink's trailing newline was not preserved"
  assert_equals 'changed' "$(cat "$second/files/notes/unique.dat")" "kept-helper-beside: the changed bytes are not preserved"
  assert_equals "$(sed -n 's/^preserve=//p' "$(find "$kc/data/copy-sweep/retained" -type f | head -n 1)")" "$second" "kept-helper-beside: the record does not name the preserve that holds the copy"
  # A return to the earlier payload is a change (P3): it asks once and reuses the first preserve.
  rm -rf "$kc/copy/.opencode" "$kc/copy/.claude/channel-outbox/b.jsonl" "$kc/copy/notes/x	a" "$kc/copy/notes/x	b" "$kc/copy/notes/link"
  printf 'only here\n' > "$kc/copy/notes/unique.dat"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=3' "$out" "kept-helper-beside: a return to the earlier payload must ask once: $(cat "$kc/stderr")"
  assert_equals 2 "$(find "$kc/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' ')" "kept-helper-beside: the earlier payload made a third preserve"
  assert_equals "$first" "$(kept_tree "$base")" "kept-helper-beside: the earlier preserve changed on the return"
  # A pre-existing preserve of the copy (an earlier teardown's) is kept as it is.
  kc=$tmp/existing
  kept_helper_case "$kc"
  base=$(kept_preserve_base "$kc")
  mkdir -p "$base/files/notes"
  printf 'earlier bytes\n' > "$base/files/notes/unique.dat"
  printf 'earlier only\n' > "$base/files/notes/gone.dat"
  first=$(kept_tree "$base")
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-beside-existing: the close failed: $(cat "$kc/stderr")"
  assert_equals "$first" "$(kept_tree "$base")" "kept-helper-beside-existing: the pre-existing preserve changed"
  # A pre-existing preserve that agrees with the copy is kept and only gains what it lacks: its
  # files and every SHA256SUMS line it had stay as they were, and the copied-in file's line is added.
  kc=$tmp/agreeing
  kept_helper_case "$kc"
  base=$(kept_preserve_base "$kc")
  mkdir -p "$base/files/notes" "$base/meta"
  printf 'only here\n' > "$base/files/notes/unique.dat"
  printf '%s\n' "$(cd "$kc/copy" && pwd -P)" > "$base/meta/copy-path"
  printf 'an earlier line an older run wrote\n%s  notes/unique.dat\n' "$(printf 'only here\n' | shasum -a 256 | awk '{print $1}')" > "$base/meta/SHA256SUMS"
  cp "$base/meta/SHA256SUMS" "$kc/sums.before"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-beside-agreeing: the close failed: $(cat "$kc/stderr")"
  assert_equals 1 "$(find "$kc/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' ')" "kept-helper-beside-agreeing: an agreeing preserve was not reused"
  assert_equals "$(cat "$kc/sums.before")" "$(head -n 2 "$base/meta/SHA256SUMS")" "kept-helper-beside-agreeing: an earlier SHA256SUMS line changed"
  assert_grep "$(printf 'one\n' | shasum -a 256 | awk '{print $1}')  .claude/channel-outbox/a.jsonl" "$base/meta/SHA256SUMS" "kept-helper-beside-agreeing: the copied-in file has no SHA256SUMS line"
  assert_equals 'only here' "$(cat "$base/files/notes/unique.dat")" "kept-helper-beside-agreeing: an earlier preserved file changed"
  # A preserve that did not hold (a selected file lost from it during the driver call): the run
  # refuses, the unchanged retry asks nothing and preserves beside it, and the damaged
  # preserve keeps every byte it still had.
  kc=$tmp/unheld
  kept_helper_case "$kc"
  # shellcheck disable=SC2016 # expanded by the stand-in driver's shell.
  printf 'rm -f "$DATA/$ID/nested-copy-preserved/"*/files/notes/unique.dat\n' > "$kc/after"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=1 kept=no calls=1' "$out" "kept-helper-beside-unheld: a preserve that does not hold must refuse: $(cat "$kc/stderr")"
  rm -f "$kc/after"
  base=$(kept_preserve_base "$kc")
  first=$(kept_tree "$base")
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-beside-unheld: the unchanged retry must close beside it without the driver: $(cat "$kc/stderr")"
  assert_equals "$first" "$(kept_tree "$base")" "kept-helper-beside-unheld: the earlier preserve changed"
  # A refusal after the driver's answer (not landed), then a changed payload: asked once more,
  # and the earlier preserve stays.
  kc=$tmp/refused
  kept_helper_case "$kc"
  : > "$kc/unlanded"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=1 kept=no calls=1' "$out" "kept-helper-beside-refused: an unlanded kept copy must refuse: $(cat "$kc/stderr")"
  base=$(kept_preserve_base "$kc")
  first=$(kept_tree "$base")
  rm -f "$kc/unlanded"
  printf 'changed\n' > "$kc/copy/notes/unique.dat"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=2' "$out" "kept-helper-beside-refused: the changed copy must ask once and close: $(cat "$kc/stderr")"
  assert_equals "$first" "$(kept_tree "$base")" "kept-helper-beside-refused: the earlier preserve changed"
  rm -rf "$tmp"
  pass "a changed kept copy is preserved beside its earlier preserve, with new .claude and .opencode entries, tab names and a newline-ended link target, and no earlier preserved byte is ever overwritten or removed"
}

# Item 2, a copy with nothing selected (only .claude files): its preserve is made when its payload
# is copied in, and every later run reuses that one preserve, its record unchanged.
test_kept_copy_helper_a_copy_with_nothing_selected_keeps_one_preserve_across_retries() {
  local tmp kc out rec
  tmp=$(fm_test_tmproot kept-helper-unselected)
  kc=$tmp/case
  kept_helper_case "$kc"
  rm -f "$kc/copy/notes/unique.dat"
  rmdir "$kc/copy/notes"
  : > "$kc/unlanded"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=1 kept=no calls=1' "$out" "kept-helper-unselected: an unlanded kept copy must refuse: $(cat "$kc/stderr")"
  rm -f "$kc/unlanded"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-unselected: the landed copy must close from its record: $(cat "$kc/stderr")"
  rec=$(find "$kc/data/copy-sweep/retained" -type f | head -n 1)
  cp "$rec" "$kc/record.closed"
  out=$(kept_helper_dispose "$kc" 2)
  assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-unselected: later runs must close without the driver: $(cat "$kc/stderr")"
  assert_equals 1 "$(find "$kc/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' ')" "kept-helper-unselected: a later run made a second preserve"
  cmp -s "$kc/record.closed" "$rec" || fail "kept-helper-unselected: a later run rewrote the record: $(diff "$kc/record.closed" "$rec")"
  assert_equals 'one' "$(cat "$(kept_preserve_base "$kc")/files/.claude/channel-outbox/a.jsonl" 2>/dev/null)" "kept-helper-unselected: the .claude file is not in the preserve"
  rm -rf "$tmp"
  pass "a kept copy with nothing selected gets one preserve when its payload is copied in, and later runs reuse it with the record unchanged"
}

# kept_preserve_dirs <dir>: the case's preserve directories, one per line, sorted.
kept_preserve_dirs() {
  find "$1/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | LC_ALL=C sort
}

# kept_preserve_trees <dirs>: kept_tree of each directory named in <dirs> (one per line).
kept_preserve_trees() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    printf '== %s\n' "$d"
    kept_tree "$d"
  done <<< "$1"
}

# kept_selected_states_case <dir> <exit>: kept_helper_case with a top-level .cache/ that the
# default selection keeps and the payload fingerprint leaves out, and the driver's exit code.
kept_selected_states_case() {
  kept_helper_case "$1"
  printf '%s\n' '.cache/' >> "$1/copy/.git/info/exclude"
  mkdir -p "$1/copy/.cache"
  printf 'A\n' > "$1/copy/.cache/x"
  printf '%s\n' "$2" > "$1/exit"
}

# kept_selected_states_run <dir> <want> <dirs-after> <label>: one run; the run's line must be
# <want>, there must then be <dirs-after> preserve directories, and every directory that existed
# before the run must be byte for byte as it was.
kept_selected_states_run() {
  local kc=$1 want=$2 count=$3 label=$4 before trees out
  before=$(kept_preserve_dirs "$kc")
  trees=$(kept_preserve_trees "$before")
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals "$want" "$out" "$label: the run did not progress as expected: $(cat "$kc/stderr")"
  assert_equals "$count" "$(kept_preserve_dirs "$kc" | wc -l | tr -d ' ')" "$label: wrong number of preserve directories: $(kept_preserve_dirs "$kc")"
  assert_equals "$trees" "$(kept_preserve_trees "$before")" "$label: an earlier preserve directory changed"
}

# Main 2007 (R7-1), released route: three selected states of .cache/x with one payload
# fingerprint each keep one preserve directory, in <sha256>, <sha256>.<P16> and <sha256>.<P16>.2;
# a run whose selected state equals an earlier one reuses its directory and builds nothing, and
# the third state is preserved and asks the driver instead of refusing on every retry.
test_kept_copy_helper_each_distinct_selected_state_keeps_one_preserve_on_the_released_route() {
  local tmp kc base third
  tmp=$(fm_test_tmproot kept-helper-states-released)
  kc=$tmp/case
  kept_selected_states_case "$kc" 4
  kept_selected_states_run "$kc" 'rc=1 kept=no calls=1' 1 "kept-helper-states-released-A"
  base=$(kept_preserve_base "$kc")
  assert_equals 'A' "$(cat "$base/files/.cache/x" 2>/dev/null)" "kept-helper-states-released: the first state is not in the first preserve"
  printf 'B\n' > "$kc/copy/.cache/x"
  kept_selected_states_run "$kc" 'rc=1 kept=no calls=2' 2 "kept-helper-states-released-B"
  kept_selected_states_run "$kc" 'rc=1 kept=no calls=3' 2 "kept-helper-states-released-B-again"
  printf 'C\n' > "$kc/copy/.cache/x"
  printf '0\n' > "$kc/exit"
  kept_selected_states_run "$kc" 'rc=0 kept=no calls=4' 3 "kept-helper-states-released-C"
  third=$(kept_preserve_dirs "$kc" | grep -x -F -v "$base" | grep '\.2$')
  case "$third" in "$base".????????????????.2) ;; *) fail "kept-helper-states-released: the third preserve is not <sha256>.<P16>.2: $(kept_preserve_dirs "$kc")" ;; esac
  assert_equals 'C' "$(cat "$third/files/.cache/x" 2>/dev/null)" "kept-helper-states-released: the third state is not in the third preserve"
  rm -rf "$tmp"
  pass "on the released route each distinct selected state keeps one preserve directory in the next free name, an equal state reuses its directory, and no earlier directory changes"
}

# Main 2007 (R7-1), kept route: the record matches while the selected-only .cache/x changes
# twice; each run closes from the record without the driver, the last in <sha256>.<P16>.2, and
# no earlier preserve directory changes.
test_kept_copy_helper_each_distinct_selected_state_keeps_one_preserve_on_the_kept_route() {
  local tmp kc base
  tmp=$(fm_test_tmproot kept-helper-states-kept)
  kc=$tmp/case
  kept_selected_states_case "$kc" 3
  kept_selected_states_run "$kc" 'rc=0 kept=yes calls=1' 1 "kept-helper-states-kept-A"
  base=$(kept_preserve_base "$kc")
  printf 'B\n' > "$kc/copy/.cache/x"
  kept_selected_states_run "$kc" 'rc=0 kept=yes calls=1' 2 "kept-helper-states-kept-B"
  printf 'C\n' > "$kc/copy/.cache/x"
  kept_selected_states_run "$kc" 'rc=0 kept=yes calls=1' 3 "kept-helper-states-kept-C"
  case "$(kept_preserve_dirs "$kc" | grep '\.2$')" in "$base".????????????????.2) ;; *) fail "kept-helper-states-kept: the third preserve is not <sha256>.<P16>.2: $(kept_preserve_dirs "$kc")" ;; esac
  assert_equals 'C' "$(cat "$(kept_preserve_dirs "$kc" | grep '\.2$')/files/.cache/x" 2>/dev/null)" "kept-helper-states-kept: the third state is not in the third preserve"
  assert_equals "$(kept_preserve_dirs "$kc" | grep '\.2$')" "$(sed -n 's/^preserve=//p' "$(find "$kc/data/copy-sweep/retained" -type f | head -n 1)")" "kept-helper-states-kept: the record does not name the preserve that holds the copy"
  rm -rf "$tmp"
  pass "on the kept route each distinct selected state keeps one preserve directory in the next free name and the task closes from its record without the driver"
}

# Main 2056: the entry proof's plan call (PR 366) and the kept route. For an own locked copy, an
# allowed plan whose disposition is archive_then_retain_tree (the real driver's answer for a tree
# with unique ignored files) is not an entry refusal: the copy goes on to the kept route and
# closes. Every other plan refusal still refuses at entry: not allowed, a non-zero exit with the
# keep-tree answer, no verdict. A copy whose record still matches asks the driver nothing, not
# even a plan.
test_kept_copy_helper_the_entry_plan_lets_a_kept_own_copy_through_and_a_matching_record_skips_it() {
  local tmp kc out shape copy
  tmp=$(fm_test_tmproot kept-helper-plan)
  for shape in keep-tree not-allowed keep-tree-nonzero no-verdict allowed matching; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    case "$shape" in
      not-allowed) printf '%s' '{"allowed": false, "reason": "cleanup_policy_not_allowed"}' > "$kc/plan-answer"; echo 3 > "$kc/plan-exit" ;;
      keep-tree-nonzero) echo 3 > "$kc/plan-exit" ;;
      no-verdict) printf '%s' 'no verdict here' > "$kc/plan-answer" ;;
      allowed) printf '%s' '{"allowed": true}' > "$kc/plan-answer" ;;
      matching)
        out=$(kept_helper_dispose "$kc" 1)
        assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-plan-matching: the first close failed: $(cat "$kc/stderr")"
        ;;
    esac
    copy=$(cd "$kc/copy" && pwd -P)
    out=$(KC=$kc ROOT=$ROOT COPY=$copy bash -c "$(kept_helper_env)"'
TEARDOWN_NESTED_COPIES=("$COPY")
mkdir -p "$KC/slot"
TEARDOWN_RETURN_SLOT=$KC/slot
TEARDOWN_FOREIGN_PROCS=()
teardown_foreign_copy_unowned() { return 0; }
prove=0; teardown_own_locked_copies_prove 2>>"$KC/stderr" || prove=$?
dispose=-
if [ "$prove" = 0 ]; then dispose=0; teardown_own_copy_dispose "$KC/slot" "$COPY" 2>>"$KC/stderr" || dispose=$?; fi
kept=no; ! teardown_copy_retained "$COPY" || kept=yes
printf "prove=%s dispose=%s kept=%s calls=%s plans=%s\n" "$prove" "$dispose" "$kept" "$(cat "$KC/calls" 2>/dev/null || echo 0)" "$(if [ -f "$KC/plan-calls" ]; then wc -l < "$KC/plan-calls" | tr -d " "; else echo 0; fi)"
')
    [ -n "${FM_RETAINED_EVIDENCE:-}" ] && printf '%s | case=%s | %s\n' "${FUNCNAME[0]}" "$shape" "$out" >> "$FM_RETAINED_EVIDENCE"
    case "$shape" in
      keep-tree) assert_equals 'prove=0 dispose=0 kept=yes calls=1 plans=1' "$out" "kept-helper-plan-keep-tree: an own copy the plan says the driver keeps must reach the kept route and close: $(cat "$kc/stderr")" ;;
      allowed) assert_equals 'prove=0 dispose=0 kept=yes calls=1 plans=1' "$out" "kept-helper-plan-allowed: the allowed plan must go on: $(cat "$kc/stderr")" ;;
      matching) assert_equals 'prove=0 dispose=0 kept=yes calls=1 plans=0' "$out" "kept-helper-plan-matching: a copy whose record matches asked the driver for a plan: $(cat "$kc/stderr")" ;;
      *)
        assert_equals 'prove=1 dispose=- kept=no calls=0 plans=1' "$out" "kept-helper-plan-$shape: the plan refusal must refuse at entry: $(cat "$kc/stderr")"
        assert_grep "would not release it" "$kc/stderr" "kept-helper-plan-$shape: the entry refusal does not name the plan"
        ;;
    esac
  done
  rm -rf "$tmp"
  pass "an own locked copy whose plan keeps the tree reaches the kept route and closes, every other plan refusal refuses at entry, and a matching record asks for no plan"
}

# Item 3 (C2 post-driver, Main 006): when the copy's record cannot be written, the close refuses
# and a refusal record names the copy, its state and the cause in data/<task>/closeout-refused/;
# every unchanged retry adds no driver call; once the record can be written the next run asks
# once (P2), closes and deletes the refusal record. Before the driver the record folder is probed
# first, so that run asks nothing; after the driver, a failed write keeps the answer in the
# refusal record.
test_kept_copy_helper_a_record_that_cannot_be_written_leaves_a_refusal_record() {
  local tmp kc out shape rdir refused
  [ "$(id -u)" != 0 ] || { pass "skipped as root: a permission bit does not stop root"; return 0; }
  tmp=$(fm_test_tmproot kept-helper-refused)
  for shape in before-driver after-driver; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    rdir=$kc/data/copy-sweep/retained
    mkdir -p "$rdir"
    refused=$kc/data/task-x1/closeout-refused/$(printf '%s' "$(cd "$kc/copy" && pwd -P)" | shasum -a 256 | awk '{print $1}')
    case "$shape" in
      before-driver)
        chmod 555 "$rdir"
        out=$(kept_helper_dispose "$kc" 2)
        assert_equals $'rc=1 kept=no calls=0\nrc=1 kept=no calls=0' "$out" "kept-helper-refused-$shape: the driver was asked while the record could not be written: $(cat "$kc/stderr")"
        ;;
      after-driver)
        # The stand-in takes the folder's write bit away after its answer, as a disk that fills does.
        printf 'chmod 555 "%s"\n' "$rdir" > "$kc/after"
        out=$(kept_helper_dispose "$kc" 1)
        rm -f "$kc/after"
        out=$out$'\n'$(kept_helper_dispose "$kc" 1)
        assert_equals $'rc=1 kept=no calls=1\nrc=1 kept=no calls=1' "$out" "kept-helper-refused-$shape: an unchanged retry asked the driver again: $(cat "$kc/stderr")"
        assert_grep 'answer-base64=' "$refused" "kept-helper-refused-$shape: the refusal record does not hold the driver's answer"
        ;;
    esac
    assert_present "$refused" "kept-helper-refused-$shape: no refusal record was written"
    assert_grep "copy=$(cd "$kc/copy" && pwd -P)" "$refused" "kept-helper-refused-$shape: the refusal record does not name the copy"
    assert_grep 'cause=' "$refused" "kept-helper-refused-$shape: the refusal record names no cause"
    assert_grep 'payload-sha256=' "$refused" "kept-helper-refused-$shape: the refusal record holds no payload fingerprint"
    assert_grep 'REFUSED' "$kc/stderr" "kept-helper-refused-$shape: the refusal printed no cause line"
    chmod 755 "$rdir"
    out=$(kept_helper_dispose "$kc" 2)
    case "$shape" in
      before-driver) assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-refused-$shape: once writable the next run must ask once and close: $(cat "$kc/stderr")" ;;
      after-driver) assert_equals $'rc=0 kept=yes calls=2\nrc=0 kept=yes calls=2' "$out" "kept-helper-refused-$shape: once writable the next run must ask once more (P2) and close: $(cat "$kc/stderr")" ;;
    esac
    assert_absent "$refused" "kept-helper-refused-$shape: the refusal record outlived its cause"
  done
  rm -rf "$tmp"
  pass "a kept copy whose record cannot be written refuses with a durable refusal record, unchanged retries ask the driver nothing, and once writable the next run asks once, closes and deletes the refusal record"
}

# Item 4 (C3 (c), C2 post-driver): every path the driver names is judged as it wrote it and its
# bytes are checked against the copy in the task's preserve. The first or the second of two
# named paths differing in the preserve, a selected-only file changed after it was preserved,
# and a preserved selected file removed after it was verified each refuse with the task kept;
# a named path the preserve lacks is copied in, checked and closes. Each name that is not an
# object inside the copy refuses, recorded (unchanged retries ask nothing); an in-copy link, a
# link to the copy's root and a real directory named with a trailing slash close.
test_kept_copy_helper_every_driver_named_path_is_judged_as_written_and_checked_against_the_copy() {
  local tmp kc out shape json count want base
  tmp=$(fm_test_tmproot kept-helper-named)
  for shape in first-differs second-differs selected-changed selected-removed lacking \
      absolute dotdot empty-component dot dir-symlink link-outside link-dangling link-slash file-slash only-slashes \
      in-copy-link root-link dir-slash; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    printf 'two\n' > "$kc/copy/.claude/channel-outbox/b.jsonl"
    base=$(kept_preserve_base "$kc")
    json='[".claude/channel-outbox/a.jsonl", ".claude/channel-outbox/b.jsonl"]' count=2 want=refuse
    case "$shape" in
      first-differs) printf 'mkdir -p "%s/.claude/channel-outbox" && printf "different\\n" > "%s/.claude/channel-outbox/a.jsonl"\n' "$base/files" "$base/files" > "$kc/after" ;;
      second-differs) printf 'mkdir -p "%s/.claude/channel-outbox" && printf "different\\n" > "%s/.claude/channel-outbox/b.jsonl"\n' "$base/files" "$base/files" > "$kc/after" ;;
      selected-changed) printf 'printf "changed\\n" > "%s/notes/unique.dat"\n' "$kc/copy" > "$kc/after-preserve" ;;
      selected-removed) printf 'rm -f "%s/notes/unique.dat"\n' "$base/files" > "$kc/after" ;;
      lacking)
        # .cache is in the regenerable class, so the preserve does not select it before the
        # driver names it; the named file is copied in and checked.
        mkdir -p "$kc/copy/.cache"; printf 'blob\n' > "$kc/copy/.cache/blob"
        printf '%s\n' '.cache/' >> "$kc/copy/.git/info/exclude"
        json='[".claude/channel-outbox/a.jsonl", ".cache/blob"]' want=close
        ;;
      absolute) json='["/etc/hosts", ".claude/channel-outbox/b.jsonl"]' ;;
      dotdot) json='[".claude/channel-outbox/a.jsonl", ".claude/../outside.dat"]' ;;
      empty-component) json='[".claude//channel-outbox/a.jsonl", ".claude/channel-outbox/b.jsonl"]' ;;
      dot) json='["./.claude/channel-outbox/a.jsonl", ".claude/channel-outbox/b.jsonl"]' ;;
      dir-symlink) ln -s channel-outbox "$kc/copy/.claude/via"; json='[".claude/via/a.jsonl", ".claude/channel-outbox/b.jsonl"]' ;;
      link-outside) ln -s /etc "$kc/copy/.claude/out"; json='[".claude/out", ".claude/channel-outbox/b.jsonl"]' ;;
      link-dangling) ln -s missing.jsonl "$kc/copy/.claude/dang"; json='[".claude/dang", ".claude/channel-outbox/b.jsonl"]' ;;
      link-slash) ln -s channel-outbox "$kc/copy/.claude/dl"; json='[".claude/dl/", ".claude/channel-outbox/b.jsonl"]' ;;
      file-slash) json='[".claude/channel-outbox/a.jsonl/", ".claude/channel-outbox/b.jsonl"]' ;;
      only-slashes) json='["///", ".claude/channel-outbox/b.jsonl"]' ;;
      in-copy-link) ln -s channel-outbox/a.jsonl "$kc/copy/.claude/inl"; json='[".claude/inl", ".claude/channel-outbox/b.jsonl"]' want=close ;;
      root-link) ln -s .. "$kc/copy/.claude/root"; json='[".claude/root", ".claude/channel-outbox/b.jsonl"]' want=close ;;
      dir-slash) json='[".claude/channel-outbox/"]' count=1 want=close ;;
    esac
    kept_helper_answer "$kc" "$json" "$count"
    out=$(kept_helper_dispose "$kc" 2)
    case "$want" in
      close)
        assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-named-$shape: the case must close: $(cat "$kc/stderr")"
        [ "$shape" != lacking ] || assert_equals 'blob' "$(cat "$base/files/.cache/blob" 2>/dev/null)" "kept-helper-named-lacking: the named file the preserve lacked was not copied in"
        ;;
      refuse)
        case "$shape" in
          selected-changed) assert_equals 'rc=1 kept=no calls=0' "$(printf '%s\n' "$out" | head -n 1)" "kept-helper-named-$shape: a file changed after it was preserved must refuse before the driver: $(cat "$kc/stderr")" ;;
          first-differs|second-differs|selected-removed) assert_equals 'rc=1 kept=no calls=1' "$(printf '%s\n' "$out" | head -n 1)" "kept-helper-named-$shape: the case must refuse after the driver: $(cat "$kc/stderr")" ;;
          *) assert_equals $'rc=1 kept=no calls=1\nrc=1 kept=no calls=1' "$out" "kept-helper-named-$shape: the name must refuse, recorded, and the retry ask nothing: $(cat "$kc/stderr")" ;;
        esac
        assert_grep 'REFUSED' "$kc/stderr" "kept-helper-named-$shape: the refusal printed no cause"
        assert_present "$kc/copy/.claude/channel-outbox/a.jsonl" "kept-helper-named-$shape: the copy lost a file"
        ;;
    esac
  done
  rm -rf "$tmp"
  pass "every driver-named path is judged as written and checked against the copy: mismatches, late changes, lost preserved files and names that are not objects inside the copy refuse, a lacking named file is copied in, and in-copy links and a trailing-slash directory close"
}

# Item 5 (C9 (a), F2): on the released route, a file changed after it was preserved refuses
# before the driver (no call, the copy stays) and the next run preserves it again; the unchanged
# control is released with the preserve holding its bytes; and a preserve that loses bytes while
# the driver releases the copy is caught after the release, the task not closed.
test_kept_copy_helper_a_file_changed_after_it_was_preserved_is_never_released_unpreserved() {
  local tmp kc out shape base
  tmp=$(fm_test_tmproot kept-helper-release)
  for shape in changed unchanged preserve-lost; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    printf '0\n' > "$kc/exit"
    base=$(kept_preserve_base "$kc")
    case "$shape" in
      changed) printf 'printf "new source\\n" > "%s/notes/unique.dat"\n' "$kc/copy" > "$kc/after-preserve" ;;
      preserve-lost) printf 'printf "lost\\n" > "%s/notes/unique.dat"\n' "$base/files" > "$kc/after" ;;
    esac
    out=$(kept_helper_dispose "$kc" 1)
    case "$shape" in
      changed)
        assert_equals 'rc=1 kept=no calls=0' "$out" "kept-helper-release-changed: a file changed after it was preserved reached the driver: $(cat "$kc/stderr")"
        assert_equals 'new source' "$(cat "$kc/copy/notes/unique.dat")" "kept-helper-release-changed: the copy's current bytes are gone"
        rm -f "$kc/after-preserve"
        out=$(kept_helper_dispose "$kc" 1)
        assert_equals 'rc=0 kept=no calls=1' "$out" "kept-helper-release-changed: the next run did not preserve and release: $(cat "$kc/stderr")"
        grep -R -q -F 'new source' "$kc/data/task-x1/nested-copy-preserved" || fail "kept-helper-release-changed: the current bytes were not preserved before the release"
        ;;
      unchanged)
        assert_equals 'rc=0 kept=no calls=1' "$out" "kept-helper-release-unchanged: the control was not released: $(cat "$kc/stderr")"
        assert_equals 'only here' "$(cat "$base/files/notes/unique.dat")" "kept-helper-release-unchanged: the preserve does not hold the released bytes"
        ;;
      preserve-lost)
        assert_equals 'rc=1 kept=no calls=1' "$out" "kept-helper-release-preserve-lost: a release whose preserve lost bytes closed: $(cat "$kc/stderr")"
        assert_grep 'no longer holds' "$kc/stderr" "kept-helper-release-preserve-lost: the refusal does not name the preserve"
        ;;
    esac
  done
  rm -rf "$tmp"
  pass "a file changed after it was preserved is never released unpreserved: it refuses before the driver and is preserved by the next run, the unchanged copy is released with its bytes held, and a preserve that loses bytes during the release is caught"
}

# F10: a root ignored file named like one of the preserve's own files (copy-path, SHA256SUMS) is
# preserved byte for byte and the kept copy closes; its preserve holds the payload in files/ and
# its meta/SHA256SUMS lists every preserved file there. Every copy uses that layout (PR 366).
test_kept_copy_helper_root_files_named_like_the_preserves_own_files_are_preserved() {
  local tmp kc out base
  tmp=$(fm_test_tmproot kept-helper-reserved)
  kc=$tmp/reserved
  kept_helper_case "$kc"
  printf '%s\n' '/SHA256SUMS' '/copy-path' >> "$kc/copy/.git/info/exclude"
  printf 'the project'"'"'s own sums\n' > "$kc/copy/SHA256SUMS"
  printf 'the project'"'"'s own copy-path\n' > "$kc/copy/copy-path"
  out=$(kept_helper_dispose "$kc" 2)
  assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-reserved: root files named like the preserve's own files must close: $(cat "$kc/stderr")"
  base=$(kept_preserve_base "$kc")
  assert_equals "the project's own sums" "$(cat "$base/files/SHA256SUMS" 2>/dev/null)" "kept-helper-reserved: SHA256SUMS of the copy is not preserved byte for byte"
  assert_equals "the project's own copy-path" "$(cat "$base/files/copy-path" 2>/dev/null)" "kept-helper-reserved: copy-path of the copy is not preserved byte for byte"
  assert_equals "$(cd "$kc/copy" && pwd -P)" "$(cat "$base/meta/copy-path")" "kept-helper-reserved: the preserve's own copy-path does not name the copy"
  (cd "$base/files" && shasum -a 256 -c ../meta/SHA256SUMS >/dev/null 2>&1) || fail "kept-helper-reserved: the preserve's SHA256SUMS does not check: $(cat "$base/meta/SHA256SUMS")"
  assert_grep '  SHA256SUMS' "$base/meta/SHA256SUMS" "kept-helper-reserved: SHA256SUMS does not list the payload's SHA256SUMS"
  kc=$tmp/ordinary
  kept_helper_case "$kc"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-reserved-ordinary: the control did not close: $(cat "$kc/stderr")"
  base=$(kept_preserve_base "$kc")
  assert_equals 'only here' "$(cat "$base/files/notes/unique.dat" 2>/dev/null)" "kept-helper-reserved-ordinary: an ordinary copy's preserve does not hold its file in files/"
  assert_grep '  notes/unique.dat' "$base/meta/SHA256SUMS" "kept-helper-reserved-ordinary: meta/SHA256SUMS does not list the preserved file"
  rm -rf "$tmp"
  pass "root files named copy-path and SHA256SUMS are preserved byte for byte in files/ and the kept copy closes, and an ordinary copy uses the same files/ and meta/ layout"
}

retained_field() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1; sed -n "s/^$2=//p" "$1" | sed -n '2,$p'
}

# retained_preserved_is <label> <relative-file>: the task's preserve holds the copy's bytes of
# <relative-file>, compared with hashes of the copy itself, and its SHA256SUMS lists it.
retained_preserved_is() {
  local want have preserve
  # The preserve the record names, or the first preserve when there is no record yet.
  preserve=$(sed -n 's/^preserve=//p' "$(retained_record_path)" 2>/dev/null | head -n 1)
  [ -n "$preserve" ] || preserve=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  want=$(shasum -a 256 "$FOREIGN_COPY/$2" | awk '{print $1}')
  have=$(shasum -a 256 "$preserve/files/$2" 2>/dev/null | awk '{print $1}')
  assert_equals "$want" "$have" "$1: the preserved $2 is not the copy's bytes"
  assert_grep "$want  $2" "$preserve/meta/SHA256SUMS" "$1: SHA256SUMS does not record $2"
}

# retained_recorded_answer: the driver's answer the record carries.
retained_recorded_answer() {
  sed -n 's/^answer-base64=//p' "$(retained_record_path)" | perl -MMIME::Base64 -0777 -ne 'print decode_base64($_)'
}

# retained_physical <path>: <path> with its folder resolved (pwd -P).
retained_physical() {
  printf '%s/%s\n' "$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" "${1##*/}"
}

# retained_tar_listing: the path and SHA-256 of every tar the stand-in driver wrote, read here.
retained_tar_listing() {
  find "$FOREIGN_SLOT/.claude/bug-evidence/worktree-preservation" -name '*.tar' -type f -exec shasum -a 256 {} + 2>/dev/null | LC_ALL=C sort
}

test_a_landed_task_closes_around_an_own_copy_the_driver_keeps() {
  local rc shape record answer
  for shape in enclosing reverse; do
    make_retained_case "retained-close-$shape" "$shape"
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 0 "$rc" "retained-close-$shape: a landed, clean copy the driver keeps with its files saved must close the task: $(cat "$FOREIGN_CASE/stderr")"
    assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-close-$shape: the driver was not asked exactly once for one tar"
    retained_assert_closed "retained-close-$shape"
    retained_preserved_is "retained-close-$shape" notes/unique.dat
    record=$(retained_record_path)
    assert_equals "$(cd "$FOREIGN_SLOT" && pwd -P)" "$(retained_field "$record" slot)" "retained-close-$shape: the record names another slot"
    assert_equals cleanup_ignored_payload_archived_tree_retained "$(retained_field "$record" reason)" "retained-close-$shape: the record does not carry the driver's reason"
    case "$(retained_field "$record" recorded-at)" in 20*Z) ;; *) fail "retained-close-$shape: the record carries no time" ;; esac
    case "$(sed -n 3p "$record")" in identity=[0-9]*:[0-9]*) ;; *) fail "retained-close-$shape: the record carries no identity" ;; esac
    assert_equals "task slot preserve reason recorded-at head status-sha256 payload-sha256 answer-base64 task-closed" "$(sed -n '5,$p' "$record" | sed 's/=.*//' | paste -sd ' ' -)" "retained-close-$shape: the record does not hold exactly its fields"
    assert_equals task-x1 "$(retained_field "$record" task-closed)" "retained-close-$shape: the completed close did not mark the record"
    retained_preserved_is "retained-close-$shape" .claude/channel-outbox/a.jsonl
    answer=$(retained_recorded_answer)
    assert_equals '[".claude/channel-outbox/a.jsonl",".claude/channel-outbox/b.jsonl"]' "$(printf '%s' "$answer" | jq -c .unique_ignored_paths)" "retained-close-$shape: the record does not carry the driver's unique paths"
    # Both paths are compared physically (on macOS /tmp is /private/tmp).
    assert_equals "$(retained_physical "$(retained_tar_listing | awk '{print $2}')")" "$(retained_physical "$(printf '%s' "$answer" | jq -r '.ignored_payload_preservation[-1].archive_path')")" "retained-close-$shape: the recorded archive is not the tar the driver wrote"
    assert_equals "$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')" "$(retained_field "$record" preserve)" "retained-close-$shape: the record does not name the preserve"
    kept_assert_lacks 'REFUSED' "$FOREIGN_CASE/stderr" "retained-close-$shape: a close that succeeded printed a refusal"
    assert_equals 1 "$(cat "$FOREIGN_CASE/stdout" "$FOREIGN_CASE/stderr" | grep -c "notice: own nested copy $FOREIGN_COPY was kept")" "retained-close-$shape: the kept copy was not reported exactly once"
    assert_absent "$FOREIGN_CASE/data/task-x1/vernant-closeout."* "retained-close-$shape: a close saved a refusal output"
  done
  pass "a landed task whose own copy the driver keeps closes: the copy, the slot and its lease are untouched, the driver's verified archive and the task's preserve hold the unique files, and one record names the copy and the answer"
}

test_a_retry_of_an_unchanged_kept_copy_asks_the_driver_nothing() {
  local rc record
  make_retained_case retained-retry enclosing
  held_plain_get_slot "$FOREIGN_CASE"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  : > "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "retained-retry: a slot that cannot be leased must refuse the close: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'could not be durably leased' "$FOREIGN_CASE/stderr" "retained-retry: the refusal did not say why"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-retry: run 1 should have asked the driver once"
  record=$(retained_record_path)
  assert_present "$record" "retained-retry: run 1 wrote no record"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-retry: the refused close removed the task record"
  cp "$record" "$FOREIGN_CASE/record.run1"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "retained-retry: run 2 must refuse for the same cause: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-retry: an unchanged copy asked the driver again"
  assert_absent "$FOREIGN_CASE/data/task-x1/vernant-closeout."* "retained-retry: a retry saved another driver output"
  cmp -s "$FOREIGN_CASE/record.run1" "$record" || fail "retained-retry: the unchanged copy's record was rewritten"
  rm -f "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-retry: run 3 with a lease must close: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-retry: the closing run asked the driver again"
  assert_equals 1 "$(find "$FOREIGN_CASE/data/copy-sweep/retained" -type f | wc -l | tr -d ' ')" "retained-retry: a second record was written"
  pass "a retry of an unchanged kept copy makes no driver call, writes no tar, no saved output and no second record, and closes once the slot can be leased"
}

test_a_changed_kept_copy_is_assessed_afresh() {
  local rc record change
  local base first added
  for change in more-ignored opencode-entry tab-name link-newline dirty-tracked unlanded; do
    make_retained_case "retained-changed-$change" enclosing
    held_plain_get_slot "$FOREIGN_CASE"
    : > "$FOREIGN_CASE/no-lease-command"
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 1 "$rc" "retained-changed-$change: run 1 must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
    record=$(retained_record_path)
    cp "$record" "$FOREIGN_CASE/record.run1"
    base=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
    first=$(kept_tree "$base")
    cp "$base/meta/SHA256SUMS" "$FOREIGN_CASE/sums.run1"
    case "$change" in
      more-ignored) printf 'more\n' > "$FOREIGN_COPY/notes/unique.dat" ;;
      opencode-entry)
        printf '%s\n' '.opencode/' >> "$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)"
        mkdir -p "$FOREIGN_COPY/.opencode"; printf 'oc\n' > "$FOREIGN_COPY/.opencode/new.json"
        ;;
      tab-name) printf 'tab\n' > "$FOREIGN_COPY/.claude/channel-outbox/a	b.jsonl" ;;
      link-newline) perl -e 'symlink("a.jsonl\n", $ARGV[0]) or die' "$FOREIGN_COPY/.claude/channel-outbox/link" ;;
      dirty-tracked) printf 'edit\n' > "$FOREIGN_COPY/untracked.txt" ;;
      unlanded) held_foreign_unlanded "$FOREIGN_COPY" ;;
    esac
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 1 "$rc" "retained-changed-$change: run 2 must refuse: $(cat "$FOREIGN_CASE/stderr")"
    case "$change" in
      more-ignored|opencode-entry|tab-name|link-newline)
        assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "retained-changed-$change: a changed copy that passes every proof was not evaluated again"
        assert_grep 'could not be durably leased' "$FOREIGN_CASE/stderr" "retained-changed-$change: run 2 did not reach the lease check"
        cmp -s "$FOREIGN_CASE/record.run1" "$record" && fail "retained-changed-$change: the stale record was not replaced"
        # No earlier preserved byte is overwritten or removed. A changed selected file goes
        # beside the earlier preserve; a new payload-only entry is copied into the earlier
        # preserve, which still agrees with the copy, and only that entry and its line are added.
        case "$change" in
          more-ignored) assert_equals "$first" "$(kept_tree "$base")" "retained-changed-$change: the earlier preserve changed" ;;
          *)
            case "$change" in
              opencode-entry) added=.opencode/new.json ;;
              tab-name) added=".claude/channel-outbox/a	b.jsonl" ;;
              link-newline) added=.claude/channel-outbox/link ;;
            esac
            assert_equals "$(printf '%s\n' "$first" | grep -v '^F \./meta/SHA256SUMS ')" "$(kept_tree "$base" | grep -v '^F \./meta/SHA256SUMS ' | grep -vF " ./files/$added ")" "retained-changed-$change: the earlier preserve lost or changed an entry, or gained one other than $added"
            { [ -e "$base/files/$added" ] || [ -L "$base/files/$added" ]; } || fail "retained-changed-$change: $added was not copied into the agreeing earlier preserve"
            assert_equals "$(cat "$FOREIGN_CASE/sums.run1")" "$(head -n "$(wc -l < "$FOREIGN_CASE/sums.run1")" "$base/meta/SHA256SUMS")" "retained-changed-$change: an earlier SHA256SUMS line changed"
            ;;
        esac
        case "$change" in
          more-ignored) retained_preserved_is "retained-changed-$change" notes/unique.dat ;;
          opencode-entry) retained_preserved_is "retained-changed-$change" .opencode/new.json ;;
          tab-name) retained_preserved_is "retained-changed-$change" ".claude/channel-outbox/a	b.jsonl" ;;
          link-newline)
            assert_equals "$(printf 'a.jsonl\n' | od -An -tx1 | tr -d ' \n')" "$(perl -e 'print unpack("H*", readlink($ARGV[0]) // "")' "$(sed -n 's/^preserve=//p' "$record")/files/.claude/channel-outbox/link")" "retained-changed-$change: the link target's trailing newline was not preserved"
            ;;
        esac
        ;;
      *)
        assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-changed-$change: a changed copy that fails a proof reached the driver"
        assert_grep 'REFUSED' "$FOREIGN_CASE/stderr" "retained-changed-$change: the refusal named no cause"
        cmp -s "$FOREIGN_CASE/record.run1" "$record" || fail "retained-changed-$change: a refused copy's record was rewritten"
        ;;
    esac
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-changed-$change: the task record was removed"
    assert_present "$FOREIGN_COPY/.git" "retained-changed-$change: the copy was removed"
  done
  pass "a kept copy whose ignored files, tracked status or HEAD changed is assessed afresh: still-eligible goes to the driver again, failing a proof refuses before any driver call"
}

# A kept copy in a slot another live task still works in (the peer route) cannot
# be held under this task's lease, so the close refuses, and its retry, with the
# record matching, asks the driver nothing.
test_a_kept_copy_in_a_slot_a_peer_works_in_refuses_and_its_retry_asks_the_driver_nothing() {
  local rc record peer run
  make_retained_case retained-peer enclosing
  peer=$FOREIGN_SLOT/peer-copy
  mkdir -p "$peer"
  fm_write_meta "$FOREIGN_CASE/state/task-y1.meta" \
    "window=firstmate:fm-task-y1" "endpoint_task_id=task-y1" \
    "worktree=$peer" "branch=fm/task-y1" "project=$FOREIGN_CASE/project" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-y1" \
    "prior_worktree=$FOREIGN_SLOT"
  record=$(retained_record_path)
  for run in 1 2; do
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 1 "$rc" "retained-peer: run $run of a kept-copy close in the peer route must refuse: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "REFUSED: own nested copy $FOREIGN_COPY was kept by Vernant's closeout driver (record $record)" "$FOREIGN_CASE/stderr" "retained-peer: run $run did not name the kept copy and its record"
    assert_grep 'which another live task still works in' "$FOREIGN_CASE/stderr" "retained-peer: run $run did not say why"
    assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-peer: run $run did not leave the driver asked exactly once"
    assert_present "$record" "retained-peer: run $run left no record"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-peer: run $run removed the task record"
    assert_equals in_flight "$(backlog_row_state "$FOREIGN_CASE")" "retained-peer: run $run moved the backlog item"
    held_fingerprint "$FOREIGN_COPY" | cmp -s - "$FOREIGN_CASE/held-before.$(basename "$FOREIGN_COPY")" || fail "retained-peer: run $run changed the kept copy"
    assert_absent "$FOREIGN_CASE/treehouse.log" "retained-peer: run $run returned the pool slot"
    [ "$run" = 2 ] || cp "$record" "$FOREIGN_CASE/record.run1"
  done
  cmp -s "$FOREIGN_CASE/record.run1" "$record" || fail "retained-peer: the retry rewrote the matching record"
  pass "a kept-copy close in a slot a peer still works in refuses with the copy and its record named, and its retry asks the driver nothing"
}

# retained_variant <variant> <plain|force> [label]: the C1 fixture with one fact changed
# (or none, for c1-input), run with or without --force and the --drop-file it needs.
# Sets RV_DISPOSITION to what survived and the exit class.
retained_variant() {
  local variant=$1 mode=$2 hash preserve inner exclude
  local -a driver_env=(FM_STUB_CLOSEOUT=retained)
  make_retained_case "retained-$variant-$mode${3:+-$3}" enclosing
  hash=$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  preserve=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$hash
  case "$variant" in
    c1-input) ;;
    unlanded) held_foreign_unlanded "$FOREIGN_COPY" ;;
    dirty) printf 'edit\n' > "$FOREIGN_COPY/untracked.txt" ;;
    changed-during-driver) driver_env+=("FM_STUB_AFTER=printf 'changed\\n' > '$FOREIGN_COPY/notes/unique.dat'") ;;
    removed-from-preserve) driver_env+=("FM_STUB_AFTER=rm -f '$preserve/files/notes/unique.dat'") ;;
    driver-path-directory) driver_env+=("FM_STUB_UNIQUE=.claude/channel-outbox/") ;;
    driver-path-differs) driver_env+=("FM_STUB_AFTER=mkdir -p '$preserve/files/.claude/channel-outbox' && printf 'different\\n' > '$preserve/files/.claude/channel-outbox/a.jsonl'") ;;
    driver-path-differs-second) driver_env+=("FM_STUB_AFTER=mkdir -p '$preserve/files/.claude/channel-outbox' && printf 'different\\n' > '$preserve/files/.claude/channel-outbox/b.jsonl'") ;;
    driver-path-gone) driver_env+=("FM_STUB_UNIQUE=.claude/channel-outbox/a.jsonl .claude/channel-outbox/missing.jsonl") ;;
    driver-path-escapes) driver_env+=("FM_STUB_UNIQUE=.claude/channel-outbox/a.jsonl ../outside.dat") ;;
    empty-path) driver_env+=('FM_STUB_UNIQUE_JSON=[""]') ;;
    archive-sha-differs) driver_env+=(FM_STUB_ARCHIVE_SHA=0000000000000000000000000000000000000000000000000000000000000000) ;;
    lease-conflict) driver_env+=(FM_STUB_REASON=cleanup_lease_conflict) ;;
    live-or-unknown) driver_env+=(FM_STUB_REASON=cleanup_skipped_live_or_unknown) ;;
    policy-not-allowed) driver_env+=(FM_STUB_REASON=cleanup_policy_not_allowed) ;;
    other-exit) driver_env+=(FM_STUB_EXIT=4) ;;
    json-broken) driver_env+=(FM_STUB_JSON=broken) ;;
    json-two) driver_env+=(FM_STUB_JSON=two) ;;
    json-no-unique) driver_env+=(FM_STUB_JSON=nounique) ;;
    json-unique-string) driver_env+=(FM_STUB_JSON=uniquestring) ;;
    reason-invented) driver_env+=(FM_STUB_REASON=cleanup_reason_no_list_holds) ;;
    same-repo-worktree)
      # A linked worktree of the same repository: the existing predicate lets it
      # stand, so the kept route is not what refuses this copy.
      git -C "$FOREIGN_CASE/project" worktree add -q -b fm/inner-lane "$FOREIGN_COPY/inner-wt" main
      exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
      printf '%s\n' 'inner-wt/' >> "$exclude"
      ;;
    other-repo)
      inner=$FOREIGN_COPY/other-repo
      mkdir -p "$inner"
      git -C "$inner" init -q
      exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
      printf '%s\n' 'other-repo/' >> "$exclude"
      ;;
  esac
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  RV_DRIVER_ENV=("${driver_env[@]}")
  retained_variant_run "$mode"
}

# retained_variant_run <plain|force>: runs teardown once more on the current
# variant case with its driver environment; sets RV_DISPOSITION.
retained_variant_run() {
  local rc=0
  FOREIGN_TEARDOWN_ARGS=()
  [ "$1" = plain ] || FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
  run_foreign_teardown rc "${RV_DRIVER_ENV[@]}"
  FOREIGN_TEARDOWN_ARGS=()
  RV_DISPOSITION="exit=$([ "$rc" = 0 ] && echo 0 || echo nonzero) task-record=$([ -e "$FOREIGN_CASE/state/task-x1.meta" ] && echo kept || echo removed)"
  RV_DISPOSITION="$RV_DISPOSITION backlog=$(backlog_row_state "$FOREIGN_CASE") copy=$([ -e "$FOREIGN_COPY/.git" ] && echo kept || echo gone)"
  RV_DISPOSITION="$RV_DISPOSITION slot-returned=$([ -e "$FOREIGN_CASE/treehouse.log" ] && echo yes || echo no) record=$([ -e "$(retained_record_path)" ] && echo written || echo none)"
  RV_DISPOSITION="$RV_DISPOSITION driver-calls=$(retained_call_count) tars=$(retained_tar_count)"
}

# C3: every other state refuses with its cause and leaves the copy, the slot and the task
# record; --force waives none of the kept route's proofs. An answer that keeps the copy is
# recorded whatever else it holds; any other driver answer refuses as before, unrecorded.
test_every_other_state_of_an_own_copy_the_driver_keeps_still_refuses() {
  local variant plain force want
  for variant in c1-input same-repo-worktree driver-path-directory unlanded dirty changed-during-driver removed-from-preserve driver-path-differs driver-path-differs-second driver-path-gone driver-path-escapes empty-path archive-sha-differs json-no-unique json-unique-string other-repo lease-conflict live-or-unknown policy-not-allowed other-exit json-broken json-two reason-invented; do
    retained_variant "$variant" plain
    plain=$RV_DISPOSITION
    case "$variant" in
      c1-input|same-repo-worktree|driver-path-directory) want="exit=0 task-record=removed backlog=done copy=kept slot-returned=no record=written driver-calls=1 tars=1" ;;
      unlanded|dirty) want="exit=nonzero task-record=kept backlog=in_flight copy=kept slot-returned=no record=none driver-calls=0 tars=0" ;;
      changed-during-driver|removed-from-preserve|driver-path-differs|driver-path-differs-second|driver-path-gone|driver-path-escapes|empty-path|archive-sha-differs|json-no-unique|json-unique-string|other-repo)
        want="exit=nonzero task-record=kept backlog=in_flight copy=kept slot-returned=no record=written driver-calls=1 tars=1" ;;
      *) want="exit=nonzero task-record=kept backlog=in_flight copy=kept slot-returned=no record=none driver-calls=1 tars=1" ;;
    esac
    assert_equals "$want" "$plain" "$variant: wrong disposition: $plain"
    case "$variant" in
      c1-input|same-repo-worktree|driver-path-directory) ;;
      unlanded) assert_grep 'not landed' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      changed-during-driver) assert_grep 'changed while Vernant' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      removed-from-preserve|driver-path-differs|driver-path-differs-second) assert_grep 'does not hold every ignored file' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      driver-path-gone|driver-path-escapes) assert_grep 'which is not a plain path inside the copy' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      archive-sha-differs) assert_grep 'does not have the SHA-256 it recorded' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      empty-path|json-no-unique|json-unique-string) assert_grep 'its recorded answer does not name a restore-verified archive' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      dirty|other-repo) assert_grep 'REFUSED' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      *) assert_grep "Vernant's closeout driver did not release own nested copy $FOREIGN_COPY (exit" "$FOREIGN_CASE/stderr" "$variant: the driver refusal was not reported" ;;
    esac
    retained_variant "$variant" force
    force=$RV_DISPOSITION
    case "$variant" in
      # --force already waives the task's own landed and clean proof before the driver (the
      # captain's authorization to discard assigned work), so the driver is asked once here,
      # as on the base; the kept route's own proof then refuses the copy it keeps.
      unlanded|dirty) assert_equals "exit=nonzero task-record=kept backlog=in_flight copy=kept slot-returned=no record=written driver-calls=1 tars=1" "$force" "$variant: --force changed what survived: $force" ;;
      *) assert_equals "$plain" "$force" "$variant: --force changed the disposition: $force" ;;
    esac
  done
  pass "each other state of an own copy the driver keeps refuses with its cause and the same disposition with and without --force, and the clean input closes the same way with --force"
}

# F6, C2 (post-driver): a kept copy refused from the driver's recorded answer refuses again on
# two unchanged retries without the driver, a tar or a saved output, with and without --force.
test_a_stable_refusal_after_the_driver_asks_the_driver_nothing_on_retry() {
  local entry variant mode run want
  want="exit=nonzero task-record=kept backlog=in_flight copy=kept slot-returned=no record=written driver-calls=1 tars=1"
  for entry in empty-path:plain archive-sha-differs:plain json-no-unique:plain other-repo:plain unlanded:force dirty:force; do
    variant=${entry%:*}
    mode=${entry#*:}
    retained_variant "$variant" "$mode" stable
    assert_equals "$want" "$RV_DISPOSITION" "stable-$variant: run 1 wrong disposition"
    retained_tar_listing > "$FOREIGN_CASE/tars.run1"
    for run in 2 3; do
      retained_variant_run "$mode"
      assert_equals "$want" "$RV_DISPOSITION" "stable-$variant: run $run asked the driver again or changed what survived"
      retained_tar_listing | cmp -s - "$FOREIGN_CASE/tars.run1" || fail "stable-$variant: run $run changed the tars"
      assert_absent "$FOREIGN_CASE/data/task-x1/vernant-closeout."* "stable-$variant: run $run saved a driver output"
      assert_grep 'REFUSED' "$FOREIGN_CASE/stderr" "stable-$variant: run $run did not refuse by name"
    done
  done
  pass "a kept copy refused from the driver's recorded answer (an empty path, an archive hash that does not match, no unique list, another repository, a forced unlanded or dirty copy) asks the driver once across two retries"
}

# (d) from the record: a kept copy whose preserve lost a selected file refuses; the next run's
# preservation rebuilds the preserve from the unchanged copy, and the record then closes the
# task without asking the driver.
test_a_kept_copy_whose_cause_went_closes_from_its_record_without_the_driver() {
  local rc preserve
  make_retained_case retained-cause-went enclosing
  preserve=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained "FM_STUB_AFTER=rm -f '$preserve/files/notes/unique.dat'"
  expect_code 1 "$rc" "retained-cause-went: a preserve without a selected file must refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-cause-went: run 1 did not ask the driver once"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-cause-went: the copy preserved again beside the first must let the record close the task: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-cause-went: the closing run asked the driver"
  retained_assert_closed retained-cause-went
  retained_preserved_is retained-cause-went notes/unique.dat
  pass "a kept copy whose cause went (preserved again beside the preserve that lost a file, which is left as it is) closes from its record without the driver"
}

# A kept copy whose only ignored files are under .claude has nothing the entry plan preserves,
# so the entry check never compares the preserve parent with the run directory. When the
# preserve parent is on another filesystem (a `stat` stand-in, with a `perl` stand-in whose
# rename fails across devices as rename(2) does), the widened preserve must still be built and
# the task must close.
test_a_kept_copy_with_only_claude_files_closes_when_its_preserve_is_on_another_filesystem() {
  local rc root real_perl
  make_retained_case retained-xdev-preserve enclosing
  rm -f "$FOREIGN_COPY/notes/unique.dat"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  root="$FOREIGN_CASE/data/task-x1/nested-copy-preserved"
  mkdir -p "$root"
  teardown_test_fake_other_device "$FOREIGN_CASE/fakebin" "$root"
  real_perl=$(command -v perl)
  cat > "$FOREIGN_CASE/fakebin/perl" <<SH
#!/usr/bin/env bash
if [ "\$#" = 5 ] && [ "\$1" = -e ] && [ "\$2" = 'rename(\$ARGV[0], \$ARGV[1]) or exit 1' ] && [ "\$3" = -- ]; then
  case "\$(uname -s)" in Darwin|*BSD) flag=-f ;; *) flag=-c ;; esac
  [ "\$(stat \$flag %d "\${4%/*}")" = "\$(stat \$flag %d "\${5%/*}")" ] || exit 1
fi
exec "$real_perl" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/perl"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-xdev-preserve: a kept copy whose preserve is on another filesystem must close: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-xdev-preserve: the driver was not asked exactly once for one tar"
  retained_assert_closed retained-xdev-preserve
  retained_preserved_is retained-xdev-preserve .claude/channel-outbox/a.jsonl
  retained_preserved_is retained-xdev-preserve .claude/channel-outbox/b.jsonl
  assert_equals '' "$(find "$root" "$FOREIGN_CASE/state" -name '.staging-own-*' -o -name 'ignored-own-*' 2>/dev/null)" "retained-xdev-preserve: a staging directory was left behind"
  pass "a kept copy with only .claude ignored files closes, its widened preserve built, when the preserve parent is on another filesystem from the run directory"
}

# C1 (f): the close and every later run leave the task's preserve, the driver's tars and the
# saved outputs as they were before (each tar's SHA-256 read before the close).
test_the_preserve_and_the_archives_survive_the_close_and_every_later_run() {
  local rc tardir tars_before outputs_before run
  make_retained_case retained-survive enclosing
  tardir=$FOREIGN_SLOT/.claude/bug-evidence/worktree-preservation
  mkdir -p "$tardir" "$FOREIGN_CASE/data/task-x1"
  printf 'earlier archive\n' > "$tardir/stub-ordinary_cleanup-0.tar"
  printf 'earlier output\n' > "$FOREIGN_CASE/data/task-x1/vernant-closeout.seed1"
  tars_before=$(retained_tar_listing)
  outputs_before=$(shasum -a 256 "$FOREIGN_CASE/data/task-x1/vernant-closeout.seed1")
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-survive: the close must succeed: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "$tars_before" "$(retained_tar_listing | grep -F "$tardir/stub-ordinary_cleanup-0.tar")" "retained-survive: the close changed a tar that existed before it"
  retained_tar_listing > "$FOREIGN_CASE/tars.after-close"
  for run in 1 2; do
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    assert_equals "1 2" "$(retained_call_count) $(retained_tar_count)" "retained-survive: later run $run asked the driver or wrote a tar"
    retained_tar_listing | cmp -s - "$FOREIGN_CASE/tars.after-close" || fail "retained-survive: later run $run changed a tar"
    assert_equals "$outputs_before" "$(shasum -a 256 "$FOREIGN_CASE/data/task-x1/vernant-closeout.seed1")" "retained-survive: later run $run changed a saved output"
    retained_preserved_is "retained-survive run $run" notes/unique.dat
  done
  pass "the task's preserve, every tar and every saved output that existed before the close keep their bytes through the close and later runs"
}

# C1 (config): the production default interpreter (<slot>/.venv/bin/python, with
# FM_TEARDOWN_VERNANT_PYTHON truly unset, and set to an empty string) and the explicit
# override give the same close; a missing default interpreter refuses and removes nothing.
test_the_default_driver_interpreter_and_the_override_close_the_same_way() {
  local rc mode
  for mode in default default-empty override missing missing-empty override-missing; do
    make_retained_case "retained-config-$mode" enclosing
    case "$mode" in
      default)
        mkdir -p "$FOREIGN_SLOT/.venv/bin"
        cp "$FOREIGN_CASE/vernant-python" "$FOREIGN_SLOT/.venv/bin/python"
        chmod +x "$FOREIGN_SLOT/.venv/bin/python"
        RETAINED_UNSET_PYTHON=1 run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
        ;;
      default-empty)
        mkdir -p "$FOREIGN_SLOT/.venv/bin"
        cp "$FOREIGN_CASE/vernant-python" "$FOREIGN_SLOT/.venv/bin/python"
        chmod +x "$FOREIGN_SLOT/.venv/bin/python"
        run_foreign_teardown rc FM_STUB_CLOSEOUT=retained FM_TEARDOWN_VERNANT_PYTHON=
        ;;
      override) run_foreign_teardown rc FM_STUB_CLOSEOUT=retained ;;
      missing) RETAINED_UNSET_PYTHON=1 run_foreign_teardown rc FM_STUB_CLOSEOUT=retained ;;
      missing-empty) run_foreign_teardown rc FM_STUB_CLOSEOUT=retained FM_TEARDOWN_VERNANT_PYTHON= ;;
      override-missing)
        mkdir -p "$FOREIGN_SLOT/.venv/bin"
        cp "$FOREIGN_CASE/vernant-python" "$FOREIGN_SLOT/.venv/bin/python"
        chmod +x "$FOREIGN_SLOT/.venv/bin/python"
        run_foreign_teardown rc FM_STUB_CLOSEOUT=retained "FM_TEARDOWN_VERNANT_PYTHON=$FOREIGN_CASE/no-such-python"
        ;;
    esac
    if [ "$mode" = missing ] || [ "$mode" = missing-empty ] || [ "$mode" = override-missing ]; then
      assert_grep 'is not available' "$FOREIGN_CASE/stderr" "retained-config-$mode: the refusal did not say the interpreter is not available"
      expect_code 1 "$rc" "retained-config-$mode: a missing default interpreter must refuse: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals "0 0" "$(retained_call_count) $(retained_tar_count)" "retained-config-$mode: the driver ran without an interpreter"
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-config-$mode: the refusal removed the task record"
      assert_present "$FOREIGN_COPY/.git" "retained-config-$mode: the copy was removed"
      kept_assert_lacks 'complete' "$FOREIGN_CASE/stdout" "retained-config-$mode: the task closed"
    else
      expect_code 0 "$rc" "retained-config-$mode: the close must succeed: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-config-$mode: the driver was not asked exactly once"
      retained_assert_closed "retained-config-$mode"
    fi
  done
  pass "the default interpreter and the explicit override close the kept-copy task the same way, and a missing default interpreter refuses with nothing removed"
}

# C2 (legacy): a copy that already holds driver tars and saved outputs, with no
# retained record, is asked once on the first teardown after the change (one named
# extra tar), and the later runs add nothing.
test_the_first_teardown_of_a_copy_that_already_holds_tars_asks_the_driver_once() {
  local rc run tardir
  make_retained_case retained-legacy enclosing
  tardir=$FOREIGN_SLOT/.claude/bug-evidence/worktree-preservation
  mkdir -p "$tardir" "$FOREIGN_CASE/data/task-x1"
  for run in 1 2 3; do
    printf 'archive %s\n' "$run" > "$tardir/stub-ordinary_cleanup-$run.tar"
  done
  printf '{"allowed": false, "reason": "cleanup_ignored_payload_archived_tree_retained", "retained_worktree_path": "%s"}\n' "$FOREIGN_COPY" > "$FOREIGN_CASE/data/task-x1/vernant-closeout.seed1"
  assert_equals "0 3" "$(retained_call_count) $(retained_tar_count)" "retained-legacy: the seeded state is wrong"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-legacy: the first run must close: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 4" "$(retained_call_count) $(retained_tar_count)" "retained-legacy: the first run did not ask the driver once for exactly one more tar"
  retained_assert_closed retained-legacy
  for run in 2 3; do
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    assert_equals "1 4" "$(retained_call_count) $(retained_tar_count)" "retained-legacy: run $run added a driver call or a tar"
  done
  pass "a copy that already holds driver tars is asked once on the first teardown, with one more tar, and later runs add none"
}

# C2 (changed) (head-only): a move of HEAD to another landed commit, with the ignored
# payload unchanged, asks the driver exactly once more (one named extra tar), and a
# further unchanged run adds nothing.
test_a_head_only_change_of_a_kept_copy_asks_the_driver_exactly_once_more() {
  local rc record head
  make_retained_case retained-head-only enclosing
  held_plain_get_slot "$FOREIGN_CASE"
  : > "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "retained-head-only: run 1 must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-head-only: run 1 should have asked the driver once"
  record=$(retained_record_path)
  cp "$record" "$FOREIGN_CASE/record.run1"
  git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'another landed commit'
  head=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
  git -C "$FOREIGN_CASE/project" fetch -q "$FOREIGN_COPY" HEAD
  git -C "$FOREIGN_CASE/project" update-ref refs/heads/main FETCH_HEAD
  add_gh_pr_merged_for_head "$FOREIGN_CASE" "$head"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "retained-head-only: run 2 must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "retained-head-only: a HEAD-only change did not ask the driver exactly once more"
  cmp -s "$FOREIGN_CASE/record.run1" "$record" && fail "retained-head-only: the stale record was not replaced"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "retained-head-only: an unchanged run after the change asked the driver again"
  pass "a move of HEAD alone asks the driver exactly once more, with one more tar, and the next unchanged run adds none"
}

# C2 (changed): a genuinely changed ignored payload is assessed again with exactly one driver
# call and one tar per change of the payload, whatever changed (a new entry the driver does not
# name, changed bytes, a second distinct change, a return to an earlier payload), and the same
# payload never asks again.
test_a_changed_payload_is_archived_once_per_change_and_never_again_while_unchanged() {
  local rc step want=1 run
  make_retained_case retained-p3 enclosing
  held_plain_get_slot "$FOREIGN_CASE"
  : > "$FOREIGN_CASE/no-lease-command"
  for step in none new-entry changed-bytes second-change earlier-payload; do
    case "$step" in
      none) ;;
      new-entry) printf 'three\n' > "$FOREIGN_COPY/.claude/channel-outbox/c.jsonl"; want=$((want + 1)) ;;
      changed-bytes) printf 'two2\n' > "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl"; want=$((want + 1)) ;;
      second-change) printf 'two3\n' > "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl"; want=$((want + 1)) ;;
      earlier-payload) printf 'two2\n' > "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl"; want=$((want + 1)) ;;
    esac
    for run in 1 2; do
      run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
      expect_code 1 "$rc" "retained-p3 $step run $run: must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals "$want $want" "$(retained_call_count) $(retained_tar_count)" "retained-p3 $step run $run: wrong driver calls and tars"
    done
  done
  pass "each change of the ignored payload causes exactly one driver call and one tar, a return to an earlier payload counts as a change, and the same payload never asks again"
}

# C2 (changed): a replaced creation lock is a different copy state and is asked again.
test_a_replaced_creation_lock_of_a_kept_copy_asks_the_driver_once_more() {
  local rc pid
  make_retained_case retained-lock enclosing
  held_plain_get_slot "$FOREIGN_CASE"
  : > "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-lock: run 1 should have asked the driver once"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-lock: an unchanged retry asked the driver"
  git -C "$FOREIGN_CASE/project" worktree unlock "$FOREIGN_COPY"
  sleep 0.1 & pid=$!
  wait "$pid" 2>/dev/null || true
  git -C "$FOREIGN_CASE/project" worktree lock --reason "vernant-session-active owner=launcher:$pid launcher=$pid" "$FOREIGN_COPY"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "retained-lock: a replaced creation lock was not assessed again exactly once"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "retained-lock: the retry after the replaced lock asked the driver"
  pass "a replaced creation lock of a kept copy asks the driver exactly once more and its retry asks nothing"
}

# (a): an anchored but unlanded commit, or an untracked .claude file, is refused; without
# --force before the driver, with --force by the kept route's own proof after it; the retry asks
# the driver nothing either way.
test_the_kept_route_refuses_an_anchored_but_unlanded_commit_and_an_untracked_claude_file() {
  local rc shape sha mode want
  for shape in anchored-unlanded untracked-claude; do
    for mode in plain force; do
      make_retained_case "retained-proof-$shape-$mode" enclosing
      case "$shape" in
        anchored-unlanded)
          printf 'new work\n' > "$FOREIGN_COPY/work.txt"
          git -C "$FOREIGN_COPY" add work.txt
          git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm "unlanded work"
          sha=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
          git -C "$FOREIGN_CASE/project" update-ref "refs/fm/anchor/task-x1-$sha" "$sha"
          ;;
        untracked-claude)
          printf 'new work\n' > "$FOREIGN_COPY/.claude/new-work.txt"
          ;;
      esac
      held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
      FOREIGN_TEARDOWN_ARGS=()
      [ "$mode" = plain ] || FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
      run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
      expect_code 1 "$rc" "retained-proof-$shape-$mode: work that is not landed or not clean must not be closed over: $(cat "$FOREIGN_CASE/stderr")"
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-proof-$shape-$mode: the task record was removed"
      assert_present "$FOREIGN_COPY/.git" "retained-proof-$shape-$mode: the copy was removed"
      assert_grep 'REFUSED' "$FOREIGN_CASE/stderr" "retained-proof-$shape-$mode: no cause was printed"
      want=$(retained_call_count)
      run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
      FOREIGN_TEARDOWN_ARGS=()
      expect_code 1 "$rc" "retained-proof-$shape-$mode: the retry must refuse again: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals "$want" "$(retained_call_count)" "retained-proof-$shape-$mode: an unchanged retry asked the driver again"
    done
  done
  pass "a kept copy with an anchored but unlanded commit or an untracked .claude file is refused, with and without --force, and its retry asks the driver nothing"
}

# C3 (a2), the shape where the ordinary proof passes: the task's current copy is the pool slot
# (clean and landed), and its prior copy, nested in the slot and locked by Vernant, holds a
# commit only a refs/fm/anchor ref keeps. The pre-driver proof accepts an anchored prior copy, so
# the driver IS asked (1 call, 1 tar); the kept route then proves the copy itself and refuses it
# (an anchor ref alone does not land it), and keeps the task, the copy, the slot and its claim.
# Two retries, with and without --force, add no driver call and no tar.
test_an_anchor_only_prior_copy_passes_the_ordinary_proof_and_is_refused_by_the_kept_route_after_the_driver() {
  local rc mode sha run
  for mode in plain force; do
    make_retained_case "retained-anchor-after-driver-$mode" reverse
    printf 'new work\n' > "$FOREIGN_COPY/work.txt"
    git -C "$FOREIGN_COPY" add work.txt
    git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm "unlanded work"
    sha=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
    git -C "$FOREIGN_CASE/project" update-ref "refs/fm/anchor/task-x1-$sha" "$sha"
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    FOREIGN_TEARDOWN_ARGS=()
    [ "$mode" = plain ] || FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
    for run in 1 2 3; do
      run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
      expect_code 1 "$rc" "anchor-after-driver-$mode run $run: an anchor-only prior copy must not be closed over: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "anchor-after-driver-$mode run $run: the driver must have been asked once and written one tar, and never again"
      kept_assert_lacks 'ship deliverable is not landed' "$FOREIGN_CASE/stderr" "anchor-after-driver-$mode run $run: the ordinary proof refused before the driver, so this is not the kept route's refusal"
      assert_grep 'a refs/fm/anchor ref alone does not land it' "$FOREIGN_CASE/stderr" "anchor-after-driver-$mode run $run: the kept route's cause was not printed"
      assert_present "$(retained_record_path)" "anchor-after-driver-$mode run $run: the driver's answer was not recorded"
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "anchor-after-driver-$mode run $run: the task record was removed"
      assert_present "$FOREIGN_COPY/work.txt" "anchor-after-driver-$mode run $run: the unlanded work was removed"
      assert_absent "$FOREIGN_CASE/treehouse.log" "anchor-after-driver-$mode run $run: the pool slot was returned"
    done
    FOREIGN_TEARDOWN_ARGS=()
  done
  pass "an anchor-only prior copy passes the ordinary proof, is refused by the kept route after the driver's one call and one tar with its answer recorded, and two retries, with and without --force, ask the driver nothing"
}

test_the_retained_record_states_the_disposition_facts() {
  local rc record
  make_retained_case retained-text enclosing
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-text: the close must succeed"
  record=$(retained_record_path)
  assert_grep "--execute-cleanup" "$record" "retained-text: the record does not say what the driver's --execute-cleanup does"
  assert_grep "writes another archive" "$record" "retained-text: the record does not say the driver writes another archive"
  assert_grep "teardown changes nothing in it" "$record" "retained-text: the record does not say teardown changes nothing in the copy"
  assert_grep "removing the copy depends on Vernant's driver" "$record" "retained-text: the record does not say who removes the copy"
  pass "the retained record states why the copy is kept, that teardown changes nothing in it, that the driver's --execute-cleanup writes another archive and that removing it depends on Vernant's driver"
}


# F-round probes, two real processes on one kept copy. The first teardown holds in
# the driver (the stand-in sleeps after it wrote its tar); the second starts while
# it is there. Whatever the second does, the driver is asked once and one tar exists.
# Two overlapping activations with a deterministic handshake: the first teardown's stand-in
# driver writes `entered` and waits for `release`, the second command starts only after
# `entered`, its attempt and output are recorded by the caller, and only then is `release`
# written. No wait here has a cut-off: a wait that runs long prints one slow-alarm line and
# keeps waiting (the first run dying ends the wait for `entered`, the second returning writes
# `release`).
# C2 (unchanged), closed end state: a retry of a task that closed around a kept copy says it is
# already closed, names the record, exits 0 and asks the driver nothing.
test_a_retry_of_a_closed_kept_copy_task_says_it_is_already_closed() {
  local rc
  make_retained_case retained-closed-retry enclosing
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-closed-retry: the close must succeed: $(cat "$FOREIGN_CASE/stderr")"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-closed-retry: a retry of a closed task must say so and succeed: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'already closed' "$FOREIGN_CASE/stdout" "retained-closed-retry: the retry did not say the task is already closed"
  assert_grep "$(retained_record_path)" "$FOREIGN_CASE/stdout" "retained-closed-retry: the retry did not name the record"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-closed-retry: the retry asked the driver"
  pass "a retry of a closed kept-copy task says it is already closed, names the record and asks the driver nothing"
}

# F8: a task record that is damaged rather than gone, one removed by hand after a refused close,
# and a pending backlog close are never reported as already closed; a completed close is.
test_a_damaged_or_unclosed_task_record_is_never_reported_as_already_closed() {
  local rc
  make_retained_case retained-closed-shape enclosing
  held_plain_get_slot "$FOREIGN_CASE"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  : > "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "closed-shape: the close without a durable lease must refuse"
  assert_present "$(retained_record_path)" "closed-shape: the refused close wrote no retained record, so the case tests nothing"
  mv "$FOREIGN_CASE/state/task-x1.meta" "$FOREIGN_CASE/meta.saved"
  mkdir "$FOREIGN_CASE/state/task-x1.meta"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "closed-shape: a task record that is a directory must refuse"
  kept_assert_lacks 'already closed' "$FOREIGN_CASE/stdout" "closed-shape: a damaged task record was reported as already closed"
  rmdir "$FOREIGN_CASE/state/task-x1.meta"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "closed-shape: a record removed by hand after a refused close must refuse"
  kept_assert_lacks 'already closed' "$FOREIGN_CASE/stdout" "closed-shape: a refused close was reported as already closed once its record went"
  assert_equals in_flight "$(backlog_row_state "$FOREIGN_CASE")" "closed-shape: the backlog item moved"
  make_retained_case retained-closed-control enclosing
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "closed control: the close must succeed: $(grep -m 3 -E 'REFUSED|error' "$FOREIGN_CASE/stderr")"
  printf 'id=task-x1\n' > "$FOREIGN_CASE/state/task-x1.backlog-close"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  kept_assert_lacks 'already closed' "$FOREIGN_CASE/stdout" "closed control: a pending backlog close was reported as already closed"
  rm -f "$FOREIGN_CASE/state/task-x1.backlog-close"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "closed control: the retry of a closed task must succeed"
  assert_grep 'already closed' "$FOREIGN_CASE/stdout" "closed control: the retry of a closed task did not say it is already closed"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "closed control: the retry asked the driver"
  pass "a damaged task record, one removed after a refused close and a pending backlog close are never reported as already closed; a completed close is"
}

# C2 (post-driver): the copy's record cannot be written (its folder takes no new file): every
# run refuses before the driver with a refusal record in data/<task>/closeout-refused/, and once
# the folder can be written the next run asks once, closes and deletes the refusal record.
test_an_unwritable_retained_record_never_makes_an_unchanged_retry_ask_the_driver() {
  local rc dir run refused
  make_retained_case retained-unwritable-retry enclosing
  dir=$FOREIGN_CASE/data/copy-sweep/retained
  mkdir -p "$dir"
  chmod a-w "$dir"
  if [ "$(id -u)" = 0 ]; then chmod u+w "$dir"; pass "skipped as root"; return 0; fi
  refused=$FOREIGN_CASE/data/task-x1/closeout-refused/$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  for run in 1 2 3; do
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 1 "$rc" "retained-unwritable-retry: run $run must refuse: $(cat "$FOREIGN_CASE/stderr")"
    assert_equals "0 0" "$(retained_call_count) $(retained_tar_count)" "retained-unwritable-retry: run $run asked the driver"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-unwritable-retry: run $run removed the task record"
    assert_grep 'cause=' "$refused" "retained-unwritable-retry: run $run left no refusal record with its cause"
  done
  chmod u+w "$dir"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-unwritable-retry: once the record can be written the close must succeed: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-unwritable-retry: the close after the cause went asked more than once"
  assert_absent "$refused" "retained-unwritable-retry: the refusal record outlived its cause"
  pass "an unwritable retained record refuses every unchanged retry before the driver with a refusal record, and the close follows with one call once it is writable"
}

retained_overlap_run() {  # <label> <second-command...>: first run in the background
  local label=$1 first_pid releaser_pid n after
  shift
  rm -f "$FOREIGN_CASE/entered" "$FOREIGN_CASE/release"
  after=": > '$FOREIGN_CASE/entered'; n=0; until [ -e '$FOREIGN_CASE/release' ]; do sleep 0.1; n=\$((n + 1)); [ \"\$n\" -ne 300 ] || echo 'slow: the stand-in driver is still waiting for release' >&2; done"
  (
    env FM_TEARDOWN_VERNANT_PYTHON="$FOREIGN_CASE/vernant-python" FM_STUB_CLOSEOUT=retained \
      "FM_STUB_AFTER=$after" FM_HOME="$FOREIGN_CASE/home" \
      FM_ROOT_OVERRIDE="$FOREIGN_CASE/code-root" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
      FM_DATA_OVERRIDE="$FOREIGN_CASE/data" FM_CONFIG_OVERRIDE="$FOREIGN_CASE/config" \
      NM_HOME="$FOREIGN_CASE/nm" PATH="$FOREIGN_CASE/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
      "$TEARDOWN" task-x1 > "$FOREIGN_CASE/stdout.first" 2> "$FOREIGN_CASE/stderr.first"
    echo $? > "$FOREIGN_CASE/rc.first"
  ) &
  first_pid=$!
  n=0
  until [ -f "$FOREIGN_CASE/entered" ]; do
    kill -0 "$first_pid" 2>/dev/null || break
    sleep 0.2
    n=$((n + 1))
    [ "$n" -ne 150 ] || echo "slow: $label: the first teardown has not entered the driver yet" >&2
  done
  [ -f "$FOREIGN_CASE/entered" ] || fail "$label: the first run ended without entering the driver"
  # The second activation either refuses at once or queues behind the first for a lock it
  # holds. A releaser writes `release` once the second is observed waiting (the lock monitor's
  # wait marker exists in the state folder); the second's own return writes it too.
  (
    n=0
    until [ -e "$FOREIGN_CASE/release" ]; do
      ls "$FOREIGN_CASE"/state/.lock-monitor.wait.* > /dev/null 2>&1 && break
      sleep 0.2
      n=$((n + 1))
      [ "$n" -ne 150 ] || echo "slow: $label: the second activation is not waiting yet" >&2
    done
    cat "$FOREIGN_CASE"/state/.lock-monitor.wait.* > "$FOREIGN_CASE/waiting-at-release.txt" 2>/dev/null || true
    : > "$FOREIGN_CASE/release"
  ) &
  releaser_pid=$!
  "$@" || true
  : > "$FOREIGN_CASE/release"
  wait "$releaser_pid" 2>/dev/null || true
  wait "$first_pid" 2>/dev/null || true
}

test_two_overlapping_teardowns_of_one_kept_copy_make_one_archive() {
  local rc
  make_retained_case retained-overlap-teardown enclosing
  retained_overlap_run retained-overlap-teardown run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  cp "$FOREIGN_CASE/stderr" "$FOREIGN_CASE/stderr.second"
  # The second activation queued behind the first (the lock monitor's wait marker was seen) or, on a
  # host whose lifecycle lock does not queue, was refused at once because another lifecycle action
  # holds the task; either way it never reached the driver while the first was in it. A second run
  # that did neither would have run beside the first, and the count below would not mean anything.
  if [ ! -s "$FOREIGN_CASE/waiting-at-release.txt" ]; then
    assert_grep "another lifecycle action is already running for task task-x1" "$FOREIGN_CASE/stderr.second" \
      "retained-overlap-teardown: the second teardown neither waited on the first one's lock nor was refused because of it: $(tail -3 "$FOREIGN_CASE/stderr.second")"
  fi
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-overlap-teardown: two overlapping teardowns made more than one driver call or tar (first rc $(cat "$FOREIGN_CASE/rc.first"), second rc $rc: $(tail -3 "$FOREIGN_CASE/stderr.second"))"
  pass "two overlapping teardowns of one kept copy ask the driver once and write one tar (first rc $(cat "$FOREIGN_CASE/rc.first"), second rc $rc; the second waited on: $(sed -n 2p "$FOREIGN_CASE/waiting-at-release.txt" 2>/dev/null | sed "s#$FOREIGN_CASE/##" | tr '\n' ' '))"
}

test_a_file_created_in_the_copy_while_the_driver_runs_is_not_closed_over() {
  local rc
  make_retained_case retained-late-file enclosing
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained "FM_STUB_AFTER=printf 'late\n' > '$FOREIGN_COPY/notes/late.dat'"
  expect_code 1 "$rc" "retained-late-file: a unique ignored file created during the driver call must not be closed over: $(cat "$FOREIGN_CASE/stderr")"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-late-file: the task record was removed"
  assert_present "$FOREIGN_COPY/notes/late.dat" "retained-late-file: the late file is gone"
  assert_equals "late" "$(cat "$FOREIGN_COPY/notes/late.dat")" "retained-late-file: the late file changed"
  pass "a unique ignored file created in the copy while the driver runs refuses the close and stays in the copy"
}

# C2 (unchanged): the record does not expire; a run 30 days after the record's
# time fields and file times asks the driver nothing.
# The control that makes the overlap check discriminate: the same two overlapping teardowns,
# the second one run from a copy of bin/ without the per-task lifecycle locks, make two driver
# calls and two tars. Without it the check above could pass for another reason. The locks
# removed are the three teardown takes per task, in order: the lease-command lock
# (fm_lease_guard, the one the first teardown holds and the second waits on), the control lock
# and the task record's meta lock. The project lock is left in place.
test_a_run_without_the_per_task_lifecycle_locks_calls_the_driver_twice_so_the_overlap_check_discriminates() {
  local rc patched
  make_retained_case retained-overlap-nolock enclosing
  patched=$FOREIGN_CASE/patched-code
  mkdir -p "$patched"
  cp -R "$ROOT/bin" "$patched/bin"
  # shellcheck disable=SC2016 # the patterns are sed text: the dollar signs are literal.
  sed -i.bak -e 's/^fm_lease_guard "\$ID" "teardown (fm-teardown)"$/true/' -e 's/^fm_lock_try_acquire "\$CONTROL_LOCK" || {$/true || {/' -e 's/^fm_lock_acquire_wait "\$META_LOCK"$/true/' "$patched/bin/fm-teardown.sh"
  [ "$(diff "$ROOT/bin/fm-teardown.sh" "$patched/bin/fm-teardown.sh" | grep -c '^>')" = 3 ] || fail "retained-overlap-nolock: the three per-task lock lines to remove were not all found"
  rc=0
  # shellcheck disable=SC2329 # run by retained_overlap_run as the second activation.
  second_without_locks() { TEARDOWN="$patched/bin/fm-teardown.sh" run_foreign_teardown rc FM_STUB_CLOSEOUT=retained; }
  retained_overlap_run retained-overlap-nolock second_without_locks
  assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "retained-overlap-nolock: without the per-task locks a second run should have called the driver again (second rc $rc: stdout $(tail -3 "$FOREIGN_CASE/stdout" | tr "\n" "|"))"
  pass "a second teardown without the per-task lifecycle locks makes a second driver call and a second tar, so the overlap check discriminates"
}

test_an_aged_record_of_an_unchanged_kept_copy_still_asks_the_driver_nothing() {
  local rc record aged_at age
  for age in 30 400; do
    make_retained_case "retained-aged-$age" enclosing
    held_plain_get_slot "$FOREIGN_CASE"
    : > "$FOREIGN_CASE/no-lease-command"
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 1 "$rc" "retained-aged-$age: run 1 must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
    record=$(retained_record_path)
    aged_at=$(date -u -v-"$age"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$age days ago" +%Y-%m-%dT%H:%M:%SZ)
    sed "s/^recorded-at=.*/recorded-at=$aged_at/" "$record" > "$record.aged" && mv "$record.aged" "$record"
    find "$FOREIGN_CASE/data" -type f -exec touch -t "$(date -u -v-"$age"d +%Y%m%d%H%M 2>/dev/null || date -u -d "$age days ago" +%Y%m%d%H%M)" {} +
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 1 "$rc" "retained-aged-$age: the aged run must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
    assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-aged-$age: an aged record asked the driver again"
    rm -f "$FOREIGN_CASE/no-lease-command"
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 0 "$rc" "retained-aged-$age: the aged record must still close the task: $(cat "$FOREIGN_CASE/stderr")"
    assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-aged-$age: the closing run asked the driver again"
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-aged-$age: a run after the close asked the driver"
  done
  pass "a record 30 and 400 days old (its time fields and every file time) of an unchanged kept copy still asks the driver nothing, before and after the close"
}

teardown_test_cases=(
test_fixture_cleanup_leaves_no_home_summary_refresh_worker
test_teardown_never_holds_up_a_steer_to_another_task
test_lane_registry_scan_reads_each_distinct_registry_once
test_task_teardown_preserves_another_homes_abandoned_worker
test_missing_startup_source_refuses_before_cleanup
test_unreadable_startup_source_refuses_before_cleanup
test_missing_adapter_sibling_refuses_before_cleanup
test_forced_child_missing_adapter_sibling_refuses_before_cleanup
test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup
test_retained_sources_still_reach_the_ordinary_refusal
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
test_top_level_pipeline_discovery_failures_remain_best_effort
test_own_autonomous_run_is_left_alone
test_leaked_worktree_process_is_reaped
test_teardown_spares_a_detached_daemon_at_the_copy_root
test_teardown_reaps_a_leaked_child_of_the_task_pane
test_teardown_ownership_fault_control_kills_the_detached_daemon
test_teardown_mixed_copy_signals_nothing
test_teardown_without_a_provable_pane_refuses_a_root_process
test_teardown_proof_survives_the_parent_the_reap_ends
test_teardown_refuses_an_orphan_it_cannot_prove
test_teardown_grace_child_that_leaves_the_group_is_refused
test_teardown_tmux_anchor_needs_the_one_recorded_pane
test_teardown_recycled_group_proves_nothing
test_tasktmp_only_route_names_an_unproven_holder_and_continues
test_teardown_ambiguous_window_refuses_before_any_close
test_teardown_unreadable_tmux_socket_refuses_before_any_close
test_leaked_tasktmp_process_is_reaped
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
test_lsof_absent_refuses_without_signalling
test_lsof_error_refuses_before_removal
test_reused_pid_identity_is_not_force_killed
test_exec_changed_process_is_still_reaped
test_process_spawned_during_grace_after_its_parent_exits_is_refused
test_process_spawned_during_grace_by_a_live_parent_is_reaped
test_persistent_scan_refuses_after_bounded_retries
test_process_exit_during_identity_lookup_does_not_refuse
test_run_abort_precedes_process_reap_precedes_worktree_removal
test_locked_own_copy_is_released_by_the_closeout_driver
test_unlocked_landed_foreign_copy_is_removed_without_the_driver
test_a_held_copy_keeps_its_unique_ignored_files_and_none_are_preserved
test_task_closes_beside_a_foreign_copy_with_unpushed_commits
test_held_copy_record_has_one_exact_line_per_copy
test_a_held_close_removes_only_the_tasks_own_nested_copy
test_a_held_close_refuses_when_an_own_nested_copy_holds_another_repository
test_a_held_close_is_not_stopped_by_a_submodule_of_the_own_repository
test_a_foreign_copy_inside_the_own_nested_copy_is_never_left_to_the_removal
test_an_ordinary_close_never_turns_into_a_held_close_during_the_project_lock_wait
test_a_stale_lock_cleanup_never_turns_an_ordinary_close_into_a_held_close
test_a_held_close_reserves_a_plain_get_slot_durably
test_a_held_close_refuses_when_the_slot_cannot_be_durably_leased
test_held_entry_lease_no_command_plain
test_held_entry_lease_no_command_enclosing
test_held_entry_lease_fails_plain
test_held_entry_lease_fails_enclosing
test_held_entry_record_directory_plain
test_held_entry_record_directory_enclosing
test_held_entry_unrecorded_readonly_plain
test_held_entry_unrecorded_readonly_enclosing
test_held_entry_symlink_dangling_plain
test_held_entry_symlink_dangling_enclosing
test_held_entry_symlink_directory_plain
test_held_entry_symlink_directory_enclosing
test_held_entry_symlink_unrecorded_readonly_plain
test_held_entry_symlink_unrecorded_readonly_enclosing
test_held_entry_symlink_writable_plain
test_held_entry_symlink_writable_enclosing
test_held_entry_no_backlog_pending_close_directory_plain
test_held_entry_no_backlog_pending_close_directory_enclosing
test_held_entry_recorded_readonly_plain
test_held_entry_recorded_readonly_enclosing
test_held_entry_recorded_writable_plain
test_held_entry_recorded_writable_enclosing
test_held_entry_close_plain
test_held_entry_close_enclosing
test_a_held_close_in_a_superseded_pool_folder_leases_the_slot_by_its_path
test_a_held_close_in_a_superseded_pool_folder_refuses_without_lease_path
test_a_refused_held_close_releases_no_misdirected_lease
test_an_ordinary_rerun_after_a_refused_held_close_releases_the_misdirected_lease
test_the_held_close_notice_promises_no_cleanup_that_does_not_exist
test_a_held_close_that_a_later_step_refuses_leaves_one_record_line_and_a_rerun_adds_none
test_a_held_copy_record_that_cannot_be_written_refuses_the_close
test_a_legacy_record_held_close_still_names_the_held_copies
test_a_foreign_copy_does_not_excuse_an_own_copy_that_is_not_landed
test_a_foreign_copy_that_cannot_be_held_still_refuses_the_whole_close
test_a_copy_held_for_ignored_files_is_typed_and_asked_about_those_files_when_another_copy_blocks
test_a_foreign_copy_not_held_for_a_process_of_this_teardown_names_that_process
test_a_foreign_copy_whose_landing_could_not_be_checked_is_not_held
test_a_failure_after_the_point_of_no_return_still_leaves_the_held_notice_and_record
test_a_forced_close_never_holds_a_foreign_copy
test_a_slot_with_no_foreign_copy_closes_and_returns_as_before
test_idle_reap_keeps_the_per_copy_reason_of_a_foreign_copy_refusal
test_foreign_copy_with_unsaved_files_is_refused
test_a_foreign_copy_with_only_unique_ignored_files_is_held_and_the_slot_is_not_returned
test_the_next_step_for_a_copy_held_for_ignored_files_never_names_a_removal
test_held_copy_notices_and_record_show_no_control_character_and_quote_the_command
test_a_forced_close_preserves_and_releases_a_foreign_copy_with_unique_ignored_files
test_graft_output_alone_does_not_hold_a_foreign_copy
test_graft_output_is_not_preserved_from_a_released_own_nested_copy
test_a_foreign_copy_inside_an_own_nested_copy_with_unique_ignored_files_is_preserved_and_released
test_the_held_record_dedupe_matches_a_name_holding_a_backslash
test_foreign_copy_regenerable_ignored_files_need_no_preservation
test_a_foreign_copy_with_durable_tac_state_is_held_and_tac_tmp_is_not_the_reason
test_a_foreign_copy_whose_ignored_files_cannot_be_listed_is_refused_not_held
test_typed_preservation_exit_completes_cleanup
test_forced_preservation_refusal_prints_no_completing_command
test_legacy_preservation_refusal_prints_no_completing_command
test_foreign_copy_that_git_protects_is_a_typed_nonforced_removal
test_foreign_copy_removal_that_fails_for_another_reason_is_a_plain_error
test_landing_check_that_could_not_ask_the_forge_is_a_plain_error
test_landing_check_that_could_not_compare_with_the_default_branch_is_a_plain_error
test_landing_check_that_the_forge_answered_not_merged_stays_a_copy_landed_refusal
test_landing_proof_that_head_changed_after_its_proof_is_unasked
test_git_protection_is_read_from_the_copy_state
test_nonforced_removal_is_decided_from_the_copy_not_from_gits_message
test_foreign_copy_with_a_modules_directory_is_a_typed_nonforced_removal
test_creation_lock_owner_asks_the_same_question_at_proof_and_release_time
test_copy_path_with_newlines_cannot_forge_envelope_lines
test_foreign_copy_that_is_not_a_worktree_root_is_a_typed_refusal
test_foreign_copy_with_an_unresolvable_head_is_a_typed_refusal
test_foreign_copy_whose_anchor_names_another_commit_is_a_typed_refusal
test_teardown_usage_and_inspection_errors_are_not_policy_events
test_earlier_preserved_copy_survives_until_its_replacement_is_verified
test_foreign_copy_named_by_an_alias_in_an_active_record_is_refused
test_half_removed_foreign_copy_is_refused_as_before
test_recycled_launcher_pid_does_not_own_a_foreign_copy
test_live_launcher_keeps_its_foreign_copy
test_task_own_session_as_lock_launcher_does_not_block_release
test_unrelated_or_stubborn_lock_launcher_keeps_its_foreign_copy
test_a_detached_process_at_the_slot_root_does_not_make_its_child_teardowns_own
test_a_mixed_slot_refuses_before_signalling_the_proved_nested_launcher
test_nested_retire_stops_when_a_support_proof_expires
test_process_in_foreign_copy_keeps_it
test_task_own_process_inside_foreign_copy_is_ended_and_released
test_two_foreign_copies_are_released_together_or_not_at_all
test_foreign_copy_nested_in_another_is_removed_first
test_foreign_copy_is_released_before_the_project_lock_wait
test_closeout_uses_the_slots_default_interpreter
test_missing_closeout_driver_or_interpreter_leaves_the_copy_in_place
test_own_locked_copy_with_no_closeout_interpreter_refuses_at_entry
test_closeout_plan_refusal_refuses_at_entry
test_linux_removability_refuses_an_entry_it_cannot_open
test_preserve_parent_and_metadata_boundaries
test_preserve_parent_on_another_filesystem_refuses_at_entry
test_closeout_refusal_and_foreign_locks_leave_the_copy_in_place
test_locked_own_nested_copy_is_released_by_the_closeout_driver
test_locked_own_nested_copy_with_a_recycled_launcher_pid_is_released
test_live_launcher_outside_the_task_keeps_its_locked_own_copy
test_locked_own_nested_copy_that_is_not_proved_is_refused
test_locked_own_nested_copy_with_unique_ignored_file_is_preserved_and_released
test_locked_own_nested_copy_stays_when_a_foreign_copy_is_refused
test_locked_own_nested_copy_is_released_before_the_project_lock_wait
test_closeout_refusal_reports_tail_and_preserves_complete_output
test_closeout_driver_refusal_leaves_a_locked_own_copy_and_its_records
test_in_copy_nm_launch_agent_refuses_without_a_creation_record
test_in_copy_nm_launch_agent_equivalent_roots_refuse
test_foreign_nm_launch_agents_are_left_alone
test_nested_nm_launch_agents_are_left_alone
test_absent_copy_nm_launch_agents_preserve_nested_ownership
test_in_copy_nm_launch_agent_refuses_even_with_force
test_in_copy_nm_launch_agent_not_loaded_refuses
test_symlinked_nm_launch_agent_plist_is_judged_through_its_target
test_teardown_removes_the_tasks_own_docker_stacks
test_docker_differently_named_metadata_hardlinks_preserve_longer_siblings
test_docker_removal_failure_keeps_the_task_records_until_a_rerun_succeeds
test_forced_teardown_retains_records_after_a_docker_removal_failure
test_docker_removal_error_without_a_survivor_does_not_stop_teardown
test_docker_failed_lane_scan_names_its_cause
test_stopped_docker_daemon_blocks_teardown
test_teardown_without_a_docker_binary_skips_docker_cleanup
test_docker_configured_supabase_identity_vetoes_all_heuristics
test_docker_unreadable_supabase_config_refuses_and_absence_proceeds
test_docker_project_labels_require_the_exact_task_id
test_docker_workdirs_canonicalize_and_exclude_foreign_lanes_and_tasktmp
test_docker_mixed_project_carriers_spare_empty_heuristic_networks
test_docker_latest_foreign_carriers_veto_network_removal
test_standalone_secondmate_skips_docker_cleanup
test_secondmate_retirement_exempts_only_its_own_missing_home
test_secondmate_retirement_keeps_stored_preservation_bundles
test_docker_project_record_failure_prevents_container_removal
test_docker_verified_cleanup_clears_retained_projects
test_docker_ambiguous_ids_trust_only_worktree_evidence
test_docker_all_failure_channels_retain_forced_tasks_until_retry
test_forced_secondmate_cleans_each_child_docker_before_retirement_and_retries
test_forced_orca_children_clean_docker_before_worktree_removal
test_forced_nested_secondmate_cleans_grandchild_docker_before_retirement_and_retries
test_docker_container_arriving_during_resource_cleanup_blocks_retirement
test_teardown_retires_the_dsh_launch_state
test_kept_copy_helper_a_valid_answer_is_recorded_once_and_judged_again_without_the_driver
test_kept_copy_helper_an_invalid_kept_answer_is_recorded_and_never_asked_again
test_kept_copy_helper_the_driver_is_asked_only_when_its_answer_can_be_recorded
test_kept_copy_helper_a_refused_kept_copy_is_judged_again_from_its_record
test_kept_copy_helper_the_retire_step_leaves_a_matching_kept_copy_out
test_kept_copy_helper_the_proof_queues_no_signal_for_a_matching_kept_copy
test_kept_copy_helper_a_receipt_that_is_not_a_regular_file_still_holds_the_copy
test_a_retry_of_a_closed_kept_copy_task_says_it_is_already_closed
test_a_damaged_or_unclosed_task_record_is_never_reported_as_already_closed
test_an_unwritable_retained_record_never_makes_an_unchanged_retry_ask_the_driver
test_kept_copy_helper_a_retry_of_a_closed_task_says_it_is_already_closed
test_kept_copy_helper_a_changed_copy_is_preserved_beside_its_earlier_preserve_which_is_never_replaced
test_kept_copy_helper_a_copy_with_nothing_selected_keeps_one_preserve_across_retries
test_kept_copy_helper_each_distinct_selected_state_keeps_one_preserve_on_the_released_route
test_kept_copy_helper_each_distinct_selected_state_keeps_one_preserve_on_the_kept_route
test_kept_copy_helper_the_entry_plan_lets_a_kept_own_copy_through_and_a_matching_record_skips_it
test_kept_copy_helper_a_record_that_cannot_be_written_leaves_a_refusal_record
test_kept_copy_helper_every_driver_named_path_is_judged_as_written_and_checked_against_the_copy
test_kept_copy_helper_a_file_changed_after_it_was_preserved_is_never_released_unpreserved
test_kept_copy_helper_root_files_named_like_the_preserves_own_files_are_preserved
test_a_landed_task_closes_around_an_own_copy_the_driver_keeps
test_a_retry_of_an_unchanged_kept_copy_asks_the_driver_nothing
test_a_changed_kept_copy_is_assessed_afresh
test_a_kept_copy_in_a_slot_a_peer_works_in_refuses_and_its_retry_asks_the_driver_nothing
test_every_other_state_of_an_own_copy_the_driver_keeps_still_refuses
test_a_stable_refusal_after_the_driver_asks_the_driver_nothing_on_retry
test_a_kept_copy_whose_cause_went_closes_from_its_record_without_the_driver
test_a_kept_copy_with_only_claude_files_closes_when_its_preserve_is_on_another_filesystem
test_the_preserve_and_the_archives_survive_the_close_and_every_later_run
test_the_default_driver_interpreter_and_the_override_close_the_same_way
test_the_first_teardown_of_a_copy_that_already_holds_tars_asks_the_driver_once
test_a_head_only_change_of_a_kept_copy_asks_the_driver_exactly_once_more
test_a_changed_payload_is_archived_once_per_change_and_never_again_while_unchanged
test_a_replaced_creation_lock_of_a_kept_copy_asks_the_driver_once_more
test_the_kept_route_refuses_an_anchored_but_unlanded_commit_and_an_untracked_claude_file
test_an_anchor_only_prior_copy_passes_the_ordinary_proof_and_is_refused_by_the_kept_route_after_the_driver
test_the_retained_record_states_the_disposition_facts
test_two_overlapping_teardowns_of_one_kept_copy_make_one_archive
test_a_file_created_in_the_copy_while_the_driver_runs_is_not_closed_over
test_a_run_without_the_per_task_lifecycle_locks_calls_the_driver_twice_so_the_overlap_check_discriminates
test_an_aged_record_of_an_unchanged_kept_copy_still_asks_the_driver_nothing
)

# In the combined tests/fm-teardown.test.sh run,
# test_local_only_fork_remote_allows left set -e in force for every case
# registered after it. test_local_only_force_overrides_unpushed
# is the first such case here, so restore that errexit state once before it.
errexit_restored=false
fm_test_before_case() {
  if [ "$errexit_restored" = false ] && [ "$1" = test_local_only_force_overrides_unpushed ]; then
    set -e
    errexit_restored=true
  fi
}
fm_test_run_cases "${teardown_test_cases[@]}" -- "$@"
