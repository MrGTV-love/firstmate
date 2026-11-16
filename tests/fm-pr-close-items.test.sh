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

# Main 045 F4: a route test gives a dependent another blocker and a hold, and reads both back.
cx_other_and_hold() {  # <case-dir> <dependent>
  cx_add "$1" "$2-other" docs
  cx "$1" block "$2" --by "$2-other" >/dev/null || fail "fixture: could not block $2 on $2-other"
  cx "$1" hold "$2" --reason "wait for a date" --kind future >/dev/null || fail "fixture: could not hold $2"
}
assert_only_other_and_hold() {  # <case-dir> <dependent> <finished-id> <label>
  local deps
  deps=$(cx_deps "$1" "$2" | sed 's/blocked-by://g; s/[ "]//g')
  case ",$deps," in *",$3,"*) fail "$4: the stored edge on $3 stayed ($deps)" ;; esac
  [ "$deps" = "$2-other" ] || fail "$4: the other blocker of $2 was not kept alone ($deps)"
  cx "$1" show "$2" | grep -q 'hold_kind: future' || fail "$4: the hold on $2 was lost"
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

# The one closes block (bin/fm-pr-closes-lib.sh owns it): an exact begin line, the directive
# lines, an exact end line. Each fixture puts its real directives in one block.
CLOSES_BEGIN='<!-- firstmate-backlog-closes:begin -->'
CLOSES_END='<!-- firstmate-backlog-closes:end -->'
block() {  # <line...>
  printf '%s\n' "$CLOSES_BEGIN" "$@" "$CLOSES_END"
}
prepend_block() {  # <body-file> <line...>: put one block first, above the body already in the file
  local file=$1 old
  shift
  old=$(cat "$file")
  { block "$@"; printf '\n%s\n' "$old"; } > "$file"
}
block_json() {  # <line...>: the same block as one JSON string
  block "$@" | "$JQ_BIN" -Rs .
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
  {
    block 'Closes-backlog-item: fm-fixture-alpha-1' 'Closes-backlog-item: fm-fixture-beta-2' 'Closes-backlog-item: fm-fixture-live-3' \
      'Closes-backlog-item: ship-a' 'Closes-backlog-item: docs-live-4' 'Closes-backlog-item: ship-a'
    printf '%s\n' '' 'Fixes things; fm-fixture-prose-5 is related.'
    printf '%s\n' '' 'Mentions Closes-backlog-item: fm-fixture-prose-5 inline.' 'closes: fm-fixture-prose-5' \
      '  Closes-backlog-item: fm-fixture-prose-5' 'Closes-backlog-item: fm-fixture-prose-5 # comment' \
      'Closes: fm-fixture-legacy-6'
  } > "$case_dir/bodies/61"

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
  block 'Closes-backlog-item: task-x1' > "$case_dir/bodies/62"
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
  block 'Closes-backlog-item: other-item' > "$case_dir/bodies/9"
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
  block "Train-member: $base/71" > "$case_dir/bodies/94"
  printf '%s\n' 'Closes: a-item' > "$case_dir/bodies/71"
  gh_merge "$case_dir" 94
  [ "$(cx_state "$case_dir" a-item)" = "done" ] || fail "c2-old-a: a member's old line kept the task that holds its URL open"
  assert_no_grep 'not closed a-item' "$case_dir/stderr" "c2-old-a: an id another source closed was reported as an old line"

  case_dir=$(gh_case c2-old-b 95)
  cx_add "$case_dir" b-item
  { block "Train-member: $base/72"; printf '%s\n' '' 'Closes: b-item'; } > "$case_dir/bodies/95"
  block 'Closes-backlog-item: b-item' > "$case_dir/bodies/72"
  gh_merge "$case_dir" 95
  [ "$(cx_state "$case_dir" b-item)" = "done" ] || fail "c2-old-b: the train's old line kept a member's named item open"
  assert_no_grep 'not closed b-item' "$case_dir/stderr" "c2-old-b: an id a member closed was reported as an old line"
  pass "an old Closes: line never stops a directive or a task record from closing the same id"
}

test_an_unrecorded_merge_closes_nothing_and_lists_the_named_items() {
  local case_dir rc=0
  case_dir=$(gh_case c1-unrecorded 64)
  cx_add "$case_dir" unrecorded-a
  block 'Closes-backlog-item: unrecorded-a' > "$case_dir/bodies/64"
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
  block 'Closes-backlog-item: watcher-a' > "$case_dir/bodies/65"
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
  # Every hold and release goes through the real owner-call route, bin/fm-captain-hold.sh.
  captain_hold() { FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_CONFIG_OVERRIDE="$case_dir/home/config" "$ROOT/bin/fm-captain-hold.sh" "$@" >/dev/null 2>"$case_dir/hold.err" \
    || { cat "$case_dir/hold.err" >&2; fail "c3: fm-captain-hold.sh $* failed"; }; }
  printf '%s\n' 'Released: go ahead.' > "$case_dir/release.md"
  cx_add "$case_dir" held-ship
  captain_hold hold held-ship --reason "owner decides"
  cx_add "$case_dir" call-open captain
  captain_hold hold call-open --reason "owner decides"
  cx_add "$case_dir" call-released captain
  captain_hold hold call-released --reason "owner decides"
  captain_hold answer call-released --decision-file "$case_dir/release.md" --release
  cx_add "$case_dir" call-expired captain
  captain_hold hold call-expired --reason "owner decides" --until 2020-01-01
  cx_add "$case_dir" call-reheld captain
  captain_hold hold call-reheld --reason "owner decides"
  captain_hold answer call-reheld --decision-file "$case_dir/release.md" --release
  captain_hold hold call-reheld --reason "owner decides again"
  cx_add "$case_dir" read-fails-once captain
  captain_hold hold read-fails-once --reason "owner decides"
  for id in held-ship call-open call-reheld read-fails-once; do
    cx "$case_dir" show "$id" | grep -q '^  held: yes' || fail "c3: the owner-call route did not hold $id"
  done
  # An expired hold no longer reads as held, but its captain hold record stays until answered.
  cx "$case_dir" show call-expired | grep -q '^  hold_kind: captain' || fail "c3: the owner-call route did not record the expired hold"
  cx "$case_dir" show call-released | grep -q '^  held: no' || fail "c3: the answered release left call-released held"
  cx_add "$case_dir" valid-last
  block 'Closes-backlog-item: no-such-item' 'Closes-backlog-item: done-already' 'Closes-backlog-item: a-scout' 'Closes-backlog-item: held-ship' \
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
  block 'Closes-backlog-item: late-hold' > "$case_dir/bodies/68"
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
  block 'Closes-backlog-item: rerun-a' > "$case_dir/bodies/69"
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
  block 'Closes-backlog-item: partial-a' 'Closes-backlog-item: partial-b' > "$case_dir/bodies/70"
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
  block 'Closes-backlog-item: open-gh-docs' > "$case_dir/bodies/92"
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
  set_json_field "$case_dir/pr.json" body "$(block 'Closes-backlog-item: open-fj-docs')"
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

# train_body <layout> <excluded-url> <extra-block-line-or-empty> <member-url>...
# Every body names its members with Train-member lines in its block. The Markdown layouts the
# old reader understood stay in the body as decoration, and they must change nothing.
# shellcheck disable=SC2016 # Backticks in the fixture bodies are literal Markdown.
train_body() {
  local layout=$1 excluded=$2 extra=$3 member n=0 lines=()
  shift 3
  for member in "$@"; do lines+=("Train-member: $member"); done
  [ -z "$extra" ] || lines+=("$extra")
  block "${lines[@]}"
  printf '%s\n' '' '## Intent' '' "Context: see $excluded, which stays out of this train." '' '## Train' ''
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
  printf '%s\n' '' "Also see $excluded again."
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
  block 'Closes-backlog-item: m1-item' > "$case_dir/bodies/71"
  block 'Closes-backlog-item: excluded-item' > "$case_dir/bodies/90"
  printf '%s\n' 71 72 73 74 90 >> "$case_dir/merged-prs"
  train_body "$layout" "$base/90" "${4:-}" "$base/71" "$base/72" "$base/73" "$base/74" > "$case_dir/bodies/$number"
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
  block 'Closes-backlog-item: m1-item' 'Closes-backlog-item: m3-live-docs' > "$case_dir/bodies/71"
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
  { block 'Train-member: https://github.com/example/repo-a/pull/5'; printf '%s\n' '' \
    'See https://github.com/example/repo-b/pull/5 for context.'; } > "$case_dir/bodies/83"
  gh_merge "$case_dir" 83
  [ "$(cx_state "$case_dir" repo-a-task)" = "done" ] || fail "c2-same-number: the matching member's task was not closed"
  [ "$(cx_state "$case_dir" repo-b-task)" = queued ] || fail "c2-same-number: a task with the same number in another repo matched"
  assert_match 'mentioned https://github.com/example/repo-b/pull/5 in the prose' "$case_dir/stderr" "c2-same-number: the other repository's link was not reported"
  pass "members match by the full URL, never by number"
}

# Main 044 F2: the whole block is checked before anything closes. A Train-member value that is
# no pull request URL, or that names the merged pull request itself, refuses the whole block:
# no direct item, no member item and no member's pr= task closes, and no stored edge changes. A
# retry after the body is repaired closes the items.
test_r4_f2_an_invalid_train_member_value_refuses_the_whole_block() {
  local case_dir n=84 bad
  for bad in 'https://example.com/not-a-pr' "$REPO_URL/84" ; do
    case_dir=$(gh_case "r4-f2-bad-member-$n" 84)
    cx_add "$case_dir" direct-item
    cx_add "$case_dir" member-item
    cx_add "$case_dir" member-meta-item docs
    cx_meta "$case_dir" member-meta-item docs "$REPO_URL/71"
    cx_add "$case_dir" waits-direct
    cx_add "$case_dir" waits-member
    cx_add "$case_dir" waits-meta
    cx "$case_dir" block waits-direct --by direct-item >/dev/null
    cx "$case_dir" block waits-member --by member-item >/dev/null
    cx "$case_dir" block waits-meta --by member-meta-item >/dev/null
    block 'Closes-backlog-item: member-item' > "$case_dir/bodies/71"
    printf '%s\n' 71 >> "$case_dir/merged-prs"
    block 'Closes-backlog-item: direct-item' "Train-member: $REPO_URL/71" "Train-member: $bad" > "$case_dir/bodies/84"
    gh_merge "$case_dir" 84
    [ "$(cx_state "$case_dir" direct-item)" = queued ] || fail "r4-f2: a direct item closed from a block with Train-member $bad"
    [ "$(cx_state "$case_dir" member-item)" = queued ] || fail "r4-f2: a member's item closed from a block with Train-member $bad"
    [ "$(cx_state "$case_dir" member-meta-item)" = queued ] || fail "r4-f2: a member's pr= task closed from a block with Train-member $bad"
    case "$(cx_deps "$case_dir" waits-direct)" in *direct-item*) ;; *) fail "r4-f2: the direct item's dependent lost its edge" ;; esac
    case "$(cx_deps "$case_dir" waits-member)" in *member-item*) ;; *) fail "r4-f2: the member item's dependent lost its edge" ;; esac
    case "$(cx_deps "$case_dir" waits-meta)" in *member-meta-item*) ;; *) fail "r4-f2: the pr= task's dependent lost its edge" ;; esac
    assert_no_grep '^close-at-merge: closed ' "$case_dir/stdout" "r4-f2: something closed from a refused block"
    assert_match "^actionable: close-at-merge: refused to close anything named by the body of $REPO_URL/84: (its closes block names Train-member $bad, which is|line [0-9]+ inside its closes block names the merged pull request itself as a Train-member: Train-member: $bad)" "$case_dir/stderr" \
      "r4-f2: the block with Train-member $bad was not refused by name"
    assert_no_grep "^pr view $REPO_URL/71 --json body" "$case_dir/gh.log" "r4-f2: a refused block's member body was read"
    n=$((n + 1))
  done
  # The retry after the repair closes the items, with the merged pull request as proof.
  block 'Closes-backlog-item: direct-item' "Train-member: $REPO_URL/71" > "$case_dir/bodies/84"
  run_close "$case_dir" task-x1 "$REPO_URL/84" > "$case_dir/retry.out" 2> "$case_dir/retry.err" || true
  [ "$(cx_state "$case_dir" direct-item)" = "done" ] || fail "r4-f2: the retry after the repair did not close the direct item"
  [ "$(cx_state "$case_dir" member-item)" = "done" ] || fail "r4-f2: the retry after the repair did not close the member item"
  [ "$(cx_state "$case_dir" member-meta-item)" = "done" ] || fail "r4-f2: the retry after the repair did not close the member's pr= task"
  [ "$(cx_deps "$case_dir" waits-direct)" = none ] || fail "r4-f2: the retry left the direct item's edge"
  pass "a Train-member value that is no pull request URL or is the train itself refuses the whole block: nothing closes and no edge changes; a retry after the repair closes"
}

# Main 044 F2 and F4: a member body whose block names an invalid Train-member value is refused by
# name and closes none of its own items, while the train's own block closes and the member's pr=
# task (C2's separate source) still closes.
test_r4_f2_a_member_block_with_an_invalid_value_is_refused_and_its_pr_task_still_closes() {
  local case_dir
  case_dir=$(gh_case r4-f2-member-bad 85)
  cx_add "$case_dir" train-own-85
  cx_add "$case_dir" member-own-85
  cx_add "$case_dir" member-meta-85 docs
  cx_meta "$case_dir" member-meta-85 docs "$REPO_URL/71"
  cx_add "$case_dir" waits-member-own-85
  cx "$case_dir" block waits-member-own-85 --by member-own-85 >/dev/null
  block 'Closes-backlog-item: member-own-85' 'Train-member: not-a-url' > "$case_dir/bodies/71"
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  block 'Closes-backlog-item: train-own-85' "Train-member: $REPO_URL/71" > "$case_dir/bodies/85"
  gh_merge "$case_dir" 85
  [ "$(cx_state "$case_dir" train-own-85)" = "done" ] || fail "r4-f2-member: the train's own item did not close"
  [ "$(cx_state "$case_dir" member-own-85)" = queued ] || fail "r4-f2-member: a refused member body closed its own item"
  case "$(cx_deps "$case_dir" waits-member-own-85)" in *member-own-85*) ;; *) fail "r4-f2-member: the refused member item's dependent lost its edge" ;; esac
  [ "$(cx_state "$case_dir" member-meta-85)" = "done" ] || fail "r4-f2-member: the member's pr= task did not close"
  assert_grep "closed member-meta-85 with $REPO_URL/85" "$case_dir/stdout" "r4-f2-member: the pr= task did not close with the train as proof"
  assert_match "^actionable: close-at-merge: refused to close anything named by the body of train member $REPO_URL/71: its closes block names Train-member not-a-url, which is not a GitHub, GitLab or Forgejo pull request URL" "$case_dir/stderr" \
    "r4-f2-member: the member body was not refused by name"
  pass "a member block with an invalid Train-member value is refused and closes none of its items; the train's block and the member's pr= task still close"
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
  set_json_field "$case_dir/mr-post.json" description "$(block "Train-member: $MR_PROJECT_URL/-/merge_requests/8" '' 'Closes-backlog-item: gl-ship' 'Closes-backlog-item: gl-docs')"
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
    set_json_field "$case_dir/pr-post.json" body "$(block "Train-member: https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls/10" '' 'Closes-backlog-item: fj-ship' 'Closes-backlog-item: fj-docs')"
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
  set_json_field "$case_dir/pr-post.json" body "$(block 'Closes-backlog-item: task-x1')"
  merge_call "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "c1-self-forgejo: the merge must succeed"
  [ "$(cx_state "$case_dir" task-x1)" = in_flight ] || fail "c1-self-forgejo: the merging task left In flight before its teardown"
  assert_match '^close-at-merge: not closed task-x1: .*live task record' "$case_dir/stdout" "c1-self-forgejo: the live-record refusal was not reported by id"
  assert_no_grep 'not closed task-x1' "$case_dir/stderr" "c1-self-forgejo: the merged task's own teardown case was reported as actionable"

  rc=0
  case_dir=$(make_gitlab_case "c1-self-gitlab-${CLOSE_PRUNE:-off}")
  cx_add "$case_dir" task-x1
  cx "$case_dir" start task-x1 >/dev/null || fail "c1-self-gitlab: could not start the merging task In flight"
  set_json_field "$case_dir/mr-post.json" description "$(block 'Closes-backlog-item: task-x1')"
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
  printf '{"merged":true,"body":%s}\n' "$(block_json 'Closes-backlog-item: fj-m1')" > "$case_dir/tea-body-$key-11.json"
  printf '{"merged":true,"body":""}\n' > "$case_dir/tea-body-$key-12.json"
  printf '{"merged":true,"body":"No item here."}\n' > "$case_dir/tea-body-$key-13.json"
  printf '{"merged":true,"body":%s}\n' "$(block_json 'Closes-backlog-item: fj-prose')" > "$case_dir/tea-body-$key-14.json"
  set_json_field "$case_dir/pr-post.json" body "$(block "Train-member: $base/11" "Train-member: $base/12" "Train-member: $base/13"; \
    printf '%s\n' '' "Context: $base/14 stays out.")"
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
  printf '{"state":"merged","description":%s}\n' "$(block_json 'Closes-backlog-item: gl-m1')" > "$case_dir/mr-body-$key-21.json"
  printf '{"state":"merged","description":""}\n' > "$case_dir/mr-body-$key-22.json"
  printf '{"state":"merged","description":"No item here."}\n' > "$case_dir/mr-body-$key-23.json"
  printf '{"state":"merged","description":%s}\n' "$(block_json 'Closes-backlog-item: gl-prose')" > "$case_dir/mr-body-$key-24.json"
  set_json_field "$case_dir/mr-post.json" description "$(block "Train-member: $base/21" "Train-member: $base/22" "Train-member: $base/23"; \
    printf '%s\n' '' "Context: $base/24 stays out.")"
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

