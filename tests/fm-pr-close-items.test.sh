#!/usr/bin/env bash
# Close at merge: bin/fm-pr-merge.sh closes the backlog items a merged pull request
# names with `Closes-backlog-item: <item-id>` lines, a merge train's members' items too, and a
# finished item stops blocking the items that waited on it.
#
# bin/fm-pr-close-items.sh owns the close contract and bin/fm-pr-closes-lib.sh owns the
# directive lines (`Closes-backlog-item:` and `Train-member:`). Every case runs the real tasks-axi against
# the case's own fixture backlog through the real bin/fm-pr-merge.sh, with forge fakes
# from tests/fm-pr-merge-helpers.sh. No case reads or writes a live backlog.
# Shared fixtures: tests/fm-pr-merge-helpers.sh.

# shellcheck source=tests/fm-pr-merge-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pr-merge-helpers.sh"

REPO_URL=https://github.com/example/repo/pull
WRAPPER_SH="$ROOT/bin/fm-tasks-axi.sh"
CLOSE_SH="$ROOT/bin/fm-pr-close-items.sh"

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed)\n'
  exit 0
}

cx() {  # <case-dir> <tasks-axi args...>
  local case_dir=$1
  shift
  (cd "$case_dir/home" && tasks-axi "$@")
}

cx_add() {  # <case-dir> <id> [kind]
  cx "$1" add "$2" "item $2" --kind "${3:-ship}" >/dev/null || fail "fixture: could not add $2"
}

cx_state() {  # <case-dir> <id>
  cx "$1" show "$2" 2>&1 | sed -n 's/^  state: *//p' | head -1
}

cx_deps() {  # <case-dir> <id>
  cx "$1" show "$2" 2>&1 | sed -n 's/^  deps: *//p' | head -1
}

cx_meta() {  # <case-dir> <id> <kind> [pr-url]
  local case_dir=$1 id=$2 kind=$3 pr=${4:-}
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=fm-$id" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=$kind" \
    "model=gpt-5.1-codex" "branch=fm/$id" "mode=no-mistakes" ${pr:+"pr=$pr"}
}

# CLOSE_PRUNE=on runs the merge with production merge prune left at its default (on), against
# a teardown that is busy (it refuses and exits non-zero), so the self-naming case defers.
# Any other value keeps the shared harness default, FM_MERGE_PRUNE=0.
merge_call() {  # <case-dir> <run_pr_merge args...>
  local case_dir=$1 stub
  if [ "${CLOSE_PRUNE:-off}" = on ]; then
    stub="$case_dir/teardown-stub"
    if [ ! -x "$stub" ]; then
      # shellcheck disable=SC2016 # The stub's own text is single-quoted on purpose.
      printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\necho "refused: the worker is busy" >&2\nexit 1\n' "$case_dir/teardown-calls" > "$stub"
      chmod +x "$stub"
    fi
    ( unset FM_MERGE_PRUNE; FM_MERGE_PRUNE_TEARDOWN_BIN="$stub" run_pr_merge "$@" )
  else
    run_pr_merge "$@"
  fi
}

# A merge fixture for the GitHub path: PR <number> is the merged pull request, and every
# PR listed in $case_dir/merged-prs counts as merged for the completion proof.
gh_case() {  # <name> <number>
  local case_dir
  case_dir=$(make_case "$1-${CLOSE_PRUNE:-off}")
  mkdir -p "$case_dir/wt" "$case_dir/bodies"
  add_gh_mocks "$case_dir" "$(printf '%040d' "$2")"
  : > "$case_dir/gh-axi.log"
  printf '%s\n' "$2" > "$case_dir/merged-prs"
  printf '%s\n' "$case_dir"
}

gh_merge() {  # <case-dir> <number> [merge args...]; the merge must succeed
  local case_dir=$1 number=$2 rc=0
  shift 2
  merge_call "$case_dir" task-x1 "$REPO_URL/$number" "$@" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ -z "${CLOSE_DEBUG:-}" ] || { printf '%s\n' '--- stdout' >&2; cat "$case_dir/stdout" >&2; printf '%s\n' '--- stderr' >&2; cat "$case_dir/stderr" >&2; }
  expect_code 0 "$rc" "close-at-merge: the merge itself must succeed"
}

# assert_match <extended-regex> <file> <message>: the pattern must match a line.
assert_match() {
  grep -E -- "$1" "$2" >/dev/null || fail "$3"
}

backlog_text() {  # <case-dir>
  cat "$1/home/data/backlog.md"
}

test_closes_lines_close_each_eligible_item_and_report_the_rest() {
  local case_dir url
  case_dir=$(gh_case c1-github 61)
  url=$REPO_URL/61
  cx_add "$case_dir" fm-fixture-alpha-1
  cx_add "$case_dir" fm-fixture-beta-2
  cx_add "$case_dir" ship-a
  cx_add "$case_dir" fm-fixture-live-3
  cx_add "$case_dir" docs-live-4 docs
  cx_add "$case_dir" docs-twin docs
  cx_add "$case_dir" fm-fixture-prose-5
  cx_add "$case_dir" fm-fixture-legacy-6
  cx_meta "$case_dir" fm-fixture-live-3 ship
  cx "$case_dir" start fm-fixture-live-3 >/dev/null || fail "c1: could not start the live ship row In flight"
  [ "$(cx_state "$case_dir" fm-fixture-live-3)" = in_flight ] || fail "c1: the live ship row is not In flight"
  cx_meta "$case_dir" docs-live-4 docs
  cx_meta "$case_dir" docs-twin docs
  # shellcheck disable=SC2016 # Backticks in the fixture body are literal Markdown.
  printf '%s\n' 'Fixes things; fm-fixture-prose-5 is related.' '' \
    'Closes-backlog-item: fm-fixture-alpha-1' 'Closes-backlog-item: fm-fixture-beta-2' 'Closes-backlog-item: fm-fixture-live-3' \
    'Closes-backlog-item: ship-a' 'Closes-backlog-item: docs-live-4' 'Closes-backlog-item: ship-a' \
    'Mentions Closes-backlog-item: fm-fixture-prose-5 inline.' 'closes: fm-fixture-prose-5' \
    '  Closes-backlog-item: fm-fixture-prose-5' 'Closes-backlog-item: fm-fixture-prose-5 # comment' \
    'Closes: fm-fixture-legacy-6' > "$case_dir/bodies/61"

  gh_merge "$case_dir" 61
  [ "$(cx_state "$case_dir" fm-fixture-alpha-1)" = "done" ] || fail "c1: alpha was not closed"
  [ "$(cx_state "$case_dir" fm-fixture-beta-2)" = "done" ] || fail "c1: beta was not closed"
  [ "$(cx_state "$case_dir" ship-a)" = "done" ] || fail "c1: ship-a (no fm- prefix) was not closed"
  assert_grep "closed fm-fixture-alpha-1 with $url" "$case_dir/stdout" "c1: alpha's close was not reported"
  assert_grep "$url" "$case_dir/home/data/backlog.md" "c1: the merged PR URL is not on the closed items"
  [ "$(cx_state "$case_dir" fm-fixture-live-3)" = in_flight ] || fail "c1: a ship item with a live record left In flight or was closed"
  assert_match "^actionable: close-at-merge: not closed fm-fixture-live-3: bin/fm-tasks-axi.sh done did not close it: .*live task record" "$case_dir/stderr" \
    "c1: another task's live item was not reported as actionable with its reason"
  [ "$(cx_state "$case_dir" fm-fixture-prose-5)" != "done" ] || fail "c1: a line that is not a Closes directive closed an item"
  [ "$(cx_state "$case_dir" fm-fixture-legacy-6)" != "done" ] || fail "c1: the old Closes: line closed an item"
  assert_match "^actionable: close-at-merge: not closed fm-fixture-legacy-6: .*Closes: line, which closes nothing; write 'Closes-backlog-item: fm-fixture-legacy-6'" "$case_dir/stderr" \
    "c1: the old form was not reported with the new form named"
  assert_match '^actionable: close-at-merge: ignored a malformed directive line in the body of .*: Closes-backlog-item: fm-fixture-prose-5 # comment' "$case_dir/stderr" \
    "c1: the malformed directive line was not reported"
  assert_match "^actionable: close-at-merge: mentioned fm-fixture-prose-5 in the prose of $url: nothing was closed for it" "$case_dir/stderr" \
    "c1: an id mentioned in prose was not reported"
  [ "$(grep -c 'mentioned fm-fixture-prose-5' "$case_dir/stderr")" = 1 ] || fail "c1: a prose mention was reported more than once"
  # The non-ship item with a live record gets exactly what the unchanged completion path gives.
  [ "$(cx_state "$case_dir" docs-live-4)" = "done" ] || fail "c1: docs-live-4 did not get the completion path's outcome"
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "done" docs-twin --pr "$url" >/dev/null 2>&1 \
    || fail "c1: the unchanged path refused the docs twin"
  [ "$(cx_state "$case_dir" docs-twin)" = "done" ] || fail "c1: the unchanged path left the docs twin open"
  assert_grep '4 closed, 3 left open' "$case_dir/stdout" "c1: summary line missing"
  pass "a merge closes each named eligible item with the merged PR URL and reports the one it left open"
}

test_a_merge_naming_its_own_task_reports_the_live_record() {
  local case_dir
  case_dir=$(gh_case c1-self 62)
  cx_add "$case_dir" task-x1
  printf '%s\n' 'Closes-backlog-item: task-x1' > "$case_dir/bodies/62"
  gh_merge "$case_dir" 62
  [ "$(cx_state "$case_dir" task-x1)" != "done" ] || fail "c1-self: the merging task was closed before its teardown"
  assert_match '^close-at-merge: not closed task-x1: .*live task record' "$case_dir/stdout" "c1-self: the live-record refusal was not reported by id"
  assert_no_grep 'not closed task-x1' "$case_dir/stderr" "c1-self: the merged task's own teardown case was reported as actionable"
  pass "a merge that names its own task reports the live-record refusal and still succeeds"
}

test_no_directive_line_changes_no_item_and_prose_mentions_close_nothing() {
  local case_dir
  case_dir=$(gh_case c1-none 63)
  cx_add "$case_dir" other-item
  cx_add "$case_dir" quiet-item
  printf '%s\n' "Related to $REPO_URL/9, which says Closes-backlog-item: other-item in prose." > "$case_dir/bodies/63"
  printf '%s\n' 'Closes-backlog-item: other-item' > "$case_dir/bodies/9"
  printf '%s\n' 9 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 63
  [ "$(cx_state "$case_dir" other-item)" = queued ] || fail "c1-none: an item changed without a directive line"
  [ "$(cx_state "$case_dir" quiet-item)" = queued ] || fail "c1-none: an unnamed item changed"
  assert_no_grep 'close-at-merge:' "$case_dir/stdout" "c1-none: the close step closed or counted something without a directive"
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/9 in the prose of $REPO_URL/63: no item was closed for it" "$case_dir/stderr" \
    "c1-none: a linked PR in prose was not reported"
  assert_match "^actionable: close-at-merge: mentioned other-item in the prose of $REPO_URL/63: nothing was closed for it" "$case_dir/stderr" \
    "c1-none: an id in prose was not reported"
  assert_no_grep 'quiet-item' "$case_dir/stderr" "c1-none: an id the body never mentions was reported"
  pass "a body with no directive line closes nothing and reports each id and pull request it mentions in prose"
}

test_a_prose_mention_of_the_merging_task_is_not_reported_and_another_id_is() {
  local case_dir
  case_dir=$(gh_case c1-self-prose 87)
  cx_add "$case_dir" task-x1
  cx_add "$case_dir" other-prose-item
  printf '%s\n' 'This finishes task-x1 and relates to other-prose-item.' > "$case_dir/bodies/87"
  gh_merge "$case_dir" 87
  [ "$(cx_state "$case_dir" task-x1)" != "done" ] || fail "c1-self-prose: a prose mention closed the merging task"
  assert_no_grep 'mentioned task-x1' "$case_dir/stderr" "c1-self-prose: the merging task's own id was reported as a mention"
  assert_match "^actionable: close-at-merge: mentioned other-prose-item in the prose of $REPO_URL/87: nothing was closed for it" "$case_dir/stderr" \
    "c1-self-prose: another id in prose was not reported"
  pass "a prose mention of the merging task prints no mention line, and another prose id still prints one"
}

