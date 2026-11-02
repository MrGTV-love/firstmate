#!/usr/bin/env bash
# Close at merge: bin/fm-pr-merge.sh closes the backlog items a merged pull request
# names with `Closes: <item-id>` lines, a merge train's members' items too, and a
# finished item stops blocking the items that waited on it.
#
# bin/fm-pr-close-items.sh owns the close contract and bin/fm-pr-closes-lib.sh owns the
# `Closes:` syntax and the train member list. Every case runs the real tasks-axi against
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

# A merge fixture for the GitHub path: PR <number> is the merged pull request, and every
# PR listed in $case_dir/merged-prs counts as merged for the completion proof.
gh_case() {  # <name> <number>
  local case_dir
  case_dir=$(make_case "$1")
  mkdir -p "$case_dir/wt" "$case_dir/bodies"
  add_gh_mocks "$case_dir" "$(printf '%040d' "$2")"
  : > "$case_dir/gh-axi.log"
  printf '%s\n' "$2" > "$case_dir/merged-prs"
  printf '%s\n' "$case_dir"
}

gh_merge() {  # <case-dir> <number> [merge args...]; the merge must succeed
  local case_dir=$1 number=$2 rc=0
  shift 2
  run_pr_merge "$case_dir" task-x1 "$REPO_URL/$number" "$@" \
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
  cx_meta "$case_dir" fm-fixture-live-3 ship
  cx_meta "$case_dir" docs-live-4 docs
  cx_meta "$case_dir" docs-twin docs
  # shellcheck disable=SC2016 # Backticks in the fixture body are literal Markdown.
  printf '%s\n' 'Fixes things; fm-fixture-prose-5 is related.' '' \
    'Closes: fm-fixture-alpha-1' 'Closes: fm-fixture-beta-2' 'Closes: fm-fixture-live-3' \
    'Closes: ship-a' 'Closes: docs-live-4' 'Closes: ship-a' \
    'Mentions Closes: fm-fixture-prose-5 inline.' 'closes: fm-fixture-prose-5' \
    '  Closes: fm-fixture-prose-5' 'Closes: fm-fixture-prose-5 # comment' > "$case_dir/bodies/61"

  gh_merge "$case_dir" 61
  [ "$(cx_state "$case_dir" fm-fixture-alpha-1)" = "done" ] || fail "c1: alpha was not closed"
  [ "$(cx_state "$case_dir" fm-fixture-beta-2)" = "done" ] || fail "c1: beta was not closed"
  [ "$(cx_state "$case_dir" ship-a)" = "done" ] || fail "c1: ship-a (no fm- prefix) was not closed"
  assert_grep "closed fm-fixture-alpha-1 with $url" "$case_dir/stdout" "c1: alpha's close was not reported"
  assert_grep "$url" "$case_dir/home/data/backlog.md" "c1: the merged PR URL is not on the closed items"
  [ "$(cx_state "$case_dir" fm-fixture-live-3)" != "done" ] || fail "c1: a ship item with a live record was closed"
  assert_match "not closed fm-fixture-live-3: bin/fm-tasks-axi.sh done refused it: .*live task record" "$case_dir/stdout" \
    "c1: the live item was not reported with its reason"
  [ "$(cx_state "$case_dir" fm-fixture-prose-5)" != "done" ] || fail "c1: a line that is not a Closes directive closed an item"
  # The non-ship item with a live record gets exactly what the unchanged completion path gives.
  [ "$(cx_state "$case_dir" docs-live-4)" = "done" ] || fail "c1: docs-live-4 did not get the completion path's outcome"
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" "$WRAPPER_SH" "done" docs-twin --pr "$url" >/dev/null 2>&1 \
    || fail "c1: the unchanged path refused the docs twin"
  [ "$(cx_state "$case_dir" docs-twin)" = "done" ] || fail "c1: the unchanged path left the docs twin open"
  assert_grep '4 closed, 1 left open' "$case_dir/stdout" "c1: summary line missing"
  pass "a merge closes each named eligible item with the merged PR URL and reports the one it left open"
}