# run_close <case-dir> <task-id> <url>: bin/fm-pr-close-items.sh by hand, against the case's fakes.
run_close() {
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" PATH="$case_dir/fakebin:$PATH" \
    FM_TEST_GH_BODIES="$case_dir/bodies" FM_TEST_GH_MERGED_PRS="$case_dir/merged-prs" FM_TEST_GH_LOG="$case_dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" "$CLOSE_SH" "$@"
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
  for id in noun-done noun-close; do cx_add "$case_dir" "$id" docs; cx_add "$case_dir" "dep-of-$id"; cx "$case_dir" block "dep-of-$id" --by "$id" >/dev/null; cx_other_and_hold "$case_dir" "dep-of-$id"; done
  wrapper task "done" noun-done --note finished >/dev/null 2>"$case_dir/e1" || fail "c4-routes: task done failed"
  wrapper task close noun-close --note finished >/dev/null 2>"$case_dir/e2" || fail "c4-routes: task close failed"
  assert_grep 'unblocked: dep-of-noun-done no longer waits on noun-done' "$case_dir/e1" "c4-routes: the task done form did not clear"
  assert_grep 'unblocked: dep-of-noun-close no longer waits on noun-close' "$case_dir/e2" "c4-routes: the task close form did not clear"
  assert_only_other_and_hold "$case_dir" dep-of-noun-done noun-done "c4-routes: task done"
  assert_only_other_and_hold "$case_dir" dep-of-noun-close noun-close "c4-routes: task close"
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
  cx_other_and_hold "$case_dir" dep-of-pf
  wrapper public-followup waive pf-1 --reason "not needed" --approved-by captain >/dev/null 2>"$case_dir/e3" \
    || fail "c4-routes: the waive failed"
  assert_grep 'unblocked: dep-of-pf no longer waits on pf-1' "$case_dir/e3" "c4-routes: a waived obligation did not clear its dependents"
  assert_only_other_and_hold "$case_dir" dep-of-pf pf-1 "c4-routes: the waive"
  pass "the task noun forms and a typed public-followup completion clear the finished edge and keep the dependent's other blocker and hold"
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
  for id in pf-archived pf-unread pf-silent; do
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
if [ "\${1:-}" = show ] && { [ "\${2:-}" = pf-unread ] || [ "\${2:-}" = pf-silent ]; }; then
  echo "error: simulated read failure" >&2
  exit 1
fi
# A completion that prints nothing about its state: the wrapper cannot tell whether it finished.
if [ "\${1:-} \${2:-} \${3:-}" = "public-followup waive pf-silent" ]; then
  "$real" "\$@" >/dev/null
  exit
fi
exec "$real" "\$@"
SH
  chmod +x "$bin_dir/tasks-axi"
  PATH="$bin_dir:$PATH" wrapper public-followup waive pf-unread --reason "not needed" --approved-by captain >/dev/null 2>"$case_dir/e2" \
    || fail "c4-pf: a failed read back changed the waive's exit status"
  # Main 2086: the row's show decides nothing; the waive's own printed result shows pf-unread
  # done, so its edge clears in the same run.
  [ "$(cx_deps "$case_dir" dep-of-pf-unread)" = none ] || fail "c4-pf: a finished waive left its edge though its show failed ($(cx_deps "$case_dir" dep-of-pf-unread))"
  assert_grep 'unblocked: dep-of-pf-unread no longer waits on pf-unread' "$case_dir/e2" "c4-pf: the same-run clear was not reported"
  # A completion whose output does not say its state, with a failed read: exit 0 is the proof
  # (Main 1795), so the edge clears in the same run and the report says the clear rests on it.
  PATH="$bin_dir:$PATH" wrapper public-followup waive pf-silent --reason "not needed" --approved-by captain >/dev/null 2>"$case_dir/e3" \
    || fail "c4-pf: the silent waive changed its exit status"
  [ "$(cx_deps "$case_dir" dep-of-pf-silent)" = none ] || fail "c4-pf: a finished silent waive left its edge"
  assert_grep 'pf-silent: tasks-axi printed no result the wrapper can read for its waive, so the clear rests on its exit 0' "$case_dir/e3" "c4-pf: the silent waive's exit-0 clear was not said"
  assert_grep 'unblocked: dep-of-pf-silent no longer waits on pf-silent' "$case_dir/e3" "c4-pf: the same-run clear of the silent waive was not reported"
  pass "a typed completion clears the edge in the same run when the row is archived at once and when its show fails, from its own printed result, and when it prints no result, on its exit 0 (Main 1795, 2086)"
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
  block 'Closes-backlog-item: edge-blocker' > "$case_dir/bodies/91"
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
  [ "$(cx_deps "$case_dir" dep-clears)" = none ] || fail "c4-merge-edges: the cleared edge is still stored"
  case "$(cx_deps "$case_dir" dep-fails)" in *edge-blocker*) ;; *) fail "c4-merge-edges: the edge whose clear failed is gone" ;; esac
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
  cx_other_and_hold "$case_dir" waits-on-call
  printf '%s\n' 'Go ahead.' > "$case_dir/decision.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" answer call-q --decision-file "$case_dir/decision.md" > "$case_dir/ans.out" 2> "$case_dir/ans.err" \
    || { cat "$case_dir/ans.err" >&2; fail "c4-captain: the answer failed"; }
  [ "$(cx_state "$case_dir" call-q)" = "done" ] || fail "c4-captain: the answered call did not close"
  assert_grep 'unblocked: waits-on-call no longer waits on call-q' "$case_dir/ans.err" "c4-captain: the dependent was not reported"
  assert_only_other_and_hold "$case_dir" waits-on-call call-q "c4-captain"
  pass "answering a captain call clears the call's edge from its dependents and keeps their other blocker and hold"
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
  cx_other_and_hold "$case_dir" waits-on-w
  hold_env hold ruling-r --reason "owner rules on call-w" >/dev/null 2>&1 || fail "c4-withdraw: could not hold the ruling"
  printf '%s\n' 'The owner rules on call-w: proceed.' > "$case_dir/ruling.md"
  hold_env answer ruling-r --decision-file "$case_dir/ruling.md" >/dev/null 2>&1 || fail "c4-withdraw: could not record the ruling"
  printf '%s\n' 'The ruling answers this call.' > "$case_dir/evidence.md"
  hold_env withdraw call-w --evidence-file "$case_dir/evidence.md" --ruling ruling-r \
    > "$case_dir/w.out" 2> "$case_dir/w.err" || { cat "$case_dir/w.err" >&2; fail "c4-withdraw: the withdrawal failed"; }
  [ "$(cx_state "$case_dir" call-w)" = "done" ] || fail "c4-withdraw: the withdrawn call did not close"
  assert_grep 'unblocked: waits-on-w no longer waits on call-w' "$case_dir/w.err" "c4-withdraw: the dependent was not reported"
  assert_only_other_and_hold "$case_dir" waits-on-w call-w "c4-withdraw"
  pass "withdrawing a captain call clears the call's edge from its dependents and keeps their other blocker and hold"
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
  (cd "$alt" && tasks-axi show alt-dep) 2>&1 | grep -q '^  deps: none$' || fail "c4-data-root: the stored edge stayed under a data-root override"
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
  block 'Closes-backlog-item: actually-landed' > "$case_dir/bodies/71"
  block 'Closes-backlog-item: explicitly-excluded' > "$case_dir/bodies/91"
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
  prepend_block "$case_dir/bodies/80" "Train-member: $REPO_URL/71"
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
  block 'Closes-backlog-item: member-example' > "$case_dir/bodies/91"
  # A fence indented three spaces is a valid CommonMark fence; its lines are examples.
  { block 'Closes-backlog-item: real-one'; printf '%s\n' '' 'An example of the form:' '   ```' 'Closes-backlog-item: example-only' \
    "Train-member: $REPO_URL/91" '   ```'; } > "$case_dir/bodies/80"
  gh_merge "$case_dir" 80
  [ "$(cx_state "$case_dir" real-one)" = "done" ] || fail "f2: the real directive outside the block was not closed"
  [ "$(cx_state "$case_dir" example-only)" = queued ] || fail "f2: an indented fenced example closed an item"
  case "$(cx_deps "$case_dir" waits-on-example)" in *example-only*) ;; *) fail "f2: the example's dependent lost its edge" ;; esac
  assert_no_grep 'train member' "$case_dir/stdout" "f2: a fenced Train-member line was read"
  # Main 043: no fence is read; the fenced lines are outside the block, so they are reported.
  assert_match "^actionable: close-at-merge: ignored a directive line outside a directive block in the body of .*: Train-member: $REPO_URL/91\$" "$case_dir/stderr" \
    "f2: a fenced Train-member line outside the block was not reported"
  pass "F2: Closes-backlog-item and Train-member lines in a fence, outside the block, close nothing and are reported, and the block still closes"
}

test_f3_a_component_table_with_a_negated_exclusion_heading_closes_nothing_without_a_member_line() {
  local case_dir
  case_dir=$(gh_case c2-f3 80)
  cx_add "$case_dir" included-item
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  block 'Closes-backlog-item: included-item' > "$case_dir/bodies/71"
  # shellcheck disable=SC2016 # Backticks in the fixture row are literal Markdown.
  printf '%s\n' '## Components - none excluded' '' '| Component | Head |' '| --- | --- |' "| $REPO_URL/71 | \`a\` |" > "$case_dir/bodies/80"
  gh_merge "$case_dir" 80
  [ "$(cx_state "$case_dir" included-item)" = queued ] || fail "f3: a table without a Train-member line closed an item"
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/71 in the prose of $REPO_URL/80: no item was closed for it; list it as a Train-member: line" "$case_dir/stderr" \
    "f3: the unlisted member was silent"
  # Control: the Train-member line closes it, whatever the heading says.
  prepend_block "$case_dir/bodies/80" "Train-member: $REPO_URL/71"
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
  set_json_field "$case_dir/pr-post.json" body "$(block "Train-member: $member")"
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
  cx_add "$case_dir" unrelated-item
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

test_a_merge_with_an_unlistable_backlog_says_so_once_per_body_with_prose() {
  local case_dir
  case_dir=$(gh_case c1-unlistable-train 88)
  { block "Train-member: $REPO_URL/9"; printf '%s\n' '' 'Notes mention some-other-id in prose.'; } > "$case_dir/bodies/88"
  printf '%s\n' 'This member names no item.' > "$case_dir/bodies/9"
  printf '%s\n' 9 >> "$case_dir/merged-prs"
  fake_unlistable_backlog "$case_dir"
  gh_merge "$case_dir" 88
  [ "$(grep -c "could not list the backlog to check which ids the prose of $REPO_URL/88 mentions" "$case_dir/stderr")" = 1 ] \
    || fail "c1-unlistable-train: the train body's prose did not report the failed id check once"
  [ "$(grep -c "could not list the backlog to check which ids the prose of train member $REPO_URL/9 mentions" "$case_dir/stderr")" = 1 ] \
    || fail "c1-unlistable-train: the member body's prose did not report the failed id check once"

  case_dir=$(gh_case c1-unlistable-member-only 87)
  block "Train-member: $REPO_URL/9" > "$case_dir/bodies/87"
  printf '%s\n' 'This member mentions some-other-id.' > "$case_dir/bodies/9"
  printf '%s\n' 9 >> "$case_dir/merged-prs"
  fake_unlistable_backlog "$case_dir"
  gh_merge "$case_dir" 87
  [ "$(grep -c 'could not list the backlog' "$case_dir/stderr")" = 1 ] || fail "c1-unlistable-member-only: the skipped id check was not reported exactly once"
  assert_match "could not list the backlog to check which ids the prose of train member $REPO_URL/9 mentions" "$case_dir/stderr" \
    "c1-unlistable-member-only: the notice did not name the member whose prose went unchecked"
  assert_no_grep "the prose of $REPO_URL/87 mentions" "$case_dir/stderr" "c1-unlistable-member-only: the notice named the train body, which has no prose"

  case_dir=$(gh_case c1-unlistable-none 89)
  printf '%s\n' 'Notes mention some-other-id in prose.' > "$case_dir/bodies/89"
  fake_unlistable_backlog "$case_dir"
  gh_merge "$case_dir" 89
  [ "$(grep -c 'could not list the backlog to check which ids the prose' "$case_dir/stderr")" = 1 ] \
    || fail "c1-unlistable-none: a body with prose and no directive line did not report the skipped id check once"
  case_dir=$(gh_case c1-unlistable-empty 86)
  block '' > "$case_dir/bodies/86"
  fake_unlistable_backlog "$case_dir"
  gh_merge "$case_dir" 86
  assert_no_grep 'could not list the backlog' "$case_dir/stderr" "c1-unlistable-empty: a body with no prose reported a skipped id check it had no use for"

  case_dir=$(gh_case c1-unlistable 85)
  cx_add "$case_dir" unlistable-a
  { block 'Closes-backlog-item: unlistable-a'; printf '%s\n' '' 'Notes mention some-other-id in prose.'; } > "$case_dir/bodies/85"
  fake_unlistable_backlog "$case_dir"
  gh_merge "$case_dir" 85
  [ "$(cx_state "$case_dir" unlistable-a)" = "done" ] || fail "c1-unlistable: the named item was not closed"
  [ "$(grep -c 'could not list the backlog to check which ids the prose' "$case_dir/stderr")" = 1 ] || fail "c1-unlistable: the failed id check was not reported exactly once"
  pass "a failed backlog listing reports the skipped id check once for each body that has prose and names that body, with or without a directive line, and still closes the named item"
}

# Review 92093289 F1: a directive inside an HTML comment is an example. Only the real
# directive closes; the example's item stays queued and its dependent keeps its edge.
test_an_html_comment_example_closes_nothing_and_keeps_its_edge() {
  local case_dir
  case_dir=$(gh_case c1-html-comment 94)
  cx_add "$case_dir" review-real
  cx_add "$case_dir" review-comment-example
  cx_add "$case_dir" review-waiting
  cx "$case_dir" block review-waiting --by review-comment-example >/dev/null
  { block 'Closes-backlog-item: review-real'; printf '%s\n' '<!-- Example only, not a closure:' \
    'Closes-backlog-item: review-comment-example' '-->'; } > "$case_dir/bodies/94"
  gh_merge "$case_dir" 94
  [ "$(cx_state "$case_dir" review-real)" = "done" ] || fail "f1-comment: the real directive did not close its item"
  [ "$(cx_state "$case_dir" review-comment-example)" = queued ] || fail "f1-comment: an item named only inside an HTML comment was closed"
  case "$(cx_deps "$case_dir" review-waiting)" in *review-comment-example*) ;; *) fail "f1-comment: the dependent lost its edge on an item that did not finish" ;; esac
  assert_no_grep 'closed review-comment-example' "$case_dir/stdout" "f1-comment: the example's close was reported"
  pass "F1: a directive inside an HTML comment closes nothing and keeps the dependent's edge, while the real directive closes"
}

# Review 92093289 F2: a train member's prose-only mention is reported, never closed; an id
# its own directive names, and an id nothing mentions, stay silent.
test_a_train_members_prose_only_mention_is_reported_and_never_closed() {
  local case_dir
  case_dir=$(gh_case c2-member-prose 95)
  cx_add "$case_dir" member-directive
  cx_add "$case_dir" member-prose-only
  cx_add "$case_dir" unrelated-item
  block "Train-member: $REPO_URL/71" > "$case_dir/bodies/95"
  { block 'Closes-backlog-item: member-directive'; printf '%s\n' '' 'This also fixes member-prose-only.' '' 'The member-directive item is the main one.'; } > "$case_dir/bodies/71"
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 95
  [ "$(cx_state "$case_dir" member-directive)" = "done" ] || fail "f2: the member's directive did not close its item"
  [ "$(cx_state "$case_dir" member-prose-only)" = queued ] || fail "f2: a member's prose mention closed an item"
  assert_match "^actionable: close-at-merge: mentioned member-prose-only in the prose of train member $REPO_URL/71: nothing was closed for it" "$case_dir/stderr" \
    "f2: a member's prose-only mention was not reported"
  [ "$(grep -c 'mentioned member-prose-only' "$case_dir/stderr")" = 1 ] || fail "f2: the mention was reported more than once"
  assert_no_grep 'mentioned member-directive' "$case_dir/stderr" "f2: an id the member's own directive closed was reported as a mention"
  assert_no_grep 'unrelated-item' "$case_dir/stderr" "f2: an id nothing mentions was reported"
  pass "F2: a train member's prose-only mention is reported once and never closed; its directive id and an unrelated id stay silent"
}

# Review 92093289 F3: an id keeps its own spelling when the prose is checked (a trailing
# underscore or hyphen belongs to it; a sentence's final period does not).
test_a_mention_keeps_the_ids_own_spelling() {
  local case_dir
  case_dir=$(gh_case c1-mention-spelling 96)
  cx_add "$case_dir" review-name_
  cx_add "$case_dir" review-dash-
  cx_add "$case_dir" review-normal
  cx_add "$case_dir" review-em-one
  cx_add "$case_dir" review-em-two
  cx_add "$case_dir" review-lone
  printf '%s\n' 'It touches review-name_, review-dash- and review-normal.' 'Last: review-normal.' \
    'Also _review-em-one_ and __review-em-two__, but review-lone_ is another word.' > "$case_dir/bodies/96"
  gh_merge "$case_dir" 96
  assert_match '^actionable: close-at-merge: mentioned review-em-one in the prose of ' "$case_dir/stderr" "f3: an id in single-underscore emphasis was missed"
  assert_match '^actionable: close-at-merge: mentioned review-em-two in the prose of ' "$case_dir/stderr" "f3: an id in double-underscore emphasis was missed"
  assert_no_grep 'mentioned review-lone ' "$case_dir/stderr" "f3: a lone trailing underscore was stripped, so review-lone_ reported review-lone"
  assert_match '^actionable: close-at-merge: mentioned review-name_ in the prose of ' "$case_dir/stderr" "f3: an id with a trailing underscore was missed"
  assert_match '^actionable: close-at-merge: mentioned review-dash- in the prose of ' "$case_dir/stderr" "f3: an id with a trailing hyphen was missed"
  assert_match '^actionable: close-at-merge: mentioned review-normal in the prose of ' "$case_dir/stderr" "f3: a plain id was missed"
  [ "$(grep -c 'mentioned review-normal' "$case_dir/stderr")" = 1 ] || fail "f3: an id mentioned twice was reported more than once"
  for id in review-name_ review-dash- review-normal; do
    [ "$(cx_state "$case_dir" "$id")" = queued ] || fail "f3: a mention closed $id"
  done
  pass "F3: a mention keeps the id's own spelling, trailing underscore and hyphen included, and is reported once"
}

# Review R11-2, under Main 043: no HTML comment is read, so a mention inside a comment is reported
# like the text after it; nothing closes.
test_a_mention_inside_a_comment_is_reported_like_any_other_text() {
  local case_dir
  case_dir=$(gh_case c1-comment-prose 98)
  cx_add "$case_dir" review-hidden
  cx_add "$case_dir" review-after
  printf '%s\n' "Fixes it. <!-- see review-hidden and $REPO_URL/12 -->" 'Note <!-- also review-hidden' 'Text --> see review-after here' > "$case_dir/bodies/98"
  gh_merge "$case_dir" 98
  assert_match '^actionable: close-at-merge: mentioned review-hidden in the prose of ' "$case_dir/stderr" "r11-2: an id inside a comment was not reported"
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/12 in the prose of " "$case_dir/stderr" "r11-2: a link inside a comment was not reported"
  assert_match '^actionable: close-at-merge: mentioned review-after in the prose of ' "$case_dir/stderr" "r11-2: an id after a comment's --> was missed"
  [ "$(cx_state "$case_dir" review-hidden)" = queued ] || fail "r11-2: a mention closed an item"
  pass "a mention inside an HTML comment is reported like the text after it, and closes nothing"
}