test_an_old_form_line_naming_the_merging_task_is_left_to_its_teardown() {
  local case_dir
  case_dir=$(gh_case c1-self-old 93)
  printf '%s\n' 'Closes: task-x1' 'Closes: other-old' > "$case_dir/bodies/93"
  gh_merge "$case_dir" 93
  assert_match '^close-at-merge: the body of .* names the merging task task-x1 with a Closes: line, which closes nothing; its own teardown closes it' "$case_dir/stdout" \
    "c1-self-old: the merging task's old line was not reported on stdout"
  assert_no_grep 'not closed task-x1' "$case_dir/stderr" "c1-self-old: the merging task's old line was reported as actionable"
  assert_match "^actionable: close-at-merge: not closed other-old: .*Closes: line, which closes nothing" "$case_dir/stderr" \
    "c1-self-old: another old-form id was not reported as actionable"
  assert_grep 'close-at-merge: 0 closed, 1 left open' "$case_dir/stdout" "c1-self-old: the merging task's old line was counted as left open"
  pass "an old Closes: line naming the merging task is left to its teardown, uncounted, while another old line is still actionable"
}

test_an_old_form_line_never_blocks_another_source_for_the_same_id() {
  local case_dir base=$REPO_URL
  case_dir=$(gh_case c2-old-a 94)
  cx_add "$case_dir" a-item docs
  cx_meta "$case_dir" a-item docs "$base/71"
  printf '%s\n' "Train-member: $base/71" > "$case_dir/bodies/94"
  printf '%s\n' 'Closes: a-item' > "$case_dir/bodies/71"
  gh_merge "$case_dir" 94
  [ "$(cx_state "$case_dir" a-item)" = "done" ] || fail "c2-old-a: a member's old line kept the task that holds its URL open"
  assert_no_grep 'not closed a-item' "$case_dir/stderr" "c2-old-a: an id another source closed was reported as an old line"

  case_dir=$(gh_case c2-old-b 95)
  cx_add "$case_dir" b-item
  printf '%s\n' 'Closes: b-item' "Train-member: $base/72" > "$case_dir/bodies/95"
  printf '%s\n' 'Closes-backlog-item: b-item' > "$case_dir/bodies/72"
  gh_merge "$case_dir" 95
  [ "$(cx_state "$case_dir" b-item)" = "done" ] || fail "c2-old-b: the train's old line kept a member's named item open"
  assert_no_grep 'not closed b-item' "$case_dir/stderr" "c2-old-b: an id a member closed was reported as an old line"
  pass "an old Closes: line never stops a directive or a task record from closing the same id"
}

test_an_unrecorded_merge_closes_nothing_and_lists_the_named_items() {
  local case_dir rc=0
  case_dir=$(gh_case c1-unrecorded 64)
  cx_add "$case_dir" unrecorded-a
  printf '%s\n' 'Closes-backlog-item: unrecorded-a' > "$case_dir/bodies/64"
  # A secondmate home with no readable parent binding cannot place the outcome.
  : > "$case_dir/home/.fm-secondmate-home"
  merge_call "$case_dir" task-x1 "$REPO_URL/64" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "c1-unrecorded: today's merge result must not change"
  assert_match 'merged .* but could not report it upward' "$case_dir/stderr" "c1-unrecorded: today's message changed"
  [ "$(cx_state "$case_dir" unrecorded-a)" = queued ] || fail "c1-unrecorded: an item closed though the merge was not recorded"
  assert_match 'not closed unrecorded-a: the merge of .* was not recorded' "$case_dir/stderr" \
    "c1-unrecorded: the named item was not listed as not closed"
  pass "a merge whose outcome cannot be recorded runs no close and lists the named items"
}

test_a_merge_the_watcher_recorded_first_still_closes_without_a_second_notice() {
  local case_dir queue_before queue_after
  case_dir=$(gh_case c1-watcher 65)
  cx_add "$case_dir" watcher-a
  printf '%s\n' 'Closes-backlog-item: watcher-a' > "$case_dir/bodies/65"
  # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
  ( . "$ROOT/bin/fm-pr-lib.sh"; fm_pr_poll_merge_mark_notified "$case_dir/state" task-x1 github github.com example/repo 65 ) \
    || fail "c1-watcher: could not mark the merge as already notified"
  queue_before=$(cat "$case_dir/state/.wake-queue" 2>/dev/null | wc -l)
  gh_merge "$case_dir" 65
  queue_after=$(cat "$case_dir/state/.wake-queue" 2>/dev/null | wc -l)
  [ "$(cx_state "$case_dir" watcher-a)" = "done" ] || fail "c1-watcher: the named item was not closed"
  [ "$queue_before" = "$queue_after" ] || fail "c1-watcher: a duplicate merge notice was sent"
  pass "a merge the watcher already recorded still closes its items and sends no second notice"
}

test_an_unreadable_body_is_reported_with_the_url_and_the_error() {
  local case_dir
  case_dir=$(gh_case c1-unreadable 66)
  : > "$case_dir/bodies/unreadable-66"
  gh_merge "$case_dir" 66
  assert_grep "could not read the body of $REPO_URL/66 (HTTP 502: bad gateway)" "$case_dir/stderr" \
    "c1-unreadable: the output does not name the PR URL and the read error"
  pass "an unreadable merged body leaves the merge unchanged and names the URL and the error"
}

# One mixed backlog in the order the contract lists it; the valid item comes last.
test_every_failure_kind_is_reported_and_the_valid_item_still_closes() {
  local case_dir bin_dir
  case_dir=$(gh_case c3-matrix 67)
  cx_add "$case_dir" archived-one
  cx "$case_dir" "done" archived-one --note finished --keep 0 >/dev/null
  cx_add "$case_dir" done-already
  cx "$case_dir" "done" done-already --note finished >/dev/null
  cx_add "$case_dir" a-scout scout
  cx_add "$case_dir" held-ship
  cx "$case_dir" hold held-ship --reason "owner decides" --kind captain >/dev/null
  cx_add "$case_dir" call-open captain
  cx "$case_dir" hold call-open --reason "owner decides" --kind captain >/dev/null
  cx_add "$case_dir" call-released captain
  cx "$case_dir" hold call-released --reason "owner decides" --kind captain >/dev/null
  cx "$case_dir" unhold call-released >/dev/null
  cx_add "$case_dir" call-expired captain
  cx "$case_dir" hold call-expired --reason "owner decides" --kind captain --until 2020-01-01 >/dev/null
  cx_add "$case_dir" call-reheld captain
  cx "$case_dir" hold call-reheld --reason "owner decides" --kind captain >/dev/null
  cx "$case_dir" unhold call-reheld >/dev/null
  cx "$case_dir" hold call-reheld --reason "owner decides again" --kind captain >/dev/null
  cx_add "$case_dir" read-fails-once captain
  cx "$case_dir" hold read-fails-once --reason "owner decides" --kind captain >/dev/null
  cx_add "$case_dir" valid-last
  printf '%s\n' 'Closes-backlog-item: no-such-item' 'Closes-backlog-item: done-already' 'Closes-backlog-item: a-scout' 'Closes-backlog-item: held-ship' \
    'Closes-backlog-item: call-open' 'Closes-backlog-item: call-released' 'Closes-backlog-item: call-expired' 'Closes-backlog-item: call-reheld' \
    'Closes-backlog-item: archived-one' 'Closes-backlog-item: absent-one' 'Closes-backlog-item: read-fails-once' 'Closes-backlog-item: valid-last' > "$case_dir/bodies/67"
  # The first read of one held row fails once.
  bin_dir=$case_dir/fakebin
  cat > "$bin_dir/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ "\${2:-}" = read-fails-once ] && [ ! -e "$case_dir/read-failed" ]; then
  : > "$case_dir/read-failed"
  echo "error: simulated read failure" >&2
  exit 1
fi
exec "$(command -v tasks-axi)" "\$@"
SH
  chmod +x "$bin_dir/tasks-axi"
  gh_merge "$case_dir" 67
  [ "$(cx_state "$case_dir" valid-last)" = "done" ] || fail "c3: failures stopped the valid item"
  [ "$(cx_state "$case_dir" call-released)" = "done" ] || fail "c3: a released call was treated as open"
  [ "$(cx_state "$case_dir" no-such-item)" != "done" ] || fail "c3: an unknown id was created"
  assert_no_grep '^- no-such-item\|no-such-item' "$case_dir/home/data/backlog.md" "c3: an unknown id was created"
  for id in call-open call-expired call-reheld held-ship read-fails-once a-scout; do
    [ "$(cx_state "$case_dir" "$id")" != "done" ] || fail "c3: $id was closed"
  done
  assert_grep 'not closed no-such-item: unknown id' "$case_dir/stderr" "c3: unknown id not reported"
  assert_grep 'done-already is already done' "$case_dir/stdout" "c3: finished item not reported"
  assert_grep 'not closed a-scout: bin/fm-tasks-axi.sh done did not close it' "$case_dir/stderr" "c3: scout refusal not reported"
  assert_match 'not closed held-ship: .*owner call' "$case_dir/stderr" "c3: held ship not reported as an open owner call"
  assert_grep 'not closed call-open: it is an open owner call' "$case_dir/stderr" "c3: open call not reported"
  assert_grep 'not closed call-expired: it is an open owner call' "$case_dir/stderr" "c3: expired-unanswered call closed or hidden"
  assert_grep 'not closed call-reheld: it is an open owner call' "$case_dir/stderr" "c3: re-held call not reported"
  assert_match 'not closed archived-one: unknown id.*active backlog' "$case_dir/stderr" "c3: archived id not reported"
  assert_grep 'not closed absent-one: unknown id' "$case_dir/stderr" "c3: absent id not reported"
  assert_grep 'not closed read-fails-once: the item could not be read (error: simulated read failure)' "$case_dir/stderr" \
    "c3: the failed hold read was not reported by id"
  pass "each failure kind is reported with its reason, none stops the next item, and holds win"
}

test_a_hold_placed_after_the_last_look_still_wins() {
  local case_dir bin_dir
  case_dir=$(gh_case c3-interleave 68)
  cx_add "$case_dir" late-hold captain
  printf '%s\n' 'Closes-backlog-item: late-hold' > "$case_dir/bodies/68"
  bin_dir=$case_dir/fakebin
  # The hold commits right after the close step's own look at the row says "unheld".
  cat > "$bin_dir/tasks-axi" <<SH
#!/usr/bin/env bash
real="$(command -v tasks-axi)"
if [ "\${1:-}" = show ] && [ "\${2:-}" = late-hold ] && [ ! -e "$case_dir/hold-placed" ]; then
  out=\$("\$real" "\$@"); rc=\$?
  : > "$case_dir/hold-placed"
  "\$real" hold late-hold --reason "owner decides late" --kind captain >/dev/null 2>&1
  printf '%s\n' "\$out"
  exit \$rc
fi
exec "\$real" "\$@"
SH
  chmod +x "$bin_dir/tasks-axi"
  gh_merge "$case_dir" 68
  [ -e "$case_dir/hold-placed" ] || fail "c3-interleave: the interleaving did not happen"
  [ "$(cx_state "$case_dir" late-hold)" != "done" ] || fail "c3-interleave: a hold placed before the close lost to it"
  assert_match 'not closed late-hold: .*owner call' "$case_dir/stderr" "c3-interleave: the late hold was not reported"
  pass "a hold placed after the close step's last look is caught inside the completion lock"
}