test_a_merge_naming_its_own_task_reports_the_live_record() {
  local case_dir
  case_dir=$(gh_case c1-self 62)
  cx_add "$case_dir" task-x1
  printf '%s\n' 'Closes: task-x1' > "$case_dir/bodies/62"
  gh_merge "$case_dir" 62
  [ "$(cx_state "$case_dir" task-x1)" != "done" ] || fail "c1-self: the merging task was closed before its teardown"
  assert_match 'not closed task-x1: .*live task record' "$case_dir/stdout" "c1-self: the live-record refusal was not reported by id"
  pass "a merge that names its own task reports the live-record refusal and still succeeds"
}

test_no_closes_line_changes_no_item_and_prose_urls_close_nothing() {
  local case_dir
  case_dir=$(gh_case c1-none 63)
  cx_add "$case_dir" other-item
  printf '%s\n' "Related to $REPO_URL/9, which says Closes: other-item in prose." > "$case_dir/bodies/63"
  printf '%s\n' 'Closes: other-item' > "$case_dir/bodies/9"
  printf '%s\n' 9 >> "$case_dir/merged-prs"
  gh_merge "$case_dir" 63
  [ "$(cx_state "$case_dir" other-item)" = queued ] || fail "c1-none: an item changed without a Closes line"
  assert_no_grep 'close-at-merge' "$case_dir/stdout" "c1-none: the close step spoke without a directive"
  pass "a body with no Closes line, even one that links another PR, changes no item"
}

test_an_unrecorded_merge_closes_nothing_and_lists_the_named_items() {
  local case_dir rc=0
  case_dir=$(gh_case c1-unrecorded 64)
  cx_add "$case_dir" unrecorded-a
  printf '%s\n' 'Closes: unrecorded-a' > "$case_dir/bodies/64"
  # A secondmate home with no readable parent binding cannot place the outcome.
  : > "$case_dir/home/.fm-secondmate-home"
  run_pr_merge "$case_dir" task-x1 "$REPO_URL/64" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
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
  printf '%s\n' 'Closes: watcher-a' > "$case_dir/bodies/65"
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
  printf '%s\n' 'Closes: no-such-item' 'Closes: done-already' 'Closes: a-scout' 'Closes: held-ship' \
    'Closes: call-open' 'Closes: call-released' 'Closes: call-expired' 'Closes: call-reheld' \
    'Closes: archived-one' 'Closes: absent-one' 'Closes: read-fails-once' 'Closes: valid-last' > "$case_dir/bodies/67"
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
  assert_grep 'not closed a-scout: bin/fm-tasks-axi.sh done refused it' "$case_dir/stderr" "c3: scout refusal not reported"
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
  printf '%s\n' 'Closes: late-hold' > "$case_dir/bodies/68"
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
  printf '%s\n' 'Closes: rerun-a' > "$case_dir/bodies/69"
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

# --- trains -----------------------------------------------------------------

# shellcheck disable=SC2016 # Backticks in the fixture bodies are literal Markdown.
# train_body <layout> <excluded-url> <member-url>...
train_body() {
  local layout=$1 excluded=$2 member n=0 headless
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
      printf '%s\n' '## Train facts' ''
      for member in "$@"; do n=$((n + 1)); printf -- '- **Component %s:** %s at `aaaa`, merge commit `bbbb`.\n' "$n" "$member"; done
      printf -- '- **Main merge:** `cccc` merged by `dddd`.\n' ;;
    heading-bullets)
      printf '%s\n' '### Components and base' ''
      for member in "$@"; do printf -- '- %s at unchanged head `aaaa`.\n' "$member"; done
      printf -- '- Latest main integrated at refresh build time: `cccc`.\n' ;;
    fenced-numbered)
      printf '%s\n' '```text' '## Train record' 'Components, in order:' ''
      for member in "$@"; do n=$((n + 1)); printf '%s. %s at `aaaa`, merged by `bbbb`.\n' "$n" "$member"; done
      printf '%s\n' '' 'Other notes.' '```' ;;
  esac
  headless=
  printf '%s\n' '' "Also see $excluded again." ${headless:+x}
}

