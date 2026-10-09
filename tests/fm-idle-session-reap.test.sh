#!/usr/bin/env bash
# tests/fm-idle-session-reap.test.sh - bin/fm-idle-session-reap.sh.
#
# Drives the real sweep script against fixture homes with a recording stand-in
# for bin/fm-teardown.sh, and asserts what it selects and what it hands to
# teardown. The contract under test: only a finished, idle, landed task is
# offered to teardown; a parked or unsure task is reported with its reason and
# never touched; teardown is asked without --force and stays the authority; a
# refusal is remembered so it is not retried every pass.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_HOME

REAP="$ROOT/bin/fm-idle-session-reap.sh"
TMP_ROOT=$(fm_test_tmproot fm-idle-session-reap)
NOW=$(date +%s)
OLD=$((NOW - 7200))

STUB="$TMP_ROOT/teardown-stub.sh"
STUB_LOG="$TMP_ROOT/teardown-calls.log"
STUB_MODE_FILE="$TMP_ROOT/teardown-mode"
export STUB_LOG STUB_MODE_FILE
export ROOT
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
# Stand-in for bin/fm-teardown.sh: records how it was called, then behaves as
# the mode file says. A completed teardown removes the task's state records.
mode=$(cat "$STUB_MODE_FILE" 2>/dev/null || echo ok)
printf '%s|argc=%s|args=%s|home=%s\n' "$$" "$#" "$*" "${FM_HOME:-}" >> "$STUB_LOG"
case "$mode" in
  ok) rm -f "$FM_STATE_OVERRIDE/$1".*; exit 0 ;;
  refuse) echo "REFUSED: task $1 has work that has not landed" >&2; exit 1 ;;
  lease) echo "error: lease held" >&2; exit 6 ;;
  hang) exec sleep 30 ;;
  steer-race)
    if [ "$1" = a-first ]; then
      mkdir -p "$FM_STATE_OVERRIDE/b-next.inbox"
      printf 'new instruction\n' > "$FM_STATE_OVERRIDE/b-next.inbox/007.msg"
      rm -f "$FM_STATE_OVERRIDE/$1".*
    else
      exec "$ROOT/bin/fm-teardown.sh" "$@"
    fi
    ;;
esac
SH
chmod +x "$STUB"
export FM_IDLE_REAP_TEARDOWN_BIN="$STUB"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  printf '%s\n' "$home"
}

# mk_task <home> <id> <kind> <busy> <status-line>... [-- <extra meta line>...]
mk_task() {
  local home=$1 id=$2 kind=$3 busy=$4 line
  shift 4
  fm_write_meta "$home/state/$id.meta" "window=w:$id" "kind=$kind" "harness=claude" "backend=herdr"
  : > "$home/state/$id.status"
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    printf '%s\n' "$1" >> "$home/state/$id.status"
    shift
  done
  [ "${1:-}" != -- ] || shift
  for line in "$@"; do printf '%s\n' "$line" >> "$home/state/$id.meta"; done
  printf 'g1.1.1\n' > "$home/state/$id.busy-gen"
  case "$busy" in
    none) rm -f "$home/state/$id.busy-state" "$home/state/$id.busy-gen" ;;
    *) printf 'v1 gen=g1.1.1 seq=1 state=%s source=claude-hook event=Stop ts=%s\n' "$busy" "$NOW" > "$home/state/$id.busy-state" ;;
  esac
}

merge_marker() {  # <home> <id> <owner/repo> <number>
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\n%s\n%s\n' "$3" "$4" > "$1/state/$2.pr-poll-merge-notified"
  chmod 0600 "$1/state/$2.pr-poll-merge-notified"
  fm_touch_epoch "$OLD" "$1/state/$2.pr-poll-merge-notified"
}

scout_report() {  # <home> <id>
  mkdir -p "$1/data/$2"
  printf '# report\nfindings\n' > "$1/data/$2/report.md"
  fm_touch_epoch "$OLD" "$1/data/$2/report.md"
}

run_reap() {  # <home> <scan|reap>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$REAP" "$@"
}

row_class() {  # <scan-output> <id>
  local out=$1 id=$2 line
  while IFS= read -r line; do
    case "$line" in *$'\t'"$id"$'\t'*) printf '%s' "${line%%$'\t'*}"; return 0 ;; esac
  done <<EOF