test_a_rerun_closes_nothing_twice() {
  local case_dir before after rc=0
  case_dir=$(gh_case c3-rerun 69)
  cx_add "$case_dir" rerun-a
  printf '%s\n' 'Closes-backlog-item: rerun-a' > "$case_dir/bodies/69"
  gh_merge "$case_dir" 69
  [ "$(cx_state "$case_dir" rerun-a)" = "done" ] || fail "c3-rerun: the first run did not close the item"
  before=$(backlog_text "$case_dir")
  # With the task record still present, then after normal prune removed it.
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" PATH="$case_dir/fakebin:$PATH" \
    FM_TEST_GH_BODIES="$case_dir/bodies" FM_TEST_GH_MERGED_PRS="$case_dir/merged-prs" FM_TEST_GH_LOG="$case_dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" "$CLOSE_SH" task-x1 "$REPO_URL/69" > "$case_dir/rerun1" 2>&1 || rc=$?
  after=$(backlog_text "$case_dir")
  [ "$before" = "$after" ] || fail "c3-rerun: a rerun changed the backlog"
  assert_grep 'rerun-a is already done' "$case_dir/rerun1" "c3-rerun: the repeat did not say the item is done"
  rm -f "$case_dir/state/task-x1.meta"
  rc=0
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" PATH="$case_dir/fakebin:$PATH" \
    FM_TEST_GH_BODIES="$case_dir/bodies" FM_TEST_GH_MERGED_PRS="$case_dir/merged-prs" FM_TEST_GH_LOG="$case_dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" "$CLOSE_SH" task-x1 "$REPO_URL/69" > "$case_dir/rerun2" 2>&1 || rc=$?
  after=$(backlog_text "$case_dir")
  [ "$before" = "$after" ] || fail "c3-rerun: a rerun after prune changed the backlog"
  [ "$(grep -c "$REPO_URL/69" "$case_dir/home/data/backlog.md")" -le 2 ] || fail "c3-rerun: a second proof link was written"
  pass "a repeat of the close step changes nothing, with the task record present and after it is gone"
}

test_a_rerun_after_a_partial_close_closes_only_the_rest() {
  local case_dir bin_dir before_a rc=0
  case_dir=$(gh_case c3-partial 70)
  cx_add "$case_dir" partial-a
  cx_add "$case_dir" partial-b
  printf '%s\n' 'Closes-backlog-item: partial-a' 'Closes-backlog-item: partial-b' > "$case_dir/bodies/70"
  bin_dir=$case_dir/fakebin
  cat > "$bin_dir/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ "\${2:-}" = partial-b ] && [ ! -e "$case_dir/read-failed" ]; then
  : > "$case_dir/read-failed"
  echo "error: simulated read failure" >&2
  exit 1
fi
exec "$(command -v tasks-axi)" "\$@"
SH
  chmod +x "$bin_dir/tasks-axi"
  gh_merge "$case_dir" 70
  [ "$(cx_state "$case_dir" partial-a)" = "done" ] || fail "c3-partial: the first run did not close partial-a"
  [ "$(cx_state "$case_dir" partial-b)" != "done" ] || fail "c3-partial: the first run closed the item it could not read"
  assert_grep 'not closed partial-b: the item could not be read' "$case_dir/stderr" "c3-partial: the item left open was not reported"
  before_a=$(cx "$case_dir" show partial-a 2>&1)
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" PATH="$case_dir/fakebin:$PATH" \
    FM_TEST_GH_BODIES="$case_dir/bodies" FM_TEST_GH_MERGED_PRS="$case_dir/merged-prs" FM_TEST_GH_LOG="$case_dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" "$CLOSE_SH" task-x1 "$REPO_URL/70" > "$case_dir/rerun" 2>&1 || rc=$?
  expect_code 0 "$rc" "c3-partial: the rerun must close the rest"
  assert_grep 'partial-a is already done' "$case_dir/rerun" "c3-partial: the rerun did not say partial-a is done"
  [ "$before_a" = "$(cx "$case_dir" show partial-a 2>&1)" ] || fail "c3-partial: the rerun changed the item it had already closed"
  assert_grep "closed partial-b with $REPO_URL/70" "$case_dir/rerun" "c3-partial: the rerun did not close the rest"
  [ "$(grep -c '^close-at-merge: closed ' "$case_dir/rerun")" = 1 ] || fail "c3-partial: the rerun closed more than the rest"
  [ "$(cx_state "$case_dir" partial-b)" = "done" ] || fail "c3-partial: partial-b is still open after the rerun"
  pass "a rerun after a partial close only reports the closed item and closes the rest"
}

# A hand run with a pull request that is still open closes nothing, on every forge.
test_a_hand_run_with_an_open_pr_closes_nothing() {
  local case_dir before rc=0
  case_dir=$(gh_case c3-open-github 91)
  cx_add "$case_dir" open-gh-docs docs
  printf '%s\n' 'Closes-backlog-item: open-gh-docs' > "$case_dir/bodies/92"
  before=$(backlog_text "$case_dir")
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" PATH="$case_dir/fakebin:$PATH" \
    FM_TEST_GH_BODIES="$case_dir/bodies" FM_TEST_GH_MERGED_PRS="$case_dir/merged-prs" FM_TEST_GH_LOG="$case_dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" "$CLOSE_SH" task-x1 "$REPO_URL/92" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 3 "$rc" "c3-open-github: an open pull request must leave the item open"
  [ "$(cx_state "$case_dir" open-gh-docs)" = queued ] || fail "c3-open-github: an item closed on a pull request that is not merged"
  [ "$before" = "$(backlog_text "$case_dir")" ] || fail "c3-open-github: the backlog changed"
  assert_match "^actionable: close-at-merge: not closed open-gh-docs: $REPO_URL/92 is not merged" "$case_dir/stderr" \
    "c3-open-github: the item was not reported as left open because the pull request is not merged"

  rc=0
  case_dir=$(make_forgejo_case "c3-open-forgejo-${CLOSE_PRUNE:-off}")
  cx_add "$case_dir" open-fj-docs docs
  set_json_field "$case_dir/pr.json" body 'Closes-backlog-item: open-fj-docs'
  before=$(backlog_text "$case_dir")
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" PATH="$case_dir/fakebin:$PATH" \
    FM_TEST_TEA_LOG="$case_dir/tea.log" HOME="$case_dir/user-home" "$CLOSE_SH" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 3 "$rc" "c3-open-forgejo: an open pull request must leave the item open"
  [ "$(cx_state "$case_dir" open-fj-docs)" = queued ] || fail "c3-open-forgejo: an item closed on a pull request that is not merged"
  [ "$before" = "$(backlog_text "$case_dir")" ] || fail "c3-open-forgejo: the backlog changed"
  assert_match "^actionable: close-at-merge: not closed open-fj-docs: $FJ_URL is not merged" "$case_dir/stderr" \
    "c3-open-forgejo: the item was not reported as left open because the pull request is not merged"
  pass "a hand run with a pull request that is not merged closes nothing and reports each named item"
}

# --- trains -----------------------------------------------------------------

# train_body <layout> <excluded-url> <member-url>...
# Every body names its members with Train-member lines. The Markdown layouts the old reader
# understood stay in the body as decoration, and they must change nothing.
# shellcheck disable=SC2016 # Backticks in the fixture bodies are literal Markdown.
train_body() {
  local layout=$1 excluded=$2 member n=0
  shift 2
  printf '%s\n' '## Intent' '' "Context: see $excluded, which stays out of this train." '' '## Train' ''
  case "$layout" in
    url-first-table)
      printf '%s\n' '| Component | Unchanged component head | Train merge commit |' '| --- | --- | --- |'
      for member in "$@"; do printf '| %s | `aaaa` | `bbbb` |\n' "$member"; done ;;
    numbered-table)
      printf '%s\n' '| # | Component PR | Head merged | Merge commit |' '|---|---|---|---|'
      for member in "$@"; do n=$((n + 1)); printf '| %s | %s | `aaaa` | `bbbb` |\n' "$n" "$member"; done ;;
    labeled-bullets)
      for member in "$@"; do n=$((n + 1)); printf -- '- **Component %s:** %s at `aaaa`, merge commit `bbbb`.\n' "$n" "$member"; done ;;
    heading-bullets)
      printf '%s\n' '### Components and base' ''
      for member in "$@"; do printf -- '- %s at unchanged head `aaaa`.\n' "$member"; done ;;
    plain) ;;
  esac
  printf '%s\n' '' "Also see $excluded again." ''
  for member in "$@"; do printf 'Train-member: %s\n' "$member"; done
}

# The train fixture: four members, as the contract lists them.
#   m1 names a ship item; m2 is found only through a live ship task's pr=;
#   m3 is found only through a live docs task's pr=; m4 names nothing.
train_case() {  # <name> <layout> <train-number> [extra directive line for the train body]
  local name=$1 layout=$2 number=$3 case_dir base=$REPO_URL
  case_dir=$(gh_case "$name" "$number")
  cx_add "$case_dir" m1-item
  cx_add "$case_dir" m2-live-ship
  cx_add "$case_dir" m3-live-docs docs
  cx_add "$case_dir" excluded-item
  cx_add "$case_dir" train-own-item
  cx_meta "$case_dir" m2-live-ship ship "$base/72"
  cx_meta "$case_dir" m3-live-docs docs "$base/73"
  # A task whose pr= only shares a prefix or the number with a member does not match.
  cx_add "$case_dir" prefix-task
  cx_meta "$case_dir" prefix-task docs "$base/711"
  cx_add "$case_dir" bare-number-task docs
  cx_meta "$case_dir" bare-number-task docs "71"
  printf '%s\n' 'Closes-backlog-item: m1-item' > "$case_dir/bodies/71"
  printf '%s\n' 'Closes-backlog-item: excluded-item' > "$case_dir/bodies/90"
  printf '%s\n' 71 72 73 74 90 >> "$case_dir/merged-prs"
  {
    train_body "$layout" "$base/90" "$base/71" "$base/72" "$base/73" "$base/74"
    [ -z "${4:-}" ] || printf '%s\n' "$4"
  } > "$case_dir/bodies/$number"
  printf '%s\n' "$case_dir"
}

check_train_outcome() {  # <case-dir> <label> <train-url>
  local case_dir=$1 label=$2 train=$3
  [ "$(cx_state "$case_dir" m1-item)" = "done" ] || fail "$label: the member's own item was not closed"
  [ "$(cx_state "$case_dir" m3-live-docs)" = "done" ] || fail "$label: the docs task found through pr= was not closed"
  [ "$(cx_state "$case_dir" m2-live-ship)" != "done" ] || fail "$label: a live ship task was closed by the merge"
  assert_match "^actionable: close-at-merge: not closed m2-live-ship: .*live task record" "$case_dir/stderr" "$label: the member's live ship task was not reported as actionable"
  [ "$(cx_state "$case_dir" excluded-item)" = queued ] || fail "$label: a PR the body only mentions closed its item"
  [ "$(cx_state "$case_dir" prefix-task)" = queued ] || fail "$label: a pr= that shares only a prefix matched"
  [ "$(cx_state "$case_dir" bare-number-task)" = queued ] || fail "$label: a pr= that is only a number matched"
  assert_grep "closed m1-item with $train" "$case_dir/stdout" "$label: the proof is not the train URL"
  assert_grep "closed m3-live-docs with $train" "$case_dir/stdout" "$label: the pr= task's proof is not the train URL"
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/90 in the prose of $train: no item was closed for it" "$case_dir/stderr" "$label: the linked PR outside the block was not reported"
  assert_no_grep "mentioned $REPO_URL/7" "$case_dir/stderr" "$label: a Train-member line was reported as a mention"
}

test_a_train_closes_the_items_of_its_train_member_lines_whatever_else_the_body_holds() {
  local layout case_dir
  for layout in plain url-first-table numbered-table heading-bullets labeled-bullets; do
    case_dir=$(train_case "c2-$layout" "$layout" 80 'Closes-backlog-item: train-own-item')
    gh_merge "$case_dir" 80 --merge
    check_train_outcome "$case_dir" "c2-$layout" "$REPO_URL/80"
    [ "$(cx_state "$case_dir" train-own-item)" = "done" ] || fail "c2-$layout: the train's own directive line was ignored"
  done
  pass "a train closes its Train-member lines' items from bodies and from pr=, never an excluded PR's, whatever decorative layout the body also holds"
}