# Contract C2: one member supplying both its own directive and a distinct task whose pr=
# is that same member, and two listed members that share a number in different repositories.
test_a_member_with_both_sources_and_two_listed_members_with_one_number() {
  local case_dir
  case_dir=$(gh_case c2-both-listed 97)
  cx_add "$case_dir" both-from-body
  cx_add "$case_dir" both-from-meta docs
  cx_meta "$case_dir" both-from-meta docs "$REPO_URL/71"
  block 'Closes-backlog-item: both-from-body' > "$case_dir/bodies/71"
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  block "Train-member: $REPO_URL/71" > "$case_dir/bodies/97"
  gh_merge "$case_dir" 97
  [ "$(cx_state "$case_dir" both-from-body)" = "done" ] || fail "c2-both: the item the member's body names was not closed"
  [ "$(cx_state "$case_dir" both-from-meta)" = "done" ] || fail "c2-both: the distinct task whose pr= is the same member was not closed"

  case_dir=$(gh_case c2-two-repos 98)
  cx_add "$case_dir" repo-a-body
  cx_add "$case_dir" repo-b-body
  cx_add "$case_dir" repo-a-meta docs
  cx_add "$case_dir" repo-b-meta docs
  cx_meta "$case_dir" repo-a-meta docs "https://github.com/example/repo-a/pull/5"
  cx_meta "$case_dir" repo-b-meta docs "https://github.com/example/repo-b/pull/5"
  block 'Closes-backlog-item: repo-a-body' > "$case_dir/bodies/example_repo-a-5"
  block 'Closes-backlog-item: repo-b-body' > "$case_dir/bodies/example_repo-b-5"
  block 'Train-member: https://github.com/example/repo-a/pull/5' 'Train-member: https://github.com/example/repo-b/pull/5' > "$case_dir/bodies/98"
  gh_merge "$case_dir" 98
  for id in repo-a-body repo-b-body repo-a-meta repo-b-meta; do
    [ "$(cx_state "$case_dir" "$id")" = "done" ] || fail "c2-two-repos: $id was not closed with both same-number members listed"
  done
  pass "a member's own directive and a distinct pr= task both close, and two listed members that share a number in different repositories both close by full URL"
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
    block 'Closes-backlog-item: second-a' > "$case_dir/bodies/72"
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
  local case_dir now later expires attempt
  command -v jq >/dev/null 2>&1 || { printf 'ok - skipped (jq is not installed)\n'; return 0; }
  case_dir=$(make_case c4-record-delivery)
  wrapper() { (cd "$case_dir/home" && FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "$@"); }
  # The real typed route: tasks-axi's own add, bind-work, work-event and begin-delivery, then
  # record-delivery through the wrapper. Nothing is posted; the receipt is what a post leaves.
  now=$(date -u +%s)
  later=$(date -u -r $((now + 7 * 86400)) +%Y-%m-%dT%H:%M:%SZ)
  expires=$(date -u -r $((now + 30 * 86400)) +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg r "$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)" --arg l "$later" '{request_id:"req-rd", platform:"discord",
    context_binding:{version:"ctx1", value:"ctx1_req-rd"}, public_safe_summary:"s", received_at:$r,
    followup_expires_at:$l, reservation_expires_at:$l}' > "$case_dir/request.json"
  jq -n '{type:"pr-merged", project:"alpha", required_deliverables:["pr_url"], completion_policy:"all-required"}' > "$case_dir/expected.json"
  jq -n '{relation_id:"rel-code", work_ref:{home_id:"main", task_id:"work-rd"}, role:"fulfills", required:true, generation:1}' > "$case_dir/relation.json"
  wrapper public-followup add pf-delivered --request-context-file "$case_dir/request.json" --purpose promised-final \
    --expected-final-file "$case_dir/expected.json" --expires-at "$expires" >/dev/null 2>&1 || fail "c4-record-delivery: add failed"
  wrapper public-followup bind-work pf-delivered --relation-file "$case_dir/relation.json" >/dev/null 2>&1 || fail "c4-record-delivery: bind-work failed"
  jq -n --arg at "$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)" '{schema_version:1,
    event_id:"0000000000000000000000000000000000000000000000000000000000000001", obligation_id:"pf-delivered",
    relation_id:"rel-code", work_id:"work-rd", generation:1, source_home_id:"main", outcome_type:"pr-merged",
    deliverables:{pr_url:"https://github.com/example/repo/pull/7"}, public_safe_outcome:"landed", occurred_at:$at, successor:null}' \
    > "$case_dir/event.json"
  wrapper public-followup work-event pf-delivered --event-file "$case_dir/event.json" >/dev/null 2>&1 || fail "c4-record-delivery: work-event failed"
  wrapper public-followup begin-delivery pf-delivered --payload-hash "$(printf x | shasum -a 256 | cut -c1-64)" >/dev/null 2>&1 \
    || fail "c4-record-delivery: begin-delivery failed"
  attempt=$(cx "$case_dir" public-followup list --json | jq -r '(.public_followups // []) | map(select(.id == "pf-delivered")) | .[0].public_followup.delivery.attempt_count')
  cx_add "$case_dir" waits-on-delivery
  cx_add "$case_dir" other-blocker docs
  cx_add "$case_dir" held-on-delivery docs
  cx "$case_dir" block waits-on-delivery --by pf-delivered >/dev/null
  cx "$case_dir" block waits-on-delivery --by other-blocker >/dev/null
  cx "$case_dir" block held-on-delivery --by pf-delivered >/dev/null
  cx "$case_dir" hold held-on-delivery --reason "owner decides" --kind captain >/dev/null
  jq -n --argjson a "$attempt" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{state:"posted", request_id:"req-rd", platform:"discord",
    attempt_count:$a, total_chunks:1, posted_chunks:1, posted_at:$t}' > "$case_dir/receipt.json"
  wrapper public-followup record-delivery pf-delivered --receipt-file "$case_dir/receipt.json" > "$case_dir/out" 2> "$case_dir/err" \
    || { cat "$case_dir/err" >&2; fail "c4-record-delivery: the command failed"; }
  [ "$(cx_state "$case_dir" pf-delivered)" = "done" ] || fail "c4-record-delivery: the row was not completed"
  assert_grep 'unblocked: waits-on-delivery no longer waits on pf-delivered; it still waits on other-blocker' "$case_dir/err" \
    "c4-record-delivery: the cleared edge was not reported with the remaining blocker"
  assert_grep 'unblocked: held-on-delivery no longer waits on pf-delivered' "$case_dir/err" "c4-record-delivery: the held dependent was not reported"
  case "$(cx_deps "$case_dir" waits-on-delivery)" in
    *pf-delivered*) fail "c4-record-delivery: the stored edge stayed" ;;
    *other-blocker*) ;;
    *) fail "c4-record-delivery: the other blocker's edge was lost" ;;
  esac
  [ "$(cx_deps "$case_dir" held-on-delivery)" = none ] || fail "c4-record-delivery: the held dependent kept the edge"
  cx "$case_dir" show held-on-delivery | grep -q 'hold_kind: captain' || fail "c4-record-delivery: the dependent's hold was lost"
  pass "a real typed record-delivery completion through the wrapper clears the finished edge, keeps another blocker and a hold"
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

# Review b4182820 F1: a heading, a <pre> example and a code span that spans lines hold no
# directive. Each witness closes nothing and keeps its dependent's edge, while a real block in
# the same body closes; a directive line outside a block is reported.
# The case folder is left in F1_CASE (no command substitution, so a fail stops the test).
f1_witness_case() {  # <name> <number> <example-id> <example lines...>
  local name=$1 number=$2 example=$3 case_dir
  shift 3
  case_dir=$(gh_case "$name" "$number")
  cx_add "$case_dir" "$name-control"
  cx_add "$case_dir" "$example"
  cx_add "$case_dir" "$name-waiter"
  cx "$case_dir" block "$name-waiter" --by "$example" >/dev/null
  { block "Closes-backlog-item: $name-control"; printf '%s\n' '' 'The real block is above; examples follow.' '' "$@"; } > "$case_dir/bodies/$number"
  gh_merge "$case_dir" "$number"
  [ "$(cx_state "$case_dir" "$name-control")" = "done" ] || fail "$name: the real directive did not close its item"
  assert_match "^close-at-merge: closed $name-control with $REPO_URL/$number " "$case_dir/stdout" "$name: the real directive's close was not reported with the merged URL"
  [ "$(cx_state "$case_dir" "$example")" = queued ] || fail "$name: an item named only by an example was closed"
  case "$(cx_deps "$case_dir" "$name-waiter")" in *"$example"*) ;; *) fail "$name: the dependent lost its edge on an item that did not finish" ;; esac
  assert_no_grep "closed $example" "$case_dir/stdout" "$name: the example's close was reported"
  F1_CASE=$case_dir
}

test_f1_a_setext_heading_directive_closes_nothing_and_is_reported() {
  f1_witness_case f1-setext 96 wit-setext 'Closes-backlog-item: wit-setext' '=========================='
  assert_match '^actionable: close-at-merge: ignored a directive line outside a directive block in the body of .*: Closes-backlog-item: wit-setext$' "$F1_CASE/stderr" \
    "f1-setext: the heading's directive line was not reported"
  pass "F1: a setext heading's directive line closes nothing, keeps the dependent's edge and is reported, while the real block closes"
}

test_f1_a_pre_example_closes_nothing_with_or_without_blank_lines() {
  f1_witness_case f1-pre 97 wit-pre '<pre>' '' 'Closes-backlog-item: wit-pre' '' '</pre>'
  f1_witness_case f1-pre-tight 98 wit-pre-tight '<pre>' 'Closes-backlog-item: wit-pre-tight' '</pre>'
  pass "F1: a directive inside a <pre> example closes nothing and keeps the dependent's edge, with or without blank lines, while the real block closes"
}

# shellcheck disable=SC2016 # Backticks in the fixture lines are literal Markdown.
test_f1_a_code_span_over_lines_closes_nothing_and_is_reported() {
  f1_witness_case f1-code 99 wit-code 'The form is `' 'Closes-backlog-item: wit-code' '` on its own line.'
  assert_match '^actionable: close-at-merge: ignored a directive line outside a directive block in the body of .*: Closes-backlog-item: wit-code$' "$F1_CASE/stderr" \
    "f1-code: the code span's directive line was not reported"
  pass "F1: a directive inside a code span over lines closes nothing, keeps the dependent's edge and is reported, while the real block closes"
}

test_f1_an_open_html_quote_or_example_element_closes_nothing() {
  f1_witness_case f1-blockquote 100 wit-blockquote '<blockquote>' '' 'Closes-backlog-item: wit-blockquote' '' '</blockquote>'
  f1_witness_case f1-details 101 wit-details '<details><summary>An example</summary>' '' 'Closes-backlog-item: wit-details' '' '</details>'
  f1_witness_case f1-inline-pre 102 wit-inline-pre 'Example: <pre>' '' 'Closes-backlog-item: wit-inline-pre' '' '</pre>'
  pass "F1: a directive inside an open <blockquote>, <details> or mid-line <pre> closes nothing and keeps the dependent's edge, while the real block closes"
}

# Review b4182820 F1, sibling witnesses: a quoting element opened on the same line as a
# comment's or a <pre> block's end, or after a mid-line comment's close, still holds what follows.
test_f1_a_container_opened_on_a_comment_or_pre_edge_line_closes_nothing() {
  f1_witness_case f1-edge-comment 105 wit-edge-comment '<!-- note --> <blockquote>' '' 'Closes-backlog-item: wit-edge-comment' '' '</blockquote>'
  f1_witness_case f1-edge-close 106 wit-edge-close '<!-- note' '--> <details>' '' 'Closes-backlog-item: wit-edge-close' '' '</details>'
  f1_witness_case f1-edge-pre 107 wit-edge-pre '<pre>x</pre> <blockquote>' '' 'Closes-backlog-item: wit-edge-pre' '' '</blockquote>'
  f1_witness_case f1-edge-midline 108 wit-edge-midline 'Intro <!-- a' 'b --> <blockquote>' '' 'Closes-backlog-item: wit-edge-midline' '' '</blockquote>'
  pass "F1: a quoting element opened after a comment's end, a <pre> block's end or a mid-line comment's close holds its directive, which closes nothing and keeps the edge"
}

# Review b4182820 F1, member side: a Train-member line inside a code span that spans lines
# lists no member, so the task whose pr= is that URL keeps its state and its dependent's edge,
# while a real Train-member line in the same body closes its member's item.
# shellcheck disable=SC2016 # Backticks in the fixture lines are literal Markdown.
test_f1_a_train_member_inside_a_code_span_lists_no_member() {
  local case_dir
  case_dir=$(gh_case f1-member-code 103)
  cx_add "$case_dir" member-control
  cx_add "$case_dir" code-member-docs docs
  cx_meta "$case_dir" code-member-docs docs "$REPO_URL/71"
  cx_add "$case_dir" code-member-waiter
  cx "$case_dir" block code-member-waiter --by code-member-docs >/dev/null
  { block "Train-member: $REPO_URL/73"; printf '%s\n' '' 'Example only: `' "Train-member: $REPO_URL/71" '` is the form.'; } > "$case_dir/bodies/103"
  block 'Closes-backlog-item: member-control' > "$case_dir/bodies/73"
  block 'Closes-backlog-item: never-read' > "$case_dir/bodies/71"
  printf '%s\n' 71 73 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 103 --merge
  [ "$(cx_state "$case_dir" member-control)" = "done" ] || fail "f1-member: the real member's item did not close"
  [ "$(cx_state "$case_dir" code-member-docs)" = queued ] || fail "f1-member: a code-span member's pr= item was closed"
  case "$(cx_deps "$case_dir" code-member-waiter)" in *code-member-docs*) ;; *) fail "f1-member: the dependent lost its edge on an item that did not finish" ;; esac
  assert_match "^actionable: close-at-merge: ignored a directive line outside a directive block in the body of .*: Train-member: $REPO_URL/71\$" "$case_dir/stderr" \
    "f1-member: the code span's Train-member line was not reported"
  pass "F1: a Train-member line inside a code span lists no member and keeps the pr= item and its dependent's edge, while the real member closes"
}

# Review b4182820 F2: a pull request link that only a train member's body holds is reported,
# never closed; the listed member and an unrelated item are not reported.
# Review b4182820 F2, the directive shape: a Train-member line in a member's own body lists
# nothing (a member's members are not read), so it is reported like a link and closes nothing.
test_f2_a_members_own_train_member_line_is_reported_and_never_closed() {
  local case_dir
  case_dir=$(gh_case f2-member-member 109)
  cx_add "$case_dir" member-member-control
  cx_add "$case_dir" nested-72-item
  cx_add "$case_dir" nested-72-docs docs
  cx_meta "$case_dir" nested-72-docs docs "$REPO_URL/72"
  block "Train-member: $REPO_URL/71" > "$case_dir/bodies/109"
  block 'Closes-backlog-item: member-member-control' "Train-member: $REPO_URL/72" > "$case_dir/bodies/71"
  block 'Closes-backlog-item: nested-72-item' > "$case_dir/bodies/72"
  printf '%s\n' 71 72 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 109 --merge
  [ "$(cx_state "$case_dir" member-member-control)" = "done" ] || fail "f2-member-member: the listed member's item did not close"
  [ "$(cx_state "$case_dir" nested-72-item)" = queued ] || fail "f2-member-member: a member's own Train-member line closed its pull request's item"
  [ "$(cx_state "$case_dir" nested-72-docs)" = queued ] || fail "f2-member-member: a member's own Train-member line closed a pr= item"
  assert_match "^actionable: close-at-merge: .*$REPO_URL/72 .*train member $REPO_URL/71" "$case_dir/stderr" \
    "f2-member-member: the member's own Train-member line was not reported"
  pass "F2: a Train-member line in a member's body lists nothing, closes nothing and is reported"
}

test_f2_a_train_members_prose_pr_link_is_reported_and_never_closed() {
  local case_dir
  case_dir=$(gh_case f2-member-link 104)
  cx_add "$case_dir" member-link-control
  cx_add "$case_dir" unlisted-72-item
  cx_add "$case_dir" unrelated-link-item
  block "Train-member: $REPO_URL/71" > "$case_dir/bodies/104"
  { block 'Closes-backlog-item: member-link-control'; printf '%s\n' '' "Related member pull request: $REPO_URL/72" "It links itself too: $REPO_URL/71 and the train $REPO_URL/104."; } > "$case_dir/bodies/71"
  block 'Closes-backlog-item: unlisted-72-item' > "$case_dir/bodies/72"
  printf '%s\n' 71 72 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 104 --merge
  [ "$(cx_state "$case_dir" member-link-control)" = "done" ] || fail "f2-link: the listed member's item did not close"
  [ "$(cx_state "$case_dir" unlisted-72-item)" = queued ] || fail "f2-link: a pull request named only by a member's link was read as a member"
  [ "$(cx_state "$case_dir" unrelated-link-item)" = queued ] || fail "f2-link: an unrelated item changed"
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/72 in the prose of train member $REPO_URL/71: no item was closed for it" "$case_dir/stderr" \
    "f2-link: the member body's pull request link was not reported"
  [ "$(grep -c "mentioned $REPO_URL/72 " "$case_dir/stderr")" = 1 ] || fail "f2-link: the link was reported more than once"
  assert_no_grep "mentioned $REPO_URL/71 " "$case_dir/stderr" "f2-link: the listed member was reported as a mention"
  assert_no_grep "mentioned $REPO_URL/104 " "$case_dir/stderr" "f2-link: the merged train was reported as a mention"
  assert_no_grep 'unrelated-link-item' "$case_dir/stderr" "f2-link: an unrelated item was reported"
  pass "F2: a pull request link in a train member's body is reported once and never closed; the listed member, the train and an unrelated item are not reported"
}

# --- review pr358-b4bbb8de (Main 043): the one closes block ---------------------------------
#
# Main 043: the reader reads only the one block between the exact begin and end lines. Any
# other line in it, a second block, a missing end line or marker text inside other text refuses
# the whole close with a named reason. Every case runs the real bin/fm-pr-merge.sh.

# refused_case <name> <number> <reason-pattern> <body-file> <item...>: each item is added. The
# merge must refuse to close anything from the body and name why; every item stays queued.
refused_case() {
  local name=$1 number=$2 reason=$3 body=$4 case_dir id
  shift 4
  case_dir=$(gh_case "$name" "$number")
  for id in "$@"; do
    cx_add "$case_dir" "$id"
    cx_add "$case_dir" "$id-waiter"
    cx "$case_dir" block "$id-waiter" --by "$id" >/dev/null
  done
  cp "$body" "$case_dir/bodies/$number"
  gh_merge "$case_dir" "$number"
  for id in "$@"; do
    [ "$(cx_state "$case_dir" "$id")" = queued ] || fail "$name: $id closed from a refused body"
    case "$(cx_deps "$case_dir" "$id-waiter")" in *"$id"*) ;; *) fail "$name: $id's dependent lost its stored edge" ;; esac
  done
  assert_no_grep '^close-at-merge: closed ' "$case_dir/stdout" "$name: something closed from a refused body"
  assert_match "^actionable: close-at-merge: refused to close anything named by the body of $REPO_URL/$number: $reason" "$case_dir/stderr" \
    "$name: the refusal was not reported with its reason"
  assert_match 'left open' "$case_dir/stdout" "$name: the refusal was not counted as left open"
  # Main 045 F3: the one refusal line names every item id the body names.
  for id in "$@"; do
    grep "^actionable: close-at-merge: refused to close anything named by the body of $REPO_URL/$number: " "$case_dir/stderr" \
      | grep -qE "; it names item ids: ([^;]*, )?$id(, [^;]*)?; " || fail "$name: the refusal did not name $id"
  done
}

# shellcheck disable=SC2016 # Backticks in the reviewer's body are literal Markdown.
test_r3_f1_a_closing_tag_inside_a_multiline_code_span_closes_no_example() {
  local case_dir deps
  case_dir=$(gh_case r3-f1-code-tag 110)
  cx_add "$case_dir" reviewer-control-two
  cx_add "$case_dir" reviewer-example-two
  cx_add "$case_dir" reviewer-member-two
  cx_add "$case_dir" reviewer-waiter-two
  cx "$case_dir" block reviewer-waiter-two --by reviewer-example-two >/dev/null
  cx "$case_dir" block reviewer-waiter-two --by reviewer-member-two >/dev/null
  # The reviewer's body: a real block, and two example lines inside an open <details> whose
  # closing tag text sits in a code span over several lines.
  {
    printf '%s\n' '<details><summary>Evidence</summary>' '' 'To document markup, write `example' \
      'closing tag </details> appears in inline code' 'and finish the code span`.' '' \
      'Closes-backlog-item: reviewer-example-two' "Train-member: $REPO_URL/71" '' '</details>' ''
    block 'Closes-backlog-item: reviewer-control-two'
  } > "$case_dir/bodies/110"
  block 'Closes-backlog-item: reviewer-member-two' > "$case_dir/bodies/71"
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 110
  # Main 044: the <details> text above the block refuses the whole body, so the block below it
  # closes nothing either; the second merge below puts the block first and it closes.
  [ "$(cx_state "$case_dir" reviewer-control-two)" = queued ] || fail "r3-f1-code-tag: a block below a <details> line closed"
  assert_match "^actionable: close-at-merge: refused to close anything named by the body of $REPO_URL/110: its first non-empty line, line 1, is not the closes block begin line" "$case_dir/stderr" \
    "r3-f1-code-tag: the body was not refused for the <details> text above its block"
  [ "$(cx_state "$case_dir" reviewer-example-two)" = queued ] || fail "r3-f1-code-tag: an example line closed its item"
  [ "$(cx_state "$case_dir" reviewer-member-two)" = queued ] || fail "r3-f1-code-tag: an example Train-member line closed its member's item"
  deps=$(cx_deps "$case_dir" reviewer-waiter-two)
  case "$deps" in *reviewer-example-two*) ;; *) fail "r3-f1-code-tag: the dependent lost its edge on the example item ($deps)" ;; esac
  case "$deps" in *reviewer-member-two*) ;; *) fail "r3-f1-code-tag: the dependent lost its edge on the member item ($deps)" ;; esac
  assert_match '^actionable: close-at-merge: ignored a directive line outside a directive block in the body of .*: Closes-backlog-item: reviewer-example-two$' "$case_dir/stderr" \
    "r3-f1-code-tag: the example directive line was not reported"
  assert_match "^actionable: close-at-merge: ignored a directive line outside a directive block in the body of .*: Train-member: $REPO_URL/71\$" "$case_dir/stderr" \
    "r3-f1-code-tag: the example Train-member line was not reported"
  # The same example below a block that comes first: the block closes, the examples do not.
  {
    block 'Closes-backlog-item: reviewer-control-two'
    printf '%s\n' '' '<details><summary>Evidence</summary>' '' 'To document markup, write `example' \
      'closing tag </details> appears in inline code' 'and finish the code span`.' '' \
      'Closes-backlog-item: reviewer-example-two' "Train-member: $REPO_URL/71" '' '</details>'
  } > "$case_dir/bodies/110"
  run_close "$case_dir" task-x1 "$REPO_URL/110" > "$case_dir/second.out" 2> "$case_dir/second.err" || true
  [ "$(cx_state "$case_dir" reviewer-control-two)" = "done" ] || fail "r3-f1-code-tag: the block above the example did not close"
  assert_grep "closed reviewer-control-two with $REPO_URL/110" "$case_dir/second.out" "r3-f1-code-tag: the close was not reported with the merged URL"
  [ "$(cx_state "$case_dir" reviewer-example-two)" = queued ] || fail "r3-f1-code-tag: an example line below the block closed its item"
  [ "$(cx_state "$case_dir" reviewer-member-two)" = queued ] || fail "r3-f1-code-tag: an example Train-member line below the block closed its member's item"
  deps=$(cx_deps "$case_dir" reviewer-waiter-two)
  case "$deps" in *reviewer-example-two*) ;; *) fail "r3-f1-code-tag: after the second merge the dependent lost its edge on the example item ($deps)" ;; esac
  case "$deps" in *reviewer-member-two*) ;; *) fail "r3-f1-code-tag: after the second merge the dependent lost its edge on the member item ($deps)" ;; esac
  pass "review F1: example lines close nothing whatever the HTML around them and keep both edges; opener text above the block refuses the body, and a block above the example closes"
}