# The train fixture: four members, as the contract lists them.
#   m1 names a ship item; m2 is found only through a live ship task's pr=;
#   m3 is found only through a live docs task's pr=; m4 names nothing.
train_case() {  # <name> <layout> <train-number> [extra Closes line for the train body]
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
  printf '%s\n' 'Closes: m1-item' > "$case_dir/bodies/71"
  printf '%s\n' 'Closes: excluded-item' > "$case_dir/bodies/90"
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
  assert_match "not closed m2-live-ship: .*live task record" "$case_dir/stdout" "$label: the live ship task was not reported"
  [ "$(cx_state "$case_dir" excluded-item)" = queued ] || fail "$label: a PR the body only mentions closed its item"
  [ "$(cx_state "$case_dir" prefix-task)" = queued ] || fail "$label: a pr= that shares only a prefix matched"
  [ "$(cx_state "$case_dir" bare-number-task)" = queued ] || fail "$label: a pr= that is only a number matched"
  assert_grep "closed m1-item with $train" "$case_dir/stdout" "$label: the proof is not the train URL"
  assert_grep "closed m3-live-docs with $train" "$case_dir/stdout" "$label: the pr= task's proof is not the train URL"
}

test_a_train_closes_the_items_of_its_listed_members_in_every_layout() {
  local layout case_dir
  for layout in url-first-table numbered-table labeled-bullets heading-bullets fenced-numbered; do
    case_dir=$(train_case "c2-$layout" "$layout" 80 'Closes: train-own-item')
    gh_merge "$case_dir" 80 --merge
    check_train_outcome "$case_dir" "c2-$layout" "$REPO_URL/80"
    [ "$(cx_state "$case_dir" train-own-item)" = "done" ] || fail "c2-$layout: the train's own Closes line was ignored"
  done
  pass "a train closes its members' items from bodies and from pr=, in all five layouts, never an excluded PR's"
}

test_a_train_with_no_closes_line_of_its_own_still_closes_member_items() {
  local case_dir
  case_dir=$(train_case c2-no-own url-first-table 81)
  gh_merge "$case_dir" 81
  check_train_outcome "$case_dir" c2-no-own "$REPO_URL/81"
  [ "$(cx_state "$case_dir" train-own-item)" = queued ] || fail "c2-no-own: an item nobody named closed"
  pass "a train body without its own Closes line still closes the members' items"
}

test_a_member_with_both_sources_and_an_unreadable_member() {
  local case_dir base=$REPO_URL
  case_dir=$(train_case c2-both url-first-table 82)
  # m3's task is also named by m3's own body; m4's body cannot be read while a docs task holds m4's URL.
  cx_add "$case_dir" m4-docs docs
  cx_meta "$case_dir" m4-docs docs "$base/74"
  printf '%s\n' 'Closes: m1-item' 'Closes: m3-live-docs' > "$case_dir/bodies/71"
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
  # shellcheck disable=SC2016 # Backticks in the fixture body are literal Markdown.
  printf '%s\n' '| Component | Head |' '| --- | --- |' \
    '| https://github.com/example/repo-a/pull/5 | `a` |' > "$case_dir/bodies/83"
  printf '%s\n' repo-a/pull/5 >/dev/null
  gh_merge "$case_dir" 83
  [ "$(cx_state "$case_dir" repo-a-task)" = "done" ] || fail "c2-same-number: the matching member's task was not closed"
  [ "$(cx_state "$case_dir" repo-b-task)" = queued ] || fail "c2-same-number: a task with the same number in another repo matched"
  pass "members match by the full URL, never by number"
}