test_a_train_with_no_directive_of_its_own_still_closes_member_items() {
  local case_dir
  case_dir=$(train_case c2-no-own plain 81)
  gh_merge "$case_dir" 81
  check_train_outcome "$case_dir" c2-no-own "$REPO_URL/81"
  [ "$(cx_state "$case_dir" train-own-item)" = queued ] || fail "c2-no-own: an item nobody named closed"
  pass "a train body without its own Closes-backlog-item line still closes the members' items"
}

test_a_member_with_both_sources_and_an_unreadable_member() {
  local case_dir base=$REPO_URL
  case_dir=$(train_case c2-both plain 82)
  # m3's task is also named by m3's own body; m4's body cannot be read while a docs task holds m4's URL.
  cx_add "$case_dir" m4-docs docs
  cx_meta "$case_dir" m4-docs docs "$base/74"
  printf '%s\n' 'Closes-backlog-item: m1-item' 'Closes-backlog-item: m3-live-docs' > "$case_dir/bodies/71"
  : > "$case_dir/bodies/unreadable-74"
  gh_merge "$case_dir" 82
  [ "$(cx_state "$case_dir" m4-docs)" = "done" ] || fail "c2-both: the task behind an unreadable member was not closed"
  assert_grep "could not read the body of train member $base/74 (HTTP 502: bad gateway)" "$case_dir/stderr" \
    "c2-both: the read failure was not reported by member URL"
  [ "$(cx_state "$case_dir" m3-live-docs)" = "done" ] || fail "c2-both: the item named by both sources was not closed"
  pass "an unreadable member is reported by URL while the item behind its pr= still closes"
}

test_two_members_with_one_number_in_different_repos_match_by_full_url() {
  local case_dir
  case_dir=$(gh_case c2-same-number 83)
  cx_add "$case_dir" repo-a-task docs
  cx_add "$case_dir" repo-b-task docs
  cx_meta "$case_dir" repo-a-task docs "https://github.com/example/repo-a/pull/5"
  cx_meta "$case_dir" repo-b-task docs "https://github.com/example/repo-b/pull/5"
  printf '%s\n' 'Train-member: https://github.com/example/repo-a/pull/5' \
    'See https://github.com/example/repo-b/pull/5 for context.' > "$case_dir/bodies/83"
  gh_merge "$case_dir" 83
  [ "$(cx_state "$case_dir" repo-a-task)" = "done" ] || fail "c2-same-number: the matching member's task was not closed"
  [ "$(cx_state "$case_dir" repo-b-task)" = queued ] || fail "c2-same-number: a task with the same number in another repo matched"
  assert_match 'mentioned https://github.com/example/repo-b/pull/5 in the prose' "$case_dir/stderr" "c2-same-number: the other repository's link was not reported"
  pass "members match by the full URL, never by number"
}

test_a_train_member_value_that_is_no_pull_request_or_is_the_train_itself_is_reported() {
  local case_dir
  case_dir=$(gh_case c2-bad-member 84)
  cx_add "$case_dir" member-item
  printf '%s\n' 'Closes-backlog-item: member-item' > "$case_dir/bodies/71"
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  printf '%s\n' "Train-member: $REPO_URL/71" 'Train-member: https://example.com/not-a-pr' "Train-member: $REPO_URL/84" \
    "Train-member: $REPO_URL/71" > "$case_dir/bodies/84"
  gh_merge "$case_dir" 84
  [ "$(cx_state "$case_dir" member-item)" = "done" ] || fail "c2-bad-member: the valid member's item was not closed"
  assert_match 'could not use Train-member https://example.com/not-a-pr: it is not a GitHub, GitLab or Forgejo pull request URL' "$case_dir/stderr" \
    "c2-bad-member: a Train-member value that is no pull request was not reported"
  assert_match "ignored Train-member $REPO_URL/84: it is the merged pull request itself" "$case_dir/stderr" "c2-bad-member: the train naming itself was not reported"
  [ "$(grep -c "closed member-item" "$case_dir/stdout")" = 1 ] || fail "c2-bad-member: a repeated member closed twice"
  pass "a Train-member line that is no pull request URL, or is the train itself, is reported and the valid member still closes"
}

# --- other forges -----------------------------------------------------------

set_json_field() {  # <file> <field> <text>
  local tmp
  tmp=$(mktemp "$TMP_ROOT/json.XXXXXX")
  "$JQ_BIN" --arg v "$3" ".$2 = \$v" "$1" > "$tmp" && mv "$tmp" "$1"
}

test_a_gitlab_merge_reports_the_completion_paths_actual_result() {
  local case_dir url=$MR_URL train rc
  case_dir=$(make_gitlab_case "c1-gitlab-${CLOSE_PRUNE:-off}")
  cx_add "$case_dir" gl-ship
  cx_add "$case_dir" gl-docs docs
  cx_add "$case_dir" gl-member-docs docs
  cx_meta "$case_dir" gl-member-docs docs "$MR_PROJECT_URL/-/merge_requests/8"
  train=$MR_URL
  set_json_field "$case_dir/mr-post.json" description "$(printf '%s\n' "Train-member: $MR_PROJECT_URL/-/merge_requests/8" '' 'Closes-backlog-item: gl-ship' 'Closes-backlog-item: gl-docs')"
  rc=0
  merge_call "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ -z "${CLOSE_DEBUG:-}" ] || { cat "$case_dir/stdout" "$case_dir/stderr" >&2; cat "$case_dir/glab.log" >&2; }
  expect_code 0 "$rc" "c1-gitlab: the merge result must be the normal success"
  # tasks-axi accepts a pull request link only in the GitHub or Forgejo form, so the
  # completion path itself refuses a merge request URL for every kind; the text is its own.
  for id in gl-ship gl-docs gl-member-docs; do
    [ "$(cx_state "$case_dir" "$id")" != "done" ] || fail "c1-gitlab: $id closed on a merge request URL the path cannot take"
  done
  assert_match 'not closed gl-ship: bin/fm-tasks-axi.sh done did not close it: only a GitHub pull request' "$case_dir/stderr" \
    "c1-gitlab: the ship refusal was not reported"
  assert_match 'not closed gl-docs: bin/fm-tasks-axi.sh done did not close it: .*canonical pull request URL' "$case_dir/stderr" \
    "c1-gitlab: the non-ship refusal was not reported with the path's own text"
  assert_match 'not closed gl-member-docs: .*canonical pull request URL' "$case_dir/stderr" \
    "c1-gitlab: the member task's refusal was not reported"
  assert_grep "mr view 8 -R $MR_PROJECT_URL -F json" "$case_dir/glab.log" "c1-gitlab: the member was not read through glab"
  pass "a GitLab merge reports the completion path's actual result per item and still succeeds"
}

test_a_forgejo_merge_reports_the_completion_paths_actual_result() {
  local case_dir rc mode
  for mode in default merge; do
    case_dir=$(make_forgejo_case "c1-forgejo-$mode-${CLOSE_PRUNE:-off}")
    cx_add "$case_dir" fj-ship
    cx_add "$case_dir" fj-docs docs
    cx_add "$case_dir" fj-member-docs docs
    cx_add "$case_dir" fj-other-repo docs
    cx_meta "$case_dir" fj-member-docs docs "https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls/10"
    cx_meta "$case_dir" fj-other-repo docs "https://$FJ_HOST/$FJ_OWNER/other-repo/pulls/10"
    set_json_field "$case_dir/pr-post.json" body "$(printf '%s\n' "Train-member: https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls/10" '' 'Closes-backlog-item: fj-ship' 'Closes-backlog-item: fj-docs')"
    rc=0
    if [ "$mode" = merge ]; then
      merge_call "$case_dir" task-x1 "$FJ_URL" -- --merge > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      merge_call "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    expect_code 0 "$rc" "c1-forgejo-$mode: the merge result must be the normal success"
    [ "$(cx_state "$case_dir" fj-docs)" = "done" ] || fail "c1-forgejo-$mode: the non-ship item was not closed"
    [ "$(cx_state "$case_dir" fj-member-docs)" = "done" ] || fail "c1-forgejo-$mode: the member's pr= task was not closed"
    [ "$(cx_state "$case_dir" fj-other-repo)" = queued ] || fail "c1-forgejo-$mode: the same number in another repository matched"
    [ "$(cx_state "$case_dir" fj-ship)" != "done" ] || fail "c1-forgejo-$mode: a ship item closed on a proof the path cannot verify"
    assert_grep 'not closed fj-ship: bin/fm-tasks-axi.sh done did not close it' "$case_dir/stderr" "c1-forgejo-$mode: refusal not reported"
  done
  pass "a Forgejo merge reports the completion path's actual result per item and still succeeds"
}

test_a_gitlab_or_forgejo_merge_naming_its_own_task_reports_the_live_record() {
  local case_dir rc=0
  case_dir=$(make_forgejo_case "c1-self-forgejo-${CLOSE_PRUNE:-off}")
  cx_add "$case_dir" task-x1
  cx "$case_dir" start task-x1 >/dev/null || fail "c1-self-forgejo: could not start the merging task In flight"
  set_json_field "$case_dir/pr-post.json" body 'Closes-backlog-item: task-x1'
  merge_call "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "c1-self-forgejo: the merge must succeed"
  [ "$(cx_state "$case_dir" task-x1)" = in_flight ] || fail "c1-self-forgejo: the merging task left In flight before its teardown"
  assert_match '^close-at-merge: not closed task-x1: .*live task record' "$case_dir/stdout" "c1-self-forgejo: the live-record refusal was not reported by id"
  assert_no_grep 'not closed task-x1' "$case_dir/stderr" "c1-self-forgejo: the merged task's own teardown case was reported as actionable"

  rc=0
  case_dir=$(make_gitlab_case "c1-self-gitlab-${CLOSE_PRUNE:-off}")
  cx_add "$case_dir" task-x1
  cx "$case_dir" start task-x1 >/dev/null || fail "c1-self-gitlab: could not start the merging task In flight"
  set_json_field "$case_dir/mr-post.json" description 'Closes-backlog-item: task-x1'
  merge_call "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "c1-self-gitlab: the merge must succeed"
  [ "$(cx_state "$case_dir" task-x1)" = in_flight ] || fail "c1-self-gitlab: the merging task left In flight before its teardown"
  assert_match '^close-at-merge: not closed task-x1: .*live task record' "$case_dir/stdout" "c1-self-gitlab: the live-record refusal was not reported by id"
  pass "a GitLab or Forgejo merge that names its own In-flight task reports the live-record refusal and still succeeds"
}