# Main 044: a block below text that can open a container is refused by name, even when that text
# sits in a code span, because the reader trusts no closer. The same text below the block is fine.
# shellcheck disable=SC2016 # Backticks in the reviewer's body are literal Markdown.
test_r4_a_block_below_opener_text_in_a_code_span_is_refused_by_name() {
  local case_dir
  { printf '%s\n' 'To document markup, write `example' 'write <details> here' 'and finish the code span`.' ''
    block 'Closes-backlog-item: reviewer-legitimate-three'; } > "$TMP_ROOT/r4-open-tag.md"
  refused_case r4-open-tag 111 'its first non-empty line, line 1, is not the closes block begin line' "$TMP_ROOT/r4-open-tag.md" reviewer-legitimate-three
  case_dir=$(gh_case r4-open-tag-first 129)
  cx_add "$case_dir" reviewer-legitimate-first
  { block 'Closes-backlog-item: reviewer-legitimate-first'
    printf '%s\n' '' 'To document markup, write `example' 'write <details> here' 'and finish the code span`.'; } > "$case_dir/bodies/129"
  gh_merge "$case_dir" 129
  [ "$(cx_state "$case_dir" reviewer-legitimate-first)" = "done" ] || fail "r4-open-tag: a block above the code span did not close"
  pass "a block below opener text in a code span is refused by name and closes nothing; the block above the same text closes"
}

test_r3_f2_a_member_line_after_a_pre_end_reports_its_link_and_id() {
  local case_dir
  case_dir=$(gh_case r3-f2-pre-suffix 112)
  cx_add "$case_dir" reviewer-member-control
  cx_add "$case_dir" reviewer-prose-item
  cx_add "$case_dir" reviewer-unlisted-72
  cx_add "$case_dir" reviewer-pre-waiter
  cx "$case_dir" block reviewer-pre-waiter --by reviewer-prose-item >/dev/null
  cx "$case_dir" block reviewer-pre-waiter --by reviewer-unlisted-72 >/dev/null
  block "Train-member: $REPO_URL/71" > "$case_dir/bodies/112"
  {
    block 'Closes-backlog-item: reviewer-member-control'
    printf '%s\n' '' "<pre>fixture output</pre><a href=\"$REPO_URL/72\">Related PR</a> and reviewer-prose-item." \
      "Plain related PR: $REPO_URL/73"
  } > "$case_dir/bodies/71"
  block 'Closes-backlog-item: reviewer-unlisted-72' > "$case_dir/bodies/72"
  printf '%s\n' 71 72 73 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 112
  [ "$(cx_state "$case_dir" reviewer-member-control)" = "done" ] || fail "r3-f2-pre-suffix: the listed member's item did not close"
  [ "$(cx_state "$case_dir" reviewer-prose-item)" = queued ] || fail "r3-f2-pre-suffix: a prose id closed"
  [ "$(cx_state "$case_dir" reviewer-unlisted-72)" = queued ] || fail "r3-f2-pre-suffix: an unlisted pull request's item closed"
  case "$(cx_deps "$case_dir" reviewer-pre-waiter)" in *reviewer-prose-item*) ;; *) fail "r3-f2-pre-suffix: the dependent lost its edge on the prose item" ;; esac
  case "$(cx_deps "$case_dir" reviewer-pre-waiter)" in *reviewer-unlisted-72*) ;; *) fail "r3-f2-pre-suffix: the dependent lost its edge on the unlisted pull request's item" ;; esac
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/72 in the prose of train member $REPO_URL/71: no item was closed for it" "$case_dir/stderr" \
    "r3-f2-pre-suffix: the link after </pre> was not reported"
  assert_match "^actionable: close-at-merge: mentioned reviewer-prose-item in the prose of train member $REPO_URL/71: nothing was closed for it" "$case_dir/stderr" \
    "r3-f2-pre-suffix: the id after </pre> was not reported"
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/73 in the prose of train member $REPO_URL/71" "$case_dir/stderr" \
    "r3-f2-pre-suffix: the plain link was not reported"
  pass "review F2: a member line that ends a <pre> example still reports its link and id; nothing outside the block closes"
}

test_r3_two_blocks_refuse_the_whole_close() {
  { block 'Closes-backlog-item: two-a'; printf '\n'; block 'Closes-backlog-item: two-b'; } > "$TMP_ROOT/r3-two.md"
  refused_case r3-two-blocks 113 'line 5 holds the closes block marker text outside its one block' "$TMP_ROOT/r3-two.md" two-a two-b
  pass "a body with two closes blocks refuses the whole close, names why and closes nothing"
}

test_r3_a_missing_or_misplaced_end_line_refuses_the_whole_close() {
  printf '%s\n' "$CLOSES_BEGIN" 'Closes-backlog-item: no-end-a' '' '## Backlog items' > "$TMP_ROOT/r3-no-end.md"
  refused_case r3-no-end 114 'its closes block has no end line' "$TMP_ROOT/r3-no-end.md" no-end-a
  printf '%s\n' "$CLOSES_END" 'Closes-backlog-item: end-first-a' "$CLOSES_BEGIN" > "$TMP_ROOT/r3-end-first.md"
  refused_case r3-end-first 115 'its first non-empty line, line 1, holds the closes block marker text but is not exactly the begin line' "$TMP_ROOT/r3-end-first.md" end-first-a
  pass "a block with no end line, or an end line before its begin line, refuses the whole close and closes nothing"
}

# shellcheck disable=SC2016 # Backticks in the fixture body are literal Markdown.
test_r3_marker_text_inside_other_text_refuses_the_whole_close() {
  { printf '%s\n' "Write \`$CLOSES_BEGIN\` above the lines." ''; block 'Closes-backlog-item: marker-text-a'; } > "$TMP_ROOT/r3-marker-text.md"
  refused_case r3-marker-text 116 'its first non-empty line, line 1, holds the closes block marker text but is not exactly the begin line' "$TMP_ROOT/r3-marker-text.md" marker-text-a
  printf '%s\n' "  $CLOSES_BEGIN" 'Closes-backlog-item: indented-marker-a' "$CLOSES_END" > "$TMP_ROOT/r3-indented-marker.md"
  refused_case r3-indented-marker 117 'its first non-empty line, line 1, holds the closes block marker text but is not exactly the begin line' "$TMP_ROOT/r3-indented-marker.md" indented-marker-a
  pass "marker text inside other text, an indented marker included, refuses the whole close"
}

test_r3_a_line_in_the_block_that_is_no_directive_refuses_the_whole_close() {
  local n=118 line
  for line in 'Some prose.' 'Closes: old-in-block' 'Closes-backlog-item: two words' '  Closes-backlog-item: indented-in-block' '```' \
    'closes-backlog-item: lower-in-block' 'Closes-backlog-item: .hidden'; do
    block 'Closes-backlog-item: tainted-a' "$line" > "$TMP_ROOT/r3-tainted-$n.md"
    refused_case "r3-tainted-$n" "$n" "line 3 inside its closes block (is not exactly a Closes-backlog-item: <item-id> line, a Train-member: <url> line or an empty line|holds a tab)" \
      "$TMP_ROOT/r3-tainted-$n.md" tainted-a
    n=$((n + 1))
  done
  pass "a prose line, an old Closes: line, a malformed, indented or lower-case directive or a fence line inside the block refuses the whole close"
}

test_r3_a_member_body_is_read_only_inside_its_own_block() {
  local case_dir
  case_dir=$(gh_case r3-member-block 126)
  cx_add "$case_dir" train-own-r3
  cx_add "$case_dir" m-inside
  cx_add "$case_dir" m-outside
  cx_add "$case_dir" m2-a
  cx_add "$case_dir" m2-b
  cx_add "$case_dir" m2-meta docs
  cx_meta "$case_dir" m2-meta docs "$REPO_URL/72"
  block "Train-member: $REPO_URL/71" "Train-member: $REPO_URL/72" 'Closes-backlog-item: train-own-r3' > "$case_dir/bodies/126"
  { block 'Closes-backlog-item: m-inside'; printf '%s\n' '' 'Closes-backlog-item: m-outside'; } > "$case_dir/bodies/71"
  { block 'Closes-backlog-item: m2-a'; printf '\n'; block 'Closes-backlog-item: m2-b'; } > "$case_dir/bodies/72"
  printf '%s\n' 71 72 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 126 --merge
  [ "$(cx_state "$case_dir" train-own-r3)" = "done" ] || fail "r3-member-block: the train's own block did not close its item"
  [ "$(cx_state "$case_dir" m-inside)" = "done" ] || fail "r3-member-block: the member's block did not close its item"
  [ "$(cx_state "$case_dir" m-outside)" = queued ] || fail "r3-member-block: a member line outside its block closed"
  [ "$(cx_state "$case_dir" m2-a)" = queued ] || fail "r3-member-block: a member body with two blocks closed m2-a"
  [ "$(cx_state "$case_dir" m2-b)" = queued ] || fail "r3-member-block: a member body with two blocks closed m2-b"
  # C2 (Main 044 F4): the refused member's own pr= task is a separate source and still closes.
  [ "$(cx_state "$case_dir" m2-meta)" = "done" ] || fail "r3-member-block: the refused member's pr= task did not close"
  assert_grep "closed m2-meta with $REPO_URL/126" "$case_dir/stdout" "r3-member-block: the refused member's pr= task did not close with the train as proof"
  assert_match "^actionable: close-at-merge: ignored a directive line outside a directive block in the body of train member $REPO_URL/71: Closes-backlog-item: m-outside\$" "$case_dir/stderr" \
    "r3-member-block: the member line outside its block was not reported"
  assert_match "^actionable: close-at-merge: refused to close anything named by the body of train member $REPO_URL/72: line 5 holds the closes block marker text outside its one block" "$case_dir/stderr" \
    "r3-member-block: the member body with two blocks was not refused by name"
  pass "a member body is read only inside its own block; a member body with two blocks closes none of its own items and is refused by name, while the train's block and the member's pr= task close"
}

# Main 1875 (Main 1741 stands): a carriage return is a control byte, so a block with CRLF line
# ends refuses the whole body by name; the same block with LF line ends closes each item.
test_r3_one_block_with_blank_lines_and_crlf_closes_each_line() {
  local case_dir
  case_dir=$(gh_case r3-crlf 127)
  cx_add "$case_dir" crlf-a
  cx_add "$case_dir" crlf-b
  printf '%s\r\n' "$CLOSES_BEGIN" 'Closes-backlog-item: crlf-a' '' 'Closes-backlog-item: crlf-b' "$CLOSES_END" '' 'Intro after the block.' > "$case_dir/bodies/127"
  gh_merge "$case_dir" 127
  [ "$(cx_state "$case_dir" crlf-a)" = queued ] || fail "r3-crlf: a CRLF block closed crlf-a"
  [ "$(cx_state "$case_dir" crlf-b)" = queued ] || fail "r3-crlf: a CRLF block closed crlf-b"
  assert_grep "refused to close anything named by the body of $REPO_URL/127" "$case_dir/stderr" "r3-crlf: the CRLF block was not refused by name"
  printf '%s\n' "$CLOSES_BEGIN" 'Closes-backlog-item: crlf-a' '' 'Closes-backlog-item: crlf-b' "$CLOSES_END" '' 'Intro after the block.' > "$case_dir/bodies/127"
  gh_merge "$case_dir" 127
  [ "$(cx_state "$case_dir" crlf-a)" = "done" ] || fail "r3-crlf: crlf-a did not close with LF line ends"
  [ "$(cx_state "$case_dir" crlf-b)" = "done" ] || fail "r3-crlf: crlf-b did not close with LF line ends"
  pass "a block with CRLF line ends is refused by name; the same block with LF line ends and a blank line inside closes each named item"
}

# Main 044 (A8, F1): the one real block sits at the top level of the body. A whole, valid block
# inside a code fence, a pre, code, blockquote or details element, an HTML comment or a Markdown
# quote is an example: it closes nothing and its item's dependent keeps its stored edge.
test_r4_f1_a_whole_block_inside_an_example_closes_nothing_and_keeps_its_edge() {
  local n=130 open close
  while IFS='|' read -r _ open close; do
    { printf '%s\n' 'A quoted example only, not an instruction:' "$open"; block "Closes-backlog-item: example-$n"; printf '%s\n' "$close"; } > "$TMP_ROOT/r4-example-$n.md"
    refused_case "r4-example-$n" "$n" "its first non-empty line, line 1, is not the closes block begin line" "$TMP_ROOT/r4-example-$n.md" "example-$n"
    n=$((n + 1))
  done <<'CASES'
```|```|```
~~~|~~~|~~~
<pre>|<pre>|</pre>
<code>|<code>|</code>
<blockquote>|<blockquote>|</blockquote>
<details>|<details><summary>Example</summary>|</details>
<!--|<!--|-->
CASES
  # A Markdown quote: the marker lines carry the quote prefix, so they are marker text inside
  # other text (Main 043); this one was refused before Main 044 too.
  { printf '%s\n' 'Quoted:'; block "Closes-backlog-item: example-$n" | sed 's/^/> /'; } > "$TMP_ROOT/r4-example-$n.md"
  refused_case "r4-example-$n" "$n" 'its first non-empty line, line 1, is not the closes block begin line' "$TMP_ROOT/r4-example-$n.md" "example-$n"
  pass "a whole block inside a fence, a pre, code, blockquote or details element, an HTML comment or a quote closes nothing and keeps its edge"
}

# Main 044: only the presence of opener text above the block counts, never a closer, so no text
# can make the reader decide that a container ended. Each body below holds a real container
# around the block that a reader trusting a closer would miss.
# shellcheck disable=SC2016 # Backticks in the fixture bodies are literal Markdown.
test_r4_opener_text_above_the_block_refuses_whatever_seems_to_close_it() {
  local n=140 body
  body=$TMP_ROOT/r4-probe
  # 1. A fence line inside an HTML block, then a real fence around the block.
  { printf '%s\n' '<div>' '```' '</div>' '' '```'; block "Closes-backlog-item: probe-$n"; printf '%s\n' '```'; } > "$body-$n.md"
  refused_case "r4-probe-$n" "$n" 'its first non-empty line, line 1, is not the closes block begin line' "$body-$n.md" "probe-$n"; n=$((n + 1))
  # 2. A list-item fence that a column-0 line ends, then a real fence around the block.
  { printf '%s\n' '- item' '  ```' '  code' 'text' '```'; block "Closes-backlog-item: probe-$n"; printf '%s\n' '```'; } > "$body-$n.md"
  refused_case "r4-probe-$n" "$n" 'its first non-empty line, line 1, is not the closes block begin line' "$body-$n.md" "probe-$n"; n=$((n + 1))
  # 3. A closing tag inside a code span after an opening tag.
  { printf '%s\n' '<details>' 'Write `</details>` in the text.' ''; block "Closes-backlog-item: probe-$n"; } > "$body-$n.md"
  refused_case "r4-probe-$n" "$n" 'its first non-empty line, line 1, is not the closes block begin line' "$body-$n.md" "probe-$n"; n=$((n + 1))
  # 4. A pre element opened in the middle of a paragraph.
  { printf '%s\n' 'A paragraph with <pre> inside it.' ''; block "Closes-backlog-item: probe-$n"; } > "$body-$n.md"
  refused_case "r4-probe-$n" "$n" 'its first non-empty line, line 1, is not the closes block begin line' "$body-$n.md" "probe-$n"; n=$((n + 1))
  # 5. A fence closed by a longer fence, and a tilde line inside it.
  { printf '%s\n' '````' '~~~' '`````' ''; block "Closes-backlog-item: probe-$n"; } > "$body-$n.md"
  refused_case "r4-probe-$n" "$n" 'its first non-empty line, line 1, is not the closes block begin line' "$body-$n.md" "probe-$n"; n=$((n + 1))
  # 6. An HTML comment that never closes.
  { printf '%s\n' 'Intro <!-- never closed' ''; block "Closes-backlog-item: probe-$n"; } > "$body-$n.md"
  refused_case "r4-probe-$n" "$n" 'its first non-empty line, line 1, is not the closes block begin line' "$body-$n.md" "probe-$n"; n=$((n + 1))
  # 7. An inline code element, opened and closed on one line.
  { printf '%s\n' 'Use <CODE>x</CODE> here.' ''; block "Closes-backlog-item: probe-$n"; } > "$body-$n.md"
  refused_case "r4-probe-$n" "$n" 'its first non-empty line, line 1, is not the closes block begin line' "$body-$n.md" "probe-$n"
  pass "opener text above the block refuses the whole body whatever seems to close it: an HTML block, a list fence, a code span, an inline tag, a longer fence or an open comment"
}

# The compliant layout: the block first, examples below it. The block closes; the example lines
# below it close nothing and are reported.
test_r4_a_block_above_every_example_closes_and_the_examples_close_nothing() {
  local case_dir
  case_dir=$(gh_case r4-block-first 150)
  cx_add "$case_dir" first-a
  cx_add "$case_dir" below-fence
  cx_add "$case_dir" below-details
  { block 'Closes-backlog-item: first-a'
    printf '%s\n' '' '## Backlog items' '' '```' 'Closes-backlog-item: below-fence' '```' '' '<details>' '' 'Closes-backlog-item: below-details' '' '</details>' \
      '<pre>example</pre> <!-- a comment -->'; } > "$case_dir/bodies/150"
  gh_merge "$case_dir" 150
  [ "$(cx_state "$case_dir" first-a)" = "done" ] || fail "r4-block-first: the block above the examples did not close"
  [ "$(cx_state "$case_dir" below-fence)" = queued ] || fail "r4-block-first: a fenced line below the block closed"
  [ "$(cx_state "$case_dir" below-details)" = queued ] || fail "r4-block-first: a details line below the block closed"
  assert_no_grep 'refused' "$case_dir/stderr" "r4-block-first: a block above every example was refused"
  assert_match "ignored a directive line outside a directive block in the body of .*: Closes-backlog-item: below-fence\$" "$case_dir/stderr" "r4-block-first: the fenced line was not reported"
  pass "a block above every example closes; the example lines below it close nothing and are reported"
}