# --- other forges -----------------------------------------------------------

set_json_field() {  # <file> <field> <text>
  local tmp
  tmp=$(mktemp "$TMP_ROOT/json.XXXXXX")
  "$JQ_BIN" --arg v "$3" ".$2 = \$v" "$1" > "$tmp" && mv "$tmp" "$1"
}

test_a_gitlab_merge_reports_the_completion_paths_actual_result() {
  local case_dir url=$MR_URL train rc
  case_dir=$(make_gitlab_case c1-gitlab)
  cx_add "$case_dir" gl-ship
  cx_add "$case_dir" gl-docs docs
  cx_add "$case_dir" gl-member-docs docs
  cx_meta "$case_dir" gl-member-docs docs "$MR_PROJECT_URL/-/merge_requests/8"
  train=$MR_URL
  # shellcheck disable=SC2016 # Literal Markdown.
  set_json_field "$case_dir/mr-post.json" description "$(printf '%s\n' '| Component | Head |' '| --- | --- |' "| $MR_PROJECT_URL/-/merge_requests/8 | \`a\` |" '' 'Closes: gl-ship' 'Closes: gl-docs')"
  rc=0
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ -z "${CLOSE_DEBUG:-}" ] || { cat "$case_dir/stdout" "$case_dir/stderr" >&2; cat "$case_dir/glab.log" >&2; }
  expect_code 0 "$rc" "c1-gitlab: the merge result must be the normal success"
  # tasks-axi accepts a pull request link only in the GitHub or Forgejo form, so the
  # completion path itself refuses a merge request URL for every kind; the text is its own.
  for id in gl-ship gl-docs gl-member-docs; do
    [ "$(cx_state "$case_dir" "$id")" != "done" ] || fail "c1-gitlab: $id closed on a merge request URL the path cannot take"
  done
  assert_match 'not closed gl-ship: bin/fm-tasks-axi.sh done refused it: only a GitHub pull request' "$case_dir/stderr" \
    "c1-gitlab: the ship refusal was not reported"
  assert_match 'not closed gl-docs: bin/fm-tasks-axi.sh done refused it: .*canonical pull request URL' "$case_dir/stderr" \
    "c1-gitlab: the non-ship refusal was not reported with the path's own text"
  assert_match 'not closed gl-member-docs: .*canonical pull request URL' "$case_dir/stderr" \
    "c1-gitlab: the member task's refusal was not reported"
  assert_grep "mr view 8 -R $MR_PROJECT_URL -F json" "$case_dir/glab.log" "c1-gitlab: the member was not read through glab"
  pass "a GitLab merge reports the completion path's actual result per item and still succeeds"
}

test_a_forgejo_merge_reports_the_completion_paths_actual_result() {
  local case_dir rc mode
  for mode in default merge; do
    case_dir=$(make_forgejo_case "c1-forgejo-$mode")
    cx_add "$case_dir" fj-ship
    cx_add "$case_dir" fj-docs docs
    cx_add "$case_dir" fj-member-docs docs
    cx_add "$case_dir" fj-other-repo docs
    cx_meta "$case_dir" fj-member-docs docs "https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls/10"
    cx_meta "$case_dir" fj-other-repo docs "https://$FJ_HOST/$FJ_OWNER/other-repo/pulls/10"
    # shellcheck disable=SC2016 # Literal Markdown.
    set_json_field "$case_dir/pr-post.json" body "$(printf '%s\n' '| Component | Head |' '| --- | --- |' "| https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls/10 | \`a\` |" '' 'Closes: fj-ship' 'Closes: fj-docs')"
    rc=0
    if [ "$mode" = merge ]; then
      run_pr_merge "$case_dir" task-x1 "$FJ_URL" -- --merge > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      run_pr_merge "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    expect_code 0 "$rc" "c1-forgejo-$mode: the merge result must be the normal success"
    [ "$(cx_state "$case_dir" fj-docs)" = "done" ] || fail "c1-forgejo-$mode: the non-ship item was not closed"
    [ "$(cx_state "$case_dir" fj-member-docs)" = "done" ] || fail "c1-forgejo-$mode: the member's pr= task was not closed"
    [ "$(cx_state "$case_dir" fj-other-repo)" = queued ] || fail "c1-forgejo-$mode: the same number in another repository matched"
    [ "$(cx_state "$case_dir" fj-ship)" != "done" ] || fail "c1-forgejo-$mode: a ship item closed on a proof the path cannot verify"
    assert_grep 'not closed fj-ship: bin/fm-tasks-axi.sh done refused it' "$case_dir/stderr" "c1-forgejo-$mode: refusal not reported"
  done
  pass "a Forgejo merge reports the completion path's actual result per item and still succeeds"
}

# --- parser and blockers ----------------------------------------------------

test_the_closes_parser_reads_real_ids_and_ignores_examples() {
  local out stray
  out=$(printf '%s\n' 'Closes: fm-backlog-close-at-merge' 'Closes: fm-backlog-finished-blocker-auto-clear' \
    'Closes: ship-a' 'Closes: a.b_c-1' 'Closes:   spaced-id   ' 'Closes: .hidden' 'Closes: two words' \
    'Closes: tail # comment' 'closes: lower' ' Closes: indented' '> Closes: quoted' '- Closes: listed' \
    '```' 'Closes: fm-fixture-other' '```' '~~~' 'Closes: tilde-other' '~~~' 'Closes: ship-a' \
    | bash -c '. "$1"; fm_pr_closes_ids -' _ "$ROOT/bin/fm-pr-closes-lib.sh")
  [ "$out" = "$(printf '%s\n' fm-backlog-close-at-merge fm-backlog-finished-blocker-auto-clear ship-a a.b_c-1 spaced-id)" ] \
    || fail "parser: unexpected ids: $(printf '%s' "$out" | tr '\n' ' ')"
  stray=$(grep -rn 'Closes:' "$ROOT/bin" | grep -v '^[^:]*:[0-9]*:#' | grep -v 'fm-pr-closes-lib.sh\|fm-pr-close-items.sh\|fm-dod-lib.sh' || true)
  [ -z "$stray" ] \
    || fail "parser: a second pattern for Closes: exists outside the owner"
  pass "the parser takes real ids, ignores fenced examples and non-directive lines, and has one owner"
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

pr_close_test_cases=(
test_closes_lines_close_each_eligible_item_and_report_the_rest
test_a_merge_naming_its_own_task_reports_the_live_record
test_no_closes_line_changes_no_item_and_prose_urls_close_nothing
test_an_unrecorded_merge_closes_nothing_and_lists_the_named_items
test_a_merge_the_watcher_recorded_first_still_closes_without_a_second_notice
test_an_unreadable_body_is_reported_with_the_url_and_the_error
test_every_failure_kind_is_reported_and_the_valid_item_still_closes
test_a_hold_placed_after_the_last_look_still_wins
test_a_rerun_closes_nothing_twice
test_a_train_closes_the_items_of_its_listed_members_in_every_layout
test_a_train_with_no_closes_line_of_its_own_still_closes_member_items
test_a_member_with_both_sources_and_an_unreadable_member
test_two_members_with_one_number_in_different_repos_match_by_full_url
test_a_gitlab_merge_reports_the_completion_paths_actual_result
test_a_forgejo_merge_reports_the_completion_paths_actual_result
test_the_closes_parser_reads_real_ids_and_ignores_examples
test_completion_clears_the_finished_blocker_on_every_route
test_the_task_noun_forms_and_typed_completions_clear_the_edge
test_an_answered_captain_call_clears_the_edge
test_a_withdrawn_captain_call_clears_the_edge
test_an_explicit_data_root_gets_the_same_clear
)
fm_test_run_cases "${pr_close_test_cases[@]}" -- "$@"