# A Forgejo train: three members listed with Train-member lines (m1 names its item in its own
# body, m2 is found only through a task's pr=, m3 names nothing), a PR mentioned in prose only,
# and a task of another repository that shares a member's number. The member bodies come from
# the tea mock's per-PR records.
test_a_forgejo_train_closes_each_listed_member_source_and_reports_the_prose_link() {
  local case_dir rc=0 base="https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls" other="https://$FJ_HOST/$FJ_OWNER/other-repo/pulls" key
  case_dir=$(make_forgejo_case "c2-forgejo-train-${CLOSE_PRUNE:-off}")
  key=$FJ_OWNER"_"$FJ_REPO
  cx_add "$case_dir" fj-m1 docs
  cx_add "$case_dir" fj-m2 docs
  cx_add "$case_dir" fj-prose docs
  cx_add "$case_dir" fj-other-repo docs
  cx_meta "$case_dir" fj-m2 docs "$base/12"
  cx_meta "$case_dir" fj-other-repo docs "$other/11"
  printf '{"merged":true,"body":"Closes-backlog-item: fj-m1"}\n' > "$case_dir/tea-body-$key-11.json"
  printf '{"merged":true,"body":""}\n' > "$case_dir/tea-body-$key-12.json"
  printf '{"merged":true,"body":"No item here."}\n' > "$case_dir/tea-body-$key-13.json"
  printf '{"merged":true,"body":"Closes-backlog-item: fj-prose"}\n' > "$case_dir/tea-body-$key-14.json"
  set_json_field "$case_dir/pr-post.json" body "$(printf '%s\n' "Context: $base/14 stays out." '' \
    "Train-member: $base/11" "Train-member: $base/12" "Train-member: $base/13")"
  merge_call "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "c2-forgejo-train: the merge must succeed"
  [ "$(cx_state "$case_dir" fj-m1)" = "done" ] || fail "c2-forgejo-train: the item named in a member body was not closed"
  [ "$(cx_state "$case_dir" fj-m2)" = "done" ] || fail "c2-forgejo-train: the item behind a member's pr= was not closed"
  [ "$(cx_state "$case_dir" fj-prose)" = queued ] || fail "c2-forgejo-train: a PR named only in prose closed its item"
  [ "$(cx_state "$case_dir" fj-other-repo)" = queued ] || fail "c2-forgejo-train: the same number in another repository matched"
  assert_grep "closed fj-m1 with $FJ_URL" "$case_dir/stdout" "c2-forgejo-train: the train URL is not the proof"
  assert_match "^actionable: close-at-merge: mentioned $base/14 in the prose of $FJ_URL: no item was closed for it" "$case_dir/stderr" \
    "c2-forgejo-train: the prose link was not reported"
  for n in 11 12 13; do
    assert_grep "pulls/$n" "$case_dir/tea.log" "c2-forgejo-train: member $n was not read"
  done
  assert_no_grep "pulls/14" "$case_dir/tea.log" "c2-forgejo-train: a prose-only PR was read as a member"
  pass "a Forgejo train closes the items of its listed members from bodies and pr=, never a prose-only PR or another repository's number, and reports the prose link"
}

# The GitLab form of the same train. The completion path takes a merge request URL for no
# item kind, so each item is reported with the path's own refusal; what the test pins is the
# member set: three listed merge requests read, a prose-only merge request not read.
test_a_gitlab_train_reads_each_listed_member_and_reports_the_prose_link() {
  local case_dir rc=0 key base n
  base="$MR_PROJECT_URL/-/merge_requests"
  case_dir=$(make_gitlab_case "c2-gitlab-train-${CLOSE_PRUNE:-off}")
  key=${MR_PATH//\//_}
  cx_add "$case_dir" gl-m1 docs
  cx_add "$case_dir" gl-m2 docs
  cx_add "$case_dir" gl-prose docs
  cx_meta "$case_dir" gl-m2 docs "$base/22"
  printf '{"state":"merged","description":"Closes-backlog-item: gl-m1"}\n' > "$case_dir/mr-body-$key-21.json"
  printf '{"state":"merged","description":""}\n' > "$case_dir/mr-body-$key-22.json"
  printf '{"state":"merged","description":"No item here."}\n' > "$case_dir/mr-body-$key-23.json"
  printf '{"state":"merged","description":"Closes-backlog-item: gl-prose"}\n' > "$case_dir/mr-body-$key-24.json"
  set_json_field "$case_dir/mr-post.json" description "$(printf '%s\n' "Context: $base/24 stays out." '' \
    "Train-member: $base/21" "Train-member: $base/22" "Train-member: $base/23")"
  merge_call "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "c2-gitlab-train: the merge must succeed"
  assert_match 'not closed gl-m1: .*canonical pull request URL|not closed gl-m1: bin/fm-tasks-axi.sh done did not close it' "$case_dir/stderr" \
    "c2-gitlab-train: the item named in a member body was neither closed nor reported"
  assert_match 'not closed gl-m2: .*canonical pull request URL|not closed gl-m2: bin/fm-tasks-axi.sh done did not close it' "$case_dir/stderr" \
    "c2-gitlab-train: the item behind a member's pr= was neither closed nor reported"
  assert_no_grep 'gl-prose: bin/fm-tasks-axi.sh' "$case_dir/stderr" "c2-gitlab-train: a prose-only merge request reached the completion path"
  [ "$(cx_state "$case_dir" gl-prose)" = queued ] || fail "c2-gitlab-train: a merge request named only in prose closed its item"
  assert_match "^actionable: close-at-merge: mentioned $base/24 in the prose of $MR_URL: no item was closed for it" "$case_dir/stderr" \
    "c2-gitlab-train: the prose link was not reported"
  for n in 21 22 23; do
    assert_grep "mr view $n -R $MR_PROJECT_URL" "$case_dir/glab.log" "c2-gitlab-train: member $n was not read"
  done
  assert_no_grep "mr view 24 " "$case_dir/glab.log" "c2-gitlab-train: a prose-only merge request was read as a member"
  pass "a GitLab train reads each listed member, never a prose-only merge request, and reports the prose link"
}

# --- parser and blockers ----------------------------------------------------

test_a_dependent_id_the_list_prints_in_quotes_loses_its_edge() {
  local case_dir id
  case_dir=$(make_case c4-quoted)
  cx_add "$case_dir" quoted-blocker docs
  cx_add "$case_dir" other-blocker docs
  for id in 123 1.5 true; do
    cx_add "$case_dir" "$id"
    cx "$case_dir" block "$id" --by quoted-blocker >/dev/null
  done
  cx "$case_dir" block 123 --by other-blocker >/dev/null
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "done" quoted-blocker --note finished >/dev/null 2>"$case_dir/err"
  assert_no_grep 'actionable:' "$case_dir/err" "c4-quoted: a clear failed"
  assert_grep 'unblocked: 123 no longer waits on quoted-blocker; it still waits on other-blocker' "$case_dir/err" "c4-quoted: the plain id 123 was not reported"
  assert_grep 'unblocked: 1.5 no longer waits on quoted-blocker; no stored blocked-by edge remains' "$case_dir/err" "c4-quoted: the plain id 1.5 was not reported"
  assert_grep 'unblocked: true no longer waits on quoted-blocker; no stored blocked-by edge remains' "$case_dir/err" "c4-quoted: the plain id true was not reported"
  case "$(cx_deps "$case_dir" 123)" in *quoted-blocker*) fail "c4-quoted: 123 kept the finished edge" ;; *other-blocker*) ;; *) fail "c4-quoted: 123 lost its other blocker" ;; esac
  [ "$(cx_deps "$case_dir" 1.5)" = none ] || fail "c4-quoted: 1.5 kept an edge"
  [ "$(cx_deps "$case_dir" true)" = none ] || fail "c4-quoted: true kept an edge"
  pass "a dependent whose id the list prints in quotes still loses the finished edge"
}

lib_call() {  # <function> [args...]; the body comes on standard input
  bash -c '. "$1"; shift; "$@"' _ "$ROOT/bin/fm-pr-closes-lib.sh" "$@"
}

# shellcheck disable=SC2016 # Backticks in the fixture lines are literal Markdown.
test_the_directive_parser_reads_real_lines_and_ignores_every_example() {
  local out
  out=$(printf '%s\n' 'Closes-backlog-item: fm-backlog-close-at-merge' 'Closes-backlog-item: fm-backlog-finished-blocker-auto-clear' \
    'Closes-backlog-item: ship-a' 'Closes-backlog-item: a.b_c-1' 'Closes-backlog-item:   spaced-id   ' $'Closes-backlog-item: crlf-id\r' \
    'Closes-backlog-item: .hidden' 'Closes-backlog-item: two words' 'Closes-backlog-item: tail # comment' \
    'closes-backlog-item: lower' ' Closes-backlog-item: indented' '> Closes-backlog-item: quoted' '- Closes-backlog-item: listed' \
    '| Closes-backlog-item: cell |' 'Closes: old-form' \
    '```' 'Closes-backlog-item: fm-fixture-other' '```' '~~~' 'Closes-backlog-item: tilde-other' '~~~' \
    '   ```text' 'Closes-backlog-item: indented-fence' '   ```' \
    '````' 'Closes-backlog-item: long-fence' '```' 'Closes-backlog-item: short-close-still-fenced' '````' \
    '~~~' 'Closes-backlog-item: mixed-fence' '```' 'Closes-backlog-item: mixed-still-fenced' '~~~' \
    '``` has `tick`' 'Closes-backlog-item: info-with-tick-is-no-fence' \
    'Closes-backlog-item: ship-a' \
    | lib_call fm_pr_closes_ids -)
  [ "$out" = "$(printf '%s\n' fm-backlog-close-at-merge fm-backlog-finished-blocker-auto-clear ship-a a.b_c-1 spaced-id crlf-id info-with-tick-is-no-fence)" ] \
    || fail "parser: unexpected ids: $(printf '%s' "$out" | tr '\n' ' ')"
  out=$(printf '%s\n' 'Closes-backlog-item: unclosed' '```' 'Closes-backlog-item: never-closed' 'Closes-backlog-item: also-never' | lib_call fm_pr_closes_ids -)
  [ "$out" = unclosed ] || fail "parser: a fence that never closes did not run to the end: $out"
  out=$(printf '%s\n' $'\t```' 'Closes-backlog-item: after-tab' '```' 'Closes-backlog-item: tab-fenced' $'\t```' 'Closes-backlog-item: still-tab-fenced' \
    | lib_call fm_pr_closes_ids -)
  [ "$out" = after-tab ] || fail "parser: a tab-indented fence line opened or closed a fence: $(printf '%s' "$out" | tr '\n' ' ')"
  out=$(printf '%s\n' 'Train-member: https://github.com/a/b/pull/1' 'Train-member:  https://github.com/a/b/pull/2  ' 'Train-member: https://github.com/a/b/pull/1' \
    '  Train-member: https://github.com/a/b/pull/3' '| Train-member: https://github.com/a/b/pull/4 |' '   ```' 'Train-member: https://github.com/a/b/pull/5' '   ```' \
    | lib_call fm_pr_closes_members -)
  [ "$out" = "$(printf '%s\n' https://github.com/a/b/pull/1 https://github.com/a/b/pull/2)" ] || fail "parser: unexpected members: $(printf '%s' "$out" | tr '\n' ' ')"
  out=$(printf '%s\n' 'Closes-backlog-item: .hidden' 'Closes-backlog-item: two words' 'Closes-backlog-item:' 'Train-member: a b' 'Closes: x y' \
    'Closes-backlog-item: fine' 'Train-member: https://github.com/a/b/pull/1' 'Closes: old-form' '```' 'Closes-backlog-item: ' '```' | lib_call fm_pr_closes_malformed -)
  [ "$out" = "$(printf '%s\n' 'Closes-backlog-item: .hidden' 'Closes-backlog-item: two words' 'Closes-backlog-item:' 'Train-member: a b' 'Closes: x y')" ] \
    || fail "parser: unexpected malformed lines: $(printf '%s' "$out" | tr '\n' ' ')"
  pass "the parser takes the two directive forms, and reads no example, indented line, table cell, quote or malformed line as one"
}