# Main 044 F3: a malformed directive-shaped line outside the block reports each active id and
# each pull request link on it, in the merged body and in a member body; nothing closes.
test_r4_f3_a_malformed_line_outside_the_block_reports_each_id_and_link() {
  local case_dir id
  case_dir=$(gh_case r4-f3-malformed 151)
  for id in outside-a outside-b outside-control member-out-a member-out-b train-own-151; do cx_add "$case_dir" "$id"; done
  { block 'Closes-backlog-item: train-own-151' "Train-member: $REPO_URL/71"
    printf '%s\n' '' "Closes-backlog-item: outside-a outside-b $REPO_URL/51 $REPO_URL/52" \
      "A normal mention of outside-control and $REPO_URL/53."; } > "$case_dir/bodies/151"
  { block; printf '%s\n' '' "Train-member: member-out-a member-out-b $REPO_URL/54"; } > "$case_dir/bodies/71"
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 151
  [ "$(cx_state "$case_dir" train-own-151)" = "done" ] || fail "r4-f3: the block's item did not close"
  for id in outside-a outside-b outside-control member-out-a member-out-b; do
    [ "$(cx_state "$case_dir" "$id")" = queued ] || fail "r4-f3: $id closed from a line outside the block"
  done
  for id in outside-a outside-b outside-control; do
    assert_match "^actionable: close-at-merge: mentioned $id in the prose of $REPO_URL/151: nothing was closed for it" "$case_dir/stderr" "r4-f3: $id was not reported by itself"
  done
  for id in 51 52 53; do
    assert_match "^actionable: close-at-merge: mentioned $REPO_URL/$id in the prose of $REPO_URL/151: no item was closed for it" "$case_dir/stderr" "r4-f3: link $id was not reported by itself"
  done
  for id in member-out-a member-out-b; do
    assert_match "^actionable: close-at-merge: mentioned $id in the prose of train member $REPO_URL/71: nothing was closed for it" "$case_dir/stderr" "r4-f3: the member body's $id was not reported by itself"
  done
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/54 in the prose of train member $REPO_URL/71" "$case_dir/stderr" "r4-f3: the member body's link was not reported by itself"
  assert_match "^actionable: close-at-merge: ignored a malformed directive line in the body of $REPO_URL/151: Closes-backlog-item: outside-a outside-b" "$case_dir/stderr" \
    "r4-f3: the malformed line itself was not reported"
  pass "a malformed directive-shaped line outside the block reports each id and each link on it, in the merged body and a member body; nothing closes"
}

# Main 044 open item 6: commit messages are never read for directives; only the PR body is. The
# merged commit's message holds a whole block; the body holds none, so nothing closes.
test_r4_a_commit_message_block_closes_nothing() {
  local case_dir
  case_dir=$(gh_case r4-commit-message 152)
  cx_add "$case_dir" commit-only-item
  cx_add "$case_dir" waits-commit-only
  cx "$case_dir" block waits-commit-only --by commit-only-item >/dev/null
  printf '%s\n' 'A body that names nothing.' > "$case_dir/bodies/152"
  # The forge would answer a commit read with this message; the close step must never ask.
  { printf '%s\n' 'fix(bin): a change' ''; block 'Closes-backlog-item: commit-only-item'; } > "$case_dir/commit-message"
  mv "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-plain"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --json commits"*|*"/pulls/152/commits"*|*"/commits/"*"/message"*) printf '%s\n' "\$*" >> "$case_dir/commit-reads"; cat "$case_dir/commit-message"; exit 0 ;;
esac
exec "$case_dir/fakebin/gh-plain" "\$@"
SH
  chmod +x "$case_dir/fakebin/gh"
  gh_merge "$case_dir" 152
  [ "$(cx_state "$case_dir" commit-only-item)" = queued ] || fail "r4-commit-message: a block in a commit message closed its item"
  case "$(cx_deps "$case_dir" waits-commit-only)" in *commit-only-item*) ;; *) fail "r4-commit-message: the dependent lost its edge" ;; esac
  [ ! -s "$case_dir/commit-reads" ] || fail "r4-commit-message: something read commit messages: $(cat "$case_dir/commit-reads")"
  [ "$(grep -c -- '--json body,state' "$case_dir/gh.log")" = 1 ] || fail "r4-commit-message: the close step did not read the body exactly once"
  assert_no_grep '^close-at-merge: closed ' "$case_dir/stdout" "r4-commit-message: something closed"
  pass "a closes block in a commit message closes nothing and changes no edge; only the PR body is read"
}

# Main 044 F6: the block a real ship brief teaches is the block the reader closes from. The
# brief text comes from the real bin/fm-dod-lib.sh generator (direct-PR mode); the body is built
# from the exact marker and directive forms it names, for a merge train.
# shellcheck disable=SC2016 # The backticks are the literal Markdown code marks the brief prints.
test_r4_the_ship_brief_block_closes_a_train() {
  local case_dir brief begin end item member
  brief=$(bash -c '. "$1/bin/fm-dod-lib.sh"; fm_dod_block direct-PR task-x1' _ "$ROOT") || fail "r4-brief: the brief generator failed"
  begin=$(printf '%s\n' "$brief" | grep -o '`<!-- firstmate-backlog-closes:begin -->`' | head -1 | tr -d '`')
  end=$(printf '%s\n' "$brief" | grep -o '`<!-- firstmate-backlog-closes:end -->`' | head -1 | tr -d '`')
  item=$(printf '%s\n' "$brief" | grep -o '`Closes-backlog-item: task-x1`' | head -1 | tr -d '`')
  member=$(printf '%s\n' "$brief" | grep -o '`Train-member: <PR URL>`' | head -1 | tr -d '`')
  [ -n "$begin" ] && [ -n "$end" ] && [ -n "$item" ] && [ -n "$member" ] || fail "r4-brief: the brief does not name the block's forms"
  case_dir=$(gh_case r4-brief-train 153)
  cx_add "$case_dir" brief-member-item
  cx_add "$case_dir" brief-other-item
  block 'Closes-backlog-item: brief-member-item' > "$case_dir/bodies/71"
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  printf '%s\n' "$begin" "${item/task-x1/brief-other-item}" "${member/<PR URL>/$REPO_URL/71}" "$end" '' 'Notes below the block.' > "$case_dir/bodies/153"
  gh_merge "$case_dir" 153
  [ "$(cx_state "$case_dir" brief-other-item)" = "done" ] || fail "r4-brief: the item line in the brief's form did not close"
  [ "$(cx_state "$case_dir" brief-member-item)" = "done" ] || fail "r4-brief: the member line in the brief's form did not close its member's item"
  pass "the block the real ship brief teaches, built for a merge train, closes the train's and its member's items"
}

# Main 045 cases for tests/fm-pr-close-items.test.sh (inserted before the case list by
# edit-tests-045.py). Each fails at 6a3422eae and passes at the fix, with a control.

# A body as large as a PR body allows (and larger) must be read whole with no write error. Under
# bash 3.2 a builtin printf that is blocked on a full pipe fails with "Interrupted system call" when
# a child exits; the reader once printed every line from bash loops and hit that on large bodies
# (logs/main044/eintr). The one parse runs ten times per record type on a 300 KB and a 60 KB body.
test_r4_a_large_body_is_read_with_no_write_error() {
  local body n=0 size fn out want run
  for size in 300000 60000; do
    body=$TMP_ROOT/r4-large-$size.md
    { block 'Closes-backlog-item: large-a'
      awk -v size="$size" 'BEGIN { for (i = 0; t < size; i++) { l = sprintf("Closes-backlog-item: out-%06d\nCloses: legacy-%06d\nplain prose line %06d with words", i, i, i); print l; t += length(l) + 1 } }'
    } > "$body"
    for fn in legacy outside id; do
      case "$fn" in
        legacy) want=$(grep -c '^Closes: ' "$body") ;;
        outside) want=$(grep -c '^Closes-backlog-item: out-' "$body") ;;
        id) want=1 ;;
      esac
      for run in 1 2 3 4 5 6 7 8 9 10; do
        out=$(bash -c '. "$1"; fm_pr_closes_parse "$2" https://github.com/example/repo/pull/1 > "$2.parse" && fm_pr_closes_get "$2.parse" "$3"' \
          _ "$ROOT/bin/fm-pr-closes-lib.sh" "$body" "$fn" 2>"$TMP_ROOT/r4-large.err" | wc -l | tr -d ' ')
        [ "$out" = "$want" ] || fail "r4-large: $fn on a $size-byte body printed $out lines, not $want"
        if grep -q 'write error' "$TMP_ROOT/r4-large.err"; then
          fail "r4-large: $fn on a $size-byte body printed a write error: $(head -1 "$TMP_ROOT/r4-large.err")"
        fi
        n=$((n + 1))
      done
      [ "$run" = 10 ] || fail "r4-large: $fn ran $run times, not 10"
    done
  done
  pass "the reader reads a 300 KB and a 60 KB body whole, $n calls, with no write error"
}

# r5_refused <name> <number> <reason-start> <body-file> <item...>: refused_case, run on a body
# file, for the Main 045 cases.
r5_refused() { refused_case "$@"; }

# Main 045 F1: a block that is not the first thing in the body is never honored, whatever
# surrounds it: a code span, a div, a details element, a table, a comment. Control: the same
# block first closes.
# shellcheck disable=SC2016 # Backticks in the fixture bodies are literal Markdown.
test_r5_f1_a_block_that_does_not_open_the_body_refuses_it() {
  local case_dir body=$TMP_ROOT/r5-f1
  printf '%s\n' 'This is an illustrative code span, not a closing instruction: `example' "$CLOSES_BEGIN" 'Closes-backlog-item: r5-span' "$CLOSES_END" 'end of example`.' > "$body-span.md"
  r5_refused r5-span 160 'its first non-empty line, line 1, is not the closes block begin line' "$body-span.md" r5-span
  printf '%s\n' 'This is an illustrative example inside a div, not a closing instruction:' '<div>' "$CLOSES_BEGIN" 'Closes-backlog-item: r5-div' "$CLOSES_END" '</div>' > "$body-div.md"
  r5_refused r5-div 161 'its first non-empty line, line 1, is not the closes block begin line' "$body-div.md" r5-div
  printf '%s\n' '| example | block |' '| --- | --- |' "$CLOSES_BEGIN" 'Closes-backlog-item: r5-table' "$CLOSES_END" > "$body-table.md"
  r5_refused r5-table 162 'its first non-empty line, line 1, is not the closes block begin line' "$body-table.md" r5-table
  printf '%s\n' '<!-- an example' "$CLOSES_BEGIN" 'Closes-backlog-item: r5-comment' "$CLOSES_END" '-->' > "$body-comment.md"
  r5_refused r5-comment 163 'its first non-empty line, line 1, is not the closes block begin line' "$body-comment.md" r5-comment
  { block 'Closes-backlog-item: r5-first-real'; printf '%s\n' '' 'Quoted below as an example:' '`'; block 'Closes-backlog-item: r5-quoted-copy'; printf '%s\n' '`'; } > "$body-copy.md"
  r5_refused r5-copy 164 'line 7 holds the closes block marker text outside its one block' "$body-copy.md" r5-first-real r5-quoted-copy
  # Control: the block first, then anything, closes.
  case_dir=$(gh_case r5-f1-control 165)
  cx_add "$case_dir" r5-control
  cx_add "$case_dir" r5-control-waiter
  cx "$case_dir" block r5-control-waiter --by r5-control >/dev/null
  { block 'Closes-backlog-item: r5-control'; printf '%s\n' '' '<div>' '`code` and <details> and ```' '</div>'; } > "$case_dir/bodies/165"
  gh_merge "$case_dir" 165
  [ "$(cx_state "$case_dir" r5-control)" = "done" ] || fail "r5-f1: the block that opens the body did not close"
  [ "$(cx_deps "$case_dir" r5-control-waiter)" = none ] || fail "r5-f1: the control's edge was not cleared"
  pass "a block in a code span, a div, a table or a comment, or a quoted second copy, refuses the whole body and keeps every edge; a block that opens the body closes"
}

# Main 045 F1 for trains: a train block inside a code span selects no member, and a member body
# whose block is inside a code span closes none of its items; the member's pr= task still goes
# through the completion. Control: a train whose block opens both bodies closes.
# shellcheck disable=SC2016 # Backticks in the fixture bodies are literal Markdown.
test_r5_f1_a_quoted_train_or_member_block_selects_nothing() {
  local case_dir
  case_dir=$(gh_case r5-train-quoted 166)
  cx_add "$case_dir" r5-quoted-member-item
  cx_add "$case_dir" r5-quoted-waiter
  cx "$case_dir" block r5-quoted-waiter --by r5-quoted-member-item >/dev/null
  printf '%s\n' 'Example of a train block inside a code span: `illustration' "$CLOSES_BEGIN" "Train-member: $REPO_URL/70" "$CLOSES_END" 'end of example`.' > "$case_dir/bodies/166"
  block 'Closes-backlog-item: r5-quoted-member-item' > "$case_dir/bodies/70"
  printf '%s\n' 70 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 166
  [ "$(cx_state "$case_dir" r5-quoted-member-item)" = queued ] || fail "r5-train: a member listed only in a quoted block closed its item"
  case "$(cx_deps "$case_dir" r5-quoted-waiter)" in *r5-quoted-member-item*) ;; *) fail "r5-train: the dependent lost its edge" ;; esac
  assert_no_grep "pr view $REPO_URL/70 --json body" "$case_dir/gh.log" "r5-train: a refused train body's member was read"
  assert_match "refused to close anything named by the body of $REPO_URL/166: .*pull request links: $REPO_URL/70" "$case_dir/stderr" "r5-train: the refusal did not name the member link"
  case_dir=$(gh_case r5-member-quoted 167)
  cx_add "$case_dir" r5-member-quoted-item
  cx_add "$case_dir" r5-member-quoted-waiter
  cx "$case_dir" block r5-member-quoted-waiter --by r5-member-quoted-item >/dev/null
  cx_add "$case_dir" r5-member-meta docs
  cx_meta "$case_dir" r5-member-meta docs "$REPO_URL/71"
  block "Train-member: $REPO_URL/71" > "$case_dir/bodies/167"
  printf '%s\n' 'An example only, not authority: `illustration' "$CLOSES_BEGIN" 'Closes-backlog-item: r5-member-quoted-item' "$CLOSES_END" 'end of example`.' > "$case_dir/bodies/71"
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 167
  [ "$(cx_state "$case_dir" r5-member-quoted-item)" = queued ] || fail "r5-member: an item quoted in a member body closed"
  case "$(cx_deps "$case_dir" r5-member-quoted-waiter)" in *r5-member-quoted-item*) ;; *) fail "r5-member: the dependent lost its edge" ;; esac
  [ "$(cx_state "$case_dir" r5-member-meta)" = "done" ] || fail "r5-member: the member's pr= docs task did not close"
  assert_match "refused to close anything named by the body of train member $REPO_URL/71: .*item ids: r5-member-quoted-item" "$case_dir/stderr" "r5-member: the member refusal did not name its item"
  pass "a quoted train block selects no member and reads none; a quoted member block closes none of its items while the member's pr= task closes"
}

# Main 045 F2 and Main 047: every block line is checked by the one grammar before any close. A
# vertical tab, a Gerrit URL, a non-canonical URL (leading zero), the train itself, a two-space
# directive, a trailing space, a tab and a non-ASCII byte each refuse the whole body; the direct item and its edge stay. A retry after the
# repair closes.
test_r5_f2_the_strict_grammar_refuses_every_doubtful_block() {
  local case_dir body=$TMP_ROOT/r5-f2 n=170 name
  { printf '%s\n' "$CLOSES_BEGIN" 'Closes-backlog-item: r5-vtab'; printf 'Train-member: not-a-url\013extra\n'; printf '%s\n' "$CLOSES_END"; } > "$body-vtab.md"
  r5_refused r5-vtab 170 'line 3 inside its closes block holds a tab, a control byte or a byte that is not printable ASCII' "$body-vtab.md" r5-vtab
  block 'Closes-backlog-item: r5-gerrit' 'Train-member: https://gerrit.example.com/c/project/+/12345' > "$body-gerrit.md"
  r5_refused r5-gerrit 171 'its closes block names Train-member https://gerrit[.]example[.]com/c/project/[+]/12345, a gerrit URL' "$body-gerrit.md" r5-gerrit
  block 'Closes-backlog-item: r5-leading-zero' "Train-member: $REPO_URL/05" > "$body-zero.md"
  r5_refused r5-leading-zero 172 "its closes block names Train-member $REPO_URL/05, which is not a GitHub, GitLab or Forgejo pull request URL" "$body-zero.md" r5-leading-zero
  block 'Closes-backlog-item: r5-self' "Train-member: $REPO_URL/173" > "$body-self.md"
  r5_refused r5-self 173 'line 3 inside its closes block names the merged pull request itself as a Train-member' "$body-self.md" r5-self
  block 'Closes-backlog-item:  r5-two-spaces' > "$body-two.md"
  r5_refused r5-two-spaces 174 'line 2 inside its closes block is not exactly' "$body-two.md" r5-two-spaces
  block 'Closes-backlog-item: r5-trailing ' > "$body-trail.md"
  r5_refused r5-trailing 175 'line 2 inside its closes block is not exactly' "$body-trail.md" r5-trailing
  { printf '%s\n' "$CLOSES_BEGIN"; printf 'Closes-backlog-item: r5-tab\t\n'; printf '%s\n' "$CLOSES_END"; } > "$body-tab.md"
  r5_refused r5-tab 176 'line 2 inside its closes block holds a tab' "$body-tab.md" r5-tab
  { printf '%s\n' "$CLOSES_BEGIN" 'Closes-backlog-item: r5-ascii'; printf 'Closes-backlog-item: caf\303\251\n'; printf '%s\n' "$CLOSES_END"; } > "$body-ascii.md"
  r5_refused r5-ascii 177 'line 3 inside its closes block holds a tab, a control byte or a byte that is not printable ASCII' "$body-ascii.md" r5-ascii
  # Retry after the repair: the same case closes.
  case_dir=$(gh_case r5-f2-retry 178)
  cx_add "$case_dir" r5-retry
  block 'Closes-backlog-item: r5-retry' 'Train-member: https://gerrit.example.com/c/project/+/12345' > "$case_dir/bodies/178"
  gh_merge "$case_dir" 178
  [ "$(cx_state "$case_dir" r5-retry)" = queued ] || fail "r5-f2: the Gerrit block closed its item"
  block 'Closes-backlog-item: r5-retry' > "$case_dir/bodies/178"
  run_close "$case_dir" task-x1 "$REPO_URL/178" > "$case_dir/retry.out" 2> "$case_dir/retry.err" || true
  [ "$(cx_state "$case_dir" r5-retry)" = "done" ] || fail "r5-f2: the retry after the repair did not close"
  pass "a vertical tab, a Gerrit or non-canonical member, the train itself, two spaces, a trailing space, a tab or a non-ASCII byte refuses the whole block and keeps its edge; the retry after the repair closes"
}