$out
EOF
}

row_detail() {  # <scan-output> <id>
  local out=$1 id=$2 line
  while IFS= read -r line; do
    case "$line" in *$'\t'"$id"$'\t'*) printf '%s' "${line##*$'\t'}"; return 0 ;; esac
  done <<EOF
$out
EOF
}

expect_class() {  # <scan-output> <id> <class> <label>
  local got
  got=$(row_class "$1" "$2")
  [ "$got" = "$3" ] || fail "$4: expected class $3 for $2, got '${got:-none}' in:"$'\n'"$1"
}

calls() {
  if [ -f "$STUB_LOG" ]; then
    wc -l < "$STUB_LOG" | tr -d ' '
  else
    printf 0
  fi
}

calls_at_least() { [ "$(calls)" -ge "$1" ]; }

# --- selection -------------------------------------------------------------

test_selection_matrix() {
  local home out
  home=$(make_home select)
  PR=https://github.com/acme/widget/pull/41

  mk_task "$home" scout-ok scout idle "done [at=$OLD]: report written"
  scout_report "$home" scout-ok
  mk_task "$home" scout-fresh scout idle "done [at=$((NOW - 60))]: report written"
  scout_report "$home" scout-fresh
  mk_task "$home" scout-touched scout idle "done [at=$OLD]: report written"
  scout_report "$home" scout-touched
  touch "$home/data/scout-touched/report.md"
  mk_task "$home" scout-noreport scout idle "done [at=$OLD]: finished"
  mk_task "$home" scout-emptyreport scout idle "done [at=$OLD]: finished"
  mkdir -p "$home/data/scout-emptyreport" && : > "$home/data/scout-emptyreport/report.md"

  mk_task "$home" ship-merged ship idle "done [at=$OLD]: PR $PR checks green" -- "pr=$PR"
  merge_marker "$home" ship-merged acme/widget 41
  mk_task "$home" ship-otherpr ship idle "done [at=$OLD]: PR $PR checks green" -- "pr=$PR"
  merge_marker "$home" ship-otherpr acme/widget 99
  mk_task "$home" ship-open ship idle "done [at=$OLD]: PR $PR checks green" -- "pr=$PR"
  mk_task "$home" ship-nopr ship idle "done [at=$OLD]: committed on branch"

  mk_task "$home" ship-parked ship idle "done [at=$((OLD - 100))]: PR $PR" "paused [key=waiting-on-fix] [at=$OLD]: waiting for d7 to land the guard fix" -- "pr=$PR"
  merge_marker "$home" ship-parked acme/widget 41
  mk_task "$home" ship-blocked ship idle "blocked [at=$OLD]: credential missing"
  mk_task "$home" ship-decision ship idle "needs-decision [key=pick-one] [at=$OLD]: option a or b"
  mk_task "$home" ship-working ship idle "working [at=$OLD]: reading code"

  mk_task "$home" ship-busy ship busy "done [at=$OLD]: PR $PR checks green" -- "pr=$PR"
  merge_marker "$home" ship-busy acme/widget 41
  mk_task "$home" ship-unknown ship unknown "done [at=$OLD]: PR $PR checks green" -- "pr=$PR"
  merge_marker "$home" ship-unknown acme/widget 41
  mk_task "$home" ship-nobusy ship none "done [at=$OLD]: PR $PR checks green" -- "pr=$PR"
  merge_marker "$home" ship-nobusy acme/widget 41

  mk_task "$home" ship-steer ship idle "done [at=$OLD]: PR $PR checks green" -- "pr=$PR"
  merge_marker "$home" ship-steer acme/widget 41
  mkdir -p "$home/state/ship-steer.inbox" && printf 'please also update the docs\n' > "$home/state/ship-steer.inbox/007.msg"

  mk_task "$home" mate secondmate idle "done [at=$OLD]: child done"
  mk_task "$home" remote-ship ship idle "done [at=$OLD]: PR $PR" -- "pr=$PR" "remote_host=far"
  merge_marker "$home" remote-ship acme/widget 41

  out=$(run_reap "$home" scan) || fail "scan failed: $out"
  expect_class "$out" scout-ok reap "a finished scout with a report is reap-ready"
  expect_class "$out" scout-fresh wait-grace "a scout finished a minute ago waits out the grace"
  expect_class "$out" scout-touched wait-grace "a report edited a moment ago keeps the grace running"
  expect_class "$out" scout-noreport scout-noreport "a done scout without a report is not reaped"
  expect_class "$out" scout-emptyreport scout-noreport "an empty report is not a report"
  expect_class "$out" ship-merged reap "a done ship with its PR's merge marker is reap-ready"
  expect_class "$out" ship-otherpr awaiting-merge "a marker for a different PR does not prove this PR merged"
  expect_class "$out" ship-open awaiting-merge "a done ship with no merge marker waits for its merge"
  expect_class "$out" ship-nopr awaiting-pipeline "a done ship with no PR is still awaiting its pipeline"
  expect_class "$out" ship-parked parked "a ship whose newest event is a pause is parked even with a merge marker"
  expect_class "$out" ship-blocked parked "a blocked task is parked"
  expect_class "$out" ship-decision parked "a task awaiting a decision is parked"
  expect_class "$out" ship-working idle-unreported "an idle task that last reported working is flagged, never reaped"
  expect_class "$out" ship-busy active "a busy task is never reaped"
  expect_class "$out" ship-unknown active "an unknown busy state is never read as idle"
  expect_class "$out" ship-nobusy active "a task with no busy record is never read as idle"
  expect_class "$out" ship-steer steer-pending "an unhandled steering message keeps the task alive"
  expect_class "$out" mate secondmate "a persistent secondmate is never reaped"
  expect_class "$out" remote-ship remote "a remote task is left to its own host"
  case "$(row_detail "$out" ship-parked)" in
    *"waiting for d7 to land the guard fix"*) ;;
    *) fail "a parked task reports its pause reason: $(row_detail "$out" ship-parked)" ;;
  esac
  [ "$(calls)" = 0 ] || fail "scan must not run teardown"
  [ ! -e "$home/state/idle-sessions.report" ] || fail "scan must not publish the report file"
  pass "scan selects exactly the finished, idle, landed tasks and reports parked ones with their reason"
}