test_completion_clears_the_finished_blocker_on_every_route() {
  local case_dir out deps
  wrapper() { FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "$@"; }
  case_dir=$(make_case c4-routes)
  cx_add "$case_dir" blocker-a docs
  cx_add "$case_dir" blocker-b docs
  cx_add "$case_dir" blocker-c docs
  cx_add "$case_dir" dep-x
  cx_add "$case_dir" dep-done
  cx_add "$case_dir" dep-y
  cx "$case_dir" block dep-x --by blocker-a >/dev/null
  cx "$case_dir" block dep-x --by blocker-b >/dev/null
  cx "$case_dir" block dep-done --by blocker-a >/dev/null
  cx "$case_dir" "done" dep-done --note x >/dev/null
  cx "$case_dir" block dep-y --by blocker-c >/dev/null
  cx "$case_dir" hold dep-y --reason "wait for a date" --kind future >/dev/null
  # Default retention, with --json: a retained Done dependent loses the edge too.
  out=$(wrapper "done" blocker-a --note finished --json 2>"$case_dir/err")
  [ -z "${CLOSE_DEBUG:-}" ] || { printf 'OUT<%s>\n' "$out" >&2; cat "$case_dir/err" >&2; }
  printf '%s' "$out" | "$JQ_BIN" -e '.task.id == "blocker-a" and .task.state == "done"' >/dev/null \
    || fail "c4: --json output is not valid JSON with the existing fields"
  deps=$(cx_deps "$case_dir" dep-x)
  case "$deps" in *blocker-a*) fail "c4: the finished edge stayed on dep-x ($deps)" ;; esac
  case "$deps" in *blocker-b*) ;; *) fail "c4: the second blocker's edge was lost ($deps)" ;; esac
  assert_grep 'unblocked: dep-x no longer waits on blocker-a; it still waits on blocker-b' "$case_dir/err" "c4: report missing for dep-x"
  assert_grep 'unblocked: dep-done no longer waits on blocker-a; no stored blocked-by edge remains' "$case_dir/err" "c4: retained Done dependent not cleared"
  case "$(cx_deps "$case_dir" dep-done)" in *blocker-a*) fail "c4: the retained Done dependent kept its edge" ;; esac
  # The second blocker later: its edge goes and the dependent reports no remaining edge.
  wrapper close blocker-b --note finished >/dev/null 2>"$case_dir/err2"
  assert_grep 'unblocked: dep-x no longer waits on blocker-b; no stored blocked-by edge remains' "$case_dir/err2" "c4: second blocker not reported"
  [ "$(cx_deps "$case_dir" dep-x)" = none ] || fail "c4: dep-x still has stored edges"
  # --keep 0 archives the blocker at once; the edge still goes, and the dependent's hold stays.
  wrapper "done" blocker-c --note finished --keep 0 >/dev/null 2>"$case_dir/err3"
  assert_grep 'unblocked: dep-y no longer waits on blocker-c; no stored blocked-by edge remains' "$case_dir/err3" "c4: --keep 0 edge not cleared"
  [ "$(cx_deps "$case_dir" dep-y)" = none ] || fail "c4: --keep 0 left an edge on dep-y"
  cx "$case_dir" show dep-y | grep -q 'hold_kind: future' || fail "c4: the dependent's hold was lost"
  # An unsuccessful completion removes nothing.
  cx_add "$case_dir" scout-blocker scout
  cx_add "$case_dir" dep-z
  cx "$case_dir" block dep-z --by scout-blocker >/dev/null
  wrapper "done" scout-blocker --note nope >/dev/null 2>&1 && fail "c4: a scout closed without a report"
  case "$(cx_deps "$case_dir" dep-z)" in *scout-blocker*) ;; *) fail "c4: a refused completion cleared an edge" ;; esac
  pass "completing a blocker clears its edge on every wrapper route, keeps other blockers and holds, and reports the dependents"
}

test_the_task_noun_forms_and_typed_completions_clear_the_edge() {
  local case_dir deps id
  command -v jq >/dev/null 2>&1 || { printf 'ok - skipped (jq is not installed)\n'; return 0; }
  case_dir=$(make_case c4-more-routes)
  wrapper() { FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "$@"; }
  for id in noun-done noun-close; do cx_add "$case_dir" "$id" docs; cx_add "$case_dir" "dep-of-$id"; cx "$case_dir" block "dep-of-$id" --by "$id" >/dev/null; done
  wrapper task "done" noun-done --note finished >/dev/null 2>"$case_dir/e1" || fail "c4-routes: task done failed"
  wrapper task close noun-close --note finished >/dev/null 2>"$case_dir/e2" || fail "c4-routes: task close failed"
  assert_grep 'unblocked: dep-of-noun-done no longer waits on noun-done' "$case_dir/e1" "c4-routes: the task done form did not clear"
  assert_grep 'unblocked: dep-of-noun-close no longer waits on noun-close' "$case_dir/e2" "c4-routes: the task close form did not clear"
  # A typed completion: waiving a public follow-up obligation finishes its row.
  jq -n '{request_id:"req-1", platform:"x", context_binding:{version:"ctx1", value:"ctx1_req-1"}, public_safe_summary:"s",
          received_at:"2026-07-30T10:00:00Z", followup_expires_at:"2026-08-06T10:00:00Z", reservation_expires_at:"2026-08-06T10:00:00Z"}' \
    > "$case_dir/request.json"
  jq -n '{type:"pr-merged", project:"alpha", required_deliverables:["pr_url"], completion_policy:"all-required"}' > "$case_dir/expected.json"
  wrapper public-followup add pf-1 --request-context-file "$case_dir/request.json" --purpose promised-final \
    --expected-final-file "$case_dir/expected.json" --expires-at 2026-10-01T00:00:00Z >/dev/null 2>&1 \
    || fail "c4-routes: could not create the obligation"
  cx_add "$case_dir" dep-of-pf
  cx "$case_dir" block dep-of-pf --by pf-1 >/dev/null
  wrapper public-followup waive pf-1 --reason "not needed" --approved-by captain >/dev/null 2>"$case_dir/e3" \
    || fail "c4-routes: the waive failed"
  assert_grep 'unblocked: dep-of-pf no longer waits on pf-1' "$case_dir/e3" "c4-routes: a waived obligation did not clear its dependents"
  deps=$(cx_deps "$case_dir" dep-of-pf)
  [ "$deps" = none ] || fail "c4-routes: the stored edge stayed after the waive ($deps)"
  pass "the task noun forms and a typed public-followup completion clear the finished edge"
}

test_a_typed_completion_that_archives_or_cannot_be_read_back() {
  local case_dir real bin_dir
  command -v jq >/dev/null 2>&1 || { printf 'ok - skipped (jq is not installed)\n'; return 0; }
  case_dir=$(make_case c4-pf-archive)
  wrapper() { FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "$@"; }
  jq -n '{request_id:"req-1", platform:"x", context_binding:{version:"ctx1", value:"ctx1_req-1"}, public_safe_summary:"s",
          received_at:"2026-07-30T10:00:00Z", followup_expires_at:"2026-08-06T10:00:00Z", reservation_expires_at:"2026-08-06T10:00:00Z"}' \
    > "$case_dir/request.json"
  jq -n '{type:"pr-merged", project:"alpha", required_deliverables:["pr_url"], completion_policy:"all-required"}' > "$case_dir/expected.json"
  sed 's/^done_keep = .*/done_keep = 0/' "$case_dir/home/.tasks.toml" > "$case_dir/tasks.toml"
  cat "$case_dir/tasks.toml" > "$case_dir/home/.tasks.toml"
  for id in pf-archived pf-unread; do
    wrapper public-followup add "$id" --request-context-file "$case_dir/request.json" --purpose promised-final \
      --expected-final-file "$case_dir/expected.json" --expires-at 2026-10-01T00:00:00Z >/dev/null 2>&1 \
      || fail "c4-pf: could not create $id"
    cx_add "$case_dir" "dep-of-$id"
    cx "$case_dir" block "dep-of-$id" --by "$id" >/dev/null
  done
  wrapper public-followup waive pf-archived --reason "not needed" --approved-by captain >/dev/null 2>"$case_dir/e1" \
    || fail "c4-pf: the waive failed"
  cx "$case_dir" show pf-archived 2>&1 | grep -q '^code: NOT_FOUND$' || fail "c4-pf: done_keep 0 did not archive the row"
  assert_grep 'unblocked: dep-of-pf-archived no longer waits on pf-archived' "$case_dir/e1" "c4-pf: an archived row did not clear its dependents"
  [ "$(cx_deps "$case_dir" dep-of-pf-archived)" = none ] || fail "c4-pf: the archived row's edge stayed"
  real=$(command -v tasks-axi)
  bin_dir=$case_dir/fakebin
  mkdir -p "$bin_dir"
  cat > "$bin_dir/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ "\${2:-}" = pf-unread ]; then
  echo "error: simulated read failure" >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$bin_dir/tasks-axi"
  PATH="$bin_dir:$PATH" wrapper public-followup waive pf-unread --reason "not needed" --approved-by captain >/dev/null 2>"$case_dir/e2" \
    || fail "c4-pf: a failed read back changed the waive's exit status"
  assert_match '^actionable: .*pf-unread.*simulated read failure.*--by pf-unread' "$case_dir/e2" "c4-pf: a failed read back was not reported as actionable"
  pass "a typed completion clears the edge when the row is archived at once and reports a failed read back"
}

test_a_typed_completion_help_call_reports_nothing_to_act_on() {
  local case_dir subcommand
  case_dir=$(make_case c4-pf-help)
  for subcommand in waive record-delivery; do
    FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" public-followup "$subcommand" --help \
      >/dev/null 2>"$case_dir/err-$subcommand" || fail "c4-pf-help: $subcommand --help failed"
    assert_no_grep 'actionable:' "$case_dir/err-$subcommand" "c4-pf-help: a $subcommand help call asked someone to act"
  done
  pass "a help call on a typed completion asks nobody to act"
}

test_a_merge_reports_each_cleared_edge_and_each_failed_clear_on_its_own_channel() {
  local case_dir real
  case_dir=$(gh_case c4-merge-edges 91)
  cx_add "$case_dir" edge-blocker
  cx_add "$case_dir" dep-clears
  cx_add "$case_dir" dep-fails
  cx "$case_dir" block dep-clears --by edge-blocker >/dev/null
  cx "$case_dir" block dep-fails --by edge-blocker >/dev/null
  printf '%s\n' 'Closes-backlog-item: edge-blocker' > "$case_dir/bodies/91"
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = unblock ] && [ "\${2:-}" = dep-fails ]; then
  echo "error: simulated unblock failure" >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
  gh_merge "$case_dir" 91
  [ "$(cx_state "$case_dir" edge-blocker)" = "done" ] || fail "c4-merge-edges: the named item was not closed"
  assert_match '^close-at-merge: unblocked: dep-clears no longer waits on edge-blocker' "$case_dir/stdout" \
    "c4-merge-edges: the cleared edge was not reported on stdout"
  assert_match '^actionable: close-at-merge: edge-blocker is done, but dep-fails could not be unblocked' "$case_dir/stderr" \
    "c4-merge-edges: the failed clear was not an actionable stderr line"
  assert_no_grep 'dep-fails could not be unblocked' "$case_dir/stdout" "c4-merge-edges: the failed clear reached stdout"
  pass "a merge reports a cleared edge on stdout and a failed clear behind actionable: on stderr"
}

test_an_answered_captain_call_clears_the_edge() {
  local case_dir home
  case_dir=$(make_case c4-captain)
  home=$case_dir/home
  cx_add "$case_dir" call-q captain
  cx_add "$case_dir" waits-on-call
  cx "$case_dir" hold call-q --reason "owner decides" --kind captain >/dev/null
  cx "$case_dir" block waits-on-call --by call-q >/dev/null
  printf '%s\n' 'Go ahead.' > "$case_dir/decision.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" answer call-q --decision-file "$case_dir/decision.md" > "$case_dir/ans.out" 2> "$case_dir/ans.err" \
    || { cat "$case_dir/ans.err" >&2; fail "c4-captain: the answer failed"; }
  [ "$(cx_state "$case_dir" call-q)" = "done" ] || fail "c4-captain: the answered call did not close"
  assert_grep 'unblocked: waits-on-call no longer waits on call-q' "$case_dir/ans.err" "c4-captain: the dependent was not reported"
  [ "$(cx_deps "$case_dir" waits-on-call)" = none ] || fail "c4-captain: the stored edge stayed"
  pass "answering a captain call clears the call's edge from its dependents"
}