# Main 045 F3: a refusal names each direct item id and each pull request link it saw, and a
# one-token malformed Train-member line outside any block reports its id and its link.
test_r5_f3_every_refusal_and_malformed_line_names_its_ids_and_links() {
  local case_dir
  case_dir=$(gh_case r5-f3-refusal 180)
  cx_add "$case_dir" r5-direct-a
  cx_add "$case_dir" r5-direct-b
  block 'Closes-backlog-item: r5-direct-a' 'Closes-backlog-item: r5-direct-b' "Train-member: $REPO_URL/71" 'Train-member: https://example.com/not-a-pr' > "$case_dir/bodies/180"
  gh_merge "$case_dir" 180
  assert_match "^actionable: close-at-merge: refused to close anything named by the body of $REPO_URL/180: .*; it names item ids: r5-direct-a, r5-direct-b; pull request links: $REPO_URL/71, https://example.com/not-a-pr; " "$case_dir/stderr" \
    "r5-f3: the refusal did not name every direct item and link"
  [ "$(cx_state "$case_dir" r5-direct-a)" = queued ] && [ "$(cx_state "$case_dir" r5-direct-b)" = queued ] || fail "r5-f3: a refused body closed an item"
  case_dir=$(gh_case r5-f3-outside 181)
  cx_add "$case_dir" r5-outside
  printf '%s\n' "Train-member: r5-outside,$REPO_URL/51" > "$case_dir/bodies/181"
  gh_merge "$case_dir" 181
  [ "$(cx_state "$case_dir" r5-outside)" = queued ] || fail "r5-f3: an outside line closed its item"
  assert_match "^actionable: close-at-merge: mentioned r5-outside in the prose of $REPO_URL/181: nothing was closed for it" "$case_dir/stderr" "r5-f3: the one-token line's id was not reported"
  assert_match "^actionable: close-at-merge: mentioned $REPO_URL/51 in the prose of $REPO_URL/181: no item was closed for it" "$case_dir/stderr" "r5-f3: the one-token line's link was not reported"
  # Control: ordinary prose still reports its id once.
  assert_match "ignored a directive line outside a directive block in the body of $REPO_URL/181: Train-member: r5-outside,$REPO_URL/51" "$case_dir/stderr" "r5-f3: the line itself was not reported"
  pass "a refusal names every direct item id and pull request link; a one-token malformed outside line reports its id and its link"
}

# Main 045 F5, the intended cost: a real block below closed example text is refused by name and
# closes nothing; the same block first closes.
test_r5_f5_a_real_block_below_closed_example_text_is_refused_by_name() {
  local case_dir
  printf '%s\n' 'An earlier, closed example:' '```' 'ordinary example text' '```' 'A genuine block follows.' "$CLOSES_BEGIN" 'Closes-backlog-item: r5-below' "$CLOSES_END" > "$TMP_ROOT/r5-below.md"
  r5_refused r5-below 182 'its first non-empty line, line 1, is not the closes block begin line' "$TMP_ROOT/r5-below.md" r5-below
  case_dir=$(gh_case r5-first 183)
  cx_add "$case_dir" r5-first
  { block 'Closes-backlog-item: r5-first'; printf '%s\n' '' 'An earlier, closed example:' '```' 'ordinary example text' '```'; } > "$case_dir/bodies/183"
  gh_merge "$case_dir" 183
  [ "$(cx_state "$case_dir" r5-first)" = "done" ] || fail "r5-f5: the block that opens the body did not close"
  pass "a real block below closed example text is refused by name (the intended cost); the same block first closes"
}

# Main 046: one parse. The close step reads each body exactly once.
test_r5_one_parse_owns_the_block() {
  local case_dir
  case_dir=$(gh_case r5-one-parse 184)
  cx_add "$case_dir" r5-one
  block 'Closes-backlog-item: r5-one' "Train-member: $REPO_URL/71" > "$case_dir/bodies/184"
  block 'Closes-backlog-item: r5-one-member' > "$case_dir/bodies/71"
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  cx_add "$case_dir" r5-one-member
  gh_merge "$case_dir" 184
  [ "$(grep -c "pr view $REPO_URL/184 --json body" "$case_dir/gh.log")" = 1 ] || fail "r5-one-parse: the merged body was read more than once"
  [ "$(grep -c "pr view $REPO_URL/71 --json body" "$case_dir/gh.log")" = 1 ] || fail "r5-one-parse: the member body was read more than once"
  [ "$(cx_state "$case_dir" r5-one)" = "done" ] && [ "$(cx_state "$case_dir" r5-one-member)" = "done" ] || fail "r5-one-parse: the control did not close"
  # Main 1785 F4: the close and the report read each exact directive line with one token: on a
  # valid block the seenid records equal the id records, trailing dot included.
  printf '%s\n' "$CLOSES_BEGIN" 'Closes-backlog-item: agree-a' 'Closes-backlog-item: agree-b.' "$CLOSES_END" > "$TMP_ROOT/r5-agree.md"
  bash -c '. "$1"; fm_pr_closes_parse "$2" https://github.com/o/r/pull/1' _ "$ROOT/bin/fm-pr-closes-lib.sh" "$TMP_ROOT/r5-agree.md" > "$TMP_ROOT/r5-agree.parse" \
    || fail "r5-one-parse: the agreement parse failed"
  [ "$(awk -F '\t' '$1 == "id" {print $2}' "$TMP_ROOT/r5-agree.parse")" = "$(awk -F '\t' '$1 == "seenid" {print $2}' "$TMP_ROOT/r5-agree.parse")" ] \
    || fail "r5-one-parse: the close and the report read the ids differently: $(tr '\n' ' ' < "$TMP_ROOT/r5-agree.parse")"
  pass "one parse: the library offers only fm_pr_closes_parse, its pass and fm_pr_closes_get, the close step calls no other reader, each body is read once, and the close and the report read ids alike"
}

# The parse result, through the library.
test_r5_the_parse_result() {
  local body=$TMP_ROOT/r5-parse.md out
  { block 'Closes-backlog-item: p-a' '' "Train-member: https://github.com/o/r/pull/5" 'Closes-backlog-item: p-a'
    printf '%s\n' 'Prose with fm-prose-id and https://github.com/o/r/pull/9.' 'Closes: legacy-outside' 'Closes-backlog-item: outside-line' 'Closes-backlog-item: bad # x'; } > "$body"
  out=$(bash -c '. "$1"; fm_pr_closes_parse "$2" https://github.com/o/r/pull/1' _ "$ROOT/bin/fm-pr-closes-lib.sh" "$body") || fail "r5-parse: the parse failed"
  [ "$(printf '%s\n' "$out" | sed -n '1p')" = "$(printf 'status\tblock')" ] || fail "r5-parse: status: $(printf '%s\n' "$out" | sed -n '1p')"
  [ "$(printf '%s\n' "$out" | awk -F '\t' '$1 == "id" {print $2}' | tr '\n' ' ')" = 'p-a ' ] || fail "r5-parse: ids"
  [ "$(printf '%s\n' "$out" | awk -F '\t' '$1 == "member" {print $2}')" = https://github.com/o/r/pull/5 ] || fail "r5-parse: members"
  [ "$(printf '%s\n' "$out" | awk -F '\t' '$1 == "legacy" {print $2}')" = legacy-outside ] || fail "r5-parse: legacy"
  [ "$(printf '%s\n' "$out" | awk -F '\t' '$1 == "outside" {print $2}')" = 'Closes-backlog-item: outside-line' ] || fail "r5-parse: outside"
  [ "$(printf '%s\n' "$out" | awk -F '\t' '$1 == "malformed" {print $2}')" = 'Closes-backlog-item: bad # x' ] || fail "r5-parse: malformed"
  printf '%s\n' "$out" | grep -qx "$(printf 'word\tfm-prose-id')" || fail "r5-parse: prose word"
  printf '%s\n' "$out" | grep -qx "$(printf 'link\thttps://github.com/o/r/pull/9')" || fail "r5-parse: prose link"
  printf '%s\n' 'No marker here.' 'Closes-backlog-item: loose' > "$body"
  out=$(bash -c '. "$1"; fm_pr_closes_parse "$2" https://github.com/o/r/pull/1' _ "$ROOT/bin/fm-pr-closes-lib.sh" "$body")
  [ "$(printf '%s\n' "$out" | sed -n '1p')" = "$(printf 'status\tnone')" ] || fail "r5-parse: a body with no marker is not status none"
  # Main 1875 (Main 1741 stands): a carriage return is a control byte, so a CRLF block refuses;
  # a leading empty line before an LF block is fine.
  printf '\r\n%s\r\n%s\r\n%s\r\n' "$CLOSES_BEGIN" 'Closes-backlog-item: crlf-a' "$CLOSES_END" > "$body"
  out=$(bash -c '. "$1"; fm_pr_closes_parse "$2" https://github.com/o/r/pull/1' _ "$ROOT/bin/fm-pr-closes-lib.sh" "$body")
  [ "${out%%$'\n'*}" = "$(printf 'status\trefused')" ] || fail "r5-parse: a CRLF block was not refused"
  printf '\n%s\n%s\n%s\n' "$CLOSES_BEGIN" 'Closes-backlog-item: lf-a' "$CLOSES_END" > "$body"
  out=$(bash -c '. "$1"; fm_pr_closes_parse "$2" https://github.com/o/r/pull/1' _ "$ROOT/bin/fm-pr-closes-lib.sh" "$body")
  [ "$(awk -F '\t' '$1 == "id" {print $2}' <<< "$out")" = lf-a ] || fail "r5-parse: an LF block after an empty line gave no id"
  [ "${out##*$'\n'}" = "$(printf 'end\tcomplete')" ] || fail "r5-parse: the result does not end with its end record"
  pass "the parse gives status, ids, members, outside, malformed and legacy lines, words and links in one result, ending with its end record; no marker is status none; a CRLF block refuses and a leading empty line is fine"
}

# Main 2086: a typed completion whose row's show fails still clears its finished edge in the same
# run, because its own printed result decides; the other blocker and the hold stay.
# Control: a plain waive with a readable row.
test_r5_f4_a_waive_whose_state_read_fails_still_clears_the_edge() {
  local case_dir rc=0 deps read_fail
  case_dir=$(make_case r5-f4-waive)
  read_fail=$case_dir/read-fail
  wrapper() { FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "$@"; }
  cat > "$case_dir/request.json" <<'JSON'
{"request_id":"req-r5","platform":"x","context_binding":{"version":"ctx1","value":"ctx1_r5"},"public_safe_summary":"fixture","received_at":"2026-07-30T10:00:00Z","followup_expires_at":"2026-08-06T10:00:00Z","reservation_expires_at":"2026-08-06T10:00:00Z"}
JSON
  cat > "$case_dir/expected.json" <<'JSON'
{"type":"pr-merged","project":"fixture","required_deliverables":["pr_url"],"completion_policy":"all-required"}
JSON
  for pf in pf-read-fails pf-control; do
    wrapper public-followup add "$pf" --request-context-file "$case_dir/request.json" --purpose promised-final \
      --expected-final-file "$case_dir/expected.json" --expires-at 2099-10-01T00:00:00Z >/dev/null 2>&1 || fail "r5-f4: could not add $pf"
    cx_add "$case_dir" "waits-$pf" docs
    cx_add "$case_dir" "other-$pf" docs
    cx "$case_dir" block "waits-$pf" --by "$pf" >/dev/null
    cx "$case_dir" block "waits-$pf" --by "other-$pf" >/dev/null
    cx "$case_dir" hold "waits-$pf" --reason "fixture hold" --kind future >/dev/null
  done
  # A tasks-axi in front of the real one fails only the read of pf-read-fails, once the waive ran.
  mkdir -p "$case_dir/shim"
  real=$(command -v tasks-axi)
  cat > "$case_dir/shim/tasks-axi" <<SH
#!/usr/bin/env bash
if [ -e "$read_fail" ] && [ "\${1:-}" = show ] && [ "\${2:-}" = pf-read-fails ]; then echo 'error: simulated read failure' >&2; exit 1; fi
exec "$real" "\$@"
SH
  chmod +x "$case_dir/shim/tasks-axi"
  touch "$read_fail"
  (PATH="$case_dir/shim:$PATH" wrapper public-followup waive pf-read-fails --reason r --approved-by captain) > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  rm -f "$read_fail"
  expect_code 0 "$rc" "r5-f4: the waive itself must succeed"
  [ "$(cx_state "$case_dir" pf-read-fails)" = "done" ] || fail "r5-f4: the waive did not finish the obligation"
  deps=$(cx_deps "$case_dir" waits-pf-read-fails | sed 's/blocked-by://g; s/[ "]//g')
  [ "$deps" = other-pf-read-fails ] || fail "r5-f4: after a failed show the stored list is not the other blocker alone ($deps)"
  cx "$case_dir" show waits-pf-read-fails | grep -q 'hold_kind: future' || fail "r5-f4: the hold was lost"
  # Control: the readable waive clears its edge the same way.
  wrapper public-followup waive pf-control --reason r --approved-by captain > "$case_dir/out2" 2> "$case_dir/err2" || fail "r5-f4: the control waive failed"
  deps=$(cx_deps "$case_dir" waits-pf-control | sed 's/blocked-by://g; s/[ "]//g')
  [ "$deps" = other-pf-control ] || fail "r5-f4: the control's stored list is not the other blocker alone ($deps)"
  pass "a waive whose show fails clears its finished edge in the same run from its own printed result; the other blocker and the hold stay; the readable control clears too"
}


# Main 1785 F1: a body file that a read step writes only in part, then fails, is no read. The
# fake sed and tail write only the first block of a two-block body and then fail, so a reader
# that trusts the cut file would close its item. Controls: the complete two-block body refuses;
# a valid single block closes.
test_r6_f1_a_partial_body_write_refuses_the_whole_body() {
  local case_dir real_sed rc=0
  case_dir=$(gh_case r6-partial 190)
  cx_add "$case_dir" r6-partial
  cx_add "$case_dir" r6-partial-waiter
  cx "$case_dir" block r6-partial-waiter --by r6-partial >/dev/null
  cx_add "$case_dir" r6-missing
  { block 'Closes-backlog-item: r6-partial'; block 'Closes-backlog-item: r6-missing'; } > "$case_dir/bodies/190"
  real_sed=$(command -v sed)
  cat > "$case_dir/fakebin/sed" <<SH
#!/usr/bin/env bash
# Only the close step's body extraction (sed 1d on the forge answer) is cut short.
if [ "\$#" -eq 1 ] && [ "\$1" = 1d ]; then "$real_sed" -n '2,4p'; echo 'simulated body write failure' >&2; exit 1; fi
exec "$real_sed" "\$@"
SH
  cat > "$case_dir/fakebin/tail" <<SH
#!/usr/bin/env bash
case "\${3:-}" in *.raw) if [ "\$1" = -n ] && [ "\$2" = +2 ]; then "$real_sed" -n '2,4p' "\$3"; echo 'simulated body write failure' >&2; exit 1; fi ;; esac
exec /usr/bin/tail "\$@"
SH
  chmod +x "$case_dir/fakebin/sed" "$case_dir/fakebin/tail"
  run_close "$case_dir" task-x1 "$REPO_URL/190" > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  rm -f "$case_dir/fakebin/sed" "$case_dir/fakebin/tail"
  [ "$(cx_state "$case_dir" r6-partial)" = queued ] || fail "r6-partial: a cut body closed its first block's item"
  case "$(cx_deps "$case_dir" r6-partial-waiter)" in *r6-partial*) ;; *) fail "r6-partial: the dependent lost its edge" ;; esac
  assert_match "^actionable: close-at-merge could not read the body of $REPO_URL/190 \\(.*simulated body write failure" "$case_dir/err" "r6-partial: the failed read was not reported with the PR and the reason"
  # Controls: the complete body refuses; a valid single block closes.
  run_close "$case_dir" task-x1 "$REPO_URL/190" > "$case_dir/out2" 2> "$case_dir/err2" || true
  assert_match "refused to close anything named by the body of $REPO_URL/190: line 4 holds the closes block marker text outside its one block" "$case_dir/err2" "r6-partial: the complete two-block body was not refused"
  [ "$(cx_state "$case_dir" r6-partial)" = queued ] || fail "r6-partial: the complete two-block body closed an item"
  block 'Closes-backlog-item: r6-partial' > "$case_dir/bodies/190"
  run_close "$case_dir" task-x1 "$REPO_URL/190" > "$case_dir/out3" 2> "$case_dir/err3" || true
  [ "$(cx_state "$case_dir" r6-partial)" = "done" ] || fail "r6-partial: the valid single block did not close"
  pass "a body that a read step writes only in part refuses the whole body with the PR and the reason; the complete two-block body refuses and a valid block closes"
}

# Main 1785 F2: a NUL byte in a member value refuses the whole body before any parse or effect,
# however a tool on the way would treat it. Controls: a vertical tab refuses; a compliant block
# closes. Real-forge transport of a NUL byte is not exercised here.
test_r6_f2_a_nul_byte_refuses_the_whole_body() {
  local case_dir
  case_dir=$(gh_case r6-nul 191)
  for id in r6-nul r6-nul-member; do cx_add "$case_dir" "$id"; cx_add "$case_dir" "$id-waiter"; cx "$case_dir" block "$id-waiter" --by "$id" >/dev/null; done
  { printf '%s\n' "$CLOSES_BEGIN" 'Closes-backlog-item: r6-nul'; printf 'Train-member: https://github.com/example/re\000po/pull/70\n'; printf '%s\n' "$CLOSES_END"; } > "$case_dir/bodies/191"
  block 'Closes-backlog-item: r6-nul-member' > "$case_dir/bodies/70"
  printf '%s\n' 70 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 191
  for id in r6-nul r6-nul-member; do
    [ "$(cx_state "$case_dir" "$id")" = queued ] || fail "r6-nul: $id closed from a body that holds a NUL byte"
    case "$(cx_deps "$case_dir" "$id-waiter")" in *"$id"*) ;; *) fail "r6-nul: $id's dependent lost its edge" ;; esac
  done
  assert_match "refused to close anything named by the body of $REPO_URL/191: the body contains a NUL byte" "$case_dir/stderr" "r6-nul: the NUL body was not refused by name"
  assert_no_grep "pr view $REPO_URL/70 --json body" "$case_dir/gh.log" "r6-nul: a member of the NUL body was read"
  # Controls: a vertical tab refuses; a compliant block closes.
  { printf '%s\n' "$CLOSES_BEGIN" 'Closes-backlog-item: r6-nul'; printf 'Train-member: https://github.com/example/re\013po/pull/70\n'; printf '%s\n' "$CLOSES_END"; } > "$case_dir/bodies/191"
  run_close "$case_dir" task-x1 "$REPO_URL/191" > "$case_dir/out2" 2> "$case_dir/err2" || true
  assert_match "refused to close anything named by the body of $REPO_URL/191: line 3 inside its closes block holds a tab, a control byte" "$case_dir/err2" "r6-nul: the vertical-tab control was not refused"
  block 'Closes-backlog-item: r6-nul' > "$case_dir/bodies/191"
  run_close "$case_dir" task-x1 "$REPO_URL/191" > "$case_dir/out3" 2> "$case_dir/err3" || true
  [ "$(cx_state "$case_dir" r6-nul)" = "done" ] || fail "r6-nul: the compliant block did not close"
  pass "a NUL byte in a member value refuses the whole body and reads no member; a vertical tab refuses; a compliant block closes"
}