# --- reap ------------------------------------------------------------------

test_reap_asks_teardown_without_force() {
  local home out
  home=$(make_home reapcall)
  : > "$STUB_LOG"
  printf 'ok\n' > "$STUB_MODE_FILE"
  mk_task "$home" scout-one scout idle "done [at=$OLD]: report written"
  scout_report "$home" scout-one
  mk_task "$home" ship-parked ship idle "paused [at=$OLD]: waiting on captain"
  out=$(run_reap "$home" reap) || fail "reap failed: $out"
  [ "$(calls)" = 1 ] || fail "reap must run teardown once for the one reap-ready task (calls=$(calls))"
  case "$(cat "$STUB_LOG")" in
    *"|argc=1|args=scout-one|home=$home") ;;
    *) fail "teardown is asked for the task id alone, never --force: $(cat "$STUB_LOG")" ;;
  esac
  expect_class "$out" scout-one reaped "a completed teardown is reported reaped"
  expect_class "$out" ship-parked parked "a parked task stays parked and untouched"
  assert_present "$home/state/ship-parked.meta" "a parked task's records are untouched"
  assert_present "$home/state/idle-sessions.report" "reap publishes the report"
  assert_grep "paused: waiting on captain" "$home/state/idle-sessions.report" "the published report carries the pause reason"
  pass "reap hands only reap-ready tasks to teardown, by id, without --force, and publishes parked reasons"
}

test_budget_bounds_teardowns_per_pass() {
  local home out i
  home=$(make_home budget)
  : > "$STUB_LOG"
  printf 'ok\n' > "$STUB_MODE_FILE"
  for i in 1 2 3 4 5; do
    mk_task "$home" "scout-$i" scout idle "done [at=$OLD]: report written"
    scout_report "$home" "scout-$i"
  done
  out=$(FM_IDLE_REAP_BUDGET=50 run_reap "$home" reap) || fail "reap failed: $out"
  [ "$(calls)" = 3 ] || fail "fixed budget permits only three teardowns (calls=$(calls))"
  out=$(run_reap "$home" reap) || fail "second reap failed: $out"
  [ "$(calls)" = 5 ] || fail "the next pass finishes the remainder (calls=$(calls))"
  pass "the fixed three-task budget bounds each pass"
}

