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

  set +e
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
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
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
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
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
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
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 0 "$rc" "mate-teardown-refuses: rerun after repair should succeed: $(cat "$case_dir/stderr2")"
  sed -E 's/ \[at=[0-9]+\]//' "$channel" | grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green' \
    || fail "mate-teardown-refuses: the rerun did not deliver the final line"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-refuses: rerun left the task record"
  pass "a secondmate home's teardown delivers the child's final line or refuses until it can"
}

test_teardown_missing_busy_sidecar_completes() {
  local case_dir gen rc
  case_dir=$(make_case missing-busy-sidecar)
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.busy-gen"

  set +e
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

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
if [ "\$count" -le 3 ]; then printf 'p%s\nfcwd\nn%s\n' '$pid' '$case_dir/wt'; fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_REUSED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  count=0
  [ ! -f "$FM_FAKE_PS_COUNT" ] || count=$(cat "$FM_FAKE_PS_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_PS_COUNT"
  if [ "$count" -le 4 ]; then printf 'Tue Aug  4 10:00:00 2026\n'
  else printf 'Tue Aug  4 10:00:01 2026\n'; fi
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

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

test_process_spawned_during_grace_is_reaped_on_later_pass() {
  local case_dir rc pid child_file child_pid="" parent_survived=0 child_survived=0
  case_dir=$(make_case grace-spawn-convergence)
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
  [ -e "$case_dir/ready" ] || fail "grace-spawn-convergence: parent not ready"

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
  expect_code 0 "$rc" "grace-spawn-convergence: teardown should converge"
  assert_present "$child_file" "grace-spawn-convergence: TERM handler did not spawn a child"
  [ "$child_survived" -eq 0 ] || fail "grace-spawn-convergence: spawned child survived"
  [ "$parent_survived" -eq 0 ] || fail "grace-spawn-convergence: original process survived"
  pass "a process spawned during grace is reaped on a later pass"
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
# daemon held a directory inside the task copy. Without a retire step, teardown
# found a process it could not prove custody of and refused (and a plain kill is
# undone by launchd KeepAlive).
test_private_nm_launch_agent_is_retired_before_teardown() {
  local case_dir rc pid label shared_state
  case_dir=$(make_case private-nm-agent)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  add_fake_launchctl "$case_dir"
  shared_state="$case_dir/shared-daemon-state"
  printf '%s\n' running > "$shared_state"
  FM_FAKE_NM_SHARED_DAEMON_STATE="$shared_state" "$case_dir/fakebin/no-mistakes" daemon stop
  [ "$(cat "$shared_state")" = stopped ] || fail "private-nm-agent: fake daemon stop did not stop the shared daemon"
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
  if kill -0 "$pid" 2>/dev/null; then
    teardown_fixture_stop "$pid"
    fail "private-nm-agent: the private daemon survived teardown"
  fi
  expect_code 0 "$rc" "private-nm-agent: teardown must finish once the agent is retired"
  assert_grep "bootout gui/$(id -u)/$label" "$case_dir/launchctl-calls" \
    "private-nm-agent: teardown did not boot the agent out of the user domain"
  assert_absent "$case_dir/launchagents/$label.plist" \
    "private-nm-agent: the plist is still installed, so the agent returns at next login"
  assert_present "$case_dir/data/task-x1/launchagent-backup/$label.plist" \
    "private-nm-agent: the plist was not archived under the task's data"
  assert_grep "retired task-private no-mistakes launch agent $label" "$case_dir/stderr" \
    "private-nm-agent: teardown did not report the retired agent"
  [ "$(cat "$shared_state")" = running ] || fail "private-nm-agent: teardown stopped the shared daemon"
  pass "a no-mistakes launch agent rooted in the task's copy is booted out and archived, then teardown finishes"
}

test_private_nm_launch_agent_equivalent_roots_are_retired() {
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
    if kill -0 "$pid" 2>/dev/null; then
      teardown_fixture_stop "$pid"
      fail "private-nm-agent-$spelling: the private daemon survived teardown"
    fi
    expect_code 0 "$rc" "private-nm-agent-$spelling: teardown must finish"
    assert_absent "$case_dir/launchctl-loaded/$label" \
      "private-nm-agent-$spelling: the agent is still loaded"
    assert_absent "$case_dir/launchagents/$label.plist" \
      "private-nm-agent-$spelling: the plist is still installed"
    assert_present "$case_dir/data/task-x1/launchagent-backup/$label.plist" \
      "private-nm-agent-$spelling: the plist was not archived"
    assert_absent "$case_dir/state/task-x1.meta" \
      "private-nm-agent-$spelling: the task record survived teardown"
  done
  pass "equivalent private roots unload their agents and allow teardown to finish"
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
      expect_code 0 "$rc" "absent-nm-agent-$recovery-$registrar: recovery refused: $(cat "$case_dir/stderr")"
      for hash in 1 2 3 4; do
        label="$NM_AGENT_PREFIX.$hash"
        assert_absent "$case_dir/launchctl-loaded/$label" "absent-nm-agent: private agent remains loaded"
        assert_absent "$case_dir/launchagents/$label.plist" "absent-nm-agent: private plist remains installed"
        assert_present "$case_dir/data/task-x1/launchagent-backup/$label.plist" "absent-nm-agent: private plist not archived"
        if [ "$hash" -le 2 ]; then
          assert_grep "bootout gui/$(id -u)/$label" "$case_dir/launchctl-calls" "absent-nm-agent: loaded private agent not booted out"
        fi
      done
      label="$NM_AGENT_PREFIX.nested"
      assert_present "$case_dir/launchctl-loaded/$label" "absent-nm-agent: nested agent was unloaded"
      assert_present "$case_dir/launchagents/$label.plist" "absent-nm-agent: nested plist was removed"
      assert_no_grep "$label" "$case_dir/launchctl-calls" "absent-nm-agent: nested agent was addressed"
      assert_absent "$case_dir/data/task-x1/launchagent-backup/$label.plist" "absent-nm-agent: nested plist was archived"
      assert_present "$home/state/other-lane.meta" "absent-nm-agent: nested task record was removed"
      assert_absent "$case_dir/state/task-x1.meta" "absent-nm-agent: recovered task record remains"
    done
  done
  pass "absent-copy recovery retires private agents but preserves nested agents registered by local task projects"
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

# An agent that will not unload still owns its process and respawns it, so
# teardown must stop with the plist and the task record intact.
test_private_nm_launch_agent_bootout_failure_refuses() {
  local case_dir rc pid label
  case_dir=$(make_case private-nm-agent-stuck)
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
  FAKE_LAUNCHCTL_BOOTOUT_FAILS=1 FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill -0 "$pid" 2>/dev/null || { teardown_fixture_stop "$pid"; fail "private-nm-agent-stuck: process was signalled around a loaded agent"; }
  teardown_fixture_stop "$pid"
  expect_code 1 "$rc" "private-nm-agent-stuck: teardown must refuse when the agent stays loaded"
  assert_present "$case_dir/launchagents/$label.plist" "private-nm-agent-stuck: plist removed although the agent is still loaded"
  assert_present "$case_dir/state/task-x1.meta" "private-nm-agent-stuck: task record removed"
  assert_present "$case_dir/wt" "private-nm-agent-stuck: task copy removed"
  assert_grep "REFUSED: no-mistakes launch agent $label (rooted in task-x1's copy) is still loaded" "$case_dir/stderr" \
    "private-nm-agent-stuck: refusal does not name the agent"
  pass "an agent that stays loaded after bootout stops teardown with its plist and the task copy intact"
}

# A plist left behind by a reboot or a manual bootout has no loaded service; it
# still brings the daemon back at next login, so it is archived too.
test_private_nm_launch_agent_not_loaded_is_archived() {
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
  expect_code 0 "$rc" "private-nm-agent-unloaded: teardown should finish"
  for hash in 1 2 3 4 5 6 7; do
    label="$NM_AGENT_PREFIX.$hash"
    assert_absent "$case_dir/launchagents/$label.plist" "private-nm-agent-unloaded: plist still installed"
    assert_present "$case_dir/data/task-x1/launchagent-backup/$label.plist" \
      "private-nm-agent-unloaded: plist not archived"
  done
  pass "a private no-mistakes plist with no loaded service is still archived"
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
  fm_test_wait_until 60 test -e "$case_dir/kill-ready" \
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

test_earlier_preserved_copy_survives_until_its_replacement_is_verified() {
  local shape rc exclude hash dest real_cp
  real_cp=$(command -v cp)
  for shape in failed-copy replaced; do
    dead_launcher_pid
    make_own_locked_copy_case "own-backup-$shape" enclosing "$FOREIGN_DEAD_PID"
    exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
    printf 'unique.dat\n' >> "$exclude"
    printf 'only here\n' > "$FOREIGN_COPY/unique.dat"
    hash=$(printf '%s' "$(cd "$FOREIGN_COPY" && pwd -P)" | shasum -a 256 | awk '{print $1}')
    dest="$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$hash"
    mkdir -p "$dest"
    printf 'earlier backup\n' > "$dest/unique.dat"
    printf 'earlier manifest\n' > "$dest/SHA256SUMS"
    if [ "$shape" = failed-copy ]; then
      cat > "$FOREIGN_CASE/fakebin/cp" <<SH
#!/usr/bin/env bash
case " \$* " in
  *nested-copy-preserved*) echo "cp: simulated copy failure" >&2; exit 1 ;;
esac
exec "$real_cp" "\$@"
SH
      chmod +x "$FOREIGN_CASE/fakebin/cp"
    fi
    run_foreign_teardown rc
    if [ "$shape" = failed-copy ]; then
      expect_code 1 "$rc" "own-backup-$shape: a failed preserve must refuse: $(cat "$FOREIGN_CASE/stderr")"
      assert_present "$FOREIGN_COPY/unique.dat" "own-backup-$shape: the own copy's ignored file was lost"
      assert_equals "earlier backup" "$(cat "$dest/unique.dat")" "own-backup-$shape: the earlier preserved copy was destroyed by a failed replacement"
      assert_equals "earlier manifest" "$(cat "$dest/SHA256SUMS")" "own-backup-$shape: the earlier manifest was destroyed by a failed replacement"
    else
      expect_code 0 "$rc" "own-backup-$shape: a verified replacement must release the copy: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals "only here" "$(cat "$dest/unique.dat")" "own-backup-$shape: the earlier preserved copy was not replaced"
      assert_grep "$(shasum -a 256 "$dest/unique.dat" | awk '{print $1}')  unique.dat" "$dest/SHA256SUMS" \
        "own-backup-$shape: the manifest does not describe the replacement"
    fi
  done
  pass "an earlier preserved copy of a locked own copy survives a failed replacement and is replaced only by a verified one"
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
  if [ "\$calls" = 2 ]; then
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
    assert_grep "did not release foreign copy $FOREIGN_COPY (exit 127)" "$FOREIGN_CASE/stderr" \
      "missing-$shape: the refusal did not report the unavailable driver"
    assert_grep "is not available" "$FOREIGN_CASE/stderr" "missing-$shape: the refusal did not say what was missing"
    assert_foreign_copy_untouched "missing-$shape"
  done
  pass "a Vernant-locked copy refuses and stays when its closeout driver or interpreter is missing"
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
  sums="$(dirname "$preserved")/SHA256SUMS"
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

teardown_test_cases=(
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
test_mismatched_run_after_abort_refuses_unconfirmed
test_empty_status_after_abort_refuses_unconfirmed
test_not_found_status_after_abort_confirms_completion
test_another_branchs_parked_run_is_never_touched
test_top_level_pipeline_discovery_failures_remain_best_effort
test_own_autonomous_run_is_left_alone
test_leaked_worktree_process_is_reaped
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
test_process_spawned_during_grace_is_reaped_on_later_pass
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
test_process_in_foreign_copy_keeps_it
test_task_own_process_inside_foreign_copy_is_ended_and_released
test_two_foreign_copies_are_released_together_or_not_at_all
test_foreign_copy_nested_in_another_is_removed_first
test_foreign_copy_is_released_before_the_project_lock_wait
test_closeout_uses_the_slots_default_interpreter
test_missing_closeout_driver_or_interpreter_leaves_the_copy_in_place
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
test_private_nm_launch_agent_is_retired_before_teardown
test_private_nm_launch_agent_equivalent_roots_are_retired
test_foreign_nm_launch_agents_are_left_alone
test_nested_nm_launch_agents_are_left_alone
test_absent_copy_nm_launch_agents_preserve_nested_ownership
test_private_nm_launch_agent_bootout_failure_refuses
test_private_nm_launch_agent_not_loaded_is_archived
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
test_docker_project_record_failure_prevents_container_removal
test_docker_verified_cleanup_clears_retained_projects
test_docker_ambiguous_ids_trust_only_worktree_evidence
test_docker_all_failure_channels_retain_forced_tasks_until_retry
test_forced_secondmate_cleans_each_child_docker_before_retirement_and_retries
test_forced_orca_children_clean_docker_before_worktree_removal
test_forced_nested_secondmate_cleans_grandchild_docker_before_retirement_and_retries
test_docker_container_arriving_during_resource_cleanup_blocks_retirement
test_teardown_retires_the_dsh_launch_state
)

# Validate the complete selection before running any behavioral case.
for requested_case in "$@"; do
  registered_case=false
  for test_case in "${teardown_test_cases[@]}"; do
    if [ "$requested_case" = "$test_case" ]; then
      registered_case=true
      break
    fi
  done
  if [ "$registered_case" = false ]; then
    printf 'Unknown test case: %s\n' "$requested_case" >&2
    printf 'Usage: bash tests/fm-teardown-cleanup.test.sh [test_function_name ...]\n' >&2
    exit 2
  fi
done

# In the combined tests/fm-teardown.test.sh run,
# test_local_only_fork_remote_allows left set -e in force for every case
# registered after it. test_local_only_force_overrides_unpushed
# is the first such case here, so restore that errexit state once before it.
errexit_restored=false
for test_case in "${teardown_test_cases[@]}"; do
  if [ "$errexit_restored" = false ] && [ "$test_case" = test_local_only_force_overrides_unpushed ]; then
    set -e
    errexit_restored=true
  fi
  if [ "$#" -eq 0 ]; then
    "$test_case"
    continue
  fi
  for requested_case in "$@"; do
    if [ "$requested_case" = "$test_case" ]; then
      "$test_case"
      break
    fi
  done
done