# Main 1785 F3: a parse that fails is an actionable non-close that names the PR, the body and
# the reason, with the ids the same pass can read; for the merged body and for a member body.
# Controls: the normal parse closes; an unreadable body is reported (test_an_unreadable_body_...).
# fake_parse_mktemp <case-dir>: a mktemp in the case's fakebin that fails the Nth parse snapshot
# (N in <case-dir>/fail-at; 1 is the merged body, 2 the first member body).
fake_parse_mktemp() {
  local real_mktemp
  real_mktemp=$(command -v mktemp)
  cat > "$1/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  */fm-pr-closes.*)
    n=\$(( \$(cat "$1/mktemp-count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$1/mktemp-count"
    [ "\$n" != "\$(cat "$1/fail-at")" ] || { echo 'simulated snapshot failure' >&2; exit 1; } ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$1/fakebin/mktemp"
}

test_r6_f3_a_parse_failure_is_reported_and_closes_nothing() {
  local case_dir
  case_dir=$(gh_case r6-parse 192)
  cx_add "$case_dir" r6-parse
  cx_add "$case_dir" r6-parse-waiter
  cx "$case_dir" block r6-parse-waiter --by r6-parse >/dev/null
  block 'Closes-backlog-item: r6-parse' > "$case_dir/bodies/192"
  fake_parse_mktemp "$case_dir"
  echo 1 > "$case_dir/fail-at"
  run_close "$case_dir" task-x1 "$REPO_URL/192" > "$case_dir/out" 2> "$case_dir/err" || true
  [ "$(cx_state "$case_dir" r6-parse)" = queued ] || fail "r6-parse: an item closed from a body whose parse failed"
  case "$(cx_deps "$case_dir" r6-parse-waiter)" in *r6-parse*) ;; *) fail "r6-parse: the dependent lost its edge" ;; esac
  assert_match "^actionable: close-at-merge: could not parse the body of $REPO_URL/192, so nothing named by it was closed and no blocked-by edge changed: the parse could not make its snapshot; it names item ids: r6-parse; " "$case_dir/err" \
    "r6-parse: the merged body's parse failure was not reported with the PR, the reason and its id"
  # A member body whose parse fails: the train's own item closes, the member's does not.
  case_dir=$(gh_case r6-parse-member 193)
  fake_parse_mktemp "$case_dir"
  echo 2 > "$case_dir/fail-at"
  cx_add "$case_dir" r6-train-own
  cx_add "$case_dir" r6-member-item
  block 'Closes-backlog-item: r6-train-own' "Train-member: $REPO_URL/71" > "$case_dir/bodies/193"
  block 'Closes-backlog-item: r6-member-item' > "$case_dir/bodies/71"
  printf '%s\n' 71 >> "$case_dir/merged-prs"
  run_close "$case_dir" task-x1 "$REPO_URL/193" > "$case_dir/out" 2> "$case_dir/err" || true
  [ "$(cx_state "$case_dir" r6-train-own)" = "done" ] || fail "r6-parse-member: the train's own item did not close"
  [ "$(cx_state "$case_dir" r6-member-item)" = queued ] || fail "r6-parse-member: an item closed from a member body whose parse failed"
  assert_match "^actionable: close-at-merge: could not parse the body of train member $REPO_URL/71, .*: the parse could not make its snapshot; it names item ids: r6-member-item; " "$case_dir/err" \
    "r6-parse-member: the member body's parse failure was not reported"
  # Control: with no failure the member's item closes.
  rm -f "$case_dir/fakebin/mktemp"
  run_close "$case_dir" task-x1 "$REPO_URL/193" > "$case_dir/out2" 2> "$case_dir/err2" || true
  [ "$(cx_state "$case_dir" r6-member-item)" = "done" ] || fail "r6-parse-member: the normal parse did not close the member's item"
  pass "a failed parse of the merged body or of a member body closes nothing from it and is reported with the PR, the body, the reason and its ids; the normal parse closes"
}

# Main 1785 F4: one token reading for closes and reports. A refused block names each accepted id
# exactly as written, trailing dot included; a valid block with that id closes it.
test_r6_f4_a_refusal_spells_each_id_exactly() {
  local case_dir out
  case_dir=$(gh_case r6-dot 194)
  for id in 'r6-dot.' r6-plain; do cx_add "$case_dir" "$id"; cx_add "$case_dir" "w-$id"; cx "$case_dir" block "w-$id" --by "$id" >/dev/null; done
  block 'Closes-backlog-item: r6-dot.' 'Closes-backlog-item: r6-plain' 'Train-member: https://example.com/not-a-pr' > "$case_dir/bodies/194"
  gh_merge "$case_dir" 194
  out=$(grep "^actionable: close-at-merge: refused to close anything named by the body of $REPO_URL/194: " "$case_dir/stderr")
  case "$out" in *"its closes block names Train-member https://example.com/not-a-pr, which is not"*"; it names item ids: r6-dot., r6-plain; "*) ;; *) fail "r6-dot: the refusal did not spell each id exactly with the invalid-member reason: $out" ;; esac
  for id in 'r6-dot.' r6-plain; do
    [ "$(cx_state "$case_dir" "$id")" = queued ] || fail "r6-dot: $id closed from a refused block"
    case "$(cx_deps "$case_dir" "w-$id")" in *"$id"*) ;; *) fail "r6-dot: $id's dependent lost its edge" ;; esac
  done
  # Control: the valid block closes the trailing-dot id.
  block 'Closes-backlog-item: r6-dot.' > "$case_dir/bodies/194"
  run_close "$case_dir" task-x1 "$REPO_URL/194" > "$case_dir/out2" 2> "$case_dir/err2" || true
  [ "$(cx_state "$case_dir" 'r6-dot.')" = "done" ] || fail "r6-dot: the valid block did not close the trailing-dot id"
  pass "a refused block names each accepted id exactly, trailing dot included, with its reason and no edge change; a valid block closes that id"
}

# Main 1785 F5: the waiver's capture file exists before the waiver runs. When it cannot be made,
# the waiver does not run, nothing changes, and the caller is told why. Control: with the file,
# the waiver runs and clears the edge.
test_r6_f5_a_waive_whose_capture_file_cannot_be_made_does_not_run() {
  local case_dir rc=0 real_mktemp
  case_dir=$(make_case r6-f5-capture)
  wrapper() { FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "$@"; }
  printf '%s' '{"request_id":"req-r6","platform":"x","context_binding":{"version":"ctx1","value":"ctx1_r6"},"public_safe_summary":"f","received_at":"2026-07-30T10:00:00Z","followup_expires_at":"2026-08-06T10:00:00Z","reservation_expires_at":"2026-08-06T10:00:00Z"}' > "$case_dir/request.json"
  printf '%s' '{"type":"pr-merged","project":"f","required_deliverables":["pr_url"],"completion_policy":"all-required"}' > "$case_dir/expected.json"
  wrapper public-followup add pf-cap --request-context-file "$case_dir/request.json" --purpose promised-final \
    --expected-final-file "$case_dir/expected.json" --expires-at 2099-10-01T00:00:00Z >/dev/null 2>&1 || fail "r6-f5: could not add pf-cap"
  cx_add "$case_dir" waits-pf-cap docs
  cx "$case_dir" block waits-pf-cap --by pf-cap >/dev/null
  cx_other_and_hold "$case_dir" waits-pf-cap
  real_mktemp=$(command -v mktemp)
  mkdir -p "$case_dir/shim"
  cat > "$case_dir/shim/mktemp" <<SH
#!/usr/bin/env bash
case "\${1:-}" in *fm-tasks-axi-pf.*) echo 'simulated capture failure' >&2; exit 1 ;; esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$case_dir/shim/mktemp"
  (PATH="$case_dir/shim:$PATH" wrapper public-followup waive pf-cap --reason r --approved-by captain) > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "r6-f5: a waive that did not run reported success"
  [ "$(cx_state "$case_dir" pf-cap)" != "done" ] || fail "r6-f5: the waiver ran though its capture file could not be made"
  case "$(cx_deps "$case_dir" waits-pf-cap)" in *pf-cap,*|*pf-cap\"*|*pf-cap) ;; *) fail "r6-f5: an edge changed though nothing ran" ;; esac
  assert_match '^actionable: the waive of pf-cap did not run, so nothing changed' "$case_dir/err" "r6-f5: the refusal was not reported"
  # Control: with the file the waiver runs, clears the finished edge and keeps the rest.
  wrapper public-followup waive pf-cap --reason r --approved-by captain > "$case_dir/out2" 2> "$case_dir/err2" || fail "r6-f5: the control waive failed"
  assert_only_other_and_hold "$case_dir" waits-pf-cap pf-cap "r6-f5 control"
  pass "a waive whose capture file cannot be made does not run, changes nothing and says so; with the file it runs and clears the finished edge"
}

# Main 1795 and 2086: when the completion's output is lost and the row's show fails, there is no
# result to read, so the completion's exit 0 is the proof: the finished edge clears in the same run
# and the other blocker and the hold stay, TOON and JSON, and the report says the clear rests on
# exit 0. Controls: a readable waive clears; a waive tasks-axi refuses keeps every edge.
test_r6_f5_a_completion_whose_output_is_lost_still_clears_in_the_same_run() {
  local case_dir rc=0 real
  case_dir=$(make_case r6-f5-lost)
  wrapper() { FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "$@"; }
  printf '%s' '{"request_id":"req-r6l","platform":"x","context_binding":{"version":"ctx1","value":"ctx1_r6l"},"public_safe_summary":"f","received_at":"2026-07-30T10:00:00Z","followup_expires_at":"2026-08-06T10:00:00Z","reservation_expires_at":"2026-08-06T10:00:00Z"}' > "$case_dir/request.json"
  printf '%s' '{"type":"pr-merged","project":"f","required_deliverables":["pr_url"],"completion_policy":"all-required"}' > "$case_dir/expected.json"
  for pf in pf-lost pf-lost-json pf-refused pf-readable; do
    wrapper public-followup add "$pf" --request-context-file "$case_dir/request.json" --purpose promised-final \
      --expected-final-file "$case_dir/expected.json" --expires-at 2099-10-01T00:00:00Z >/dev/null 2>&1 || fail "r6-lost: could not add $pf"
    cx_add "$case_dir" "waits-$pf" docs
    cx "$case_dir" block "waits-$pf" --by "$pf" >/dev/null
    cx_other_and_hold "$case_dir" "waits-$pf"
  done
  real=$(command -v tasks-axi)
  mkdir -p "$case_dir/shim"
  # The read of each obligation fails, and each waive runs for real but its output is lost.
  cat > "$case_dir/shim/tasks-axi" <<SH
#!/usr/bin/env bash
case "\${1:-}:\${2:-}" in show:pf-*) echo 'error: simulated read failure' >&2; exit 1 ;; esac
case "\${1:-} \${2:-}" in "public-followup waive") "$real" "\$@" >/dev/null; exit ;; esac
exec "$real" "\$@"
SH
  chmod +x "$case_dir/shim/tasks-axi"
  for pf in pf-lost pf-lost-json; do
    rc=0
    if [ "$pf" = pf-lost-json ]; then
      (PATH="$case_dir/shim:$PATH" wrapper public-followup waive "$pf" --reason r --approved-by captain --json) > "$case_dir/$pf.out" 2> "$case_dir/$pf.err" || rc=$?
    else
      (PATH="$case_dir/shim:$PATH" wrapper public-followup waive "$pf" --reason r --approved-by captain) > "$case_dir/$pf.out" 2> "$case_dir/$pf.err" || rc=$?
    fi
    expect_code 0 "$rc" "r6-lost: the $pf waive must succeed"
    [ ! -s "$case_dir/$pf.out" ] || fail "r6-lost: the fixture did not lose the $pf output"
    [ "$(cx_state "$case_dir" "$pf")" = "done" ] || fail "r6-lost: the $pf waive did not finish its row"
    assert_only_other_and_hold "$case_dir" "waits-$pf" "$pf" "r6-lost: $pf in the same run"
    assert_grep "$pf: tasks-axi printed no result the wrapper can read for its waive, so the clear rests on its exit 0" "$case_dir/$pf.err" "r6-lost: the exit-0 clear of $pf was not said"
    assert_grep "unblocked: waits-$pf no longer waits on $pf; it still waits on waits-$pf-other" "$case_dir/$pf.err" "r6-lost: the cleared edge of $pf was not reported"
  done
  # Control: a waive tasks-axi refuses is genuinely not done; every edge stays.
  rc=0
  (PATH="$case_dir/shim:$PATH" wrapper public-followup waive pf-refused --reason r --approved-by owner) > "$case_dir/refused.out" 2> "$case_dir/refused.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "r6-lost: a refused waive reported success"
  [ "$(cx_state "$case_dir" pf-refused)" != "done" ] || fail "r6-lost: the refused waive finished its row"
  case "$(cx_deps "$case_dir" waits-pf-refused | sed 's/blocked-by://g; s/[ "]//g')" in pf-refused,waits-pf-refused-other|waits-pf-refused-other,pf-refused) ;; *) fail "r6-lost: a refused waive changed an edge ($(cx_deps "$case_dir" waits-pf-refused))" ;; esac
  # Control: a readable waive clears in the same run.
  wrapper public-followup waive pf-readable --reason r --approved-by captain > "$case_dir/readable.out" 2> "$case_dir/readable.err" || fail "r6-lost: the readable waive failed"
  assert_only_other_and_hold "$case_dir" waits-pf-readable pf-readable "r6-lost: the readable waive"
  pass "a waive whose output is lost and whose show fails clears its finished edge in the same run on its exit 0, TOON and JSON, keeping the other blocker and hold, and says so; a refused waive keeps every edge; a readable waive clears"
}

# Main 2086: the completion's own printed result decides. A result that shows the row not done
# keeps every edge and hold, and the wrapper says so; the fake completion exits 0, changes nothing
# and prints such a result. A store lock held by another writer when the clear runs makes
# tasks-axi's own unblock refuse, so every edge stays and the failed clear is reported.
test_r7_f3_a_result_not_done_or_a_held_lock_keeps_every_edge() {
  local case_dir rc=0 real deps
  case_dir=$(make_case r7-f3-store)
  wrapper() { FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "$@"; }
  printf '%s' '{"request_id":"req-r7","platform":"x","context_binding":{"version":"ctx1","value":"ctx1_r7"},"public_safe_summary":"f","received_at":"2026-07-30T10:00:00Z","followup_expires_at":"2026-08-06T10:00:00Z","reservation_expires_at":"2026-08-06T10:00:00Z"}' > "$case_dir/request.json"
  printf '%s' '{"type":"pr-merged","project":"f","required_deliverables":["pr_url"],"completion_policy":"all-required"}' > "$case_dir/expected.json"
  wrapper public-followup add pf-open --request-context-file "$case_dir/request.json" --purpose promised-final \
    --expected-final-file "$case_dir/expected.json" --expires-at 2099-10-01T00:00:00Z >/dev/null 2>&1 || fail "r7-f3: could not add pf-open"
  cx_add "$case_dir" waits-pf-open docs
  cx "$case_dir" block waits-pf-open --by pf-open >/dev/null
  cx_other_and_hold "$case_dir" waits-pf-open
  real=$(command -v tasks-axi)
  mkdir -p "$case_dir/shim"
  cat > "$case_dir/shim/tasks-axi" <<SH
#!/usr/bin/env bash
case "\${1:-}:\${2:-}" in show:pf-*) echo 'error: simulated read failure' >&2; exit 1 ;; esac
case "\${1:-} \${2:-}" in "public-followup waive") printf 'ok: public-followup waive pf-open -> waived (revision 2)\npublic_followup:\n  id: pf-open\n  state: queued\n  delivery_state: waived\n'; exit 0 ;; esac
exec "$real" "\$@"
SH
  chmod +x "$case_dir/shim/tasks-axi"
  (PATH="$case_dir/shim:$PATH" wrapper public-followup waive pf-open --reason r --approved-by captain) > "$case_dir/out" 2> "$case_dir/err" || rc=$?
  expect_code 0 "$rc" "r7-f3: the wrapper must keep the completion's exit status"
  [ "$(cx_state "$case_dir" pf-open)" != "done" ] || fail "r7-f3: the fixture finished the obligation"
  deps=$(cx_deps "$case_dir" waits-pf-open | sed 's/blocked-by://g; s/[ "]//g')
  case "$deps" in pf-open,waits-pf-open-other|waits-pf-open-other,pf-open) ;; *) fail "r7-f3: an edge changed while an unfinished item holds the id ($deps)" ;; esac
  cx "$case_dir" show waits-pf-open | grep -q 'hold_kind: future' || fail "r7-f3: the hold was lost"
  assert_grep 'actionable: tasks-axi accepted the waive of pf-open, but its own result shows pf-open as queued, not done, so every blocked-by edge and hold on it is kept' "$case_dir/err" "r7-f3: the kept edges were not reported"
  # A lock held by another writer when the clear runs: tasks-axi's own unblock refuses, so the
  # finished waive's edges are kept and the failed clear is reported.
  wrapper public-followup add pf-locked --request-context-file "$case_dir/request.json" --purpose promised-final \
    --expected-final-file "$case_dir/expected.json" --expires-at 2099-10-01T00:00:00Z >/dev/null 2>&1 || fail "r7-f3: could not add pf-locked"
  cx_add "$case_dir" waits-pf-locked docs
  cx "$case_dir" block waits-pf-locked --by pf-locked >/dev/null
  cat > "$case_dir/shim/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = "public-followup waive" ]; then
  "$real" "\$@"; rc=\$?
  printf 'held by a fixture writer\n' > "$case_dir/home/data/backlog.md.lock"
  exit \$rc
fi
exec "$real" "\$@"
SH
  chmod +x "$case_dir/shim/tasks-axi"
  rc=0
  (PATH="$case_dir/shim:$PATH" wrapper public-followup waive pf-locked --reason r --approved-by captain) > "$case_dir/out2" 2> "$case_dir/err2" || rc=$?
  rm -f "$case_dir/home/data/backlog.md.lock"
  expect_code 0 "$rc" "r7-f3: the locked-store waive must keep its exit status"
  case "$(cx_deps "$case_dir" waits-pf-locked)" in *pf-locked*) ;; *) fail "r7-f3: an edge changed while the store lock was held" ;; esac
  assert_match '^actionable: pf-locked is done, but .*(could not be unblocked|could not be listed)' "$case_dir/err2" "r7-f3: the refused clear under a held lock was not reported"
  assert_no_grep 'unblocked:' "$case_dir/err" "r7-f3: an edge was reported cleared"
  pass "a result that shows the row not done keeps every edge and the hold, and a held store lock makes the unblock refuse with every edge kept; both are reported (Main 2086)"
}

# Main 1851 F4: the wrapper resolves the id with tasks-axi's own grammar, so a completion with
# its flags before the id, or with the task noun, clears the finished edge like the plain form,
# and the capture guard applies to every form.
test_r7_f4_every_typed_form_clears_and_is_guarded() {
  local case_dir rc=0 real_mktemp pf
  case_dir=$(make_case r7-f4-forms)
  wrapper() { FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "$@"; }
  printf '%s' '{"request_id":"req-r7f","platform":"x","context_binding":{"version":"ctx1","value":"ctx1_r7f"},"public_safe_summary":"f","received_at":"2026-07-30T10:00:00Z","followup_expires_at":"2026-08-06T10:00:00Z","reservation_expires_at":"2026-08-06T10:00:00Z"}' > "$case_dir/request.json"
  printf '%s' '{"type":"pr-merged","project":"f","required_deliverables":["pr_url"],"completion_policy":"all-required"}' > "$case_dir/expected.json"
  for pf in pf-flags-first pf-noun pf-equals pf-guarded; do
    wrapper public-followup add "$pf" --request-context-file "$case_dir/request.json" --purpose promised-final \
      --expected-final-file "$case_dir/expected.json" --expires-at 2099-10-01T00:00:00Z >/dev/null 2>&1 || fail "r7-f4: could not add $pf"
    cx_add "$case_dir" "waits-$pf" docs
    cx "$case_dir" block "waits-$pf" --by "$pf" >/dev/null
    cx_other_and_hold "$case_dir" "waits-$pf"
  done
  wrapper public-followup waive --reason r --approved-by captain pf-flags-first > "$case_dir/o1" 2> "$case_dir/e1" || fail "r7-f4: the flags-first waive failed"
  assert_only_other_and_hold "$case_dir" waits-pf-flags-first pf-flags-first "r7-f4: flags before the id"
  wrapper task public-followup waive pf-noun --json --reason r --approved-by captain > "$case_dir/o2" 2> "$case_dir/e2" || fail "r7-f4: the task-noun waive failed"
  assert_only_other_and_hold "$case_dir" waits-pf-noun pf-noun "r7-f4: the task noun"
  wrapper public-followup waive --reason=r --approved-by=captain pf-equals > "$case_dir/o3" 2> "$case_dir/e3" || fail "r7-f4: the --flag=value waive failed"
  assert_only_other_and_hold "$case_dir" waits-pf-equals pf-equals "r7-f4: --flag=value"
  real_mktemp=$(command -v mktemp)
  cat > "$case_dir/shim-mktemp" <<SH
#!/usr/bin/env bash
case "\${1:-}" in *fm-tasks-axi-pf.*) echo 'simulated capture failure' >&2; exit 1 ;; esac
exec "$real_mktemp" "\$@"
SH
  mkdir -p "$case_dir/shim"
  mv "$case_dir/shim-mktemp" "$case_dir/shim/mktemp"
  chmod +x "$case_dir/shim/mktemp"
  (PATH="$case_dir/shim:$PATH" wrapper task public-followup waive --reason r --approved-by captain pf-guarded) > "$case_dir/o4" 2> "$case_dir/e4" || rc=$?
  [ "$rc" -ne 0 ] || fail "r7-f4: a flags-first waive with no capture file reported success"
  [ "$(cx_state "$case_dir" pf-guarded)" != "done" ] || fail "r7-f4: the flags-first waive ran with no capture file"
  assert_match '^actionable: the waive of pf-guarded did not run, so nothing changed' "$case_dir/e4" "r7-f4: the guard refusal was not reported"
  pass "a typed completion with its flags first, with the task noun or with --flag=value clears its finished edge and keeps the rest, and the capture guard stops every form"
}