test_refusal_is_remembered_and_retried_on_change() {
  local home out long
  home=$(make_home refusal)
  : > "$STUB_LOG"
  printf 'refuse\n' > "$STUB_MODE_FILE"
  printf -v long '%0300d' 0
  mk_task "$home" scout-held scout idle "done [at=$OLD]: report"$'\t'"written $long"
  scout_report "$home" scout-held

  out=$(run_reap "$home" reap) || fail "reap failed: $out"
  expect_class "$out" scout-held teardown-refused "a refusal is reported, not an error"
  case "$(row_detail "$out" scout-held)" in *"has work that has not landed"*) ;; *) fail "refusal reason is kept: $(row_detail "$out" scout-held)" ;; esac
  assert_present "$home/state/.idle-reap/scout-held.refused" "the refusal is remembered"
  assert_present "$home/state/scout-held.meta" "a refused task keeps its records"
  [ "$(calls)" = 1 ] || fail "first pass asks teardown once"

  out=$(FM_IDLE_REAP_RETRY_SECS=0 run_reap "$home" reap) || fail "second reap failed: $out"
  [ "$(calls)" = 1 ] || fail "an unchanged refused task is not offered to teardown again (calls=$(calls))"
  expect_class "$out" scout-held refused "the standing refusal is reported with its reason"

  printf 'done [at=%s]: follow-up report written\n' "$OLD" >> "$home/state/scout-held.status"
  out=$(run_reap "$home" reap) || fail "third reap failed: $out"
  [ "$(calls)" = 2 ] || fail "a new status line lifts the memo and teardown is asked again (calls=$(calls))"

  # An aged memo is retried even if nothing changed.
  printf 'fm-idle-reap-refused-v1\n%s\n%s\nold reason\n' "$((NOW - 100000))" "$(tail -n 1 "$home/state/scout-held.status")" > "$home/state/.idle-reap/scout-held.refused"
  out=$(run_reap "$home" reap) || fail "fourth reap failed: $out"
  [ "$(calls)" = 3 ] || fail "a memo older than the retry interval is retried (calls=$(calls))"

  printf 'ok\n' > "$STUB_MODE_FILE"
  rm -f "$home/state/.idle-reap/scout-held.refused"
  out=$(run_reap "$home" reap) || fail "fifth reap failed: $out"
  expect_class "$out" scout-held reaped "once teardown agrees the task is reaped"
  assert_absent "$home/state/.idle-reap/scout-held.refused" "a completed teardown leaves no memo"
  pass "a teardown refusal is remembered, retried on a status change or after the retry interval, and cleared on success"
}

test_real_teardown_refusal_preserves_the_task() {
  local home out
  home=$(make_home realteardown)
  # A scout whose recorded endpoint cannot be proved its own: the real teardown
  # refuses before any destructive step, which is the contract the sweep leans on.
  mk_task "$home" scout-real scout idle "done [at=$OLD]: report written"
  scout_report "$home" scout-real
  fm_write_meta "$home/state/scout-real.meta" "window=w:x" "kind=scout" "harness=claude" "backend=tmux" \
    "worktree=$home/no-such-copy" "project=$home"
  out=$(FM_IDLE_REAP_TEARDOWN_BIN="$ROOT/bin/fm-teardown.sh" run_reap "$home" reap) || fail "reap failed: $out"
  expect_class "$out" scout-real teardown-refused "the real teardown refuses an endpoint it cannot prove"
  case "$(row_detail "$out" scout-real)" in
    REFUSED:*|error:*) ;;
    *) fail "the real refusal reason is kept verbatim: $(row_detail "$out" scout-real)" ;;
  esac
  assert_present "$home/state/scout-real.meta" "a refused teardown preserves the task record"
  assert_present "$home/state/scout-real.status" "a refused teardown preserves the status log"
  assert_present "$home/state/.idle-reap/scout-real.refused" "the real refusal is remembered"
  pass "the real fm-teardown.sh refuses without touching the task, and the sweep records why"
}