test_a_withdrawn_captain_call_clears_the_edge() {
  local case_dir home
  case_dir=$(make_case c4-withdraw)
  home=$case_dir/home
  hold_env() { FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
  cx_add "$case_dir" call-w captain
  cx_add "$case_dir" ruling-r captain
  hold_env hold call-w --reason "owner decides" >/dev/null 2>&1 || fail "c4-withdraw: could not hold call-w"
  cx_add "$case_dir" waits-on-w
  cx "$case_dir" block waits-on-w --by call-w >/dev/null
  hold_env hold ruling-r --reason "owner rules on call-w" >/dev/null 2>&1 || fail "c4-withdraw: could not hold the ruling"
  printf '%s\n' 'The owner rules on call-w: proceed.' > "$case_dir/ruling.md"
  hold_env answer ruling-r --decision-file "$case_dir/ruling.md" >/dev/null 2>&1 || fail "c4-withdraw: could not record the ruling"
  printf '%s\n' 'The ruling answers this call.' > "$case_dir/evidence.md"
  hold_env withdraw call-w --evidence-file "$case_dir/evidence.md" --ruling ruling-r \
    > "$case_dir/w.out" 2> "$case_dir/w.err" || { cat "$case_dir/w.err" >&2; fail "c4-withdraw: the withdrawal failed"; }
  [ "$(cx_state "$case_dir" call-w)" = "done" ] || fail "c4-withdraw: the withdrawn call did not close"
  assert_grep 'unblocked: waits-on-w no longer waits on call-w' "$case_dir/w.err" "c4-withdraw: the dependent was not reported"
  pass "withdrawing a captain call clears the call's edge from its dependents"
}

test_an_explicit_data_root_gets_the_same_clear() {
  local case_dir alt
  case_dir=$(make_case c4-data-root)
  alt=$case_dir/elsewhere
  mkdir -p "$alt/data" "$alt/state"
  fm_test_tasks_toml "$alt/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$alt/data/backlog.md"
  (cd "$alt" && tasks-axi add alt-blocker "alt blocker" --kind docs >/dev/null && tasks-axi add alt-dep "alt dep" --kind ship >/dev/null \
    && tasks-axi block alt-dep --by alt-blocker >/dev/null) || fail "c4-data-root: fixture"
  FM_HOME="$alt" FM_DATA_OVERRIDE="$alt/data" FM_STATE_OVERRIDE="$alt/state" "$WRAPPER_SH" "done" alt-blocker --note finished \
    >/dev/null 2>"$case_dir/err" || { cat "$case_dir/err" >&2; fail "c4-data-root: the completion failed"; }
  assert_grep 'unblocked: alt-dep no longer waits on alt-blocker' "$case_dir/err" "c4-data-root: the dependent was not cleared under a data-root override"
  pass "an explicit data root gets the same blocker clear"
}

# --- review findings F1-F4 of the Markdown reader: each closes nothing now and reports ---------

test_f1_an_excluded_component_table_under_a_subheading_closes_nothing_and_is_reported() {
  local case_dir
  case_dir=$(gh_case c2-f1 80)
  cx_add "$case_dir" actually-landed
  cx_add "$case_dir" explicitly-excluded
  cx_add "$case_dir" waits-on-excluded
  cx "$case_dir" block waits-on-excluded --by explicitly-excluded >/dev/null
  printf '%s\n' 71 91 >> "$case_dir/merged-prs"
  printf '%s\n' 'Closes-backlog-item: actually-landed' > "$case_dir/bodies/71"
  printf '%s\n' 'Closes-backlog-item: explicitly-excluded' > "$case_dir/bodies/91"
  # The reviewer's shape: an exclusion heading, a subheading, then a Component table.
  # shellcheck disable=SC2016 # Backticks in the fixture rows are literal Markdown.
  printf '%s\n' '## Train' '| Component | Head |' '| --- | --- |' "| $REPO_URL/71 | \`a\` |" '' \
    '## Excluded Components' '### Details' '' '| Component | Reason |' '| --- | --- |' "| $REPO_URL/91 | excluded |" \
    > "$case_dir/bodies/80"
  gh_merge "$case_dir" 80
  [ "$(cx_state "$case_dir" actually-landed)" = queued ] || fail "f1: a Component table closed a member without a Train-member line"
  [ "$(cx_state "$case_dir" explicitly-excluded)" = queued ] || fail "f1: an excluded PR's item was closed"
  case "$(cx_deps "$case_dir" waits-on-excluded)" in *explicitly-excluded*) ;; *) fail "f1: an excluded item's dependency edge was cleared" ;; esac
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/91 in the prose of $REPO_URL/80: no item was closed for it" "$case_dir/stderr" "f1: the excluded link was not reported"
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/71 in the prose of $REPO_URL/80: no item was closed for it" "$case_dir/stderr" "f1: the unlisted legitimate link was not reported"
  assert_no_grep 'close-at-merge: closed' "$case_dir/stdout" "f1: something closed without a directive line"
  # Control: the same body with the legitimate member on a Train-member line closes it, and only it.
  printf '%s\n' "Train-member: $REPO_URL/71" >> "$case_dir/bodies/80"
  gh_merge "$case_dir" 80
  [ "$(cx_state "$case_dir" actually-landed)" = "done" ] || fail "f1 control: a Train-member line did not close the member's item"
  [ "$(cx_state "$case_dir" explicitly-excluded)" = queued ] || fail "f1 control: the excluded item closed"
  case "$(cx_deps "$case_dir" waits-on-excluded)" in *explicitly-excluded*) ;; *) fail "f1 control: the excluded item's edge was cleared" ;; esac
  pass "F1: an excluded descendant Component table closes nothing, keeps its item and edge, and is reported; a Train-member line closes the member"
}

test_f2_an_indented_fenced_example_closes_nothing() {
  local case_dir
  case_dir=$(gh_case c8-f2 80)
  cx_add "$case_dir" real-one
  cx_add "$case_dir" example-only
  cx_add "$case_dir" waits-on-example
  cx "$case_dir" block waits-on-example --by example-only >/dev/null
  printf '%s\n' 91 >> "$case_dir/merged-prs"
  printf '%s\n' 'Closes-backlog-item: member-example' > "$case_dir/bodies/91"
  # A fence indented three spaces is a valid CommonMark fence; its lines are examples.
  printf '%s\n' 'Closes-backlog-item: real-one' '' 'An example of the form:' '   ```' 'Closes-backlog-item: example-only' \
    "Train-member: $REPO_URL/91" '   ```' > "$case_dir/bodies/80"
  gh_merge "$case_dir" 80
  [ "$(cx_state "$case_dir" real-one)" = "done" ] || fail "f2: the real directive outside the block was not closed"
  [ "$(cx_state "$case_dir" example-only)" = queued ] || fail "f2: an indented fenced example closed an item"
  case "$(cx_deps "$case_dir" waits-on-example)" in *example-only*) ;; *) fail "f2: the example's dependent lost its edge" ;; esac
  assert_no_grep 'train member' "$case_dir/stdout" "f2: a fenced Train-member line was read"
  assert_no_grep "$REPO_URL/91" "$case_dir/stderr" "f2: a fenced example was reported as a mention"
  pass "F2: a fence indented three spaces keeps its Closes-backlog-item and Train-member lines examples, and the real directive still closes"
}

test_f3_a_component_table_with_a_negated_exclusion_heading_closes_nothing_without_a_member_line() {
  local case_dir
  case_dir=$(gh_case c2-f3 80)
  cx_add "$case_dir" included-item
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  printf '%s\n' 'Closes-backlog-item: included-item' > "$case_dir/bodies/71"
  # shellcheck disable=SC2016 # Backticks in the fixture row are literal Markdown.
  printf '%s\n' '## Components - none excluded' '' '| Component | Head |' '| --- | --- |' "| $REPO_URL/71 | \`a\` |" > "$case_dir/bodies/80"
  gh_merge "$case_dir" 80
  [ "$(cx_state "$case_dir" included-item)" = queued ] || fail "f3: a table without a Train-member line closed an item"
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/71 in the prose of $REPO_URL/80: no item was closed for it; list it as a Train-member: line" "$case_dir/stderr" \
    "f3: the unlisted member was silent"
  # Control: the Train-member line closes it, whatever the heading says.
  printf '%s\n' "Train-member: $REPO_URL/71" >> "$case_dir/bodies/80"
  gh_merge "$case_dir" 80
  [ "$(cx_state "$case_dir" included-item)" = "done" ] || fail "f3 control: the Train-member line did not close the member's item"
  pass "F3: a negated exclusion heading no longer decides anything; the unlisted member is reported and a Train-member line closes it"
}

test_f4_an_unlisted_forgejo_or_gitlab_member_is_reported_by_its_url() {
  local case_dir rc=0 member
  case_dir=$(make_forgejo_case "c2-f4-forgejo-${CLOSE_PRUNE:-off}")
  member="https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls/10"
  cx_add "$case_dir" fj-unlisted docs
  cx_meta "$case_dir" fj-unlisted docs "$member"
  set_json_field "$case_dir/pr-post.json" body "$(printf '%s\n' '| Component | Head |' '| --- | --- |' "| merged: $member | a |")"
  merge_call "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "f4-forgejo: the merge must succeed"
  [ "$(cx_state "$case_dir" fj-unlisted)" = queued ] || fail "f4-forgejo: an unlisted member's task closed"
  assert_match "^actionable: close-at-merge: mentioned $member in the prose of $FJ_URL: no item was closed for it" "$case_dir/stderr" "f4-forgejo: the unlisted member was silent"
  # Control: on a fresh merge, the Train-member line closes the task that records it.
  case_dir=$(make_forgejo_case "c2-f4-forgejo-control-${CLOSE_PRUNE:-off}")
  cx_add "$case_dir" fj-unlisted docs
  cx_meta "$case_dir" fj-unlisted docs "$member"
  set_json_field "$case_dir/pr-post.json" body "$(printf '%s\n' "Train-member: $member")"
  rc=0
  merge_call "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "f4-forgejo control: the merge must succeed"
  [ "$(cx_state "$case_dir" fj-unlisted)" = "done" ] || fail "f4-forgejo control: the Train-member line did not close the recorded task"

  case_dir=$(make_gitlab_case "c2-f4-gitlab-${CLOSE_PRUNE:-off}")
  member="$MR_PROJECT_URL/-/merge_requests/8"
  cx_add "$case_dir" gl-unlisted docs
  set_json_field "$case_dir/mr-post.json" description "$(printf '%s\n' '| Component | Head |' '| --- | --- |' "| merged: $member | a |")"
  rc=0
  merge_call "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "f4-gitlab: the merge must succeed"
  [ "$(cx_state "$case_dir" gl-unlisted)" = queued ] || fail "f4-gitlab: an unlisted member's task closed"
  assert_match "^actionable: close-at-merge: mentioned $member in the prose of $MR_URL: no item was closed for it" "$case_dir/stderr" "f4-gitlab: the unlisted member was silent"
  # Non-train negative: a body with no link names nothing.
  case_dir=$(make_forgejo_case "c2-f4-none-${CLOSE_PRUNE:-off}")
  set_json_field "$case_dir/pr-post.json" body "Plain change, nothing linked."
  rc=0
  merge_call "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "f4-none: the merge must succeed"
  assert_no_grep 'close-at-merge:' "$case_dir/stderr" "f4-none: a body that links nothing was reported"
  pass "F4: an unlisted Forgejo or GitLab member is reported by its URL and closes nothing; a Train-member line closes it; a plain body is silent"
}

fake_unlistable_backlog() {  # <case-dir>
  cat > "$1/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = list ]; then
  echo "error: simulated list failure" >&2
  exit 1
fi
exec "$(command -v tasks-axi)" "\$@"
SH
  chmod +x "$1/fakebin/tasks-axi"
}