# Main 1851 F1 and F2, Main 1875 rule P, the reviewers' injections through the real close step:
# a fake awk fails the member extractor, and a fake cat cuts or fails the one read of a body's
# parse result. A member read that fails refuses the whole block; a parse result read in part,
# or not at all, closes nothing from that body, reads no member and keeps every edge, with one
# line naming the body. Control: the same body closes both items without the fakes.
test_r7_f1_f2_a_failed_read_of_the_parse_or_its_result_closes_nothing() {
  local case_dir real_awk real_cat id
  case_dir=$(gh_case r7-reads 192)
  for id in r7-first r7-second r7-member; do
    cx_add "$case_dir" "$id"
    cx_add "$case_dir" "waits-$id"
    cx "$case_dir" block "waits-$id" --by "$id" >/dev/null
  done
  real_awk=$(command -v awk)
  real_cat=$(command -v cat)
  cat > "$case_dir/fakebin/awk" <<SH
#!/usr/bin/env bash
# The member extractor: awk -v t=member <program>, its text on standard input.
case "\${R7_FAIL:-}:\${1:-}:\${2:-}:\$#" in
  member:-v:t=member:3) echo 'simulated member read failure' >&2; exit 42 ;;
esac
exec "$real_awk" "\$@"
SH
  cat > "$case_dir/fakebin/cat" <<SH
#!/usr/bin/env bash
# The one read of a parse result: cat -- <body>.parse. "cut" gives all but the last record and
# exits 0; "fail" gives the first two records and exits 42.
case "\${R7_FAIL:-}:\${2:-}" in
  cut:*.parse) "$real_cat" -- "\$2" | sed '\$d'; exit 0 ;;
  fail:*.parse) sed -n '1,2p' "\$2"; echo 'simulated result read failure' >&2; exit 42 ;;
esac
exec "$real_cat" "\$@"
SH
  chmod +x "$case_dir/fakebin/awk" "$case_dir/fakebin/cat"
  for mode in cut fail; do
    block 'Closes-backlog-item: r7-first' 'Closes-backlog-item: r7-second' > "$case_dir/bodies/192"
    R7_FAIL=$mode run_close "$case_dir" task-x1 "$REPO_URL/192" > "$case_dir/$mode.out" 2> "$case_dir/$mode.err" || true
    for id in r7-first r7-second; do
      [ "$(cx_state "$case_dir" "$id")" = queued ] || fail "r7-reads: $id closed from a parse result read $mode"
      case "$(cx_deps "$case_dir" "waits-$id")" in *"$id"*) ;; *) fail "r7-reads: the edge on $id changed ($mode)" ;; esac
    done
    assert_grep "could not read the parse result of the body of $REPO_URL/192 whole, so no item closed, every edge kept" "$case_dir/$mode.err" "r7-reads: the $mode result read was not reported"
  done
  block 'Closes-backlog-item: r7-member' "Train-member: $REPO_URL/71" > "$case_dir/bodies/192"
  R7_FAIL=member run_close "$case_dir" task-x1 "$REPO_URL/192" > "$case_dir/member.out" 2> "$case_dir/member.err" || true
  [ "$(cx_state "$case_dir" r7-member)" = queued ] || fail "r7-reads: a block closed though its member values could not be read"
  assert_grep 'Train-member values could not be read' "$case_dir/member.err" "r7-reads: the member read failure was not the refusal reason"
  assert_no_grep "^pr view $REPO_URL/71 --json body" "$case_dir/gh.log" "r7-reads: a refused block's member body was read"
  # Control: the two-item body closes both without the fakes.
  rm -f "$case_dir/fakebin/awk" "$case_dir/fakebin/cat"
  block 'Closes-backlog-item: r7-first' 'Closes-backlog-item: r7-second' > "$case_dir/bodies/192"
  run_close "$case_dir" task-x1 "$REPO_URL/192" > "$case_dir/ctl.out" 2> "$case_dir/ctl.err" || true
  for id in r7-first r7-second; do
    [ "$(cx_state "$case_dir" "$id")" = "done" ] || fail "r7-reads control: $id did not close"
  done
  pass "a failed member read refuses the block; a parse result read cut or failed closes nothing and keeps every edge, with one line naming the body; the control closes"
}

# Main 1875 F3, through the real wrapper: a typed completion with the global --backend flag
# before the subcommand or after the id is the same completion: the capture guard stops it, and
# with its capture file it clears the finished edge and keeps the rest.
test_r8_f3_a_global_backend_flag_is_the_same_completion() {
  local case_dir rc=0 real_mktemp pf
  case_dir=$(make_case r8-f3-backend)
  wrapper() { FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "$@"; }
  printf '%s' '{"request_id":"req-r8","platform":"x","context_binding":{"version":"ctx1","value":"ctx1_r8"},"public_safe_summary":"f","received_at":"2026-07-30T10:00:00Z","followup_expires_at":"2026-08-06T10:00:00Z","reservation_expires_at":"2026-08-06T10:00:00Z"}' > "$case_dir/request.json"
  printf '%s' '{"type":"pr-merged","project":"f","required_deliverables":["pr_url"],"completion_policy":"all-required"}' > "$case_dir/expected.json"
  for pf in pf-backend-first pf-backend-last pf-backend-guarded; do
    wrapper public-followup add "$pf" --request-context-file "$case_dir/request.json" --purpose promised-final \
      --expected-final-file "$case_dir/expected.json" --expires-at 2099-10-01T00:00:00Z >/dev/null 2>&1 || fail "r8-f3: could not add $pf"
    cx_add "$case_dir" "waits-$pf" docs
    cx "$case_dir" block "waits-$pf" --by "$pf" >/dev/null
    cx_other_and_hold "$case_dir" "waits-$pf"
  done
  wrapper public-followup --backend=markdown waive pf-backend-first --reason r --approved-by captain > "$case_dir/o1" 2> "$case_dir/e1" || fail "r8-f3: the --backend-first waive failed"
  assert_only_other_and_hold "$case_dir" waits-pf-backend-first pf-backend-first "r8-f3: --backend before the subcommand"
  wrapper public-followup waive pf-backend-last --reason r --approved-by captain --json --backend markdown > "$case_dir/o2" 2> "$case_dir/e2" || fail "r8-f3: the --backend-last waive failed"
  assert_only_other_and_hold "$case_dir" waits-pf-backend-last pf-backend-last "r8-f3: --backend after the id"
  jq -e . "$case_dir/o2" >/dev/null 2>&1 || fail "r8-f3: the JSON output of the --backend-last waive is not valid JSON"
  real_mktemp=$(command -v mktemp)
  mkdir -p "$case_dir/shim"
  cat > "$case_dir/shim/mktemp" <<SH
#!/usr/bin/env bash
case "\${1:-}" in *fm-tasks-axi-pf.*) echo 'simulated capture failure' >&2; exit 1 ;; esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$case_dir/shim/mktemp"
  (PATH="$case_dir/shim:$PATH" wrapper public-followup --backend markdown waive pf-backend-guarded --reason r --approved-by captain) > "$case_dir/o3" 2> "$case_dir/e3" || rc=$?
  [ "$rc" -ne 0 ] || fail "r8-f3: a --backend waive with no capture file reported success"
  [ "$(cx_state "$case_dir" pf-backend-guarded)" != "done" ] || fail "r8-f3: the --backend waive ran with no capture file"
  assert_match '^actionable: the waive of pf-backend-guarded did not run, so nothing changed' "$case_dir/e3" "r8-f3: the guard refusal was not reported"
  pass "a typed completion with --backend before the subcommand or after the id clears its finished edge and keeps the rest, its JSON stays valid, and the capture guard stops it"
}

# Main 1890, through the public entries (owed to CI): a Forgejo train member record without its
# body field is a failed read, reported by URL; a task record that cannot be read while members
# are matched is reported, never taken as no match; a byte count that fails is a failed parse,
# reported with the ids it names; the train's own item still closes.
test_r9_public_entry_reads_are_checked() {
  local case_dir rc=0 base="https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls" key real_wc
  case_dir=$(make_forgejo_case "r9-reads-${CLOSE_PRUNE:-off}")
  key=$FJ_OWNER"_"$FJ_REPO
  cx_add "$case_dir" r9-own docs
  cx_add "$case_dir" r9-locked docs
  cx_meta "$case_dir" r9-locked docs "$base/12"
  printf '{"merged":true}\n' > "$case_dir/tea-body-$key-11.json"
  printf '{"merged":true,"body":""}\n' > "$case_dir/tea-body-$key-12.json"
  set_json_field "$case_dir/pr-post.json" body "$(block 'Closes-backlog-item: r9-own' "Train-member: $base/11" "Train-member: $base/12")"
  chmod 000 "$case_dir/state/r9-locked.meta"
  merge_call "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  chmod 600 "$case_dir/state/r9-locked.meta"
  expect_code 0 "$rc" "r9-reads: the merge must succeed"
  [ "$(cx_state "$case_dir" r9-own)" = "done" ] || fail "r9-reads: the train's own item did not close"
  [ "$(cx_state "$case_dir" r9-locked)" = queued ] || fail "r9-reads: an item behind an unreadable task record closed"
  assert_grep "could not read the body of train member $base/11 (the forge answered" "$case_dir/stderr" "r9-reads: a member record without a body field was not a failed read"
  assert_grep "could not read the task record of r9-locked" "$case_dir/stderr" "r9-reads: the unreadable task record was not reported"
  # A byte count that fails: the parse fails and is reported with the ids it names.
  case_dir=$(gh_case r9-wc 194)
  cx_add "$case_dir" r9-wc
  block 'Closes-backlog-item: r9-wc' > "$case_dir/bodies/194"
  real_wc=$(command -v wc)
  printf '#!/usr/bin/env bash\necho "simulated count failure" >&2\nexit 42\n' > "$case_dir/fakebin/wc"
  chmod +x "$case_dir/fakebin/wc"
  run_close "$case_dir" task-x1 "$REPO_URL/194" > "$case_dir/out" 2> "$case_dir/err" || true
  rm -f "$case_dir/fakebin/wc"
  [ -n "$real_wc" ] || fail "r9-wc: wc is not installed"
  [ "$(cx_state "$case_dir" r9-wc)" = queued ] || fail "r9-wc: an item closed after a failed byte count"
  assert_grep "could not parse the body of $REPO_URL/194, .*could not count the bytes of its snapshot; it names item ids: r9-wc" "$case_dir/err" "r9-wc: the failed count was not reported with its id"
  pass "a member record without a body field and an unreadable task record are reported, a failed byte count is a reported parse failure, and the train's own item still closes"
}

# Main 2086 (2) and Main 1875 F8, through the wrapper (owed to CI): no tasks-axi version is
# checked, so a tasks-axi package that says it is another version, first on PATH, clears the
# finished edge in the same run and keeps the other blocker and the hold; a failed replay of the
# kept output exits 1 and is reported, while the finished edge still clears from the kept result.
test_r9_public_entry_any_version_and_replay() {
  local case_dir rc=0 pkg real_cat real
  command -v node >/dev/null 2>&1 || { printf 'ok - skipped (node is not installed)\n'; return 0; }
  case_dir=$(make_case r9-pin)
  wrapper() { FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "$@"; }
  printf '%s' '{"request_id":"req-r9","platform":"x","context_binding":{"version":"ctx1","value":"ctx1_r9"},"public_safe_summary":"f","received_at":"2026-07-30T10:00:00Z","followup_expires_at":"2026-08-06T10:00:00Z","reservation_expires_at":"2026-08-06T10:00:00Z"}' > "$case_dir/request.json"
  printf '%s' '{"type":"pr-merged","project":"f","required_deliverables":["pr_url"],"completion_policy":"all-required"}' > "$case_dir/expected.json"
  for pf in pf-pinned pf-replay; do
    wrapper public-followup add "$pf" --request-context-file "$case_dir/request.json" --purpose promised-final \
      --expected-final-file "$case_dir/expected.json" --expires-at 2099-10-01T00:00:00Z >/dev/null 2>&1 || fail "r9-pin: could not add $pf"
    cx_add "$case_dir" "waits-$pf" docs
    cx "$case_dir" block "waits-$pf" --by "$pf" >/dev/null
    cx_other_and_hold "$case_dir" "waits-$pf"
  done
  # A copy of the installed package that says it is 0.2.7, first on PATH.
  real=$(command -v tasks-axi) || fail "r9-pin: tasks-axi is not installed"
  while [ -L "$real" ]; do case "$(readlink "$real")" in /*) real=$(readlink "$real") ;; *) real=${real%/*}/$(readlink "$real") ;; esac; done
  pkg=$(cd "${real%/*}/../.." && pwd -P) || fail "r9-pin: the tasks-axi package was not found"
  grep -q '"name": *"tasks-axi"' "$pkg/package.json" || fail "r9-pin: $pkg is not the tasks-axi package"
  mkdir -p "$case_dir/fakepkg/bin"
  cp -R "$pkg" "$case_dir/fakepkg/tasks-axi"
  sed 's/"version": *"[^"]*"/"version": "0.2.7"/' "$pkg/package.json" > "$case_dir/fakepkg/tasks-axi/package.json"
  ln -s "$case_dir/fakepkg/tasks-axi/dist/bin/tasks-axi.js" "$case_dir/fakepkg/bin/tasks-axi"
  (PATH="$case_dir/fakepkg/bin:$PATH" wrapper public-followup waive pf-pinned --reason r --approved-by captain) > "$case_dir/o1" 2> "$case_dir/e1" || rc=$?
  expect_code 0 "$rc" "r9-pin: the waive itself must succeed"
  [ "$(cx_state "$case_dir" pf-pinned)" = "done" ] || fail "r9-pin: the waive did not finish the obligation"
  assert_only_other_and_hold "$case_dir" waits-pf-pinned pf-pinned "r9-pin: the finished edge under another tasks-axi version"
  assert_grep 'unblocked: waits-pf-pinned no longer waits on pf-pinned; it still waits on waits-pf-pinned-other' "$case_dir/e1" "r9-pin: the clear under another tasks-axi version was not reported"
  # A replay of the kept output that fails.
  real_cat=$(command -v cat)
  mkdir -p "$case_dir/shim"
  cat > "$case_dir/shim/cat" <<SH
#!/usr/bin/env bash
case "\${2:-}" in *fm-tasks-axi-pf.*) printf '{"ok":'; exit 74 ;; esac
exec "$real_cat" "\$@"
SH
  chmod +x "$case_dir/shim/cat"
  rc=0
  (PATH="$case_dir/shim:$PATH" wrapper public-followup waive pf-replay --reason r --approved-by captain --json) > "$case_dir/o2" 2> "$case_dir/e2" || rc=$?
  [ "$rc" -eq 1 ] || fail "r9-replay: a failed replay exited $rc, not 1"
  assert_grep 'but the wrapper could not show its output' "$case_dir/e2" "r9-replay: the failed replay was not reported"
  assert_only_other_and_hold "$case_dir" waits-pf-replay pf-replay "r9-replay: the finished edge after a failed replay"
  pass "a tasks-axi that says it is another version clears the finished edge, keeping the other blocker and the hold; a failed replay exits 1 and is reported while the finished edge clears"
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
test_r4_f2_an_invalid_train_member_value_refuses_the_whole_block
test_r4_f2_a_member_block_with_an_invalid_value_is_refused_and_its_pr_task_still_closes
test_two_members_with_one_number_in_different_repos_match_by_full_url
test_f1_an_excluded_component_table_under_a_subheading_closes_nothing_and_is_reported
test_f2_an_indented_fenced_example_closes_nothing
test_f3_a_component_table_with_a_negated_exclusion_heading_closes_nothing_without_a_member_line
test_f4_an_unlisted_forgejo_or_gitlab_member_is_reported_by_its_url
test_a_gitlab_or_forgejo_merge_naming_its_own_task_reports_the_live_record
test_a_forgejo_train_closes_each_listed_member_source_and_reports_the_prose_link
test_a_gitlab_train_reads_each_listed_member_and_reports_the_prose_link
test_a_merge_with_an_unlistable_backlog_says_so_once_per_body_with_prose
test_an_html_comment_example_closes_nothing_and_keeps_its_edge
test_a_train_members_prose_only_mention_is_reported_and_never_closed
test_a_mention_keeps_the_ids_own_spelling
test_a_mention_inside_a_comment_is_reported_like_any_other_text
test_a_member_with_both_sources_and_two_listed_members_with_one_number
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
test_f1_a_setext_heading_directive_closes_nothing_and_is_reported
test_f1_a_pre_example_closes_nothing_with_or_without_blank_lines
test_f1_a_code_span_over_lines_closes_nothing_and_is_reported
test_f1_an_open_html_quote_or_example_element_closes_nothing
test_f1_a_train_member_inside_a_code_span_lists_no_member
test_f2_a_train_members_prose_pr_link_is_reported_and_never_closed
test_f1_a_container_opened_on_a_comment_or_pre_edge_line_closes_nothing
test_f2_a_members_own_train_member_line_is_reported_and_never_closed
test_r3_f1_a_closing_tag_inside_a_multiline_code_span_closes_no_example
test_r4_a_block_below_opener_text_in_a_code_span_is_refused_by_name
test_r3_f2_a_member_line_after_a_pre_end_reports_its_link_and_id
test_r3_two_blocks_refuse_the_whole_close
test_r3_a_missing_or_misplaced_end_line_refuses_the_whole_close
test_r3_marker_text_inside_other_text_refuses_the_whole_close
test_r3_a_line_in_the_block_that_is_no_directive_refuses_the_whole_close
test_r3_a_member_body_is_read_only_inside_its_own_block
test_r3_one_block_with_blank_lines_and_crlf_closes_each_line
test_r4_f1_a_whole_block_inside_an_example_closes_nothing_and_keeps_its_edge
test_r4_opener_text_above_the_block_refuses_whatever_seems_to_close_it
test_r4_a_block_above_every_example_closes_and_the_examples_close_nothing
test_r4_f3_a_malformed_line_outside_the_block_reports_each_id_and_link
test_r4_a_commit_message_block_closes_nothing
test_r4_the_ship_brief_block_closes_a_train
test_r4_a_large_body_is_read_with_no_write_error
test_r5_f1_a_block_that_does_not_open_the_body_refuses_it
test_r5_f1_a_quoted_train_or_member_block_selects_nothing
test_r5_f2_the_strict_grammar_refuses_every_doubtful_block
test_r5_f3_every_refusal_and_malformed_line_names_its_ids_and_links
test_r5_f5_a_real_block_below_closed_example_text_is_refused_by_name
test_r5_one_parse_owns_the_block
test_r5_the_parse_result
test_r5_f4_a_waive_whose_state_read_fails_still_clears_the_edge
test_r6_f1_a_partial_body_write_refuses_the_whole_body
test_r6_f2_a_nul_byte_refuses_the_whole_body
test_r6_f3_a_parse_failure_is_reported_and_closes_nothing
test_r6_f4_a_refusal_spells_each_id_exactly
test_r6_f5_a_waive_whose_capture_file_cannot_be_made_does_not_run
test_r6_f5_a_completion_whose_output_is_lost_still_clears_in_the_same_run
test_r7_f3_a_result_not_done_or_a_held_lock_keeps_every_edge
test_r7_f4_every_typed_form_clears_and_is_guarded
test_r7_f1_f2_a_failed_read_of_the_parse_or_its_result_closes_nothing
test_r8_f3_a_global_backend_flag_is_the_same_completion
test_r9_public_entry_reads_are_checked
test_r9_public_entry_any_version_and_replay
)
fm_test_run_cases "${pr_close_test_cases[@]}" -- "$@"