test_lease_refusal_is_transient() {
  local home out
  home=$(make_home lease)
  : > "$STUB_LOG"
  printf 'lease\n' > "$STUB_MODE_FILE"
  mk_task "$home" scout-leased scout idle "done [at=$OLD]: report written"
  scout_report "$home" scout-leased
  out=$(run_reap "$home" reap) || fail "reap failed: $out"
  expect_class "$out" scout-leased lease-skipped "a lease held by the other actor skips the task"
  assert_absent "$home/state/.idle-reap/scout-leased.refused" "a lease skip is transient and records nothing"
  out=$(run_reap "$home" reap) || fail "second reap failed: $out"
  [ "$(calls)" = 2 ] || fail "a leased task is offered again on the next pass (calls=$(calls))"
  pass "a lease refusal is skipped without a memo and retried next pass"
}


test_single_flight_lock() {
  local home out pid hung
  home=$(make_home lock)
  : > "$STUB_LOG"
  printf 'hang\n' > "$STUB_MODE_FILE"
  mk_task "$home" scout-lock scout idle "done [at=$OLD]: report written"
  scout_report "$home" scout-lock
  run_reap "$home" reap >/dev/null 2>&1 &
  pid=$!
  fm_test_wait_until 10 calls_at_least 1 || fail "first sweep never reached teardown"
  hung=$(cut -d'|' -f1 "$STUB_LOG" | head -n 1)
  out=$(run_reap "$home" reap) || fail "overlapping sweep failed: $out"
  [ "$(calls)" = 1 ] || fail "an overlapping sweep must not start another teardown (calls=$(calls))"
  [ -z "$out" ] || fail "an overlapping sweep exits quietly: $out"
  # The stub exec'd into its sleeper, so the logged pid is the hung teardown itself.
  kill "$hung" 2>/dev/null
  wait "$pid" 2>/dev/null
  pass "overlapping sweeps are single-flight"
}

test_stale_memo_is_pruned() {
  local home
  home=$(make_home prune)
  mkdir -p "$home/state/.idle-reap"
  printf 'fm-idle-reap-refused-v1\n%s\nx\ny\n' "$NOW" > "$home/state/.idle-reap/gone.refused"
  run_reap "$home" reap >/dev/null || fail "reap failed"
  assert_absent "$home/state/.idle-reap/gone.refused" "a memo for a task with no record is dropped"
  pass "refusal memos for retired tasks are pruned"
}

test_bad_usage() {
  local home out rc=0
  home=$(make_home usage)
  out=$(run_reap "$home" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown subcommand"
  pass "unknown subcommands exit 2"
}

test_unknown_times_and_fixed_grace() {
  local home out
  home=$(make_home times)
  mk_task "$home" unstamped scout idle "done: legacy event"
  scout_report "$home" unstamped
  mk_task "$home" fresh scout idle "done [at=$NOW]: just finished"
  scout_report "$home" fresh
  out=$(FM_IDLE_REAP_GRACE_SECS=0 run_reap "$home" scan) || fail "scan failed"
  expect_class "$out" unstamped wait-grace "an unstamped done event cannot borrow old evidence"
  expect_class "$out" fresh wait-grace "environment cannot remove the grace"
  out=$(
    . "$ROOT/bin/fm-idle-reap-lib.sh"
    fm_path_mtime() { return 1; }
    fm_idle_reap_terminal_age "done [at=$OLD]: finished" "$home/data/unstamped/report.md" "$NOW"
  )
  [ "$out" = 0 ] || fail "an unreadable evidence timestamp must not borrow the status timestamp"
  pass "both terminal timestamps must be known and the grace remains fixed"
}

test_canonical_forge_markers() {
  local home out id url provider host path
  home=$(make_home forges)
  for id in github gitlab gerrit; do
    case "$id" in
      github) url=https://github.com/acme/widget/pull/41; provider=github; host=github.com; path=acme/widget ;;
      gitlab) url=https://gitlab.example.com/acme/team/widget/-/merge_requests/41; provider=gitlab; host=gitlab.example.com; path=acme/team/widget ;;
      gerrit) url=https://review.example.com/c/acme/widget/+/41; provider=gerrit; host=review.example.com; path=acme/widget ;;
    esac
    mk_task "$home" "$id" ship idle "done [at=$OLD]: merged" -- "pr=$url"
    printf 'fm-pr-poll-merge-notified-v1\n%s\n%s\n%s\n41\n' "$provider" "$host" "$path" > "$home/state/$id.pr-poll-merge-notified"
    chmod 0600 "$home/state/$id.pr-poll-merge-notified"
    fm_touch_epoch "$OLD" "$home/state/$id.pr-poll-merge-notified"
  done
  out=$(run_reap "$home" scan) || fail "scan failed"
  for id in github gitlab gerrit; do expect_class "$out" "$id" reap "canonical $id marker accepted"; done
  printf 'extra\n' >> "$home/state/gerrit.pr-poll-merge-notified"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\nwrong.example.com\nacme/widget\n41\n' > "$home/state/github.pr-poll-merge-notified"
  out=$(run_reap "$home" scan) || fail "scan failed"
  expect_class "$out" gerrit awaiting-merge "trailing marker content is refused"
  expect_class "$out" github awaiting-merge "a wrong host cannot prove a merge"
  pass "canonical merge identities work across all supported forges"
}