test_a_merge_with_directive_lines_and_an_unlistable_backlog_says_so_once() {
  local case_dir
  case_dir=$(gh_case c1-unlistable-train 88)
  printf '%s\n' "Train-member: $REPO_URL/9" '' 'Notes mention some-other-id in prose.' > "$case_dir/bodies/88"
  printf '%s\n' 'This member names no item.' > "$case_dir/bodies/9"
  printf '%s\n' 9 >> "$case_dir/merged-prs"
  fake_unlistable_backlog "$case_dir"
  gh_merge "$case_dir" 88
  [ "$(grep -c 'could not list the backlog to check which ids the prose' "$case_dir/stderr")" = 1 ] || fail "c1-unlistable-train: a body with only a Train-member line did not report the failed id check once"

  case_dir=$(gh_case c1-unlistable-none 89)
  printf '%s\n' 'Notes mention some-other-id in prose.' > "$case_dir/bodies/89"
  fake_unlistable_backlog "$case_dir"
  gh_merge "$case_dir" 89
  assert_no_grep 'could not list the backlog' "$case_dir/stderr" "c1-unlistable-none: a body with no directive line reported the failed id check"

  case_dir=$(gh_case c1-unlistable 85)
  cx_add "$case_dir" unlistable-a
  printf '%s\n' 'Closes-backlog-item: unlistable-a' '' 'Notes mention some-other-id in prose.' > "$case_dir/bodies/85"
  fake_unlistable_backlog "$case_dir"
  gh_merge "$case_dir" 85
  [ "$(cx_state "$case_dir" unlistable-a)" = "done" ] || fail "c1-unlistable: the named item was not closed"
  [ "$(grep -c 'could not list the backlog to check which ids the prose' "$case_dir/stderr")" = 1 ] || fail "c1-unlistable: the failed id check was not reported exactly once"
  pass "a failed backlog listing reports the skipped id check once and still closes the named item"
}

# --- exact-head evidence with production merge prune on (contract C1, C3) ----------------

test_the_named_item_matrix_with_production_prune_on() {
  local CLOSE_PRUNE=on
  test_closes_lines_close_each_eligible_item_and_report_the_rest
  test_a_merge_naming_its_own_task_reports_the_live_record
  # The busy teardown was really asked (production prune ran), and the item stayed open.
  fm_test_wait_until --progress-file "$TMP_ROOT/c1-self-on/home/data/task-x1/merge-prune.log" -- test -s "$TMP_ROOT/c1-self-on/teardown-calls" \
    || fail "prune-on: the production prune never asked teardown for the merged task"
  [ "$(cx_state "$TMP_ROOT/c1-self-on" task-x1)" != "done" ] || fail "prune-on: the busy self-naming task closed"
  test_a_gitlab_merge_reports_the_completion_paths_actual_result
  test_a_forgejo_merge_reports_the_completion_paths_actual_result
  test_a_gitlab_or_forgejo_merge_naming_its_own_task_reports_the_live_record
  test_a_forgejo_train_closes_each_listed_member_source_and_reports_the_prose_link
  test_a_gitlab_train_reads_each_listed_member_and_reports_the_prose_link
  pass "with production merge prune on and a busy teardown, GitHub, GitLab and Forgejo merges close, report and defer as with prune off"
}

test_a_second_merge_run_changes_nothing_with_the_record_present_and_after_prune() {
  local CLOSE_PRUNE=on case_dir before after mode stub rc
  for mode in present removed; do
    case_dir=$(gh_case "c3-second-merge-$mode" 72)
    cx_add "$case_dir" second-a
    printf '%s\n' 'Closes-backlog-item: second-a' > "$case_dir/bodies/72"
    if [ "$mode" = removed ]; then
      # A teardown that succeeds and removes the task record, as normal prune does.
      stub="$case_dir/teardown-stub"
      # shellcheck disable=SC2016 # The stub's own text is single-quoted on purpose.
      printf '#!/usr/bin/env bash\nrm -f "%s/task-x1.meta"\nexit 0\n' "$case_dir/state" > "$stub"
      chmod +x "$stub"
    fi
    gh_merge "$case_dir" 72
    [ "$(cx_state "$case_dir" second-a)" = "done" ] || fail "c3-second-$mode: the first merge did not close the item"
    if [ "$mode" = removed ]; then
      fm_test_wait_until --progress-file "$case_dir/home/data/task-x1/merge-prune.log" -- test ! -e "$case_dir/state/task-x1.meta" \
        || fail "c3-second-$mode: prune never removed the task record"
    fi
    before=$(backlog_text "$case_dir")
    # The forge now reports the pull request merged, as it does for a real repeat: the second
    # run is against an already-merged PR, not against the pre-merge answer.
    "$JQ_BIN" '.state = "MERGED"' "$case_dir/github-view.json" > "$case_dir/github-view.merged" \
      && mv "$case_dir/github-view.merged" "$case_dir/github-view.json"
    rc=0
    merge_call "$case_dir" task-x1 "$REPO_URL/72" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
    # The script's own answer to a repeat: it refuses a merged PR, or a task whose record prune removed.
    [ "$rc" -ne 0 ] || fail "c3-second-$mode: the second run reported success on a merged PR"
    if [ "$mode" = removed ]; then
      assert_grep 'task metadata is unavailable' "$case_dir/stderr2" "c3-second-$mode: the second run gave no reason"
    else
      assert_grep 'state is "MERGED", not open' "$case_dir/stderr2" "c3-second-$mode: the second run gave no reason"
    fi
    after=$(backlog_text "$case_dir")
    assert_no_grep 'closed second-a' "$case_dir/stdout2" "c3-second-$mode: the second run closed the item again"
    [ "$before" = "$after" ] || fail "c3-second-$mode: the second merge run changed the backlog"
    [ "$(grep -c "$REPO_URL/72" "$case_dir/home/data/backlog.md")" -le 2 ] || fail "c3-second-$mode: a second proof link was written"
  done
  pass "a second bin/fm-pr-merge.sh run on the merged PR changes nothing, with the task record present and after prune removed it"
}

# --- completion routes at the wrapper boundary (contract C4) -------------------------------

test_the_typed_record_delivery_completion_clears_the_finished_edge() {
  local case_dir shim real
  case_dir=$(make_case c4-record-delivery)
  cx_add "$case_dir" pf-delivered docs
  cx_add "$case_dir" waits-on-delivery
  cx_add "$case_dir" other-blocker docs
  cx "$case_dir" block waits-on-delivery --by pf-delivered >/dev/null
  cx "$case_dir" block waits-on-delivery --by other-blocker >/dev/null
  # The tasks-axi record-delivery subcommand needs a relay-owned delivery attempt that no
  # fixture here can create, so a shim in front of the real tasks-axi completes the same
  # row (a real Done transition) when it sees the exact command; everything else is real.
  real=$(command -v tasks-axi)
  shim="$case_dir/shimbin"
  mkdir -p "$shim"
  cat > "$shim/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = public-followup ] && [ "\${2:-}" = record-delivery ]; then
  exec "$real" "done" "\${3:-}" --note posted
fi
exec "$real" "\$@"
SH
  chmod +x "$shim/tasks-axi"
  printf '{}\n' > "$case_dir/receipt.json"
  (cd "$case_dir/home" && PATH="$shim:$PATH" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$WRAPPER_SH" public-followup record-delivery pf-delivered --receipt-file "$case_dir/receipt.json" \
    > "$case_dir/out" 2> "$case_dir/err") || { cat "$case_dir/err" >&2; fail "c4-record-delivery: the command failed"; }
  [ "$(cx_state "$case_dir" pf-delivered)" = "done" ] || fail "c4-record-delivery: the row was not completed"
  assert_grep 'unblocked: waits-on-delivery no longer waits on pf-delivered; it still waits on other-blocker' "$case_dir/err" \
    "c4-record-delivery: the cleared edge was not reported with the remaining blocker"
  case "$(cx_deps "$case_dir" waits-on-delivery)" in *pf-delivered*) fail "c4-record-delivery: the stored edge stayed" ;; esac
  pass "a typed record-delivery completion through the wrapper clears the finished edge and keeps another blocker"
}

test_done_json_has_the_same_fields_and_values_as_tasks_axi_alone() {
  local one two a b
  command -v jq >/dev/null 2>&1 || { printf 'ok - skipped (jq is not installed)\n'; return 0; }
  one=$(make_case c4-json-wrapper)
  two=$(make_case c4-json-direct)
  for d in "$one" "$two"; do
    cx_add "$d" json-blocker docs
    cx_add "$d" json-dep
    cx "$d" block json-dep --by json-blocker >/dev/null
  done
  a=$(FM_HOME="$one/home" FM_STATE_OVERRIDE="$one/state" "$WRAPPER_SH" "done" json-blocker --note finished --json 2>/dev/null) || fail "c4-json: wrapper done failed"
  b=$(cx "$two" "done" json-blocker --note finished --json 2>/dev/null) || fail "c4-json: direct done failed"
  [ "$(printf '%s' "$a" | jq -S .)" = "$(printf '%s' "$b" | jq -S .)" ] \
    || fail "c4-json: the wrapper's --json differs from tasks-axi alone"
  pass "done --json through the wrapper has the same fields and values as tasks-axi alone"
}

pr_close_test_cases=(
test_closes_lines_close_each_eligible_item_and_report_the_rest
test_a_merge_naming_its_own_task_reports_the_live_record
test_a_prose_mention_of_the_merging_task_is_not_reported_and_another_id_is
test_an_old_form_line_naming_the_merging_task_is_left_to_its_teardown
test_an_old_form_line_never_blocks_another_source_for_the_same_id
test_no_directive_line_changes_no_item_and_prose_mentions_close_nothing
test_an_unrecorded_merge_closes_nothing_and_lists_the_named_items
test_a_merge_the_watcher_recorded_first_still_closes_without_a_second_notice
test_an_unreadable_body_is_reported_with_the_url_and_the_error
test_every_failure_kind_is_reported_and_the_valid_item_still_closes
test_a_hold_placed_after_the_last_look_still_wins
test_a_rerun_closes_nothing_twice
test_a_rerun_after_a_partial_close_closes_only_the_rest
test_a_hand_run_with_an_open_pr_closes_nothing
test_a_train_closes_the_items_of_its_train_member_lines_whatever_else_the_body_holds
test_a_train_with_no_directive_of_its_own_still_closes_member_items
test_a_member_with_both_sources_and_an_unreadable_member
test_a_train_member_value_that_is_no_pull_request_or_is_the_train_itself_is_reported
test_two_members_with_one_number_in_different_repos_match_by_full_url
test_f1_an_excluded_component_table_under_a_subheading_closes_nothing_and_is_reported
test_f2_an_indented_fenced_example_closes_nothing
test_f3_a_component_table_with_a_negated_exclusion_heading_closes_nothing_without_a_member_line
test_f4_an_unlisted_forgejo_or_gitlab_member_is_reported_by_its_url
test_a_gitlab_or_forgejo_merge_naming_its_own_task_reports_the_live_record
test_a_forgejo_train_closes_each_listed_member_source_and_reports_the_prose_link
test_a_gitlab_train_reads_each_listed_member_and_reports_the_prose_link
test_a_merge_with_directive_lines_and_an_unlistable_backlog_says_so_once
test_the_directive_parser_reads_real_lines_and_ignores_every_example
test_a_gitlab_merge_reports_the_completion_paths_actual_result
test_a_forgejo_merge_reports_the_completion_paths_actual_result
test_a_dependent_id_the_list_prints_in_quotes_loses_its_edge
test_completion_clears_the_finished_blocker_on_every_route
test_the_task_noun_forms_and_typed_completions_clear_the_edge
test_a_typed_completion_that_archives_or_cannot_be_read_back
test_a_typed_completion_help_call_reports_nothing_to_act_on
test_a_merge_reports_each_cleared_edge_and_each_failed_clear_on_its_own_channel
test_an_answered_captain_call_clears_the_edge
test_a_withdrawn_captain_call_clears_the_edge
test_an_explicit_data_root_gets_the_same_clear
test_the_named_item_matrix_with_production_prune_on
test_a_second_merge_run_changes_nothing_with_the_record_present_and_after_prune
test_the_typed_record_delivery_completion_clears_the_finished_edge
test_done_json_has_the_same_fields_and_values_as_tasks_axi_alone
)
fm_test_run_cases "${pr_close_test_cases[@]}" -- "$@"