test_semantic_idle_sources() {
  local home out ws root log
  home=$(make_home semantic)
  mk_task "$home" cursor scout none "done [at=$OLD]: report written" -- harness=cursor backend=tmux
  scout_report "$home" cursor
  ws="$home/cursor-workspace"; root="$home/cursor-projects"
  mkdir -p "$ws" "$root/project/agent-transcripts/conv"
  printf '{\n  "workspacePath": "%s",\n  "trustMethod": "cli-flag"\n}\n' "$ws" > "$root/project/.workspace-trusted"
  printf '{"role":"user"}\n{"type":"turn_ended","status":"success"}\n' > "$root/project/agent-transcripts/conv/conv.jsonl"
  printf 'projects_root=%s\nworkspace_root=%s\n' "$root" "$ws" > "$home/state/cursor.cursor-session"
  mk_task "$home" muse scout none "done [at=$OLD]: report written" -- harness=muse backend=tmux
  scout_report "$home" muse
  ws="$home/muse-workspace"; root="$home/muse-sessions"
  mkdir -p "$ws" "$root/2026/10/08/session"
  log="$root/2026/10/08/session/session.jsonl"
  printf '{"schema_version":1,"payload_type":"runtime.session.metadata","payload":{"kind":"metadata","record":{"workspace_root":"%s"}}}\n' "$ws" > "$log"
  printf '{"payload_type":"runtime.session","payload":{"kind":"run","run_id":"r1","event":{"kind":"started"}}}\n{"payload_type":"runtime.session","payload":{"kind":"run","run_id":"r1","event":{"kind":"terminal","terminal":"completed"}}}\n' >> "$log"
  printf 'sessions_root=%s\nworkspace_root=%s\n' "$root" "$ws" > "$home/state/muse.muse-session"
  mk_task "$home" mismatch scout idle "done [at=$OLD]: report written" -- harness=pi
  scout_report "$home" mismatch
  out=$(run_reap "$home" scan) || fail "scan failed"
  expect_class "$out" cursor reap "settled Cursor transcript proves idle without hook records"
  expect_class "$out" muse reap "settled Muse session proves idle without hook records"
  expect_class "$out" mismatch active "a foreign harness hook cannot prove idle"
  printf '{"role":"user"}\n' >> "$home/cursor-projects/project/agent-transcripts/conv/conv.jsonl"
  printf '{"payload_type":"runtime.session","payload":{"kind":"run","run_id":"r2","event":{"kind":"started"}}}\n' >> "$log"
  out=$(run_reap "$home" scan) || fail "scan failed"
  expect_class "$out" cursor active "a reopened Cursor turn is not reaped"
  expect_class "$out" muse active "a reopened Muse run is not reaped"
  pass "the sweep uses semantic harness classification and source trust"
}

test_captain_holds() {
  local home out rc=0
  home=$(make_home captain)
  mk_task "$home" held scout idle "done [at=$OLD]: report written"
  scout_report "$home" held
  FM_HOME="$home" TASKS_AXI_BACKEND=markdown "$ROOT/bin/fm-captain-hold.sh" hold held --title "Captain call" --reason "choose next action" --repo sample >/dev/null || fail "hold failed"
  out=$(TASKS_AXI_BACKEND=markdown run_reap "$home" scan) || fail "scan failed"
  expect_class "$out" held parked "durable captain hold overrides an old done event"
  out=$(FM_HOME="$home" TASKS_AXI_BACKEND=markdown FM_IDLE_REAP_ADMISSION=1 "$ROOT/bin/fm-teardown.sh" held 2>&1) || rc=$?
  expect_code 1 "$rc" "automatic teardown refuses a held task"
  case "$out" in *"automatic reap ineligible: parked: captain-held"*) ;; *) fail "hold must refuse at admission: $out" ;; esac
  assert_present "$home/state/held.meta" "held task remains"
  rm "$home/.tasks.toml"
  mkdir "$home/.tasks.toml"
  out=$(run_reap "$home" scan) || fail "scan failed"
  expect_class "$out" held parked "an inconclusive captain hold read fails closed"
  pass "durable and unreadable captain holds prevent automatic cleanup"
}

test_stale_selection_is_revalidated() {
  local home out
  home=$(make_home stale)
  : > "$STUB_LOG"
  printf 'steer-race\n' > "$STUB_MODE_FILE"
  mk_task "$home" a-first scout idle "done [at=$OLD]: report written"
  scout_report "$home" a-first
  mk_task "$home" b-next scout idle "done [at=$OLD]: report written"
  scout_report "$home" b-next
  out=$(run_reap "$home" reap) || fail "reap failed: $out"
  expect_class "$out" a-first reaped "the first eligible task completes"
  expect_class "$out" b-next teardown-refused "a steer arriving during earlier teardown stops later cleanup"
  case "$(row_detail "$out" b-next)" in *"automatic reap ineligible: steer-pending"*) ;; *) fail "stale selection must refuse at admission: $out" ;; esac
  assert_present "$home/state/b-next.meta" "newly steered task remains"
  assert_present "$home/state/b-next.inbox/007.msg" "new instruction remains"
  pass "locked automatic admission rejects eligibility made stale by an earlier teardown"
}

test_admission_reads_after_metadata_lock() {
  local home out pid lock rc=0
  home=$(make_home locked)
  mk_task "$home" worker scout idle "done [at=$OLD]: report written"
  scout_report "$home" worker
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    lock=$(fm_meta_lock_path "$home/state/worker.meta")
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    FM_HOME="$home" FM_IDLE_REAP_ADMISSION=1 "$ROOT/bin/fm-teardown.sh" worker > "$home/teardown.out" 2>&1 &
    pid=$!
    fm_test_wait_until 10 test -e "$home/state/.control-worker.lock" || { kill "$pid"; exit 1; }
    mkdir -p "$home/state/worker.inbox"
    printf 'instruction delivered while admission waits\n' > "$home/state/worker.inbox/007.msg"
    fm_lock_release "$lock"
    wait "$pid"
  ) || rc=$?
  expect_code 1 "$rc" "late instruction refuses teardown"
  # shellcheck disable=SC2031 # The parent fixture path is unchanged by the subshell.
  out=$(cat "$home/teardown.out")
  case "$out" in *"automatic reap ineligible: steer-pending"*) ;; *) fail "admission must read after acquiring metadata lock: $out" ;; esac
  # shellcheck disable=SC2031 # The parent fixture path is unchanged by the subshell.
  assert_present "$home/state/worker.meta" "task survives locked race"
  # shellcheck disable=SC2031 # The parent fixture path is unchanged by the subshell.
  assert_present "$home/state/worker.inbox/007.msg" "instruction survives locked race"
  pass "automatic admission observes inbox delivery before the metadata lock is released"
}
test_admission_rechecks_every_gate() {
  local home out gate expected rc
  for gate in kind remote busy status evidence grace refusal; do
    home=$(make_home "admission-$gate")
    mk_task "$home" worker scout idle "done [at=$OLD]: report written"
    scout_report "$home" worker
    out=$(run_reap "$home" scan) || fail "initial scan failed"
    expect_class "$out" worker reap "$gate task initially eligible"
    case "$gate" in
      kind) printf 'kind=secondmate\n' >> "$home/state/worker.meta"; expected=secondmate ;;
      remote) printf 'remote_host=elsewhere\n' >> "$home/state/worker.meta"; expected=remote ;;
      busy)
        printf 'v1 gen=g1.1.1 seq=2 state=busy source=claude-hook event=UserPromptSubmit ts=%s\n' "$NOW" > "$home/state/worker.busy-state"
        expected=active ;;
      status) printf 'paused [at=%s]: waiting\n' "$NOW" >> "$home/state/worker.status"; expected=parked ;;
      evidence) rm "$home/data/worker/report.md"; expected=scout-noreport ;;
      grace) touch "$home/data/worker/report.md"; expected=wait-grace ;;
      refusal)
        mkdir -p "$home/state/.idle-reap"
        printf 'fm-idle-reap-refused-v1\n%s\ndone [at=%s]: report written\nstill unlanded\n' "$NOW" "$OLD" > "$home/state/.idle-reap/worker.refused"
        expected=refused ;;
    esac
    rc=0
    out=$(FM_HOME="$home" FM_IDLE_REAP_ADMISSION=1 "$ROOT/bin/fm-teardown.sh" worker 2>&1) || rc=$?
    expect_code 1 "$rc" "$gate automatic admission refuses"
    case "$out" in *"automatic reap ineligible: $expected:"*) ;; *) fail "$gate was not revalidated: $out" ;; esac
    assert_present "$home/state/worker.meta" "$gate ineligible task remains"
  done
  home=$(make_home admission-ship)
  mk_task "$home" worker ship idle "done [at=$OLD]: merged" -- pr=https://github.com/acme/widget/pull/41
  merge_marker "$home" worker acme/widget 41
  out=$(run_reap "$home" scan) || fail "initial ship scan failed"
  expect_class "$out" worker reap "ship initially eligible"
  printf 'pr=https://github.com/acme/widget/pull/99\n' >> "$home/state/worker.meta"
  rc=0
  out=$(FM_HOME="$home" FM_IDLE_REAP_ADMISSION=1 "$ROOT/bin/fm-teardown.sh" worker 2>&1) || rc=$?
  expect_code 1 "$rc" "changed PR automatic admission refuses"
  case "$out" in *"automatic reap ineligible: awaiting-merge:"*) ;; *) fail "ship identity was not revalidated: $out" ;; esac
  assert_present "$home/state/worker.meta" "ship with changed PR remains"
  pass "automatic admission rechecks all selection gates for ships and scouts"
}

test_teardown_timeout_is_bounded() {
  local home out start end fakebin
  home=$(make_home timeout)
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = 600 ]; then
  exec /bin/sleep 1
fi
exec /bin/sleep "$@"
SH
  chmod +x "$fakebin/sleep"
  : > "$STUB_LOG"
  printf 'hang\n' > "$STUB_MODE_FILE"
  mk_task "$home" scout-slow scout idle "done [at=$OLD]: report written"
  scout_report "$home" scout-slow
  start=$(date +%s)
  out=$(PATH="$fakebin:$PATH" FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_IDLE_REAP_TEARDOWN_SECS=0 run_reap "$home" reap) || fail "reap failed: $out"
  end=$(date +%s)
  [ $((end - start)) -lt 20 ] || fail "a hung teardown was not cut at the accelerated bound"
  expect_class "$out" scout-slow teardown-timeout "the real timeout runner cuts a hung teardown"
  assert_present "$home/state/.idle-reap/scout-slow.refused" "a timeout is remembered"
  assert_present "$home/state/scout-slow.meta" "a timeout does not retire the task"
  pass "the fixed teardown timeout cuts a hung command and records its refusal"
}

test_selection_matrix
test_reap_asks_teardown_without_force
test_budget_bounds_teardowns_per_pass
test_refusal_is_remembered_and_retried_on_change
test_real_teardown_refusal_preserves_the_task
test_lease_refusal_is_transient
test_unknown_times_and_fixed_grace
test_canonical_forge_markers
test_semantic_idle_sources
test_captain_holds
test_stale_selection_is_revalidated
test_admission_reads_after_metadata_lock
test_admission_rechecks_every_gate
test_teardown_timeout_is_bounded
test_single_flight_lock
test_stale_memo_is_pruned
test_bad_usage
