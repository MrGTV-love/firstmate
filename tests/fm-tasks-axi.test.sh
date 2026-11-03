#!/usr/bin/env bash
# Behavior tests for bin/fm-tasks-axi.sh home addressing and bootstrap's
# shadow-backlog check, over the split layout where the operational home lives
# outside the code root that carries the tracked .tasks.toml.
#
# The fork these guard against: .tasks.toml names data/backlog.md relative to
# the caller's working directory, and tasks-axi writes by renaming a temp file
# over its target, so a bare tasks-axi run from the code root turns a code-root
# symlink into the home's backlog into a private regular copy. The suite proves
# that every write through bin/fm-tasks-axi.sh lands in $FM_HOME/data from the
# code root (including archiving and relative --body-file arguments),
# that the command refuses addressing it cannot keep correct, and that bootstrap
# reports any code-root copy that is not this home's own file while staying
# silent for a link into the home, an absent copy, and the single-home layout.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasks-axi)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# The developer shell may pin any of these; each case states its own layout.
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# A fixture title no other fixture title shares a word with, so a fixture that is
# not about duplicate detection never meets the intake check.
ftitle() {  # <key>
  local k
  k=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' 'x' | tr '[:upper:]' '[:lower:]')
  printf '%saaa %sbbb %sccc' "$k" "$k" "$k"
}

empty_backlog() {  # <path>
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$1"
}

# A code root carrying the tracked .tasks.toml and an operational home beside
# it, with the code-root backlog linked into the home the way an operator
# would try to keep the two in sync.
make_split() {  # <name>; prints the case directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/data" "$dir/home/data" "$dir/home/state" "$dir/home/config"
  fm_test_tasks_toml "$dir/code/.tasks.toml"
  empty_backlog "$dir/home/data/backlog.md"
  ln -s "$dir/home/data/backlog.md" "$dir/code/data/backlog.md"
  printf '%s\n' "$dir"
}

# Run the wrapper from the code root, as firstmate does.
wrapper_from_code() {  # <case-dir> <tasks-axi args...>
  local dir=$1
  shift
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" "$@")
}

# Only the shadow-backlog lines matter here; the rest of a detect-only local
# bootstrap pass reports this host's toolchain, which is not under test, so it
# runs on the bare base PATH where every tool probe is a fast miss.
bootstrap_backlog_lines() {  # <code-root> [<home>]
  local code=$1 home=${2:-}
  if [ -n "$home" ]; then
    PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
      FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
  else
    PATH="$BASE_PATH" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
      FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
  fi
}

test_guard_reports_regular_code_root_backlog() {
  local dir out
  dir=$(make_split guard-regular)
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_equals "" "$out" "a code-root link into this home must stay silent"

  rm "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_equals "" "$out" "an absent code-root backlog must stay silent"

  printf '## In flight\n\n## Queued\n\n- [ ] stray: written from the code root\n\n## Done\n' \
    > "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "BACKLOG_RECONCILE: code-root $dir/code/data/backlog.md is not this home's $dir/home/data/backlog.md" \
    "a regular code-root backlog beside a separate home was not reported"
  assert_not_contains "$out" "done-archive.md" "an absent code-root archive was reported"
  pass "bootstrap reports a regular code-root backlog and stays silent for a link into the home or no copy"
}

test_guard_reports_foreign_link_and_archive() {
  local dir out
  dir=$(make_split guard-foreign)
  empty_backlog "$dir/elsewhere.md"
  rm "$dir/code/data/backlog.md"
  ln -s "$dir/elsewhere.md" "$dir/code/data/backlog.md"
  printf '## Done\n' > "$dir/code/data/done-archive.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" "code-root $dir/code/data/backlog.md is not this home's" \
    "a code-root backlog linked outside this home was not reported"
  assert_contains "$out" "code-root $dir/code/data/done-archive.md is not this home's $dir/home/data/done-archive.md" \
    "a regular code-root archive beside a separate home was not reported"
  pass "bootstrap reports a code-root backlog linked elsewhere and a forked archive"
}

test_guard_silent_for_single_home() {
  local dir out
  dir="$TMP_ROOT/single-guard"
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  printf '## Done\n' > "$dir/data/done-archive.md"
  out=$(bootstrap_backlog_lines "$dir")
  assert_equals "" "$out" "the single-home layout's own backlog was reported as a fork"
  out=$(bootstrap_backlog_lines "$dir" "$dir")
  assert_equals "" "$out" "FM_HOME naming the code root was reported as a fork"
  pass "bootstrap stays silent when the code root is the home"
}

# The end-to-end fork: a bare tasks-axi write from the code root. Whatever the
# installed tasks-axi does to the link, bootstrap must agree with the result:
# a replaced link is reported, a written-through link is not.
test_bare_tasks_axi_fork_is_detected() {
  local dir out
  dir=$(make_split bare-fork)
  (cd "$dir/code" && tasks-axi add bare-1 "written from the code root" >/dev/null 2>&1) \
    || fail "bare tasks-axi add failed in the code root"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  if [ -L "$dir/code/data/backlog.md" ]; then
    assert_grep "bare-1" "$dir/home/data/backlog.md" "a written-through link lost the row"
    assert_equals "" "$out" "a written-through link was reported as a fork"
    pass "bare tasks-axi wrote through the code-root link and bootstrap stayed silent"
  else
    assert_no_grep "bare-1" "$dir/home/data/backlog.md" "the replaced link still reached the home"
    assert_contains "$out" "code-root $dir/code/data/backlog.md is not this home's" \
      "bootstrap missed the fork a bare tasks-axi write left behind"
    pass "bare tasks-axi replaced the code-root link and bootstrap reported the fork"
  fi
}

test_wrapper_writes_through_to_home() {
  local dir i
  dir=$(make_split wrapper-home)
  for i in 1 2; do
    wrapper_from_code "$dir" add --objective O7 "ship-$i" "$(ftitle "ship-$i")" >/dev/null || fail "add ship-$i failed"
    wrapper_from_code "$dir" start "ship-$i" >/dev/null || fail "start ship-$i failed"
    wrapper_from_code "$dir" "done" "ship-$i" >/dev/null || fail "done ship-$i failed"
  done
  wrapper_from_code "$dir" add --objective O7 call-1 "captain call" >/dev/null || fail "add call-1 failed"
  wrapper_from_code "$dir" hold call-1 --reason "awaiting the captain" --kind captain >/dev/null \
    || fail "hold call-1 failed"
  printf 'RELATIVE-BODY-MARKER\n' > "$dir/code/body.md"
  wrapper_from_code "$dir" update call-1 --body-file body.md >/dev/null \
    || fail "update with a caller-relative --body-file failed"
  wrapper_from_code "$dir" prune --keep 1 >/dev/null || fail "prune failed"

  [ -L "$dir/code/data/backlog.md" ] || fail "a wrapper write replaced the code-root link"
  [ "$dir/code/data/backlog.md" -ef "$dir/home/data/backlog.md" ] \
    || fail "the code-root link no longer names the home's backlog"
  assert_grep "call-1" "$dir/home/data/backlog.md" "the held row did not land in the home"
  assert_grep "RELATIVE-BODY-MARKER" "$dir/home/data/backlog.md" \
    "a caller-relative --body-file was not read from the caller's directory"
  assert_present "$dir/home/data/done-archive.md" "archiving did not reach the home"
  assert_grep "ship-1" "$dir/home/data/done-archive.md" "the oldest closed row was not archived in the home"
  assert_absent "$dir/code/data/done-archive.md" "archiving wrote a code-root archive"
  assert_equals "" "$(bootstrap_backlog_lines "$dir/code" "$dir/home")" \
    "bootstrap reported a fork after only wrapper writes"
  pass "fm-tasks-axi.sh writes, holds, archives, and reads relative body files through to the home from the code root"
}

test_wrapper_overrides_ambient_file() {
  local dir
  dir=$(make_split wrapper-ambient)
  empty_backlog "$dir/decoy.md"
  (cd "$dir/code" && TASKS_AXI_FILE="$dir/decoy.md" FM_HOME="$dir/home" "$WRAPPER" add --objective O7 amb-1 "ambient" >/dev/null) \
    || fail "add under an ambient TASKS_AXI_FILE failed"
  assert_grep "amb-1" "$dir/home/data/backlog.md" "an ambient TASKS_AXI_FILE diverted the write from the home"
  assert_no_grep "amb-1" "$dir/decoy.md" "an ambient TASKS_AXI_FILE received the write"
  wrapper_from_code "$dir" >/dev/null || fail "the no-command dashboard failed"
  pass "fm-tasks-axi.sh pins the home's backlog over an ambient TASKS_AXI_FILE and serves the dashboard"
}

test_wrapper_refusals() {
  local dir out rc before
  dir=$(make_split wrapper-refuse)
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" add --objective O7 r-1 "explicit" --file "$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file"
  assert_contains "$out" "drop --file" "--file refusal did not explain itself"
  out=$(wrapper_from_code "$dir" list --file="$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file="

  mv "$dir/home/data/backlog.md" "$dir/home/real-backlog.md"
  ln -s "$dir/home/real-backlog.md" "$dir/home/data/backlog.md"
  out=$(wrapper_from_code "$dir" add --objective O7 r-2 "through a link" 2>&1)
  rc=$?
  expect_code 2 "$rc" "symlinked home backlog"
  assert_contains "$out" "is a symlink" "the symlinked home backlog refusal did not name the link"
  [ -L "$dir/home/data/backlog.md" ] || fail "a refused call still replaced the home link"
  assert_equals "$before" "$(cat "$dir/home/real-backlog.md")" "a refused call changed the backlog"

  out=$(cd "$dir/code" && FM_HOME="$dir/missing-home" "$WRAPPER" list 2>&1)
  rc=$?
  expect_code 2 "$rc" "missing data directory"
  pass "fm-tasks-axi.sh refuses caller --file, a symlinked home backlog, and an unresolvable home"
}

# Dispatch alone moves a row to In flight, because only bin/fm-spawn.sh
# creates the task record, status file, and inbox that go with it; a row
# hand-placed there through `add --start` would count as live work nobody runs.
test_wrapper_refuses_add_start() {
  local dir out rc before
  dir=$(make_split wrapper-add-start)
  before=$(cat "$dir/home/data/backlog.md")
  out=$(wrapper_from_code "$dir" add --objective O7 hs-1 "hand-started" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "add --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the add --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused add --start still wrote a row"
  out=$(wrapper_from_code "$dir" create --objective O7 hs-c "hand-started via alias" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "create --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the create --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused create --start still wrote a row"
  wrapper_from_code "$dir" add --objective O7 hs-2 "queued" >/dev/null || fail "plain add was refused"
  assert_grep "hs-2" "$dir/home/data/backlog.md" "plain add did not write its row"
  wrapper_from_code "$dir" start hs-2 >/dev/null || fail "start <id> was refused"
  pass "fm-tasks-axi.sh refuses add --start while plain add and start <id> pass through"
}

test_wrapper_single_home() {
  local dir
  dir="$TMP_ROOT/single-wrapper"
  mkdir -p "$dir/data"
  fm_test_tasks_toml "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  (cd "$dir" && FM_ROOT_OVERRIDE="$dir" "$WRAPPER" add --objective O7 solo-1 "single home" >/dev/null) \
    || fail "add in the single-home layout failed"
  assert_grep "solo-1" "$dir/data/backlog.md" "the single-home layout lost its own backlog write"
  pass "fm-tasks-axi.sh keeps the single-home layout addressing its own code-root backlog"
}

# Completion needs proof of the deliverable, however the command is spelled.
completion_refused() {  # <case-dir> <label> <wrapper args...>
  local dir=$1 label=$2 out rc=0
  shift 2
  out=$(wrapper_from_code "$dir" "$@" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "$label: expected a refusal (exit 2), got $rc: $out"
  printf '%s' "$out"
}

row_state() {  # <case-dir> <id>
  grep -E "^- \[[x ]\] $2 " "$1/home/data/backlog.md" | sed -E 's/^- \[(.)\].*/\1/'
}

test_completion_needs_proof_of_the_deliverable() {
  local dir fakebin out
  dir=$(make_split completion)
  fakebin=$(fm_fakebin "$dir")
  wrapper_from_code "$dir" add --objective O7 ship-a "ship a" --kind ship --repo p >/dev/null
  wrapper_from_code "$dir" add --objective O7 scout-a "scout a" --kind scout --repo p >/dev/null
  wrapper_from_code "$dir" add --objective O7 note-a "a plain note" --kind docs --repo p >/dev/null
  # Every spelling of a completion without proof is refused and leaves the row open.
  completion_refused "$dir" "bare done" "done" ship-a >/dev/null
  completion_refused "$dir" "close alias" "close" ship-a >/dev/null
  completion_refused "$dir" "task noun" "task" "done" ship-a >/dev/null
  completion_refused "$dir" "task noun and close" "task" "close" ship-a >/dev/null
  wrapper_from_code "$dir" add --objective O7 markdown "backend-value decoy" --kind docs >/dev/null \
    || fail "could not create backend-value decoy"
  completion_refused "$dir" "backend between done and id" "done" --backend markdown ship-a >/dev/null
  completion_refused "$dir" "backend between noun close and id" "task" "close" --backend=markdown ship-a >/dev/null
  completion_refused "$dir" "backend after target id" "done" ship-a --backend=markdown >/dev/null
  completion_refused "$dir" "split backend after target id" "task" "close" ship-a --backend markdown >/dev/null
  [ "$(row_state "$dir" markdown)" = " " ] || fail "backend parsing completed the decoy row"
  out=$(completion_refused "$dir" "help text inside a note" "done" ship-a --note=$'a note\n--help')
  assert_contains "$out" "completion needs proof" "a note naming --help skipped the guard"
  completion_refused "$dir" "a note alone is no proof" "done" ship-a --note "local main" >/dev/null
  [ "$(row_state "$dir" ship-a)" = " " ] || fail "a refused completion closed the row"
  # A scout's deliverable is a written non-empty regular file; a ship's is a merged pull request.
  mkdir -p "$dir/home/data/scout-a/report.md"
  completion_refused "$dir" "directory as report" "done" scout-a --report data/scout-a/report.md >/dev/null
  rmdir "$dir/home/data/scout-a/report.md"
  : > "$dir/home/data/scout-a/report.md"
  completion_refused "$dir" "empty report" "done" scout-a --report data/scout-a/report.md >/dev/null
  printf '# findings\n' > "$dir/home/data/scout-a/report.md"
  completion_refused "$dir" "report for a ship" "done" ship-a --report data/scout-a/report.md >/dev/null
  out=$(wrapper_from_code "$dir" task close scout-a --report data/scout-a/report.md 2>&1) \
    || fail "a written report was refused: $out"
  [ "$(row_state "$dir" scout-a)" = x ] || fail "the reported scout did not close"
  completion_refused "$dir" "non-GitHub pull request" "done" ship-a --pr https://forge.example.com/o/r/pulls/3 >/dev/null
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'api_response:\n  body: merged=%s\n' "${FAKE_MERGED:-false}"
SH
  chmod +x "$fakebin/gh-axi"
  (cd "$dir/code" && PATH="$fakebin:$PATH" FAKE_MERGED=false FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    "$WRAPPER" "done" ship-a --pr https://github.com/o/r/pull/9 >/dev/null 2>&1) && fail "an unmerged pull request closed the row"
  (cd "$dir/code" && PATH="$fakebin:$PATH" FAKE_MERGED=true FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    "$WRAPPER" "done" ship-a --pr https://github.com/o/r/pull/9 >/dev/null) || fail "a merged pull request was refused"
  [ "$(row_state "$dir" ship-a)" = x ] || fail "the merged ship did not close"
  # Other row kinds, help text, and unknown ids keep tasks-axi's own behavior.
  wrapper_from_code "$dir" "done" note-a >/dev/null || fail "a non-delivery row was refused"
  wrapper_from_code "$dir" "done" --help >/dev/null || fail "done --help was refused"
  pass "fm-tasks-axi.sh closes a ship or scout only with its proved deliverable"
}

test_completion_by_the_captains_own_words() {
  local dir words out
  dir=$(make_split drop)
  words="$dir/words.txt"
  wrapper_from_code "$dir" add --objective O7 ship-d "$(ftitle ship-d)" --kind ship --repo p >/dev/null
  wrapper_from_code "$dir" add --objective O7 ship-e "$(ftitle ship-e)" --kind ship --repo p >/dev/null
  : > "$words"
  completion_refused "$dir" "empty words" "done" ship-d --drop-file "$words" >/dev/null
  ln -s "$words" "$dir/words-link.txt"
  printf 'Drop it; the premise is gone.\n' > "$words"
  completion_refused "$dir" "symbolic link words" "done" ship-d --drop-file "$dir/words-link.txt" >/dev/null
  completion_refused "$dir" "words with a pull request" "done" ship-d --drop-file "$words" --pr https://github.com/o/r/pull/9 >/dev/null
  out=$(wrapper_from_code "$dir" "task" "done" ship-d --drop-file "$words" 2>&1) \
    || fail "the captain's words were refused: $out"
  [ "$(row_state "$dir" ship-d)" = x ] || fail "the dropped row did not close"
  cmp -s "$words" "$dir/home/data/ship-d/captain-drop.md" || fail "the exact words were not retained"
  assert_grep "dropped" "$dir/home/data/backlog.md" "the row does not record the fixed drop note"
  # A live task record completes only through teardown.
  printf 'kind=ship\n' > "$dir/home/state/ship-e.meta"
  out=$(completion_refused "$dir" "live task record" "done" ship-e --drop-file "$words")
  assert_contains "$out" "fm-teardown.sh ship-e" "a live task did not point at teardown"
  pass "fm-tasks-axi.sh records a captain's drop with the exact words and refuses a live task"
}

# A finished item stops blocking the items that waited on it: the wrapper removes
# the finished id from every other item's blocked-by edges and reports each cleared
# edge on stderr, leaving stdout as tasks-axi printed it. An edge to a second,
# unfinished blocker stays.
deps_of() {  # <case-dir> <id>
  wrapper_from_code "$1" show "$2" 2>&1 | sed -n 's/^  deps: *//p' | head -1 | tr -d '"'
}

test_completion_clears_the_finished_blocker_from_dependents() {
  local dir words out err
  dir=$(make_split unblock)
  words="$dir/words.txt"
  printf 'Dropped by the captain.\n' > "$words"
  wrapper_from_code "$dir" add --objective O7 blk-a "$(ftitle blk-a)" --kind docs >/dev/null
  wrapper_from_code "$dir" add --objective O7 blk-b "$(ftitle blk-b)" --kind docs >/dev/null
  wrapper_from_code "$dir" add --objective O7 blk-ship "$(ftitle blk-ship)" --kind ship --repo p >/dev/null
  wrapper_from_code "$dir" add --objective O7 dep-two "$(ftitle dep-two)" --kind docs >/dev/null
  wrapper_from_code "$dir" add --objective O7 dep-one "$(ftitle dep-one)" --kind docs >/dev/null
  wrapper_from_code "$dir" add --objective O7 dep-ship "$(ftitle dep-ship)" --kind docs >/dev/null
  wrapper_from_code "$dir" add --objective O7 bystander "$(ftitle bystander)" --kind docs >/dev/null
  wrapper_from_code "$dir" block dep-two --by blk-a >/dev/null
  wrapper_from_code "$dir" block dep-two --by blk-b >/dev/null
  wrapper_from_code "$dir" block dep-one --by blk-a >/dev/null
  wrapper_from_code "$dir" block dep-ship --by blk-ship >/dev/null
  wrapper_from_code "$dir" start dep-ship >/dev/null

  out=$(wrapper_from_code "$dir" "done" blk-a --note finished 2> "$dir/err") \
    || fail "completing a blocker failed: $out $(cat "$dir/err")"
  err=$(cat "$dir/err")
  assert_not_contains "$out" "unblocked:" "the unblock report leaked into tasks-axi's stdout"
  assert_contains "$err" "unblocked: dep-two no longer waits on blk-a" "a dependent was not reported unblocked"
  assert_contains "$err" "unblocked: dep-one no longer waits on blk-a" "a second dependent was not reported unblocked"
  [ "$(deps_of "$dir" dep-two)" = "blocked-by:blk-b" ] \
    || fail "the second, unfinished blocker did not stay: $(deps_of "$dir" dep-two)"
  assert_contains "$(wrapper_from_code "$dir" show dep-two 2>&1)" "blocked: yes" "the item with an unfinished blocker was freed"
  [ "$(deps_of "$dir" dep-one)" = none ] || fail "the only blocker was not cleared: $(deps_of "$dir" dep-one)"
  [ "$(deps_of "$dir" bystander)" = none ] || fail "an unrelated item changed"

  # A repeat of the completion has nothing left to clear and reports nothing.
  out=$(wrapper_from_code "$dir" "done" blk-a --note finished 2>&1) || true
  assert_not_contains "$out" "unblocked:" "a repeat completion reported an edge it had already cleared"

  # A ship completes with the captain's words and clears its dependents the same way,
  # including a dependent that is already in flight.
  wrapper_from_code "$dir" "done" blk-ship --drop-file "$words" 2> "$dir/err" >/dev/null \
    || fail "the ship drop failed: $(cat "$dir/err")"
  assert_contains "$(cat "$dir/err")" "unblocked: dep-ship no longer waits on blk-ship" "an in-flight dependent was not unblocked by a ship's completion"
  [ "$(deps_of "$dir" dep-ship)" = none ] || fail "the ship's dependent kept its edge"
  pass "fm-tasks-axi.sh clears a finished blocker from every dependent, keeps another blocker, and reports on stderr only"
}

test_completion_preserves_retained_captain_calls() {
  local dir fakebin words before spelling evidence out
  local command_args=() evidence_args=()
  dir=$(make_split retained-captain-call)
  fakebin=$(fm_fakebin "$dir")
  words="$dir/drop.txt"
  printf 'Discard the finished work.\n' > "$words"
  wrapper_from_code "$dir" add --objective O7 held-ship "retained ship call" --kind ship --repo p >/dev/null \
    || fail "could not create the retained ship"
  wrapper_from_code "$dir" add --objective O7 held-scout "paused investigation awaiting direction" --kind scout --repo p >/dev/null \
    || fail "could not create the retained scout"
  for evidence in held-ship held-scout; do
    wrapper_from_code "$dir" hold "$evidence" --reason "which route?" --kind captain >/dev/null \
      || fail "could not hold $evidence for the captain"
    printf 'kind=%s\n' "${evidence#held-}" > "$dir/home/state/$evidence.meta"
    rm "$dir/home/state/$evidence.meta"
  done
  mkdir -p "$dir/home/data/held-scout"
  printf '# findings\n' > "$dir/home/data/held-scout/report.md"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$FAKE_FORGE_LOG"
printf 'api_response:\n  body: merged=true\n'
SH
  chmod +x "$fakebin/gh-axi"
  before=$(cat "$dir/home/data/backlog.md")
  for spelling in "done" "close" task-done task-close; do
    case "$spelling" in
      done|close) command_args=("$spelling") ;;
      task-done) command_args=("task" "done") ;;
      task-close) command_args=("task" "close") ;;
    esac
    for evidence in ship-drop scout-drop report pr; do
      case "$evidence" in
        ship-drop) evidence_args=(held-ship --drop-file "$words") ;;
        scout-drop) evidence_args=(held-scout "--drop-file=$words") ;;
        report) evidence_args=(held-scout --report data/held-scout/report.md) ;;
        pr) evidence_args=(held-ship --pr=https://github.com/o/r/pull/9) ;;
      esac
      out=$(PATH="$fakebin:$PATH" FAKE_FORGE_LOG="$dir/forge-called" \
        completion_refused "$dir" "$spelling with $evidence" "${command_args[@]}" "${evidence_args[@]}")
      assert_contains "$out" "open captain call" "$spelling with $evidence missed the captain hold"
      assert_contains "$out" "fm-captain-hold.sh answer" "$spelling with $evidence did not name the answer boundary"
      assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" \
        "$spelling with $evidence changed the retained captain call"
    done
  done
  assert_absent "$dir/forge-called" "a retained captain call reached the forge evidence check"
  assert_absent "$dir/home/data/held-ship/captain-drop.md" "a refused ship completion retained drop words"
  assert_absent "$dir/home/data/held-scout/captain-drop.md" "a refused scout completion retained drop words"
  printf 'Take the north route.\n' > "$dir/answer.txt"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$ROOT/bin/fm-captain-hold.sh" \
    answer held-ship --decision-file "$dir/answer.txt" >/dev/null \
    || fail "the captain answer could not close the retained ship call"
  [ "$(row_state "$dir" held-ship)" = x ] || fail "the answered ship call did not close"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$ROOT/bin/fm-captain-hold.sh" \
    answer held-scout --decision-file "$dir/answer.txt" --release >/dev/null \
    || fail "the captain answer could not release the retained scout call"
  wrapper_from_code "$dir" task close held-scout --report data/held-scout/report.md >/dev/null \
    || fail "the released scout could not complete with its report"
  [ "$(row_state "$dir" held-scout)" = x ] || fail "the released scout did not close"
  pass "all completion spellings preserve retained captain calls before accepting drop, report, or merged PR evidence"
}

test_public_restart_retires_drop_provenance() (
  local dir verb noun layout id stored out data data_override
  local prefix=()
  dir=$(make_split public-restart-drop)
  printf 'Keep these exact captain words: café 航海.\n' > "$dir/words.txt"
  printf '%s\n' 'Body café 航海' '  dropped  ' ' Deliverable of the finished work: dropped ' \
    'Question: keep dropped as a word?' 'dropped later' > "$dir/body.txt"
  for layout in home relative; do
    if [ "$layout" = relative ]; then
      data_override=relocated/data
      data="$dir/code/relocated/data"
      mkdir -p "$data"
      empty_backlog "$data/backlog.md"
    else
      data_override=
      data="$dir/home/data"
    fi
    for verb in reopen start; do
      for noun in bare task; do
        id="$layout-$verb-$noun"
        if [ "$noun" = task ]; then prefix=(task "$verb"); else prefix=("$verb"); fi
        FM_DATA_OVERRIDE="$data_override" wrapper_from_code "$dir" add --objective O7 "$id" "$(ftitle "$id")" --kind scout >/dev/null \
          || fail "could not add restart fixture"
        FM_DATA_OVERRIDE="$data_override" wrapper_from_code "$dir" "done" "$id" --drop-file "$dir/words.txt" >/dev/null \
          || fail "could not drop restart fixture"
        FM_DATA_OVERRIDE="$data_override" wrapper_from_code "$dir" update "$id" --body-file "$dir/body.txt" >/dev/null \
          || fail "could not attach restart body"
        out=$(FM_DATA_OVERRIDE="$data_override" wrapper_from_code "$dir" "${prefix[@]}" "$id" 2>&1) \
          || fail "public $layout $noun $verb failed: $out"
        stored=$(FM_DATA_OVERRIDE="$data_override" wrapper_from_code "$dir" show "$id" --full) || fail "could not read restarted row"
        if [ "$verb" = start ]; then
          assert_contains "$stored" "state: in_flight" "$layout $noun start did not change state"
        else
          assert_contains "$stored" "state: queued" "$layout $noun reopen did not change state"
        fi
        assert_contains "$stored" "Historical captain disposition: dropped" "$layout $noun $verb left drop disposition active"
        assert_contains "$stored" "Historical deliverable of the finished work: dropped" "$verb left dropped deliverable active"
        assert_contains "$stored" "Body café 航海" "$verb changed Unicode body bytes"
        assert_contains "$stored" "Question: keep dropped as a word?" "$verb changed the captain question"
        assert_contains "$stored" "dropped later" "$verb rewrote a non-exact dropped line"
        cmp -s "$dir/words.txt" "$data/$id/captain-drop.md" \
          || fail "$layout $noun $verb changed retained captain words"
        assert_grep "$id" "$data/backlog.md" "$layout $noun $verb missed the addressed backlog"
        if [ "$layout" = relative ]; then
          assert_no_grep "$id" "$dir/home/data/backlog.md" "relative restart wrote the home backlog"
          assert_absent "$dir/home/relocated/data" "relative restart resolved data from home"
        fi
      done
    done
  done
  pass "public reopen and start with either noun retire drop provenance in home and caller-relative data, preserving body and words"
)

test_restart_handles_sole_drop_and_failed_body_update() {
  local dir fakebin real before rc
  dir=$(make_split restart-body-boundaries)
  fakebin=$(fm_fakebin "$dir")
  real=$(command -v tasks-axi)
  wrapper_from_code "$dir" add --objective O7 sole-drop "sole dropped body" --kind scout >/dev/null || fail "could not add sole drop"
  printf 'dropped\n' > "$dir/body"
  wrapper_from_code "$dir" update sole-drop --body-file "$dir/body" >/dev/null || fail "could not set sole body"
  wrapper_from_code "$dir" start sole-drop >/dev/null || fail "sole drop restart failed"
  assert_contains "$(wrapper_from_code "$dir" show sole-drop --full)" \
    "Historical captain disposition: dropped" "sole dropped body was not retired"
  wrapper_from_code "$dir" add --objective O7 failed-drop "failed body update" --kind scout >/dev/null || fail "could not add failed drop"
  wrapper_from_code "$dir" update failed-drop --body-file "$dir/body" >/dev/null || fail "could not set failed body"
  before=$(cat "$dir/home/data/backlog.md")
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in --body-file|--body-file=*) exit 1 ;; esac
done
exec "$real" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
  rc=0
  PATH="$fakebin:$PATH" wrapper_from_code "$dir" start failed-drop >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "restart ignored failed retirement body update"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "failed retirement changed the original backlog"
  pass "restart handles sole dropped bodies and refuses failed retirement updates without changing the row"
}

wait_mutation_fixture() {
  local path=$1 label=$2 child=${3:-} result=${4:-} status=0 out=''
  local deadline=$((SECONDS + ${FM_BACKLOG_ROW_TIMEOUT_SECS:-10} + ${FM_TASKS_AXI_TIMEOUT:-30} + 10))
  while [ ! -e "$path" ]; do
    if [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null; then
      wait "$child" || status=$?
      [ -z "$result" ] || out=$(cat "$result")
      fail "$label exited before its synchronization point (status $status): $out"
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      [ -z "$result" ] || out=$(cat "$result")
      fail "$label did not reach its synchronization point within the read/mutation grace: $out"
    fi
    sleep 0.05
  done
}

make_mutation_wait_sleep() {
  local fakebin=$1 real
  real=$(command -v sleep)
  cat > "$fakebin/sleep" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = 0.1 ] && [ -n "\${FAKE_LOCK_WAIT:-}" ]; then
  : > "\$FAKE_LOCK_WAIT"
fi
exec "$real" "\$@"
SH
  chmod +x "$fakebin/sleep"
}

test_unsupported_leading_backend_preserves_the_row() {
  local dir verb form out rc before
  local args=()
  dir=$(make_split leading-backend)
  wrapper_from_code "$dir" add --objective O7 leading-drop "unsupported leading backend" --kind scout >/dev/null \
    || fail "could not create leading backend fixture"
  printf 'Keep the original drop.\n' > "$dir/words"
  wrapper_from_code "$dir" "done" leading-drop --drop-file "$dir/words" >/dev/null \
    || fail "could not drop leading backend fixture"
  before=$(cat "$dir/home/data/backlog.md")
  for verb in "done" "close" start reopen; do
    for form in prefix-split prefix-equals noun-split noun-equals prefix-json noun-json; do
      case "$form" in
        prefix-split) args=(--backend markdown "$verb" leading-drop) ;;
        prefix-equals) args=(--backend=markdown task "$verb" leading-drop) ;;
        noun-split) args=(task --backend markdown "$verb" leading-drop) ;;
        noun-equals) args=(task --backend=markdown "$verb" leading-drop) ;;
        prefix-json) args=(--json "$verb" leading-drop) ;;
        noun-json) args=(task --json "$verb" leading-drop) ;;
      esac
      rc=0
      out=$(wrapper_from_code "$dir" "${args[@]}" 2>&1) || rc=$?
      expect_code 2 "$rc" "$form $verb"
      assert_contains "$out" "tasks-axi directly" "$form $verb did not name the direct SDK escape"
      assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" \
        "$form $verb changed provenance despite the wrapper refusal"
      cmp -s "$dir/words" "$dir/home/data/leading-drop/captain-drop.md" \
        || fail "$form $verb changed retained captain words"
    done
  done
  pass "unsupported leading global forms are refused by the wrapper without changing the task"
}

test_task_mutations_wait_for_lifecycle_custody() (
  local dir fakebin real lock_kind verb child='' holder='' out rc
  local args=()
  dir=$(make_split mutation-custody)
  fakebin=$(fm_fakebin "$dir")
  real=$(command -v tasks-axi)
  make_mutation_wait_sleep "$fakebin"
  wrapper_from_code "$dir" add --objective O7 custody "custody fixture" --kind scout >/dev/null || fail "could not add custody row"
  mkdir -p "$dir/home/data/custody"
  printf '# findings\n' > "$dir/home/data/custody/report.md"
  printf 'dropped\n' > "$dir/body"
  wrapper_from_code "$dir" update custody --body-file "$dir/body" >/dev/null || fail "could not set custody body"
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
: > "$dir/tasks-called"
exec "$real" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
  trap 'touch "$dir/unlock"; [ -z "$child" ] || kill "$child" 2>/dev/null || true; [ -z "$holder" ] || kill "$holder" 2>/dev/null || true' EXIT
  for lock_kind in control meta; do
    for verb in "done" "close" start reopen; do
      rm -f "$dir/locked" "$dir/unlock" "$dir/lock-wait" "$dir/tasks-called"
      FM_HOME="$dir/home" bash -c '
        . "$1"
        lock="$STATE/.$2-custody.lock"
        fm_lock_acquire_wait "$lock"
        trap '\''fm_lock_release "$lock"'\'' EXIT
        : > "$3/locked"
        while [ ! -e "$3/unlock" ]; do sleep 0.05; done
      ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock_kind" "$dir" &
      holder=$!
      wait_mutation_fixture "$dir/locked" "$lock_kind holder" "$holder"
      case "$verb" in
        done) args=("done" custody --report data/custody/report.md) ;;
        close) args=("task" "close" custody --report data/custody/report.md) ;;
        start) args=(task start custody) ;;
        reopen) args=(reopen custody) ;;
      esac
      PATH="$fakebin:$PATH" FAKE_LOCK_WAIT="$dir/lock-wait" \
        wrapper_from_code "$dir" "${args[@]}" > "$dir/result" 2>&1 &
      child=$!
      wait_mutation_fixture "$dir/lock-wait" "$lock_kind $verb contention" "$child" "$dir/result"
      assert_absent "$dir/tasks-called" "$verb read or changed the task before $lock_kind custody"
      : > "$dir/unlock"
      wait "$holder" || fail "$lock_kind holder failed"
      holder=''
      rc=0
      wait "$child" || rc=$?
      child=''
      out=$(cat "$dir/result")
      [ "$rc" -eq 0 ] || fail "$verb failed after $lock_kind custody was released: $out"
      assert_present "$dir/tasks-called" "$verb did not resume after $lock_kind custody was released"
      assert_absent "$dir/home/state/.control-custody.lock" "$verb leaked control custody"
      assert_absent "$dir/home/state/.meta-custody.lock" "$verb leaked metadata custody"
    done
  done
  FM_STATE_OVERRIDE=relative-state wrapper_from_code "$dir" start custody >/dev/null \
    || fail "restart with caller-relative state directory failed"
  assert_absent "$dir/code/relative-state/.control-custody.lock" "backlog-root change leaked caller-relative control custody"
  assert_absent "$dir/code/relative-state/.meta-custody.lock" "backlog-root change leaked caller-relative metadata custody"
  pass "completion and restart spellings wait for control then metadata custody before authoritative reads"
)

test_completion_serializes_with_a_concurrent_hold() (
  local dir fakebin real completion='' holding='' rc out
  dir=$(make_split completion-hold-race)
  fakebin=$(fm_fakebin "$dir")
  real=$(command -v tasks-axi)
  make_mutation_wait_sleep "$fakebin"
  wrapper_from_code "$dir" add --objective O7 hold-first "$(ftitle hold-first)" --kind ship >/dev/null || fail "could not add held row"
  wrapper_from_code "$dir" add --objective O7 completion-first "$(ftitle completion-first)" --kind ship >/dev/null || fail "could not add completion row"
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ "\${2:-}" = hold-first ]; then
  : > "$dir/held-row-read"
fi
if [ "\${1:-}" = hold ] && [ "\${2:-}" != hold-first ]; then
  : > "$dir/concurrent-hold-entered"
fi
if [ "\${1:-}" = hold ] && [ "\${2:-}" = hold-first ]; then
  : > "$dir/hold-entered"
  while [ ! -e "$dir/release-hold" ]; do sleep 0.05; done
fi
exec "$real" "\$@"
SH
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
: > "$dir/forge-entered"
while [ ! -e "$dir/release-forge" ]; do sleep 0.05; done
printf 'api_response:\n  body: merged=true\n'
SH
  chmod +x "$fakebin/tasks-axi" "$fakebin/gh-axi"
  trap 'touch "$dir/release-hold" "$dir/release-forge"; [ -z "$completion" ] || kill "$completion" 2>/dev/null || true; [ -z "$holding" ] || kill "$holding" 2>/dev/null || true' EXIT
  PATH="$fakebin:$PATH" wrapper_from_code "$dir" hold hold-first --reason "captain decides" --kind captain \
    > "$dir/hold-result" 2>&1 &
  holding=$!
  wait_mutation_fixture "$dir/hold-entered" "hold mutation" "$holding" "$dir/hold-result"
  PATH="$fakebin:$PATH" FAKE_LOCK_WAIT="$dir/completion-wait" \
    wrapper_from_code "$dir" task close hold-first --pr https://github.com/o/r/pull/9 \
    > "$dir/completion-result" 2>&1 &
  completion=$!
  wait_mutation_fixture "$dir/completion-wait" "completion behind hold" "$completion" "$dir/completion-result"
  assert_absent "$dir/held-row-read" "completion read the row before its hold committed"
  assert_absent "$dir/forge-entered" "completion checked evidence while a hold was committing"
  : > "$dir/release-hold"
  wait "$holding" || fail "concurrent hold failed"
  holding=''
  rc=0
  wait "$completion" || rc=$?
  completion=''
  expect_code 2 "$rc" "completion after captain hold"
  out=$(cat "$dir/completion-result")
  assert_contains "$out" "open captain call" "completion did not re-read the committed captain hold"
  [ "$(row_state "$dir" hold-first)" = " " ] || fail "completion closed a concurrently held task"
  assert_absent "$dir/forge-entered" "held completion reached its evidence check"
  PATH="$fakebin:$PATH" wrapper_from_code "$dir" "done" completion-first --pr https://github.com/o/r/pull/9 \
    > "$dir/completion-result" 2>&1 &
  completion=$!
  wait_mutation_fixture "$dir/forge-entered" "completion evidence" "$completion" "$dir/completion-result"
  PATH="$fakebin:$PATH" FAKE_LOCK_WAIT="$dir/hold-wait" \
    wrapper_from_code "$dir" hold --reason "captain decides" --kind captain completion-first \
    > "$dir/hold-result" 2>&1 &
  holding=$!
  wait_mutation_fixture "$dir/hold-wait" "hold behind completion" "$holding" "$dir/hold-result"
  assert_absent "$dir/concurrent-hold-entered" "hold mutated the row during completion evidence"
  : > "$dir/release-forge"
  wait "$completion" || fail "completion failed after its evidence was released"
  completion=''
  wait "$holding" || fail "hold failed after completion released custody"
  holding=''
  [ "$(row_state "$dir" completion-first)" = x ] || fail "concurrent hold interrupted proved completion"
  assert_contains "$(wrapper_from_code "$dir" show completion-first --full)" \
    "hold_kind: captain" "hold did not resume after completion released custody"
  assert_absent "$dir/home/state/.control-completion-first.lock" "completion/hold leaked control custody"
  pass "a concurrent hold serializes before admission or after proved completion, never inside its evidence-to-mutation window"
)

test_restart_serializes_with_a_concurrent_body_change() (
  local dir fakebin real verb restart='' updating='' rc stored
  dir=$(make_split restart-body-race)
  fakebin=$(fm_fakebin "$dir")
  real=$(command -v tasks-axi)
  make_mutation_wait_sleep "$fakebin"
  printf 'Drop the previous work.\n' > "$dir/words"
  printf 'Captain body update must survive.\n' > "$dir/replacement"
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "\$FAKE_RESTART_VERB" ]; then
  : > "$dir/restart-entered"
  while [ ! -e "$dir/release-restart" ]; do sleep 0.05; done
  printf 'restart failed before mutation\n' >&2
  exit 47
fi
exec "$real" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
  trap 'touch "$dir/release-restart"; [ -z "$restart" ] || kill "$restart" 2>/dev/null || true; [ -z "$updating" ] || kill "$updating" 2>/dev/null || true' EXIT
  for verb in start reopen; do
    wrapper_from_code "$dir" add --objective O7 "body-$verb" "$(ftitle "body-$verb")" --kind scout >/dev/null || fail "could not add body race row"
    wrapper_from_code "$dir" "done" "body-$verb" --drop-file "$dir/words" >/dev/null || fail "could not drop body race row"
    rm -f "$dir/restart-entered" "$dir/release-restart" "$dir/update-wait"
    PATH="$fakebin:$PATH" FAKE_RESTART_VERB="$verb" FM_TASKS_AXI_TIMEOUT=30 \
      wrapper_from_code "$dir" "$verb" "body-$verb" > "$dir/restart-result" 2>&1 &
    restart=$!
    wait_mutation_fixture "$dir/restart-entered" "$verb mutation" "$restart" "$dir/restart-result"
    PATH="$fakebin:$PATH" FAKE_RESTART_VERB="$verb" FAKE_LOCK_WAIT="$dir/update-wait" \
      wrapper_from_code "$dir" task edit --body-file "$dir/replacement" --backend markdown "body-$verb" \
      > "$dir/update-result" 2>&1 &
    updating=$!
    wait_mutation_fixture "$dir/update-wait" "$verb competing body update" "$updating" "$dir/update-result"
    stored=$(wrapper_from_code "$dir" show "body-$verb" --full) || fail "could not read paused restart"
    assert_contains "$stored" "Historical captain disposition: dropped" "$verb did not retire provenance before mutation"
    assert_not_contains "$stored" "Captain body update must survive." "$verb let a body change enter its rollback window"
    : > "$dir/release-restart"
    rc=0
    wait "$restart" || rc=$?
    restart=''
    expect_code 47 "$rc" "$verb failure"
    wait "$updating" || fail "body update did not resume after $verb"
    updating=''
    stored=$(wrapper_from_code "$dir" show "body-$verb" --full) || fail "could not read updated body"
    assert_contains "$stored" "Captain body update must survive." "$verb rollback overwrote a concurrent body change"
    assert_not_contains "$stored" "Historical captain disposition:" "$verb rollback overwrote the final replacement body"
    cmp -s "$dir/words" "$dir/home/data/body-$verb/captain-drop.md" || fail "$verb changed retained captain words"
  done
  pass "start and reopen keep body updates outside retirement, failed-command readback, and rollback custody"
)

test_failed_restart_reads_back_before_restoring_drop() (
  local dir fakebin real verb noun layout outcome id out rc stored data data_override
  local prefix=()
  dir=$(make_split failed-restart-readback)
  fakebin=$(fm_fakebin "$dir")
  real=$(command -v tasks-axi)
  printf 'Exact drop words café 航海.\n' > "$dir/words"
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
command=\${1:-}
[ "\$command" != task ] || command=\${2:-}
if [ "\${1:-}" = show ] && [ "\$FAKE_RESTART_OUTCOME" = unreadable ] && [ -e "$dir/restart-failed" ]; then
  printf 'readback unavailable\n' >&2
  exit 46
fi
if [ "\$command" = "\$FAKE_RESTART_VERB" ]; then
  if [ "\$FAKE_RESTART_OUTCOME" = committed ]; then
    "$real" "\$@" || exit \$?
  fi
  : > "$dir/restart-failed"
  printf 'restart command failed\n' >&2
  exit 47
fi
exec "$real" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
  for layout in home relative; do
    if [ "$layout" = relative ]; then
      data_override=relocated/data
      data="$dir/code/relocated/data"
      mkdir -p "$data"
      empty_backlog "$data/backlog.md"
    else
      data_override=
      data="$dir/home/data"
    fi
    for verb in start reopen; do
      for noun in bare task; do
        if [ "$noun" = task ]; then prefix=(task "$verb"); else prefix=("$verb"); fi
        for outcome in before committed unreadable; do
          id="$layout-$verb-$noun-$outcome"
          FM_DATA_OVERRIDE="$data_override" wrapper_from_code "$dir" add --objective O7 "$id" "$(ftitle "$id")" --kind scout >/dev/null || fail "could not add restart failure fixture"
          FM_DATA_OVERRIDE="$data_override" wrapper_from_code "$dir" "done" "$id" --drop-file "$dir/words" >/dev/null || fail "could not drop restart failure fixture"
          rm -f "$dir/restart-failed"
          rc=0
          out=$(FM_DATA_OVERRIDE="$data_override" PATH="$fakebin:$PATH" FAKE_RESTART_VERB="$verb" FAKE_RESTART_OUTCOME="$outcome" \
            wrapper_from_code "$dir" "${prefix[@]}" "$id" 2>&1) || rc=$?
          expect_code 47 "$rc" "$layout $noun $verb $outcome failure"
          assert_contains "$out" "restart command failed" "$verb $outcome lost the original command error"
          stored=$(FM_DATA_OVERRIDE="$data_override" wrapper_from_code "$dir" show "$id" --full) || fail "could not read failed restart row"
          if [ "$outcome" = before ]; then
            assert_contains "$stored" "state: done" "$verb failed-before-mutation changed state"
            assert_not_contains "$stored" "Historical captain disposition:" "$verb did not roll back proved unchanged disposition"
            assert_contains "$stored" "dropped" "$layout $noun $verb lost the original active drop body"
          else
            assert_contains "$stored" "Historical captain disposition: dropped" "$verb $outcome restored active drop provenance"
            assert_contains "$out" "prior drop provenance was not restored" "$verb $outcome did not describe withheld rollback"
            if [ "$outcome" = committed ]; then
              if [ "$verb" = start ]; then
                assert_contains "$stored" "state: in_flight" "failed committed start was not applied"
              else
                assert_contains "$stored" "state: queued" "failed committed reopen was not applied"
              fi
            else
              assert_contains "$stored" "state: done" "$verb unreadable fixture unexpectedly mutated state"
              assert_contains "$out" "restart outcome could not be verified" "$verb unreadable failure was not reported"
            fi
          fi
          cmp -s "$dir/words" "$data/$id/captain-drop.md" || fail "$verb $outcome changed retained captain words"
          assert_grep "$id" "$data/backlog.md" "$layout $noun $verb missed the addressed backlog"
          if [ "$layout" = relative ]; then
            assert_no_grep "$id" "$dir/home/data/backlog.md" "failed relative restart wrote the home backlog"
            assert_absent "$dir/home/relocated/data" "failed relative restart resolved data from home"
          fi
          assert_absent "$dir/home/state/.control-$id.lock" "$verb $outcome leaked control custody"
          assert_absent "$dir/home/state/.meta-$id.lock" "$verb $outcome leaked metadata custody"
        done
      done
    done
  done
  pass "failed start and reopen with either noun read back home and caller-relative data before restoring only proved unchanged drops"
)

test_resumed_deliveries_reach_landed_output() {
  local dir fakebin id kind json out
  command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found for resumed landed output\n'; return; }
  dir=$(make_split resumed-landed)
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux treehouse gh
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'api_response:\n  body: merged=true\n'
SH
  chmod +x "$fakebin/gh-axi"
  printf 'Drop this work.\n' > "$dir/words"
  for id in resumed-scout resumed-ship untouched-drop; do
    case "$id" in resumed-scout) kind=scout ;; *) kind=ship ;; esac
    wrapper_from_code "$dir" add --objective O7 "$id" "$(ftitle "$id")" --kind "$kind" >/dev/null || fail "could not create landed fixture"
    out=$(wrapper_from_code "$dir" "task" "done" "$id" --drop-file "$dir/words" 2>&1) \
      || fail "could not drop landed fixture: $out"
  done
  out=$(wrapper_from_code "$dir" task reopen resumed-scout 2>&1) \
    || fail "could not reopen scout: $out"
  out=$(wrapper_from_code "$dir" task start resumed-ship 2>&1) \
    || fail "could not restart ship: $out"
  json=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --home-input) || fail "resumed snapshot failed"
  printf '%s' "$json" | jq -e '
    (.backlog.records | any(.id == "resumed-scout" and .captain_drop == false))
    and (.backlog.records | any(.id == "resumed-ship" and .captain_drop == false))
    and (.backlog.records | any(.id == "untouched-drop" and .captain_drop == true))
  ' >/dev/null || fail "snapshot conflated resumed and untouched captain drops"
  printf '# Fresh findings\n' > "$dir/home/data/resumed-scout/report.md"
  out=$(wrapper_from_code "$dir" "task" "done" resumed-scout --report data/resumed-scout/report.md 2>&1) \
    || fail "resumed scout report was refused: $out"
  out=$(PATH="$fakebin:$PATH" wrapper_from_code "$dir" task close resumed-ship --pr https://github.com/o/r/pull/9 2>&1) \
    || fail "resumed merged ship was refused: $out"
  json=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-bearings-snapshot.sh" --json --all-landed) || fail "resumed bearings failed"
  printf '%s' "$json" | jq -e '
    (.landed | any(.id == "resumed-scout"))
    and (.landed | any(.id == "resumed-ship"))
    and (.landed | any(.id == "untouched-drop") | not)
  ' >/dev/null || fail "Recently Landed did not select resumed deliveries and exclude untouched drop"
  pass "real snapshot and landed projection distinguish resumed deliveries from untouched captain drops"
}

test_bounded_mutation_grammar_refuses_before_side_effects() {
  local dir fakebin real verb noun form token spelling out rc before
  local prefix=() args=()
  dir=$(make_split bounded-mutations)
  fakebin=$(fm_fakebin "$dir")
  real=$(command -v tasks-axi)
  wrapper_from_code "$dir" add --objective O7 bounded "$(ftitle bounded)" --kind scout >/dev/null || fail "could not add bounded row"
  wrapper_from_code "$dir" add --objective O7 decoy "$(ftitle decoy)" --kind docs >/dev/null || fail "could not add decoy row"
  wrapper_from_code "$dir" add --objective O7 ship-row "$(ftitle ship-row)" --kind ship >/dev/null || fail "could not add ship fixture"
  wrapper_from_code "$dir" add --objective O7 docs-row "$(ftitle docs-row)" --kind docs >/dev/null || fail "could not add docs fixture"
  wrapper_from_code "$dir" add --objective O7 retained-row "retained drop" --kind scout >/dev/null || fail "could not add retained fixture"
  printf 'dropped\n' > "$dir/body"
  wrapper_from_code "$dir" update bounded --body-file "$dir/body" >/dev/null || fail "could not set dropped provenance"
  printf 'Captain words stay private.\n' > "$dir/words"
  printf 'Replacement must never be retained.\n' > "$dir/replacement"
  wrapper_from_code "$dir" "done" retained-row --drop-file "$dir/words" >/dev/null || fail "could not retain original words"
  before=$(cat "$dir/home/data/backlog.md")
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
: > "$dir/sdk-called"
exec "$real" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
  for verb in "done" "close" start reopen; do
    for noun in bare task; do
      if [ "$noun" = task ]; then prefix=(task "$verb"); else prefix=("$verb"); fi
      for form in global-split global-equals unknown extra separator short-help help-equals missing-id consumed-pr consumed-note consumed-keep; do
        case "$form" in
          global-split) args=(--backend markdown bounded) ;;
          global-equals) args=(bounded --backend=markdown) ;;
          unknown) args=(bounded --mystery) ;;
          extra) args=(bounded decoy) ;;
          separator) args=(-- bounded) ;;
          short-help) args=(bounded -h) ;;
          help-equals) args=(bounded --help=true) ;;
          missing-id) args=() ;;
          consumed-pr)
            [ "$verb" = "done" ] || continue
            args=(--pr --backend=markdown https://github.com/o/r/pull/9 ship-row)
            ;;
          consumed-note)
            [ "$verb" = "done" ] || continue
            args=(--note --backend=markdown docs-row ship-row)
            ;;
          consumed-keep)
            [ "$verb" = "done" ] || continue
            args=(retained-row --drop-file "$dir/replacement" --keep --help)
            ;;
        esac
        rm -f "$dir/sdk-called"
        rc=0
        out=$(PATH="$fakebin:$PATH" wrapper_from_code "$dir" "${prefix[@]}" ${args[@]+"${args[@]}"} 2>&1) || rc=$?
        expect_code 2 "$rc" "$noun $verb $form"
        assert_contains "$out" "tasks-axi directly" "$noun $verb $form did not name the direct SDK escape"
        assert_absent "$dir/sdk-called" "$noun $verb $form reached the SDK"
        assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "$noun $verb $form changed row or provenance"
        assert_absent "$dir/home/data/bounded/captain-drop.md" "$noun $verb $form retained drop words"
        cmp -s "$dir/words" "$dir/home/data/retained-row/captain-drop.md" \
          || fail "$noun $verb $form replaced retained captain words"
        assert_absent "$dir/home/data/done-archive.md" "$noun $verb $form archived a row"
        assert_absent "$dir/home/state/.control-bounded.lock" "$noun $verb $form left control custody"
        assert_absent "$dir/home/state/.meta-bounded.lock" "$noun $verb $form left metadata custody"
      done
    done
  done
  for verb in "done" "close"; do
    for noun in bare task; do
      if [ "$noun" = task ]; then prefix=(task "$verb"); else prefix=("$verb"); fi
      for form in --note --pr --report --drop-file --keep; do
        for token in --help --backend=markdown --json; do
          for spelling in split equals; do
            if [ "$spelling" = split ]; then args=("$form" "$token"); else args=("$form=$token"); fi
            rm -f "$dir/sdk-called"
            rc=0
            out=$(PATH="$fakebin:$PATH" wrapper_from_code "$dir" "${prefix[@]}" bounded "${args[@]}" --drop-file "$dir/words" 2>&1) || rc=$?
            expect_code 2 "$rc" "$noun $verb $form $spelling $token"
            assert_absent "$dir/sdk-called" "consumed option value reached production help/global parsing"
            assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "consumed option value changed backlog"
            assert_absent "$dir/home/data/bounded/captain-drop.md" "consumed option value retained drop words"
          done
        done
        rm -f "$dir/sdk-called"
        rc=0
        out=$(PATH="$fakebin:$PATH" wrapper_from_code "$dir" "${prefix[@]}" bounded "$form" 2>&1) || rc=$?
        expect_code 2 "$rc" "$noun $verb missing $form value"
        assert_absent "$dir/sdk-called" "missing value reached the SDK"
      done
    done
  done
  pass "bounded completion and restart grammar refuses before SDK calls, drop retention, retirement, or archiving"
}

test_bounded_refusals_preserve_retained_words_with_ambient_backends() (
  local dir fakebin source verb noun form out rc before
  local prefix=() args=()
  dir=$(make_split bounded-retained-backends)
  fakebin=$(fm_fakebin "$dir")
  wrapper_from_code "$dir" add --objective O7 retained-row "retained drop" --kind scout >/dev/null || fail "could not add retained fixture"
  printf 'Original captain words café 航海.\n' > "$dir/words"
  wrapper_from_code "$dir" "done" retained-row --drop-file "$dir/words" >/dev/null || fail "could not retain original words"
  before=$(cat "$dir/home/data/backlog.md")
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
: > "$dir/sdk-called"
exit 99
SH
  chmod +x "$fakebin/tasks-axi"
  for source in default environment home-config; do
    unset TASKS_AXI_BACKEND
    case "$source" in
      environment) export TASKS_AXI_BACKEND=beads ;;
      home-config)
        printf 'backend = "beads"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n' \
          > "$dir/home/.tasks.toml"
        ;;
    esac
    for verb in "done" "close" start reopen; do
      for noun in bare task; do
        if [ "$noun" = task ]; then prefix=(task "$verb"); else prefix=("$verb"); fi
        for form in backend-split backend-equals; do
          case "$form" in
            backend-split) args=(retained-row --backend markdown) ;;
            backend-equals) args=(retained-row --backend=markdown) ;;
          esac
          rm -f "$dir/sdk-called"
          rc=0
          out=$(PATH="$fakebin:$PATH" wrapper_from_code "$dir" "${prefix[@]}" "${args[@]}" 2>&1) || rc=$?
          expect_code 2 "$rc" "$source $noun $verb $form"
          assert_contains "$out" "tasks-axi directly" "$source $noun $verb $form did not name the direct SDK escape"
          assert_absent "$dir/sdk-called" "$source $noun $verb $form invoked the SDK"
          assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "$source $noun $verb $form changed rows or provenance"
          cmp -s "$dir/words" "$dir/home/data/retained-row/captain-drop.md" \
            || fail "$source $noun $verb $form replaced retained captain words"
          assert_absent "$dir/home/data/done-archive.md" "$source $noun $verb $form archived a row"
          assert_absent "$dir/home/state/.control-retained-row.lock" "$source $noun $verb $form leaked control custody"
          assert_absent "$dir/home/state/.meta-retained-row.lock" "$source $noun $verb $form leaked metadata custody"
        done
      done
    done
  done
  pass "bounded backend refusals preserve rows and retained captain words under default, environment beads, and home beads configuration"
)

test_exact_mutation_help_has_no_side_effects() {
  local dir verb noun before out
  local prefix=()
  dir=$(make_split exact-help)
  wrapper_from_code "$dir" add --objective O7 help-row "help scout" --kind scout >/dev/null || fail "could not create help fixture"
  printf 'dropped\n' > "$dir/body"
  wrapper_from_code "$dir" update help-row --body-file "$dir/body" >/dev/null || fail "could not set help body"
  printf 'Do not retain these words for help.\n' > "$dir/words"
  before=$(cat "$dir/home/data/backlog.md")
  for verb in "done" "close" start reopen; do
    for noun in bare task; do
      if [ "$noun" = task ]; then prefix=(task "$verb"); else prefix=("$verb"); fi
      out=$(wrapper_from_code "$dir" "${prefix[@]}" --help 2>&1) || fail "$noun $verb help failed: $out"
      assert_contains "$out" "usage: tasks-axi" "$noun $verb did not print production help"
      if [ "$verb" = "done" ] || [ "$verb" = "close" ]; then
        out=$(wrapper_from_code "$dir" "${prefix[@]}" help-row --drop-file "$dir/words" --help 2>&1) || fail "drop help failed: $out"
      else
        out=$(wrapper_from_code "$dir" "${prefix[@]}" help-row --json --help 2>&1) || fail "restart help failed: $out"
      fi
      assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "$noun $verb help mutated provenance"
      assert_absent "$dir/home/data/help-row/captain-drop.md" "$noun $verb help retained drop words"
      assert_absent "$dir/home/data/done-archive.md" "$noun $verb help archived a row"
      assert_absent "$dir/home/state/.control-help-row.lock" "$noun $verb help took control custody"
    done
  done
  pass "only exact unconsumed help tokens reach production help without completion or restart side effects"
}

test_completion_keep_count_and_normal_options() {
  local dir id form out
  dir=$(make_split completion-keep)
  for form in split equals no-prune; do
    id="keep-$form"
    wrapper_from_code "$dir" add --objective O7 "$id" "$(ftitle "$id")" --kind docs >/dev/null || fail "could not add keep fixture"
    case "$form" in
      split) out=$(wrapper_from_code "$dir" "done" "$id" --keep 0 --note "Count zero" --json 2>&1) ;;
      equals) out=$(wrapper_from_code "$dir" "task" "close" "$id" --keep=0 --note="Count zero" --json 2>&1) ;;
      no-prune) out=$(wrapper_from_code "$dir" "close" "$id" --keep 0 --no-prune --note "Retain this row" --json 2>&1) ;;
    esac || fail "$form keep completion failed: $out"
    if [ "$form" = no-prune ]; then
      assert_grep "$id" "$dir/home/data/backlog.md" "--no-prune did not retain the completed row"
    else
      assert_not_contains "$(cat "$dir/home/data/backlog.md")" "$id" "--keep 0 did not prune the completed row"
      assert_grep "$id" "$dir/home/data/done-archive.md" "--keep 0 did not archive the completed row"
    fi
  done
  pass "documented numeric keep forms, no-prune, note, json, and optional noun preserve ordinary completion"
}

# Relative operational roots must retain their caller meaning after the wrapper
# changes into the backlog root. The nested home makes a mistaken second
# resolution name a distinct, enabled decoy home rather than the original one.
test_relative_home_and_overrides_keep_fleet_ledger() (
  local layout dir home decoy out rows
  for layout in home overrides; do
    dir="$TMP_ROOT/ledger-relative-$layout"
    home="$dir/homes/one"
    decoy="$dir/homes/homes/one"
    mkdir -p "$dir/project" "$home/data" "$home/state" "$home/config" \
      "$decoy/state" "$decoy/config"
    empty_backlog "$home/data/backlog.md"
    fm_test_tasks_toml "$home/.tasks.toml"
    : > "$home/config/fleet-ledger"
    : > "$decoy/config/fleet-ledger"
    printf 'Drop the completed addressing fixture.\n' > "$dir/words.txt"
    unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
    if [ "$layout" = home ]; then
      export FM_HOME=../homes/one
    else
      export FM_HOME="$home" FM_STATE_OVERRIDE=../homes/one/state \
        FM_CONFIG_OVERRIDE=../homes/one/config
    fi
    out=$(cd "$dir/project" && "$WRAPPER" add --objective O7 "relative-$layout" \
      'nested relative addressing' --kind ship --repo sample --priority 2 2>&1) \
      || fail "$layout relative add failed: $out"
    assert_grep "relative-$layout" "$home/data/backlog.md" "$layout add missed the home backlog"
    assert_present "$home/state/fleet-ledger.jsonl" "$layout add missed the original home ledger after changing cwd"
    rows=$(jq -c '[.event, .task, .repo, .kind, .priority]' "$home/state/fleet-ledger.jsonl")
    assert_equals "[\"task.filed\",\"relative-$layout\",\"sample\",\"ship\",2]" "$rows" \
      "$layout task.filed must reach the original home"
    out=$(cd "$dir/project" && "$WRAPPER" 'done' "relative-$layout" \
      --drop-file ../words.txt 2>&1) || fail "$layout relative close failed: $out"
    rows=$(jq -c 'select(.event == "task.closed") | [.task, .evidence]' "$home/state/fleet-ledger.jsonl")
    assert_equals "[\"relative-$layout\",\"drop_file\"]" "$rows" \
      "$layout task.closed must reach the original home"
    assert_absent "$decoy/state/fleet-ledger.jsonl" "$layout ledger leaked into the internally reinterpreted home"
    assert_absent "$dir/project/state" "$layout ledger leaked into the caller's project"
  done
  pass "nested relative FM_HOME and caller-relative state/config keep filed and closed records in the original home"
)

# The opt-in fleet ledger (docs/fleet-ledger.md): `add` appends one task.filed
# record for the item it created, and changes nothing else about the command.
test_add_records_task_filed_once() {
  local dir out rows plain_out plain_rc=0 on_rc=0 filed
  dir=$(make_split ledger-filed)
  : > "$dir/home/config/fleet-ledger"
  out=$(wrapper_from_code "$dir" add --objective O7 ship-a "a ship item" --kind ship --repo sample --priority 2 2>&1) \
    || fail "add with the ledger on failed: $out"
  rows=$(jq -c '[.event, .task, .repo, .kind, .priority] , (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")), (.ts | type)' \
    "$dir/home/state/fleet-ledger.jsonl")
  assert_equals "$(printf '%s\n' '["task.filed","ship-a","sample","ship",2]' true '"number"')" "$rows" "task.filed record"
  filed=$(jq -r '.ts | todate' "$dir/home/state/fleet-ledger.jsonl")
  assert_equals "$filed" "$(jq -r '.at' "$dir/home/state/fleet-ledger.jsonl")" "at must be the same instant as ts"

  # tasks-axi reports an add of an existing id as already present and exits 0;
  # nothing was filed, so nothing is recorded.
  # An add is never its own neighbour, so the repeat reaches tasks-axi unprompted.
  wrapper_from_code "$dir" add --objective O7 ship-a "a ship item" --kind ship >/dev/null 2>&1 || fail "repeat add failed"
  assert_equals 1 "$(wc -l < "$dir/home/state/fleet-ledger.jsonl" | tr -d ' ')" "records after a repeated add"

  # A minted id, --json output, and absent fields are read from what tasks-axi stored.
  wrapper_from_code "$dir" add --objective O7 "quick note" --mint --json >/dev/null 2>&1 || fail "minted add failed"
  rows=$(jq -c 'select(.task != "ship-a") | [.event, .repo, .kind, .priority, (.task | startswith("quick-note") or startswith("quick"))]' \
    "$dir/home/state/fleet-ledger.jsonl")
  assert_equals '["task.filed",null,null,null,true]' "$rows" "minted --json add"

  # The ledger changes neither the output nor the exit status of the command.
  plain_out=$(wrapper_from_code "$dir" add --objective O7 ship-b "identical entry text" --kind ship --repo sample 2>&1) || plain_rc=$?
  rm -f "$dir/home/config/fleet-ledger"
  empty_backlog "$dir/home/data/backlog.md"
  out=$(wrapper_from_code "$dir" add --objective O7 ship-b "identical entry text" --kind ship --repo sample 2>&1) || on_rc=$?
  assert_equals "$out" "$plain_out" "add output with the ledger on and off"
  assert_equals "$on_rc" "$plain_rc" "add exit status with the ledger on and off"
  pass "ledger on: add records one task.filed with the stored fields, a repeat add records none, and output and status are unchanged"
}

test_add_ledger_off_and_failing_ledger_leave_add_alone() {
  local dir out rc=0 stdout stderr
  dir=$(make_split ledger-filed-off)
  out=$(wrapper_from_code "$dir" add --objective O7 off-a "no ledger" --kind ship 2>&1) || fail "add with the flag absent failed: $out"
  assert_absent "$dir/home/state/fleet-ledger.jsonl" "the flag-off add wrote a ledger"

  : > "$dir/home/config/fleet-ledger"
  mkdir "$dir/home/state/fleet-ledger.jsonl"
  stdout=$(wrapper_from_code "$dir" add --objective O7 bad-a "unwritable sink" --kind ship 2>"$dir/stderr") || rc=$?
  stderr=$(cat "$dir/stderr")
  assert_equals 0 "$rc" "add exit status with an unwritable ledger"
  assert_contains "$stdout" "ok: added bad-a" "add stdout with an unwritable ledger"
  assert_equals "fm-fleet-ledger: could not record filed for bad-a; the ledger may be missing records" "$stderr" \
    "an unwritable ledger must cost exactly one stderr line"
  wrapper_from_code "$dir" show bad-a >/dev/null 2>&1 || fail "the item was not filed when the ledger failed"
  pass "ledger off writes nothing, and an unwritable ledger costs one stderr line without changing the add"
}

# The opt-in fleet ledger (docs/fleet-ledger.md): a `done` that passed the proof
# check and closed an open row appends one task.closed record naming its proof.
test_completion_records_task_closed_once_with_its_proof() {
  local dir fakebin words rows out rc=0 pr=https://github.com/o/r/pull/9
  dir=$(make_split ledger-closed)
  fakebin=$(fm_fakebin "$dir")
  words="$dir/words.txt"
  : > "$dir/home/config/fleet-ledger"
  for kind in "ship-a ship" "scout-a scout" "ship-d ship" "ship-e ship" "ship-f ship" "note-a docs"; do
    # shellcheck disable=SC2086
    set -- $kind
    wrapper_from_code "$dir" add --objective O7 "$1" "$(ftitle "$1")" --kind "$2" --repo p >/dev/null
  done
  rm -f "$dir/home/state/fleet-ledger.jsonl"
  mkdir -p "$dir/home/data/scout-a"
  printf '# findings\n' > "$dir/home/data/scout-a/report.md"
  printf 'Drop it; the premise is gone.\n' > "$words"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'api_response:\n  body: merged=true\n'
SH
  chmod +x "$fakebin/gh-axi"

  completion_refused "$dir" "bare done" "done" ship-e >/dev/null
  wrapper_from_code "$dir" task close scout-a --report data/scout-a/report.md >/dev/null 2>&1 || fail "the reported scout was refused"
  (cd "$dir/code" && PATH="$fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    "$WRAPPER" "done" ship-a --pr "$pr" >/dev/null 2>&1) || fail "a merged pull request was refused"
  wrapper_from_code "$dir" "done" ship-d --drop-file "$words" >/dev/null 2>&1 || fail "the captain's words were refused"
  wrapper_from_code "$dir" "done" note-a >/dev/null 2>&1 || fail "a non-delivery row was refused"
  rows=$(jq -c 'select(.event == "task.closed") | [.task, .evidence, .pr, (.at | test("Z$"))]' "$dir/home/state/fleet-ledger.jsonl")
  assert_equals "$(printf '%s\n' '["scout-a","report",null,true]' "[\"ship-a\",\"merged_pr\",\"$pr\",true]" '["ship-d","drop_file",null,true]')" \
    "$rows" "task.closed records for a proven report, merged PR, and captain's drop; a refusal and a plain row write none"

  # A row that is already Done records nothing, however it is closed again.
  (cd "$dir/code" && PATH="$fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    "$WRAPPER" "done" ship-a --pr "$pr" >/dev/null 2>&1) || true
  wrapper_from_code "$dir" "done" ship-a --drop-file "$words" >/dev/null 2>&1 || true
  assert_equals 3 "$(jq -c 'select(.event == "task.closed")' "$dir/home/state/fleet-ledger.jsonl" | wc -l | tr -d ' ')" \
    "task.closed records after closing a Done row again"

  # An unwritable ledger costs one stderr line and changes neither the close nor its output.
  rm -f "$dir/home/state/fleet-ledger.jsonl"
  mkdir "$dir/home/state/fleet-ledger.jsonl"
  out=$(wrapper_from_code "$dir" "done" ship-f --drop-file "$words" 2>"$dir/stderr") || rc=$?
  assert_equals 0 "$rc" "done exit status with an unwritable ledger"
  assert_contains "$out" "ship-f" "done stdout with an unwritable ledger"
  assert_equals "fm-fleet-ledger: could not record closed for ship-f; the ledger may be missing records" "$(cat "$dir/stderr")" \
    "an unwritable ledger must cost exactly one stderr line"
  [ "$(row_state "$dir" ship-f)" = x ] || fail "the row did not close when the ledger failed"
  pass "ledger on: a proven done records one task.closed, a refusal or a Done row records none, and a failing ledger leaves the close alone"
}

# Intake: every add names an objective and a near-duplicate title is refused
# with its neighbours; the two overrides are the only ways through.
refusal_of() {  # <case-dir> <label> <wrapper args...>; prints the output of a refused call
  completion_refused "$@"
}

# Titles of the worked pairs docs/configuration.md documents.
PAIR_BASE="Lock holder crash"
PAIR_ABOVE="Lock holder crash recovery"
PAIR_AT="Lock timeout"
PAIR_BELOW="Lock timeout retry loop"

# Done rows written straight into a backlog's Done section, newest first:
# done-1 is the newest and done-<count> the oldest. Rows <hit-a> and <hit-b>
# (positions) carry the title $4; every other row has a title of its own.
seed_done_rows() {  # <backlog> <count> <hit-title> <hit-position>...
  local backlog=$1 count=$2 hit=$3 i p hit_row rows=''
  shift 3
  for ((i = 1; i <= count; i++)); do
    hit_row=0
    for p in "$@"; do [ "$p" = "$i" ] && hit_row=1; done
    if [ "$hit_row" = 1 ]; then
      rows="$rows- [x] done-$i - $hit (done 2026-11-01)"$'\n'
    else
      rows="$rows- [x] done-$i - $(ftitle "done-$i") (done 2026-11-01)"$'\n'
    fi
  done
  printf '## In flight\n\n## Queued\n\n## Done\n%s' "$rows" > "$backlog"
}

# The ids a refusal lists, in the order it lists them.
listed_ids() {  # <refusal output>
  printf '%s\n' "$1" | grep -E '^  [A-Za-z0-9._-]+ \(' | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//'
}

test_add_requires_an_objective() {
  local dir out o fx
  dir=$(make_split intake-objective)
  out=$(refusal_of "$dir" "no objective" add obj-1 "Drain the wake queue before peeking")
  assert_contains "$out" "--objective" "the refusal did not print the flag"
  assert_contains "$out" "O1 O2 O3 O4 O5 O6 O7" "the refusal did not list the objectives from docs/objectives.md"
  assert_no_grep "obj-1" "$dir/home/data/backlog.md" "a refused add filed the item"
  out=$(refusal_of "$dir" "unknown objective" add obj-1 "Drain the wake queue before peeking" --objective O9)
  assert_contains "$out" "unknown objective 'O9'" "an unknown objective id was not named"
  out=$(refusal_of "$dir" "two objectives in one value" add obj-1 "Drain the wake queue before peeking" --objective "O1 O2")
  assert_contains "$out" "unknown objective 'O1 O2'" "two ids in one value were accepted"
  out=$(refusal_of "$dir" "none without a reason" add obj-1 "Drain the wake queue before peeking" --objective none)
  assert_contains "$out" "--objective-reason" "none without a reason did not print the reason flag"
  out=$(refusal_of "$dir" "none with a blank reason" add obj-1 "Drain the wake queue before peeking" --objective none --objective-reason "   ")
  assert_contains "$out" "--objective-reason" "a blank reason was accepted"
  out=$(refusal_of "$dir" "objective flag without a value" add obj-1 "Drain the wake queue before peeking" --objective)
  assert_contains "$out" "--objective requires a value" "a valueless objective was accepted"
  out=$(refusal_of "$dir" "create without an objective" create obj-1 "Drain the wake queue before peeking")
  assert_contains "$out" "--objective" "create skipped the objective check"
  out=$(refusal_of "$dir" "json without an objective" add obj-1 "Drain the wake queue before peeking" --json)
  assert_contains "$out" "--objective" "--json skipped the objective check"
  out=$(refusal_of "$dir" "json unknown objective" create obj-1 "Drain the wake queue before peeking" --json --objective O9)
  assert_contains "$out" "unknown objective 'O9'" "--json accepted an unknown objective"
  assert_absent "$dir/home/data/backlog-review.tsv" "refusals wrote the review record"
  # Every id docs/objectives.md lists is accepted, each with an exact row.
  : > "$dir/expected.tsv"
  for o in O1 O2 O3 O4 O5 O6 O7; do
    wrapper_from_code "$dir" add "obj-$o" "$(ftitle "obj-$o")" --objective "$o" >/dev/null \
      || fail "an add naming $o was refused"
    printf 'obj-%s\t\t%s\t\n' "$o" "$o" >> "$dir/expected.tsv"
  done
  wrapper_from_code "$dir" task add obj-none "$(ftitle obj-none)" --objective=none --objective-reason="nothing in O1 to O7 covers it" >/dev/null \
    || fail "none with a reason was refused"
  printf 'obj-none\t\tnone\tnothing in O1 to O7 covers it\n' >> "$dir/expected.tsv"
  assert_equals "$(cat "$dir/expected.tsv")" "$(cat "$dir/home/data/backlog-review.tsv")" \
    "the review record is not exactly id, empty review-by, objective, reason"
  out=$(refusal_of "$dir" "task noun create without an objective" task create obj-3 "Lavish answers route by hand")
  assert_contains "$out" "--objective" "the task create spelling skipped the objective check"
  # The ids come from the file: a copy of the tree whose docs/objectives.md adds O8 accepts it.
  fx="$dir/fixture-tree"
  mkdir -p "$fx/docs"
  cp -R "$ROOT/bin" "$fx/bin"
  cp "$ROOT/docs/objectives.md" "$fx/docs/objectives.md"
  printf -- '- O8 - Fixture: an objective only this tree lists.\n' >> "$fx/docs/objectives.md"
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$fx/bin/fm-tasks-axi.sh" add obj-8 "$(ftitle obj-8)" --objective O8 >/dev/null) \
    || fail "an objective added to docs/objectives.md was not accepted"
  assert_grep "$(printf 'obj-8\t\tO8\t')" "$dir/home/data/backlog-review.tsv" "the O8 row is missing"
  out=$(refusal_of "$dir" "O8 in the tracked file" add obj-9 "$(ftitle obj-9)" --objective O8)
  assert_contains "$out" "unknown objective 'O8'" "O8 was accepted without the fixture file"
  pass "fm-tasks-axi.sh refuses an add with no objective, an unknown id, or none without a reason, accepts each listed id with an exact row, and reads the ids from docs/objectives.md"
}

test_objective_rows_land_in_the_addressed_home() {
  local dir out minted before
  dir=$(make_split objective-homes)
  # A minted id is recorded as the stored id.
  out=$(wrapper_from_code "$dir" add "Reticulate the spline carefully" --mint --objective O3 2>&1) || fail "minted add failed: $out"
  minted=$(printf '%s\n' "$out" | sed -n 's/^  id: //p' | sed -n '1p')
  [ -n "$minted" ] || fail "the minted add did not report its id: $out"
  assert_equals "$(printf '%s\t\tO3\t' "$minted")" "$(cat "$dir/home/data/backlog-review.tsv")" "the minted id is not the recorded id"
  # Several adds after one pre-existing row keep every row.
  wrapper_from_code "$dir" add row-b "$(ftitle row-b)" --objective O1 >/dev/null || fail "add row-b failed"
  wrapper_from_code "$dir" add row-c "$(ftitle row-c)" --objective O2 >/dev/null || fail "add row-c failed"
  assert_equals "$(printf '%s\t\tO3\t\nrow-b\t\tO1\t\nrow-c\t\tO2\t' "$minted")" "$(cat "$dir/home/data/backlog-review.tsv")" \
    "an add lost or rewrote an earlier row"
  # An overriding data root records in that root; the decoy home and the code root stay untouched.
  mkdir -p "$dir/alt/data"
  empty_backlog "$dir/alt/data/backlog.md"
  (cd "$dir/code" && FM_DATA_OVERRIDE="$dir/alt/data" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" add alt-1 "$(ftitle alt-1)" --objective O5 >/dev/null) \
    || fail "an add through an overriding data root failed"
  assert_equals "$(printf 'alt-1\t\tO5\t')" "$(cat "$dir/alt/data/backlog-review.tsv")" "the override root missed its row"
  assert_no_grep "alt-1" "$dir/home/data/backlog-review.tsv" "the decoy home received the override root's row"
  assert_absent "$dir/code/data/backlog-review.tsv" "the code root received a row"
  # A sidecar that cannot take a row stops the add before it files anything.
  rm -f "$dir/home/data/backlog-review.tsv"
  mkdir "$dir/home/data/backlog-review.tsv"
  before=$(cat "$dir/home/data/backlog.md")
  out=$(refusal_of "$dir" "unwritable sidecar" add row-d "$(ftitle row-d)" --objective O1)
  assert_contains "$out" "cannot record the objective" "an unwritable sidecar was not reported"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "an add filed an item it could not record"
  rmdir "$dir/home/data/backlog-review.tsv"
  pass "an objective row is written for the stored id in the addressed data directory, keeps earlier rows, and a sidecar that cannot take it stops the add"
}

test_failed_row_write_removes_the_filed_item() {
  local dir fakebin real out rc=0
  dir=$(make_split objective-rollback)
  fakebin=$(fm_fakebin "$dir")
  real=$(command -v tasks-axi)
  # The sidecar turns unwritable between the readiness check and the write.
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
"$real" "\$@"
rc=\$?
if [ "\${1:-}" = add ]; then rm -f "$dir/home/data/backlog-review.tsv"; mkdir "$dir/home/data/backlog-review.tsv"; fi
exit \$rc
SH
  chmod +x "$fakebin/tasks-axi"
  out=$(PATH="$fakebin:$PATH" wrapper_from_code "$dir" add late-1 "$(ftitle late-1)" --objective O1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an add whose row could not be written reported success: $out"
  assert_contains "$out" "so the item was removed again" "the rollback was not reported"
  assert_no_grep "late-1" "$dir/home/data/backlog.md" "an item stayed filed without its row"
  rmdir "$dir/home/data/backlog-review.tsv"
  pass "an item whose objective row cannot be written is removed again and the add fails"
}

# A home without jq (a stub that always fails stands in for it) must still record
# the objective of an item a --json add files.
test_json_add_records_its_objective_without_jq() {
  local dir fakebin out
  dir=$(make_split objective-no-jq)
  fakebin=$(fm_fakebin "$dir")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/jq"
  chmod +x "$fakebin/jq"
  out=$(PATH="$fakebin:$PATH" wrapper_from_code "$dir" add json-row "$(ftitle json-row)" --objective O2 --json 2>&1) \
    || fail "a --json add without jq failed: $out"
  assert_contains "$out" '"ok": true' "the --json add did not report success"
  assert_grep "json-row" "$dir/home/data/backlog.md" "the --json add did not file the item"
  assert_equals "$(printf 'json-row\t\tO2\t')" "$(cat "$dir/home/data/backlog-review.tsv")" \
    "a --json add without jq filed an item with no objective row"
  pass "a --json add on a home without jq still records the objective row"
}

# A fake non-Markdown adapter: tasks-axi answers from files under .stubdata when
# the working directory's .tasks.toml names the beads backend, and is the real
# tasks-axi anywhere else.
make_adapter_stub() {  # <fakebin>
  local real
  real=$(command -v tasks-axi)
  cat > "$1/tasks-axi" <<SH
#!/usr/bin/env bash
if grep -q 'backend = "beads"' .tasks.toml 2>/dev/null; then
  d=.stubdata
  printf '%s\n' "\$*" >> "\$d/calls"
  case "\${1:-}" in
    --version) echo 0.2.6 ;;
    update) [ "\${2:-}" = --help ] && echo --archive-body ;;
    mv) [ "\${2:-}" = --help ] && echo 'usage: tasks-axi mv <id>...' ;;
    list) cat "\$d/list" ;;
    show) if [ -f "\$d/show-\$2" ]; then cat "\$d/show-\$2"; else echo 'code: NOT_FOUND'; exit 1; fi ;;
    add) printf 'ok: added %s -> Queued\ntask:\n  id: %s\n  kind: task\n' "\$2" "\$2" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exec "$real" "\$@"
SH
  chmod +x "$1/tasks-axi"
}

# Give <home> a beads backlog whose list holds one open item and whose stale
# Markdown file says something else.
make_adapter_home() {  # <home> <open-id> <open-title>
  mkdir -p "$1/.stubdata"
  printf 'backend = "beads"\n\n[beads]\npath = ".beads"\n' > "$1/.tasks.toml"
  printf 'count: 1\ntasks[1]{id,state,kind,repo,title}:\n  %s,queued,task,"-",%s\n' "$2" "$3" > "$1/.stubdata/list"
  printf 'task:\n  id: %s\n  title: %s\n  state: queued\n  held: no\n  blocked: no\n  kind: task\n' "$2" "$3" > "$1/.stubdata/show-$2"
}

test_add_judges_near_duplicate_titles() {
  local dir out sp before fakebin ids
  dir=$(make_split intake-dup)
  wrapper_from_code "$dir" add dup-base "$PAIR_BASE" --objective O7 >/dev/null || fail "could not file the base item"
  before=$(cat "$dir/home/data/backlog.md")
  # The three documented worked pairs: above, exactly at, and below 0.25.
  out=$(refusal_of "$dir" "pair above" add dup-above "$PAIR_ABOVE" --objective O7)
  assert_contains "$out" "dup-base (Queued, overlap 0.75) $PAIR_BASE" "the above pair is not listed with 0.75"
  out=$(refusal_of "$dir" "pair at" add dup-at "$PAIR_AT" --objective O7)
  assert_contains "$out" "dup-base (Queued, overlap 0.25) $PAIR_BASE" "the pair at the threshold is not refused with 0.25"
  out=$(wrapper_from_code "$dir" add dup-below "$PAIR_BELOW" --objective O7 2>&1) || fail "the pair below the threshold was refused: $out"
  assert_not_contains "$out" "overlap" "the pair below the threshold saw a neighbour list"
  assert_no_grep "dup-above" "$dir/home/data/backlog.md" "a refused add filed the item"
  assert_no_grep "dup-at" "$dir/home/data/backlog.md" "a refused add filed the item"
  # Every supported spelling refuses a duplicate and a missing objective, and files nothing.
  before=$(cat "$dir/home/data/backlog.md")
  for sp in "add dup-sp POSITIONAL" "create dup-sp POSITIONAL" "task add dup-sp POSITIONAL" "task create dup-sp POSITIONAL" \
            "add dup-sp --title TITLE" "add POSITIONAL --mint" "create POSITIONAL --mint"; do
    # shellcheck disable=SC2086  # the spelling is a word list on purpose
    set -- $sp
    local args=() w
    for w in "$@"; do
      case "$w" in
        POSITIONAL) args+=("$PAIR_ABOVE") ;;
        TITLE) args+=("$PAIR_ABOVE") ;;
        *) args+=("$w") ;;
      esac
    done
    out=$(refusal_of "$dir" "duplicate via $sp" "${args[@]}" --objective O7)
    assert_contains "$out" "dup-base (Queued, overlap 0.75)" "$sp did not list the neighbour"
    out=$(refusal_of "$dir" "no objective via $sp" "${args[@]}")
    assert_contains "$out" "--objective" "$sp skipped the objective check"
    out=$(refusal_of "$dir" "json duplicate via $sp" "${args[@]}" --objective O7 --json)
    assert_contains "$out" "dup-base (Queued" "$sp with --json did not list the neighbour"
    assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "$sp changed the backlog"
  done
  # An unrelated title files on the first try with no neighbour output.
  out=$(wrapper_from_code "$dir" add dup-u "Reticulate splines nightly" --objective O7 2>&1) || fail "an unrelated title was refused: $out"
  assert_not_contains "$out" "overlap" "an unrelated title saw a neighbour list"
  # Help prints help and files nothing.
  before=$(cat "$dir/home/data/backlog.md")
  for sp in "add" "create" "task add"; do
    # shellcheck disable=SC2086
    out=$(wrapper_from_code "$dir" $sp --help 2>&1) || fail "$sp --help failed: $out"
    assert_contains "$out" "usage: tasks-axi" "$sp --help did not print help"
  done
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "help changed the backlog"
  # A repeat of an existing id is never its own neighbour; tasks-axi answers it and nothing changes.
  out=$(wrapper_from_code "$dir" add dup-base "$PAIR_BASE" --objective O7 2>&1) || fail "a repeated id was refused: $out"
  assert_not_contains "$out" "overlap" "a repeated id was listed as its own neighbour"
  assert_contains "$out" "already" "the repeat did not reach tasks-axi"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a repeated id changed the backlog"
  # Overlap order and the top three: four open qualifying items and an archived Done one.
  dir=$(make_split intake-order)
  wrapper_from_code "$dir" add ord-o4 "alpha bravo" --objective O7 >/dev/null
  wrapper_from_code "$dir" add ord-o3 "alpha bravo charlie" --objective O7 --not-dup ord-o4 >/dev/null
  wrapper_from_code "$dir" add ord-o2 "alpha bravo charlie delta" --objective O7 --not-dup ord-o3 >/dev/null
  wrapper_from_code "$dir" add ord-o1 "alpha bravo charlie delta echo" --objective O7 --not-dup ord-o2 >/dev/null
  wrapper_from_code "$dir" add ord-d1 "alpha bravo charlie delta echo foxtrot" --objective O7 --not-dup ord-o1 >/dev/null
  wrapper_from_code "$dir" "done" ord-d1 >/dev/null || fail "could not close the Done neighbour"
  wrapper_from_code "$dir" prune --keep 0 >/dev/null || fail "could not archive the Done neighbour"
  assert_grep "ord-d1" "$dir/home/data/done-archive.md" "the Done neighbour was not archived"
  before=$(cat "$dir/home/data/backlog.md")
  for sp in add create; do
    out=$(refusal_of "$dir" "ordering via $sp" "$sp" ord-new "alpha bravo charlie delta echo" --objective O7)
    ids=$(listed_ids "$out")
    assert_equals "ord-o1 ord-d1 ord-o2" "$ids" "$sp did not list the three best neighbours best first"
    assert_contains "$out" "ord-d1 (Done, archived, overlap 0.83) alpha bravo charlie delta echo foxtrot" "the archived Done neighbour is not listed with its state and title"
    assert_contains "$out" "--dup-of ord-o1" "the --dup-of override is not printed"
    assert_contains "$out" "--not-dup ord-o1" "the --not-dup override is not printed"
    assert_contains "$out" "$sp ord-new" "the override is not a full command"
    assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "$sp changed the backlog"
  done
  # A fourth qualifying item is never listed but --not-dup may still name it.
  wrapper_from_code "$dir" add ord-new "alpha bravo charlie delta echo" --objective O7 --not-dup ord-o4 >/dev/null \
    || fail "--not-dup naming a neighbour outside the top three was refused"
  assert_equals "$(printf 'ord-new\t\tO7\t')" "$(grep '^ord-new	' "$dir/home/data/backlog-review.tsv")" "the --not-dup item's row is not the plain objective row"
  # In flight is a state a neighbour may have.
  dir=$(make_split intake-inflight)
  wrapper_from_code "$dir" add fly-1 "Rotate pager schedule weekly" --objective O7 >/dev/null
  wrapper_from_code "$dir" start fly-1 >/dev/null || fail "could not start the item"
  out=$(refusal_of "$dir" "in flight neighbour" add fly-2 "Rotate pager schedule monthly" --objective O7)
  assert_contains "$out" "fly-1 (In flight, overlap" "an In flight item was not listed with its state"
  # Search follows the addressed backlog: an overriding data root and a decoy code-root file.
  dir=$(make_split intake-addressed)
  wrapper_from_code "$dir" add home-hit "Zulu yankee xray whiskey" --objective O7 >/dev/null
  mkdir -p "$dir/alt/data"
  empty_backlog "$dir/alt/data/backlog.md"
  (cd "$dir/code" && FM_DATA_OVERRIDE="$dir/alt/data" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" add alt-hit "Zulu yankee xray victor" --objective O7 >/dev/null) \
    || fail "could not file the override root's item"
  out=$(cd "$dir/code" && FM_DATA_OVERRIDE="$dir/alt/data" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" add new-1 "Zulu yankee xray victor tango" --objective O7 2>&1) && fail "the override root's duplicate was filed"
  assert_contains "$out" "alt-hit (Queued" "the override root's neighbour was not listed"
  assert_not_contains "$out" "home-hit" "the decoy home's item was listed for the override root"
  rm -f "$dir/code/data/backlog.md"
  printf '## In flight\n\n## Queued\n- [ ] decoy-hit - Zulu yankee xray whiskey tango (since 2026-11-01)\n\n## Done\n' > "$dir/code/data/backlog.md"
  out=$(refusal_of "$dir" "split home" add new-2 "Zulu yankee xray whiskey tango" --objective O7)
  assert_contains "$out" "home-hit (Queued" "the home's own neighbour was not listed"
  assert_not_contains "$out" "decoy-hit" "the code root's decoy was listed"
  # A non-Markdown adapter is read through tasks-axi, whatever a stale Markdown file says.
  dir=$(make_split intake-adapter)
  fakebin=$(fm_fakebin "$dir")
  make_adapter_stub "$fakebin"
  make_adapter_home "$dir/home" ad-open "$PAIR_BASE"
  printf '## In flight\n\n## Queued\n- [ ] ad-decoy - Quartz walnut pigeon (since 2026-11-01)\n\n## Done\n' > "$dir/home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" completion_refused "$dir" "adapter duplicate" add ad-new "$PAIR_ABOVE" --objective O7)
  assert_contains "$out" "ad-open (Queued, overlap 0.75) $PAIR_BASE" "the adapter's item was not listed"
  out=$(PATH="$fakebin:$PATH" wrapper_from_code "$dir" add ad-new "Quartz walnut pigeon feeders" --objective O7 2>&1) \
    || fail "a title matching only the stale Markdown decoy was refused through the adapter: $out"
  assert_grep "add ad-new" "$dir/home/.stubdata/calls" "the adapter did not receive the add"
  pass "fm-tasks-axi.sh refuses near-duplicate titles with the three best neighbours and both overrides, in every spelling, over the addressed backlog and a non-Markdown adapter"
}

test_duplicate_check_boundaries_and_unreadable_sources() {
  local dir out before fakebin
  # The 50 newest Done items reach past the rows tasks-axi keeps: a real multi-row prune archives 41 of 51.
  dir=$(make_split intake-window-a)
  seed_done_rows "$dir/home/data/backlog.md" 51 "Pager rotation handoff gap" 50 51
  wrapper_from_code "$dir" prune --keep 10 >/dev/null || fail "could not prune the Done rows"
  assert_grep "done-50 " "$dir/home/data/done-archive.md" "the 50th newest Done row was not archived"
  assert_grep "done-51 " "$dir/home/data/done-archive.md" "the 51st newest Done row was not archived"
  before=$(cat "$dir/home/data/backlog.md")
  out=$(refusal_of "$dir" "50th and 51st Done" add win-new "Pager rotation handoff gap review" --objective O7)
  assert_equals "done-50" "$(listed_ids "$out")" "the 50th newest Done item was not listed alone, or the 51st was"
  assert_contains "$out" "done-50 (Done, archived, overlap 0.80)" "the archived 50th Done item is not listed with its state"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused add changed the backlog"
  # Only the 51st newest matches: filed with no neighbour output.
  dir=$(make_split intake-window-b)
  seed_done_rows "$dir/home/data/backlog.md" 51 "Pager rotation handoff gap" 51
  wrapper_from_code "$dir" prune --keep 10 >/dev/null || fail "could not prune the Done rows"
  out=$(wrapper_from_code "$dir" add win-new "Pager rotation handoff gap review" --objective O7 2>&1) \
    || fail "a title matching only the 51st newest Done item was refused: $out"
  assert_not_contains "$out" "overlap" "the 51st newest Done item was listed"
  # Only the 50th newest matches, and it is archived: refused and listed.
  dir=$(make_split intake-window-c)
  seed_done_rows "$dir/home/data/backlog.md" 51 "Pager rotation handoff gap" 50
  wrapper_from_code "$dir" prune --keep 10 >/dev/null || fail "could not prune the Done rows"
  out=$(refusal_of "$dir" "archived only" create win-new "Pager rotation handoff gap review" --objective O7)
  assert_equals "done-50" "$(listed_ids "$out")" "an archived Done neighbour was not the only listing"
  # A source that cannot be read or interpreted stops the add: nothing filed, nothing recorded.
  dir=$(make_split intake-unreadable)
  wrapper_from_code "$dir" add un-base "$PAIR_BASE" --objective O7 >/dev/null
  before=$(cat "$dir/home/data/backlog.md")
  rm -f "$dir/home/data/backlog-review.tsv"
  mkdir "$dir/home/data/done-archive.md"
  out=$(refusal_of "$dir" "unreadable archive" add un-new "Reticulate splines nightly" --objective O7)
  assert_contains "$out" "could not read the backlog or its done archive" "an unreadable archive was not reported"
  rmdir "$dir/home/data/done-archive.md"
  printf '\n## Archived 2026-11-01\n- [x] broken\n' > "$dir/home/data/done-archive.md"
  out=$(refusal_of "$dir" "uninterpretable archive" add un-new "Reticulate splines nightly" --objective O7)
  assert_contains "$out" "could not read the backlog or its done archive" "an uninterpretable archive was not reported"
  rm -f "$dir/home/data/done-archive.md"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = list ]; then echo 'error: backlog is unreadable' >&2; exit 1; fi
exec "$(command -v tasks-axi)" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
  out=$(PATH="$fakebin:$PATH" completion_refused "$dir" "unreadable list" add un-new "Reticulate splines nightly" --objective O7)
  assert_contains "$out" "cannot read the backlog" "an unreadable list was not reported"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a failed read changed the backlog"
  assert_absent "$dir/home/data/backlog-review.tsv" "a failed read recorded a row"
  pass "the duplicate check counts the 50 newest Done items across a multi-row prune and stops when a source cannot be read"
}


# A tasks-axi stand-in that lets the first full read of <id> finish, then changes
# the body of <id> the way another writer would, before the wrapper writes.
make_interleaving_stub() {  # <fakebin> <id> <flag-file>
  local real
  real=$(command -v tasks-axi)
  cat > "$1/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ "\${2:-}" = "$2" ] && [ "\${3:-}" = --full ] && [ ! -e "$3" ]; then
  "$real" "\$@"
  rc=\$?
  : > "$3"
  "$real" update "$2" --body "OTHER-WRITER-TEXT" "\${@: -2}" >/dev/null 2>&1
  exit \$rc
fi
exec "$real" "\$@"
SH
  chmod +x "$1/tasks-axi"
}

test_dup_of_and_not_dup_do_what_the_refusal_says() {
  local dir out fakebin
  dir=$(make_split override-dup)
  wrapper_from_code "$dir" add ov-kept "Teardown retire slot manifest" --objective O7 --body OLD-BODY-MARKER >/dev/null || fail "could not file the kept item"
  wrapper_from_code "$dir" add ov-done "Teardown retire slot manifest proof" --objective O7 --not-dup ov-kept >/dev/null
  wrapper_from_code "$dir" "done" ov-done >/dev/null || fail "could not close the retained Done item"
  # --dup-of: the kept item keeps its text and gains the new title and body; nothing is filed.
  printf 'FILE-BODY-LINE\n' > "$dir/new-body.md"
  mkdir -p "$dir/elsewhere"
  out=$(cd "$dir/elsewhere" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" add ov-new "Teardown retire slot manifest again" \
    --objective O7 --dup-of ov-kept --body-file ../new-body.md 2>&1) || fail "--dup-of with a caller-relative body file failed: $out"
  assert_contains "$out" "merged into ov-kept" "--dup-of did not report the merge"
  assert_no_grep "ov-new" "$dir/home/data/backlog.md" "--dup-of filed the item"
  assert_grep "OLD-BODY-MARKER" "$dir/home/data/backlog.md" "--dup-of lost the kept item's text"
  assert_grep "Merged from a duplicate filing: Teardown retire slot manifest again" "$dir/home/data/backlog.md" "--dup-of did not append the new title"
  assert_grep "FILE-BODY-LINE" "$dir/home/data/backlog.md" "--dup-of did not append the new body file"
  assert_grep "OLD-BODY-MARKER" "$dir/home/data/note-archive.md" "--dup-of did not archive the previous body"
  assert_no_grep "ov-new" "$dir/home/data/backlog-review.tsv" "--dup-of wrote a review row for an item it did not file"
  # --dup-of a qualifying Done item still in the active backlog works like an open one.
  wrapper_from_code "$dir" add ov-new "Teardown retire slot manifest proof again" --objective O7 --dup-of ov-done --body DONE-KEPT-BODY >/dev/null 2>&1 \
    || fail "--dup-of a retained Done item failed"
  assert_grep "DONE-KEPT-BODY" "$dir/home/data/backlog.md" "the retained Done item did not take the appended body"
  # Missing ids, an archived-only Done id, and a missing objective stop it.
  out=$(refusal_of "$dir" "dup-of a missing id" add ov-new "Teardown retire slot manifest again" --objective O7 --dup-of ov-nope)
  assert_contains "$out" "does not exist" "a missing kept id was accepted"
  out=$(refusal_of "$dir" "dup-of without an objective" add ov-new "Teardown retire slot manifest again" --dup-of ov-kept)
  assert_contains "$out" "--objective" "--dup-of skipped the objective"
  out=$(refusal_of "$dir" "not-dup without an objective" add ov-new "Teardown retire slot manifest again" --not-dup ov-kept)
  assert_contains "$out" "--objective" "--not-dup skipped the objective"
  before=$(cat "$dir/home/data/backlog.md")
  out=$(refusal_of "$dir" "dup-of its own id" add ov-kept "Teardown retire slot manifest" --objective O7 --dup-of ov-kept)
  assert_contains "$out" "duplicate of itself" "--dup-of its own id was accepted"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "--dup-of its own id changed the backlog"
  out=$(refusal_of "$dir" "both overrides" add ov-new "Teardown retire slot manifest again" --objective O7 --dup-of ov-kept --not-dup ov-kept)
  assert_contains "$out" "not both" "both overrides were accepted"
  wrapper_from_code "$dir" prune --keep 0 >/dev/null || fail "could not archive the Done item"
  assert_no_grep "ov-done" "$dir/home/data/backlog.md" "the Done item stayed in the active backlog"
  out=$(refusal_of "$dir" "dup-of an archived id" add ov-new "Teardown retire slot manifest proof again" --objective O7 --dup-of ov-done)
  assert_contains "$out" "Done and archived" "an archived kept item was not reported"
  assert_contains "$out" "--not-dup ov-done" "the archived refusal did not point at --not-dup"
  assert_no_grep "ov-new" "$dir/home/data/backlog.md" "a refused --dup-of filed the item"
  # --not-dup: any qualifying neighbour, listed or not, files the item once.
  wrapper_from_code "$dir" add ov-n1 "Teardown retire slot manifest later" --objective O7 --not-dup ov-kept >/dev/null || fail "--not-dup naming a listed neighbour failed"
  wrapper_from_code "$dir" add ov-n2 "Teardown retire slot manifest sooner" --objective O7 --not-dup ov-kept >/dev/null || fail "--not-dup naming another neighbour failed"
  wrapper_from_code "$dir" add ov-n3 "Teardown retire slot manifest never" --objective O7 --not-dup ov-kept >/dev/null || fail "the third --not-dup add failed"
  out=$(refusal_of "$dir" "four neighbours" add ov-n4 "Teardown retire slot manifest" --objective O7)
  [ "$(listed_ids "$out" | wc -w | tr -d ' ')" = 3 ] || fail "the refusal did not list exactly three neighbours: $out"
  wrapper_from_code "$dir" add ov-n4 "Teardown retire slot manifest" --objective O7 --not-dup ov-done >/dev/null \
    || fail "--not-dup naming an archived qualifying neighbour failed"
  [ "$(grep -c '^ov-n4	' "$dir/home/data/backlog-review.tsv")" = 1 ] || fail "ov-n4 was not recorded exactly once"
  assert_equals "$(printf 'ov-n4\t\tO7\t')" "$(grep '^ov-n4	' "$dir/home/data/backlog-review.tsv")" "the --not-dup item's row is not the plain objective row"
  out=$(refusal_of "$dir" "not-dup naming a missing id" add ov-n5 "Teardown retire slot manifest" --objective O7 --not-dup ov-nope)
  assert_contains "$out" "names no item" "a missing --not-dup id was accepted"
  wrapper_from_code "$dir" add ov-far "Reticulate splines nightly" --objective O7 >/dev/null
  out=$(refusal_of "$dir" "not-dup naming a stranger" add ov-n5 "Teardown retire slot manifest" --objective O7 --not-dup ov-far)
  assert_contains "$out" "does not overlap this one enough" "a non-qualifying --not-dup id was accepted"
  assert_no_grep "ov-n5" "$dir/home/data/backlog.md" "a refused --not-dup filed the item"
  # Another writer changes the kept item between the wrapper's read and its append.
  dir=$(make_split override-race)
  fakebin=$(fm_fakebin "$dir")
  wrapper_from_code "$dir" add rc-kept "Teardown retire slot manifest" --objective O7 --body FIRST-BODY >/dev/null
  make_interleaving_stub "$fakebin" rc-kept "$dir/raced"
  out=$(PATH="$fakebin:$PATH" wrapper_from_code "$dir" add rc-new "Teardown retire slot manifest again" --objective O7 --dup-of rc-kept --body NEW-BODY 2>&1) \
    || fail "--dup-of beside another writer failed: $out"
  assert_present "$dir/raced" "the other writer never ran"
  assert_grep "OTHER-WRITER-TEXT" "$dir/home/data/backlog.md" "the append overwrote another writer's update"
  assert_grep "NEW-BODY" "$dir/home/data/backlog.md" "the append was lost beside another writer"
  pass "--dup-of appends to an open or retained Done item and --not-dup files past a qualifying neighbour, and neither runs without an objective or beside a lost update"
}

test_dup_of_repeat_needs_the_whole_block() {
  local dir out
  dir=$(make_split dup-repeat)
  wrapper_from_code "$dir" add dr-kept "Normalize the archive header spacing" --objective O7 --kind docs >/dev/null
  wrapper_from_code "$dir" add dr-a "Rotate the stale mirror credentials" --objective O7 --dup-of dr-kept --body $'FIRST-LINE\n  SECOND-LINE\n' >/dev/null || fail "the first merge failed"
  # The same title and body again is an interrupted run's repeat, and adds nothing.
  wrapper_from_code "$dir" add dr-a "Rotate the stale mirror credentials" --objective O7 --dup-of dr-kept --body $'FIRST-LINE\n  SECOND-LINE\n' >/dev/null || fail "the repeat failed"
  assert_equals 1 "$(grep -o 'SECOND-LINE' "$dir/home/data/backlog.md" | wc -l | tr -d ' ')" "a repeat appended the block again"
  # The same title with a different body is a second merge.
  out=$(wrapper_from_code "$dir" add dr-b "Rotate the stale mirror credentials" --objective O7 --dup-of dr-kept --body OTHER-EVIDENCE 2>&1) || fail "the second merge failed: $out"
  assert_contains "$out" "merged into dr-kept" "the second merge did not report the merge"
  assert_grep "OTHER-EVIDENCE" "$dir/home/data/backlog.md" "a second merge with a different body lost its body"
  # A title that is a prefix of an earlier one is its own merge, with or without a body.
  wrapper_from_code "$dir" add dr-c "Rotate the stale mirror" --objective O7 --dup-of dr-kept --body PREFIX-EVIDENCE >/dev/null || fail "the prefix merge failed"
  assert_grep "PREFIX-EVIDENCE" "$dir/home/data/backlog.md" "a prefix title lost its body"
  wrapper_from_code "$dir" add dr-d "Rotate the stale" --objective O7 --dup-of dr-kept >/dev/null || fail "the bodyless prefix merge failed"
  assert_equals "Merged from a duplicate filing: Rotate the stale" \
    "$(FM_HOME="$dir/home" python3 "$ROOT/bin/fm-backlog-intake.py" field body < <(wrapper_from_code "$dir" show dr-kept --full) | grep -x 'Merged from a duplicate filing: Rotate the stale')" \
    "a bodyless prefix title was not appended as its own line"
  pass "--dup-of counts a repeat only when the whole block is already there, so a second body or a prefix title is never lost"
}

test_archived_blocked_by_rows_keep_their_title_score() {
  local dir out
  dir=$(make_split archive-blocked-by)
  printf '\n## Archived 2026-11-01\n- [x] ab-one - Retire widget cache blocked-by: some-long-blocker blocked-by: other-blocker data/ab-one/report.md (repo: p) (kind: scout) (done 2026-10-30)\n' \
    > "$dir/home/data/done-archive.md"
  out=$(refusal_of "$dir" "archived neighbour" add ab-new "Widget cache eviction policy review" --objective O7)
  assert_contains "$out" "ab-one (Done, archived, overlap 0.33) Retire widget cache" "an archived row's blocked-by tail was scored as title words"
  pass "an archived row's unparenthesized blocked-by tail is not scored as title words"
}

test_archived_merged_row_keeps_its_title_score() {
  local dir out fakebin
  dir=$(make_split archive-merged)
  fakebin=$(fm_fakebin "$dir/fakebin")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'api_response:\n  body: merged=true\n'
SH
  chmod +x "$fakebin/gh-axi"
  wrapper_from_code "$dir" add am-one "$PAIR_BASE" --objective O7 --kind ship --repo p --priority 2 >/dev/null || fail "could not file the merged row"
  out=$(cd "$dir/code" && PATH="$fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" \
    "$WRAPPER" "done" am-one --pr https://github.com/o/r/pull/9 --keep 0 2>&1) || fail "could not close and prune the merged row: $out"
  assert_no_grep "am-one" "$dir/home/data/backlog.md" "the merged row was not pruned"
  assert_grep "(merged " "$dir/home/data/done-archive.md" "the archived row has no merged tail, so this fixture proves nothing"
  assert_grep "(priority: 2)" "$dir/home/data/done-archive.md" "the archived row has no priority tail, so this fixture proves nothing"
  out=$(refusal_of "$dir" "documented pair above the threshold" add am-new "$PAIR_ABOVE" --objective O7)
  assert_contains "$out" "am-one (Done, archived, overlap 0.75) $PAIR_BASE" "a merged archived row was not scored on its title"
  out=$(refusal_of "$dir" "documented pair at the threshold" add am-new "$PAIR_AT" --objective O7)
  assert_contains "$out" "am-one (Done, archived, overlap 0.25) $PAIR_BASE" "a merged archived row missed the threshold"
  wrapper_from_code "$dir" add am-held "Quartz harbor signal" --objective O7 --kind docs --priority 1 >/dev/null || fail "could not file the held row"
  wrapper_from_code "$dir" hold am-held --reason "a vendor reply" --until 2026-12-01 --kind external >/dev/null || fail "could not hold the row"
  wrapper_from_code "$dir" "done" am-held --keep 0 >/dev/null || fail "could not close and prune the held row"
  assert_grep "(hold-until: 2026-12-01)" "$dir/home/data/done-archive.md" "the archived row has no dated hold tail, so this fixture proves nothing"
  out=$(refusal_of "$dir" "held tails" add am-held-new "Quartz harbor signal mast" --objective O7)
  assert_contains "$out" "am-held (Done, archived, overlap 0.75) Quartz harbor signal" "an archived row's hold tails were scored as title words"
  printf '\n## Archived 2026-11-02\n- [x] am-spelled - Cobalt ferry lantern (kind: docs) (hold-until 2026-12-01)\n' >> "$dir/home/data/done-archive.md"
  out=$(refusal_of "$dir" "hold-until with no colon" add am-spelled-new "Cobalt ferry lantern mast" --objective O7)
  assert_contains "$out" "am-spelled (Done, archived, overlap 0.75) Cobalt ferry lantern" "a hold-until tail with no colon was scored as title words"
  pass "an archived row's merged, priority, and hold tails are not scored as title words"
}

test_archived_title_words_in_parentheses_stay_in_the_title() {
  local dir out
  dir=$(make_split archive-title-words)
  wrapper_from_code "$dir" add pw-clean "Fix the lock crash (process cleanup)" --objective O7 --kind docs --repo firstmate >/dev/null || fail "could not file the first row"
  wrapper_from_code "$dir" add pw-report "Survey kiosk (report action 3)" --objective O7 --kind docs >/dev/null || fail "could not file the report row"
  wrapper_from_code "$dir" add pw-prod "Mend gateway (production)" --objective O7 --kind docs >/dev/null || fail "could not file the production row"
  wrapper_from_code "$dir" add pw-pr "Trim ferry (pr 123)" --objective O7 --kind docs >/dev/null || fail "could not file the pr row"
  wrapper_from_code "$dir" add pw-blocked "Mend loom (blocked-by tide)" --objective O7 --kind docs >/dev/null || fail "could not file the blocked row"
  for id in pw-clean pw-report pw-prod pw-pr pw-blocked; do
    wrapper_from_code "$dir" "done" "$id" --keep 0 >/dev/null || fail "could not close and prune $id"
    assert_no_grep "$id" "$dir/home/data/backlog.md" "$id was not pruned"
  done
  out=$(refusal_of "$dir" "process cleanup" add pw-new "Process cleanup" --objective O7)
  assert_contains "$out" "pw-clean (Done, archived, overlap 0.40) Fix the lock crash (process cleanup)" "(process cleanup) was stripped as a tail"
  out=$(refusal_of "$dir" "report action" add pw-new "Report action" --objective O7)
  assert_contains "$out" "pw-report (Done, archived, overlap 0.50) Survey kiosk (report action 3)" "(report action 3) was stripped as a tail"
  out=$(refusal_of "$dir" "production gateway" add pw-new "Production gateway" --objective O7)
  assert_contains "$out" "pw-prod (Done, archived, overlap 0.67) Mend gateway (production)" "(production) was stripped as a tail"
  out=$(refusal_of "$dir" "ferry 123" add pw-new "Ferry 123" --objective O7)
  assert_contains "$out" "pw-pr (Done, archived, overlap 0.67) Trim ferry (pr 123)" "(pr 123) was stripped as a tail"
  out=$(refusal_of "$dir" "blocked tide" add pw-new "Blocked tide" --objective O7)
  assert_contains "$out" "pw-blocked (Done, archived, overlap 0.50) Mend loom (blocked-by tide)" "(blocked-by tide) was stripped as a tail"
  pass "an archived row keeps the parenthesized words of its title and loses only the tails tasks-axi writes"
}

test_intake_flags_refuse_empty_values_and_a_repeated_not_dup() {
  local dir out flag before
  dir=$(make_split intake-flag-values)
  wrapper_from_code "$dir" add fv-one "Quartz harbor signal alpha" --objective O7 >/dev/null || fail "could not file the first neighbour"
  wrapper_from_code "$dir" add fv-two "Quartz harbor signal beta" --objective O7 --not-dup fv-one >/dev/null || fail "could not file the second neighbour"
  before=$(cat "$dir/home/data/backlog.md")
  for flag in --not-dup --objective --objective-reason --dup-of; do
    out=$(refusal_of "$dir" "empty $flag=" add fv-new "Quartz harbor signal gamma" --objective O7 "$flag=")
    assert_contains "$out" "$flag requires a value" "an empty $flag= was accepted"
    out=$(refusal_of "$dir" "option-like $flag=" add fv-new "Quartz harbor signal gamma" --objective O7 "$flag=-x")
    assert_contains "$out" "$flag requires a value" "an option-like $flag= was accepted"
  done
  out=$(refusal_of "$dir" "repeated --not-dup" add fv-new "Quartz harbor signal gamma" --objective O7 --not-dup fv-one --not-dup fv-two)
  assert_contains "$out" "--not-dup takes one neighbour id" "a repeated --not-dup was accepted"
  out=$(refusal_of "$dir" "repeated --not-dup, = form" add fv-new "Quartz harbor signal gamma" --objective O7 --not-dup=fv-one --not-dup=fv-one)
  assert_contains "$out" "--not-dup takes one neighbour id" "a repeated --not-dup= was accepted"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused flag value changed the backlog"
  out=$(wrapper_from_code "$dir" add fv-new "Quartz harbor signal gamma" --objective=O7 --not-dup=fv-two 2>&1) || fail "the = forms with real values were stopped: $out"
  assert_grep "fv-new" "$dir/home/data/backlog.md" "the = forms did not file the item"
  pass "the intake flags refuse an empty or option-like value in the = form, and --not-dup can be given only once"
}

# How many records of <file> carry every <key>=<value> pair (JSON values as text).
jsonl_count() {  # <file> <key>=<value>...
  python3 - "$@" <<'PY'
import json, sys
wanted = [pair.split("=", 1) for pair in sys.argv[2:]]
try:
    lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
except FileNotFoundError:
    lines = []
def text(value):
    return json.dumps(value) if isinstance(value, bool) else str(value)
print(sum(all(text(json.loads(line).get(k)) == v for k, v in wanted) for line in lines))
PY
}

test_backlog_guards_log_each_refusal_and_escape() {
  local dir out events friction
  dir=$(make_split guard-logging)
  events="$dir/home/state/guard-events.jsonl"
  friction="$dir/home/state/friction.jsonl"
  make_peer_home "$dir/sm1" gl-open
  printf -- '- sm-one - A local home (home: %s; scope: demo scope; projects: p; added 2026-11-01)\n' "$dir/sm1" > "$dir/home/data/secondmates.md"

  out=$(refusal_of "$dir" "no objective" add gl-a "Quartz harbor signal alpha")
  assert_contains "$out" "REFUSED: guard=backlog-intake-objective rule=objective-missing" "the objective refusal carries no envelope"
  assert_contains "$out" "completing-command: " "the objective refusal names no completing command"
  assert_contains "$out" "fm-tasks-axi: add needs the objective the item serves" "the envelope replaced the refusal text"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-intake-objective decision=deny source_ok=true)" "the objective refusal wrote no deny event"
  assert_equals 1 "$(jsonl_count "$friction" guard_id=backlog-intake-objective rule_id=objective-missing exit_kind=machine)" "the objective refusal wrote no friction record"

  wrapper_from_code "$dir" add gl-a "Quartz harbor signal alpha" --objective O7 --kind docs >/dev/null || fail "could not file the first item"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-intake-objective decision=allow)" "a passing objective wrote no allow event"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-intake-duplicate decision=allow override=false)" "a title with no neighbour wrote no allow event"

  out=$(refusal_of "$dir" "overlap" add gl-b "Quartz harbor signal beta" --objective O7)
  assert_contains "$out" "REFUSED: guard=backlog-intake-duplicate rule=title-overlap" "the duplicate refusal carries no envelope"
  assert_contains "$out" "human-only-exit: is this add the same work as gl-a?" "the duplicate refusal does not ask the question"
  assert_contains "$out" "this title overlaps open or recently closed items" "the envelope replaced the duplicate refusal text"
  assert_contains "$out" "--not-dup gl-a" "the envelope replaced the printed override"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-intake-duplicate decision=deny)" "the duplicate refusal wrote no deny event"

  out=$(refusal_of "$dir" "not-dup with no neighbour" add gl-b "Quartz harbor signal beta" --objective O7 --not-dup gl-nope)
  assert_contains "$out" "fm-tasks-axi: --not-dup gl-nope names no item in this backlog" "the --not-dup refusal text changed"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-intake-not-dup decision=deny)" "the --not-dup refusal wrote no deny event"
  wrapper_from_code "$dir" add gl-b "Quartz harbor signal beta" --objective O7 --kind docs --not-dup gl-a >/dev/null || fail "--not-dup did not file"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-intake-not-dup decision=allow)" "a passing --not-dup wrote no allow event"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-intake-duplicate decision=allow override=true cleared_by=not-dup)" "the --not-dup escape was not logged as an override"

  out=$(refusal_of "$dir" "dup-of nothing" add gl-c "Quartz harbor signal gamma" --objective O7 --dup-of gl-nope)
  assert_contains "$out" "fm-tasks-axi: the kept item gl-nope does not exist in this backlog" "the --dup-of refusal text changed"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-intake-dup-of decision=deny)" "the --dup-of refusal wrote no deny event"
  wrapper_from_code "$dir" add gl-c "Quartz harbor signal gamma" --objective O7 --dup-of gl-a >/dev/null || fail "--dup-of did not append"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-intake-dup-of decision=allow)" "a completed --dup-of wrote no allow event"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-intake-duplicate decision=allow override=false cleared_by=dup-of)" "the --dup-of escape was not logged as agreeing with the guard"

  out=$(refusal_of "$dir" "duplicate of nothing" "done" gl-b --duplicate-of gl-nope)
  assert_contains "$out" "REFUSED: guard=backlog-close-duplicate-of rule=kept-missing" "the --duplicate-of refusal carries no envelope"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-close-duplicate-of decision=deny)" "the --duplicate-of refusal wrote no deny event"
  out=$(refusal_of "$dir" "moved to nowhere" "done" gl-b --moved-to sm-nope gl-open)
  assert_contains "$out" "REFUSED: guard=backlog-close-moved-to rule=home-not-registered" "the --moved-to refusal carries no envelope"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-close-moved-to decision=deny)" "the --moved-to refusal wrote no deny event"
  wrapper_from_code "$dir" add gl-own "$(ftitle gl-own)" --objective O7 --kind docs --body "Owner 2026-11-01: keep this" >/dev/null || fail "could not file the owner item"
  out=$(refusal_of "$dir" "owner item" "done" gl-own --duplicate-of gl-a)
  assert_contains "$out" "REFUSED: guard=backlog-close-item-eligible rule=owner-filed" "the owner refusal carries no envelope"
  assert_equals 1 "$(jsonl_count "$friction" guard_id=backlog-close-item-eligible rule_id=owner-filed exit_kind=human-only)" "the owner refusal is not recorded as human-only"

  wrapper_from_code "$dir" "done" gl-b --duplicate-of gl-a >/dev/null || fail "a checked duplicate did not close"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-close-duplicate-of decision=allow)" "a completed duplicate close wrote no allow event"
  wrapper_from_code "$dir" add gl-mov "$(ftitle gl-mov)" --objective O7 --kind docs >/dev/null || fail "could not file the moved item"
  wrapper_from_code "$dir" "done" gl-mov --moved-to sm-one gl-open >/dev/null || fail "a checked move did not close"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-close-moved-to decision=allow)" "a completed moved close wrote no allow event"
  assert_equals 2 "$(jsonl_count "$events" guard=backlog-close-item-eligible decision=allow)" "the shared closing checks did not log each pass"

  mkdir "$dir/home/data/done-archive.md"
  out=$(refusal_of "$dir" "unreadable archive" add gl-d "$(ftitle gl-d)" --objective O7)
  assert_contains "$out" "the duplicate check could not read" "an unreadable archive did not stop the add"
  assert_not_contains "$out" "REFUSED:" "an unreadable source printed a policy envelope"
  assert_equals 1 "$(jsonl_count "$events" guard=backlog-intake-duplicate decision=deny source_ok=false)" "an unreadable source was not logged as such"
  pass "the intake and closing-proof guards log every refusal, pass, and escape, and keep their refusal text"
}

test_duplicate_of_closes_on_checked_proof() {
  local dir out before fakebin
  dir=$(make_split proof-dup)
  : > "$dir/home/config/fleet-ledger"
  wrapper_from_code "$dir" add pd-kept "Normalize the archive header spacing" --objective O7 --kind docs --body KEPT-BODY >/dev/null
  wrapper_from_code "$dir" add pd-fly "Compact the notes folder layout" --objective O7 --kind docs >/dev/null
  wrapper_from_code "$dir" start pd-fly >/dev/null || fail "could not start the In flight kept item"
  wrapper_from_code "$dir" add pd-dup "Align heading gaps inside the done ledger" --objective O7 --kind ship --repo p --body DUP-BODY >/dev/null
  wrapper_from_code "$dir" add pd-dup2 "Square the margin rhythm of every ledger" --objective O7 --kind docs --body DUP2-BODY >/dev/null
  wrapper_from_code "$dir" add pd-scout "Survey the pending release notes" --objective O7 --kind scout >/dev/null
  wrapper_from_code "$dir" add pd-closed "Retire the spent fixture cache" --objective O7 >/dev/null
  wrapper_from_code "$dir" "done" pd-closed >/dev/null || fail "could not close a plain row"
  before=$(cat "$dir/home/data/backlog.md")
  out=$(refusal_of "$dir" "missing kept" "done" pd-dup --duplicate-of pd-nope)
  assert_contains "$out" "does not exist" "a missing kept item was accepted"
  out=$(refusal_of "$dir" "closed kept" "done" pd-dup --duplicate-of pd-closed)
  assert_contains "$out" "not Queued or In flight" "a closed kept item was accepted"
  out=$(refusal_of "$dir" "self" "done" pd-dup --duplicate-of pd-dup)
  assert_contains "$out" "duplicate of itself" "an item was a duplicate of itself"
  refusal_of "$dir" "with a note" "done" pd-dup --duplicate-of pd-kept --note "same work" >/dev/null
  refusal_of "$dir" "with a report" "done" pd-scout --duplicate-of pd-kept --report data/pd-scout/report.md >/dev/null
  refusal_of "$dir" "with a pull request" "done" pd-dup --duplicate-of pd-kept --pr https://github.com/o/r/pull/9 >/dev/null
  refusal_of "$dir" "with moved-to" "done" pd-dup --duplicate-of pd-kept --moved-to sm pd-x >/dev/null
  refusal_of "$dir" "without a value" "done" pd-dup --duplicate-of >/dev/null
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused closing proof changed the backlog"
  # An append that fails leaves the duplicate open and the kept item as it was.
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = update ] && [ "\${2:-}" != --help ]; then echo 'error: backlog is unwritable' >&2; exit 1; fi
exec "$(command -v tasks-axi)" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
  out=$(PATH="$fakebin:$PATH" completion_refused "$dir" "append failure" "done" pd-dup --duplicate-of pd-kept)
  assert_contains "$out" "could not append" "a failed append was not reported"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a failed append closed the duplicate or changed the kept item"
  rm -f "$fakebin/tasks-axi"
  # A Queued kept item takes the duplicate, which closes with a note naming the kept id.
  out=$(wrapper_from_code "$dir" "done" pd-dup --duplicate-of pd-kept 2>&1) || fail "a proved duplicate was refused: $out"
  [ "$(row_state "$dir" pd-dup)" = x ] || fail "the duplicate did not close"
  [ "$(row_state "$dir" pd-kept)" = " " ] || fail "the kept item closed"
  assert_grep "duplicate of pd-kept" "$dir/home/data/backlog.md" "the closing note does not record the kept id"
  assert_grep "Merged from duplicate pd-dup: Align heading gaps inside the done ledger" "$dir/home/data/backlog.md" "the kept item did not receive the duplicate's title"
  assert_grep "DUP-BODY" "$dir/home/data/backlog.md" "the kept item did not receive the duplicate's body"
  assert_grep "KEPT-BODY" "$dir/home/data/backlog.md" "the kept item lost its own body"
  assert_grep "KEPT-BODY" "$dir/home/data/note-archive.md" "the kept item's previous body was not archived"
  # An In flight kept item takes a duplicate too.
  wrapper_from_code "$dir" task close pd-dup2 --duplicate-of pd-fly >/dev/null || fail "a duplicate of an In flight item was refused"
  assert_grep "DUP2-BODY" "$dir/home/data/backlog.md" "the In flight kept item did not receive the duplicate's body"
  # The ledger never records a duplicate close as a landing.
  assert_equals "task.closed none" "$(jq -r 'select(.task == "pd-dup" and .event == "task.closed") | [.event, .evidence] | join(" ")' "$dir/home/state/fleet-ledger.jsonl")" \
    "a duplicate close was not recorded with evidence none"
  assert_equals 0 "$(jq -s '[.[] | select(.event == "task.merged")] | length' "$dir/home/state/fleet-ledger.jsonl")" "a duplicate close claimed a landing"
  wrapper_from_code "$dir" task close pd-scout --duplicate-of pd-kept >/dev/null || fail "task close of a scout was refused"
  [ "$(row_state "$dir" pd-scout)" = x ] || fail "the scout did not close on a duplicate proof"
  # Another writer changes the kept item between the wrapper's read and its append.
  dir=$(make_split proof-dup-race)
  fakebin=$(fm_fakebin "$dir")
  wrapper_from_code "$dir" add pr-kept "Normalize the archive header spacing" --objective O7 --body FIRST-BODY >/dev/null
  wrapper_from_code "$dir" add pr-dup "Align heading gaps inside the done ledger" --objective O7 --body DUP-BODY >/dev/null
  make_interleaving_stub "$fakebin" pr-kept "$dir/raced"
  PATH="$fakebin:$PATH" wrapper_from_code "$dir" "done" pr-dup --duplicate-of pr-kept >/dev/null 2>&1 || fail "a duplicate close beside another writer failed"
  assert_grep "OTHER-WRITER-TEXT" "$dir/home/data/backlog.md" "the append overwrote another writer's update"
  assert_grep "DUP-BODY" "$dir/home/data/backlog.md" "the append was lost beside another writer"
  [ "$(row_state "$dir" pr-dup)" = x ] || fail "the duplicate did not close beside another writer"
  pass "fm-tasks-axi.sh closes a duplicate into a Queued or In flight item on checked proof and leaves both items alone when a check or the append fails"
}


# An ssh stand-in for bin/fm-on.sh (FM_SSH_BIN): it decodes the entrypoint
# arguments and runs the named wrapper command locally against the "remote" home,
# which lives under $FAKE_REMOTE_PREFIX so a same-named local path stays a decoy.
make_fake_ssh() {  # <fakebin>
  cat > "$1/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "${FAKE_SSH_MODE:-}" != unreachable ] || exit 255
[ "${FAKE_SSH_MODE:-}" != refused ] || { echo 'remote says: backlog is locked'; exit 1; }
[ "${FAKE_SSH_MODE:-}" != garbled ] || { echo 'welcome to far-box'; exit 0; }
root=$(printf '%s' "$4" | base64 -d)
home=$(printf '%s' "$5" | base64 -d)
argv=()
while IFS= read -r -d '' a; do argv+=("$a"); done < <(printf '%s' "$6" | base64 -d)
cmd=${argv[0]}
unset 'argv[0]'
exec env -i PATH="$PATH" HOME="$HOME" FM_HOME="${FAKE_REMOTE_PREFIX:-}$home" "$root/bin/$cmd" "${argv[@]}"
SH
  chmod +x "$1/fake-ssh"
}

# A local registered home <path> holding the items, one per line "id|state".
make_peer_home() {  # <path> <id|state>...
  local path=$1 spec
  shift
  mkdir -p "$path/data" "$path/state"
  empty_backlog "$path/data/backlog.md"
  for spec in "$@"; do
    tasks-axi add "${spec%%|*}" "$(ftitle "${spec%%|*}")" --file "$path/data/backlog.md" >/dev/null
    [ "${spec##*|}" != "done" ] || tasks-axi "done" "${spec%%|*}" --file "$path/data/backlog.md" >/dev/null
  done
}

moved_close() {  # <case-dir> <item> <home> <dest-item>; runs the proof with the fake transport wired in
  local dir=$1
  shift
  FM_SSH_BIN="$dir/fakebin/fake-ssh" FAKE_REMOTE_PREFIX="$dir/remote-fs" FAKE_SSH_MODE="${FAKE_SSH_MODE:-}" \
    wrapper_from_code "$dir" "done" "$1" --moved-to "$2" "$3" 2>&1
}

test_moved_to_closes_on_checked_proof() {
  local dir out fakebin n before
  dir=$(make_split proof-moved)
  fakebin=$(fm_fakebin "$dir")
  make_fake_ssh "$fakebin"
  make_adapter_stub "$fakebin"
  : > "$dir/home/config/fleet-ledger"
  make_peer_home "$dir/sm1" mv-open "mv-gone|done"
  # The remote home's backlog exists only under the transport's prefix; a local
  # path of the same name is a decoy that holds the item open.
  make_peer_home "$dir/remote-fs$dir/far-home" mv-far "mv-fardone|done"
  make_peer_home "$dir/far-home" mv-decoy
  ln -s "$dir/home" "$dir/home-link"
  {
    printf -- '- sm-one - A local home, with (parens); semicolons - and dashes (home: %s; scope: demo scope; projects: p; added 2026-11-01)\n' "$dir/sm1"
    printf -- '- sm-far - A far home (host: far-box; root: %s; home: %s; scope: far scope; projects: p; added 2026-11-01)\n' "$ROOT" "$dir/far-home"
    printf -- '- sm-self - The active home (home: %s; scope: self; projects: p; added 2026-11-01)\n' "$dir/home"
    printf -- '- sm-link - A path to the active home (home: %s; scope: self; projects: p; added 2026-11-01)\n' "$dir/home-link"
    printf -- '- sm-twice - First (home: %s; scope: dup scope; projects: p; added 2026-11-01)\n' "$dir/sm1"
    printf -- '- sm-twice - Second (home: %s; scope: dup scope; projects: p; added 2026-11-01)\n' "$dir/sm1"
  } > "$dir/home/data/secondmates.md"
  for n in item0 item1 item2 item3 item4 item5 item6 item7 item8 item9 item10 item11; do
    wrapper_from_code "$dir" add "mv-$n" "$(ftitle "mv-$n")" --objective O7 --kind ship >/dev/null
  done
  before=$(cat "$dir/home/data/backlog.md")
  out=$(moved_close "$dir" mv-item0 sm-none mv-open) && fail "an unregistered home was accepted"
  assert_contains "$out" "not one registered home" "an unregistered home was not named"
  out=$(moved_close "$dir" mv-item0 sm-one mv-absent) && fail "an absent item was accepted"
  assert_contains "$out" "has no item mv-absent" "an absent item in the home was not named"
  out=$(moved_close "$dir" mv-item0 sm-one mv-gone) && fail "a Done item in the home was accepted"
  assert_contains "$out" "is not open" "a Done item in the home was not named"
  out=$(moved_close "$dir" mv-item0 sm-twice mv-open) && fail "a home id with two registry entries was accepted"
  assert_contains "$out" "not one registered home" "an ambiguous home id was not named"
  out=$(moved_close "$dir" mv-item0 sm-self mv-item1) && fail "the active home was accepted as the destination"
  assert_contains "$out" "this backlog itself" "the active home was not named"
  out=$(moved_close "$dir" mv-item0 sm-link mv-item1) && fail "another path to the active backlog was accepted"
  assert_contains "$out" "this backlog itself" "another path to the active backlog was not named"
  out=$(FAKE_SSH_MODE=unreachable moved_close "$dir" mv-item0 sm-far mv-far) && fail "an unreachable remote home was accepted"
  assert_contains "$out" "cannot read sm-far's backlog" "an unreachable remote home was not named"
  out=$(FAKE_SSH_MODE=refused moved_close "$dir" mv-item0 sm-far mv-far) && fail "a remote error was accepted"
  assert_contains "$out" "remote says: backlog is locked" "the remote's own error was lost"
  out=$(FAKE_SSH_MODE=garbled moved_close "$dir" mv-item0 sm-far mv-far) && fail "a remote answer that is not a task record was accepted"
  assert_contains "$out" "the answer from sm-far is not a task record" "the not-a-record reason was lost"
  out=$(moved_close "$dir" mv-item0 sm-far mv-decoy) && fail "a local decoy path counted for a remote home"
  assert_contains "$out" "has no item mv-decoy" "the decoy local path was read"
  out=$(moved_close "$dir" mv-item0 sm-far mv-fardone) && fail "a Done item in the remote home was accepted"
  assert_contains "$out" "is not open" "a Done remote item was not named"
  out=$(moved_close "$dir" mv-item0 sm-one one two) && fail "a missing item id was accepted"
  out=$(refusal_of "$dir" "one value" "done" mv-item0 --moved-to sm-one)
  assert_contains "$out" "two values" "a one-value --moved-to was accepted"
  out=$(refusal_of "$dir" "equals form" "done" mv-item0 --moved-to=sm-one)
  assert_contains "$out" "two values" "the = form of --moved-to was accepted"
  refusal_of "$dir" "with a note" "done" mv-item0 --moved-to sm-one mv-open --note moved >/dev/null
  refusal_of "$dir" "with a duplicate proof" "done" mv-item0 --moved-to sm-one mv-open --duplicate-of mv-item1 >/dev/null
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused closing proof changed the backlog"
  # A local home with the item open.
  out=$(moved_close "$dir" mv-item0 sm-one mv-open) || fail "a proved local move was refused: $out"
  [ "$(row_state "$dir" mv-item0)" = x ] || fail "the moved item did not close"
  assert_grep "moved to sm-one as mv-open" "$dir/home/data/backlog.md" "the closing note does not record the home and item"
  assert_no_grep "mv-item0" "$dir/sm1/data/backlog.md" "the move touched the other home's backlog"
  assert_equals "task.closed none" "$(jq -r 'select(.task == "mv-item0" and .event == "task.closed") | [.event, .evidence] | join(" ")' "$dir/home/state/fleet-ledger.jsonl")" \
    "a moved close was not recorded with evidence none"
  assert_equals 0 "$(jq -s '[.[] | select(.event == "task.merged")] | length' "$dir/home/state/fleet-ledger.jsonl")" "a moved close claimed a landing"
  # A remote home with the item open, read through the transport.
  out=$(moved_close "$dir" mv-item1 sm-far mv-far) || fail "a proved remote move was refused: $out"
  [ "$(row_state "$dir" mv-item1)" = x ] || fail "the item moved to the remote home did not close"
  assert_grep "moved to sm-far as mv-far" "$dir/home/data/backlog.md" "the remote move's note does not record the proof"
  # The probe of another home must leave this home addressed: a later write still lands here.
  wrapper_from_code "$dir" add mv-after "Audit the lavish listener sockets" --objective O7 >/dev/null || fail "an add after a move failed"
  assert_grep "mv-after" "$dir/home/data/backlog.md" "a write after a move left this home"
  assert_no_grep "mv-after" "$dir/sm1/data/backlog.md" "a write after a move reached the other home"
  # A destination on a non-Markdown adapter is read through tasks-axi, not from a Markdown file.
  mkdir -p "$dir/ad1/data" "$dir/ad2/data"
  make_adapter_home "$dir/ad1" ad-item "Adapter item that the stub says is done"
  printf 'task:\n  id: ad-item\n  title: done one\n  state: done\n  held: no\n  blocked: no\n  kind: task\n' > "$dir/ad1/.stubdata/show-ad-item"
  printf '## In flight\n\n## Queued\n- [ ] ad-item - stale markdown shows it open (since 2026-11-01)\n\n## Done\n' > "$dir/ad1/data/backlog.md"
  make_adapter_home "$dir/ad2" ad-item "Adapter item that the stub says is open"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/ad2/data/backlog.md"
  {
    printf -- '- sm-ad1 - adapter done (home: %s; scope: a; projects: p; added 2026-11-01)\n' "$dir/ad1"
    printf -- '- sm-ad2 - adapter open (home: %s; scope: a; projects: p; added 2026-11-01)\n' "$dir/ad2"
  } >> "$dir/home/data/secondmates.md"
  out=$(PATH="$fakebin:$PATH" moved_close "$dir" mv-item2 sm-ad1 ad-item) && fail "an adapter item that is Done counted as open: $out"
  assert_contains "$out" "is not open" "the adapter's Done answer was not used"
  out=$(PATH="$fakebin:$PATH" moved_close "$dir" mv-item2 sm-ad2 ad-item) || fail "an open adapter item was refused: $out"
  [ "$(row_state "$dir" mv-item2)" = x ] || fail "the item moved to the adapter home did not close"
  # The registry is the source operation's own: an overriding data root and a split home.
  mkdir -p "$dir/alt/data"
  empty_backlog "$dir/alt/data/backlog.md"
  (cd "$dir/code" && FM_DATA_OVERRIDE="$dir/alt/data" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" add alt-item "$(ftitle alt-item)" --objective O7 >/dev/null) \
    || fail "could not file the override root's item"
  out=$(cd "$dir/code" && FM_DATA_OVERRIDE="$dir/alt/data" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" "done" alt-item --moved-to sm-one mv-open 2>&1) \
    && fail "a destination only a decoy registry holds was accepted"
  assert_contains "$out" "not one registered home" "the decoy registry was read for the override root"
  printf -- '- sm-one - A local home (home: %s; scope: demo scope; projects: p; added 2026-11-01)\n' "$dir/sm1" > "$dir/alt/data/secondmates.md"
  (cd "$dir/code" && FM_DATA_OVERRIDE="$dir/alt/data" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" "done" alt-item --moved-to sm-one mv-open >/dev/null 2>&1) \
    || fail "the override root's own registry route was refused"
  pass "fm-tasks-axi.sh closes a moved item on checked proof, local, remote, and adapter, from the source's own registry, and stops on every unproved case"
}

# One owner-filed marker per row, through one proof. The rows are written into
# the Queued section in one step, since only the closing proof is under test.
owner_marker_cases() {  # <case-dir> <proof-label> <done-args-suffix...>
  local dir=$1 label=$2 who word n=0 id body rows='' positive=() negative=() out
  shift 2
  for who in Captain Owner; do
    for word in ask words question call decision ruling rule answer; do
      n=$((n + 1)); id="own-$label-$n"; positive+=("$id")
      rows="$rows- [ ] $id - $(ftitle "$id") (since 2026-11-01)"$'\n'"  $who $word was recorded here"$'\n'
    done
  done
  for body in "Captain 2026 asked for this" "Owner: keep" "Captain: keep" \
    "Captain's words 2026-10-19: yes on both" "Captain's ask: a workstream view" \
    "Captain chose 2026-10-20: this one" "Captain direction: one owner" \
    "Captain's words, 2026-10-20 (via /kun): this one" "Captain's ask 2026-09-22 on /bearings lavish: a view" \
    "Captain chose this on the Lavish page" "Captain direction 2026-10-22, verbatim in the direction file"; do
    n=$((n + 1)); id="own-$label-$n"; positive+=("$id")
    rows="$rows- [ ] $id - $(ftitle "$id") (since 2026-11-01)"$'\n'"  $body"$'\n'
  done
  for body in "Owner 2026 notes only" "the lock owner holds nothing" "the captain of the ship mentioned this" "Owner's idea"; do
    n=$((n + 1)); id="own-$label-$n"; negative+=("$id")
    rows="$rows- [ ] $id - $(ftitle "$id") (since 2026-11-01)"$'\n'"  $body"$'\n'
  done
  {
    sed '/^## Done/,$d' "$dir/home/data/backlog.md"
    printf '%s' "$rows"
    sed -n '/^## Done/,$p' "$dir/home/data/backlog.md"
  } > "$dir/home/data/backlog.md.new" && mv "$dir/home/data/backlog.md.new" "$dir/home/data/backlog.md"
  for id in "${positive[@]}"; do
    out=$(refusal_of "$dir" "$id via $label" "done" "$id" "$@")
    assert_contains "$out" "the owner's own item" "$id did not read as owner-filed through $label"
    assert_contains "$out" "--drop-file" "the owner-filed refusal did not name the owner's words"
  done
  for id in "${negative[@]}"; do
    out=$(wrapper_from_code "$dir" "done" "$id" "$@" 2>&1) || fail "$id mentions the owner without a marker and was stopped through $label: $out"
    [ "$(row_state "$dir" "$id")" = x ] || fail "$id did not close through $label"
  done
}

owner_call_cases() {  # <case-dir> <proof-label> <done-args-suffix...>
  local dir=$1 label=$2 id fakebin out
  shift 2
  # held through bin/fm-captain-hold.sh
  wrapper_from_code "$dir" add "hold-a-$label" "$(ftitle "hold-a-$label")" --objective O7 --kind ship >/dev/null
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$ROOT/bin/fm-captain-hold.sh" hold "hold-a-$label" --reason "which name?" >/dev/null 2>&1) \
    || fail "fm-captain-hold.sh could not hold hold-a-$label"
  out=$(refusal_of "$dir" "held through fm-captain-hold" "done" "hold-a-$label" "$@")
  assert_contains "$out" "open owner call" "a task held through fm-captain-hold.sh closed"
  assert_contains "$out" "fm-captain-hold.sh answer" "the open-call refusal did not name how to answer it"
  # a kind:captain row with an open hold
  wrapper_from_code "$dir" add "hold-b-$label" "$(ftitle "hold-b-$label")" --objective O7 --kind captain >/dev/null
  wrapper_from_code "$dir" hold "hold-b-$label" --reason "which?" --kind captain >/dev/null || fail "could not hold a captain row"
  refusal_of "$dir" "captain row" "done" "hold-b-$label" "$@" >/dev/null
  # a dated hold that expired unanswered
  wrapper_from_code "$dir" add "hold-c-$label" "$(ftitle "hold-c-$label")" --objective O7 --kind ship >/dev/null
  wrapper_from_code "$dir" hold "hold-c-$label" --reason "which?" --kind captain --until 2020-01-01 >/dev/null || fail "could not hold with a past date"
  out=$(refusal_of "$dir" "expired hold" "done" "hold-c-$label" "$@")
  assert_contains "$out" "open owner call" "an expired unanswered hold closed"
  # released and then held again
  wrapper_from_code "$dir" add "hold-d-$label" "$(ftitle "hold-d-$label")" --objective O7 --kind ship >/dev/null
  wrapper_from_code "$dir" hold "hold-d-$label" --reason "which?" --kind captain >/dev/null
  wrapper_from_code "$dir" unhold "hold-d-$label" >/dev/null || fail "could not release the hold"
  wrapper_from_code "$dir" hold "hold-d-$label" --reason "again?" --kind captain >/dev/null
  refusal_of "$dir" "re-held" "done" "hold-d-$label" "$@" >/dev/null
  # a captain row whose hold was released is not an open call
  wrapper_from_code "$dir" add "hold-e-$label" "$(ftitle "hold-e-$label")" --objective O7 --kind captain >/dev/null
  wrapper_from_code "$dir" hold "hold-e-$label" --reason "which?" --kind captain >/dev/null
  wrapper_from_code "$dir" unhold "hold-e-$label" >/dev/null
  out=$(wrapper_from_code "$dir" "done" "hold-e-$label" "$@" 2>&1) || fail "a released captain row was read as an open call: $out"
  [ "$(row_state "$dir" "hold-e-$label")" = x ] || fail "a released captain row did not close through $label"
  # a hold whose state cannot be read counts as undecided
  wrapper_from_code "$dir" add "hold-f-$label" "$(ftitle "hold-f-$label")" --objective O7 --kind ship >/dev/null
  # The wrapper hands bin/fm-captain-hold.sh an explicit FM_DATA_OVERRIDE, which its
  # own reads do not carry, so this stand-in fails only the hold predicate's read.
  fakebin=$(fm_fakebin "$dir/hold-fakebin-$label")
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ -n "\${FM_DATA_OVERRIDE:-}" ]; then
  echo 'error: hold state unreadable' >&2
  exit 1
fi
exec "$(command -v tasks-axi)" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
  out=$(PATH="$fakebin:$PATH" completion_refused "$dir" "unreadable hold" "done" "hold-f-$label" "$@")
  assert_contains "$out" "undecided" "an unreadable hold did not count as undecided"
  # a live task, ship and non-ship, in the default and an overridden state directory
  wrapper_from_code "$dir" add "live-a-$label" "$(ftitle "live-a-$label")" --objective O7 --kind ship >/dev/null
  wrapper_from_code "$dir" add "live-b-$label" "$(ftitle "live-b-$label")" --objective O7 --kind docs >/dev/null
  wrapper_from_code "$dir" add "live-c-$label" "$(ftitle "live-c-$label")" --objective O7 --kind docs >/dev/null
  printf 'kind=ship\n' > "$dir/home/state/live-a-$label.meta"
  printf 'kind=docs\n' > "$dir/home/state/live-b-$label.meta"
  for id in "live-a-$label" "live-b-$label"; do
    out=$(refusal_of "$dir" "live task $id" "done" "$id" "$@")
    assert_contains "$out" "fm-teardown.sh $id" "a live task was not sent to teardown"
  done
  mkdir -p "$dir/altstate"
  printf 'kind=docs\n' > "$dir/altstate/live-c-$label.meta"
  out=$(FM_STATE_OVERRIDE="$dir/altstate" completion_refused "$dir" "live task in an overridden state directory" "done" "live-c-$label" "$@")
  assert_contains "$out" "fm-teardown.sh live-c-$label" "a live task in an overridden state directory closed"
}

test_closing_proofs_keep_open_dependents_blocked() {
  local dir out before
  dir=$(make_split proof-dependents)
  make_peer_home "$dir/sm1" dp-open
  printf -- '- sm-one - A local home (home: %s; scope: demo scope; projects: p; added 2026-11-01)\n' "$dir/sm1" > "$dir/home/data/secondmates.md"
  wrapper_from_code "$dir" add dp-kept "Normalize the archive header spacing" --objective O7 --kind docs >/dev/null
  wrapper_from_code "$dir" add dp-dup "Align heading gaps inside the done ledger" --objective O7 --kind docs --body DUP-BODY >/dev/null
  wrapper_from_code "$dir" add dp-dup-long "Retire the spent fixture cache" --objective O7 --kind docs >/dev/null
  wrapper_from_code "$dir" add dp-closer "Survey the pending release notes" --objective O7 --kind docs --blocked-by dp-dup >/dev/null
  wrapper_from_code "$dir" "done" dp-closer >/dev/null || fail "could not close a plain dependent"
  wrapper_from_code "$dir" add dp-near "Compact the notes folder layout" --objective O7 --kind docs --blocked-by dp-dup-long >/dev/null
  wrapper_from_code "$dir" add dp-dep "Rotate the stale mirror credentials" --objective O7 --kind docs --blocked-by dp-dup >/dev/null
  wrapper_from_code "$dir" add dp-self "Mend the porch lantern wiring" --objective O7 --kind docs --blocked-by dp-dup >/dev/null
  wrapper_from_code "$dir" hold dp-dep --reason "waiting on a vendor" --kind external >/dev/null || fail "could not hold the dependent"
  before=$(cat "$dir/home/data/backlog.md")
  out=$(refusal_of "$dir" "duplicate with a dependent" "done" dp-dup --duplicate-of dp-kept)
  assert_contains "$out" "still blocks open items: dp-dep dp-self" "the refusal did not name every dependent"
  assert_not_contains "$out" "dp-near" "the refusal named an item blocked by a different id"
  assert_not_contains "$out" "dp-closer" "the refusal named a Done dependent"
  assert_contains "$out" "unblock <dependent> --by dp-dup" "the refusal did not say how to clear the old blocker"
  assert_contains "$out" "Re-point every one first, held or not: bin/fm-tasks-axi.sh block <dependent> --by dp-kept, then bin/fm-tasks-axi.sh unblock <dependent> --by dp-dup" "the refusal did not re-point every dependent"
  assert_not_contains "$out" "keeps that hold" "the duplicate refusal let a held dependent skip the re-point"
  assert_not_contains "$out" "fm-tasks-axi.sh hold" "the duplicate refusal printed a hold command"
  out=$(refusal_of "$dir" "kept item blocked by the duplicate" "done" dp-dup --duplicate-of dp-self)
  assert_contains "$out" "the kept item dp-self itself needs only the unblock step" "the refusal told the kept item to block itself"
  assert_contains "$out" "unblock <dependent> --by dp-dup" "the kept-item refusal did not say how to clear the blocker"
  out=$(refusal_of "$dir" "move with a dependent" "done" dp-dup --moved-to sm-one dp-open)
  assert_contains "$out" "still blocks open items: dp-dep dp-self" "the move refusal did not name every dependent"
  assert_contains "$out" "for a dependent with no hold, bin/fm-tasks-axi.sh hold <dependent>" "the move refusal did not limit its hold step to a dependent with no hold"
  assert_contains "$out" "A dependent already on a hold keeps that hold and needs only the unblock step" "the move refusal did not spare a held dependent"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused proof close changed the backlog"
  assert_equals "dp-dup" "$(wrapper_from_code "$dir" show dp-dep | sed -n 's/^  blocked_by: *//p' | tr -d '"')" "a refused proof close released the dependent"
  # The held dependent follows the advice like any other; the Done one never counted.
  wrapper_from_code "$dir" block dp-dep --by dp-kept >/dev/null || fail "could not re-point the held dependent"
  wrapper_from_code "$dir" unblock dp-dep --by dp-dup >/dev/null || fail "could not clear the blocker"
  wrapper_from_code "$dir" unblock dp-self --by dp-dup >/dev/null || fail "could not clear the kept item's blocker"
  assert_equals "external" "$(wrapper_from_code "$dir" show dp-dep | sed -n 's/^  hold_kind: *//p')" "the unblock step changed the dependent's hold"
  out=$(wrapper_from_code "$dir" "done" dp-dup --duplicate-of dp-kept 2>&1) || fail "a re-pointed duplicate was refused: $out"
  [ "$(row_state "$dir" dp-dup)" = x ] || fail "the re-pointed duplicate did not close"
  assert_equals "dp-kept" "$(wrapper_from_code "$dir" show dp-dep | sed -n 's/^  blocked_by: *//p' | tr -d '"')" "the held dependent is not still waiting for the kept item"
  pass "fm-tasks-axi.sh refuses a proof close while the item still blocks open items, and closes once they are re-pointed"
}

test_closing_proofs_leave_the_owners_items_alone() {
  local dir out body id form
  dir=$(make_split proof-owner)
  make_peer_home "$dir/sm1" ow-open
  printf -- '- sm-one - A local home (home: %s; scope: demo scope; projects: p; added 2026-11-01)\n' "$dir/sm1" > "$dir/home/data/secondmates.md"
  wrapper_from_code "$dir" add ow-kept "$(ftitle ow-kept)" --objective O7 --kind docs >/dev/null
  # Each proof reads the same markers and the same holds, so the cases run through both.
  owner_marker_cases "$dir" dup "--duplicate-of" ow-kept
  owner_marker_cases "$dir" mov "--moved-to" sm-one ow-open
  owner_call_cases "$dir" dup "--duplicate-of" ow-kept
  owner_call_cases "$dir" mov "--moved-to" sm-one ow-open
  for form in "Captain's words" "Captain's ask" "Captain chose" "Captain direction"; do
    printf '%s: keep\n' "$form" | python3 "$ROOT/bin/fm-backlog-intake.py" owner-filed || fail "$form: did not read as owner-filed"
    printf '%s 2026-10-22: keep\n' "$form" | python3 "$ROOT/bin/fm-backlog-intake.py" owner-filed || fail "$form with a date did not read as owner-filed"
  done
  for body in "the owner decision stands" "captain chose: agent prose" "Owner's idea: agent prose" \
    "Captain's wordsmith" "Captain's asking" "Captain chosen" "Captain directions" "SeaCaptain chose"; do
    if printf '%s\n' "$body" | python3 "$ROOT/bin/fm-backlog-intake.py" owner-filed; then
      fail "'$body' read as owner-filed"
    fi
  done
  # The dated form, in the shape two live backlog items carry, through both proofs.
  for id in fm-role-publish-target-binding fm-nm-protected-paths-policy; do
    wrapper_from_code "$dir" add "$id" "$(ftitle "$id")" --objective O7 --kind docs --body "Owner 2026-11-01: this stays mine" >/dev/null \
      || fail "could not file $id"
    out=$(refusal_of "$dir" "$id via duplicate" "done" "$id" --duplicate-of ow-kept)
    assert_contains "$out" "the owner's own item" "$id closed through --duplicate-of without the owner's words"
    out=$(refusal_of "$dir" "$id via move" "done" "$id" --moved-to sm-one ow-open)
    assert_contains "$out" "the owner's own item" "$id closed through --moved-to without the owner's words"
    [ "$(row_state "$dir" "$id")" != x ] || fail "$id closed"
  done
  wrapper_from_code "$dir" add dated-captain "$(ftitle dated-captain)" --objective O7 --kind docs --body "Captain 2027-01-15: this stays mine" >/dev/null \
    || fail "could not file dated-captain"
  out=$(refusal_of "$dir" "dated captain" "done" dated-captain --duplicate-of ow-kept)
  assert_contains "$out" "the owner's own item" "a dated Captain item in a later year closed without the owner's words"
  pass "both closing proofs stop at every owner-filed marker, open owner call, unreadable hold, and live task, and close an item that only mentions the owner"
}

# A hold or a live task published while a proof is running never lands on a
# closed item or closes a held one.
test_closing_proofs_serialize_with_holds_and_live_tasks() (
  local dir fakebin real proof closer='' holder='' out rc label
  trap 'touch "$dir/release-done" "$dir/release-hold"; [ -z "$closer" ] || kill "$closer" 2>/dev/null || true; [ -z "$holder" ] || kill "$holder" 2>/dev/null || true' EXIT
  for label in dup mov; do
    dir=$(make_split "proof-race-$label")
    fakebin=$(fm_fakebin "$dir")
    real=$(command -v tasks-axi)
    make_mutation_wait_sleep "$fakebin"
    make_peer_home "$dir/sm1" race-open
    printf -- '- sm-one - A local home (home: %s; scope: demo scope; projects: p; added 2026-11-01)\n' "$dir/sm1" > "$dir/home/data/secondmates.md"
    wrapper_from_code "$dir" add race-kept "$(ftitle race-kept)" --objective O7 --kind docs >/dev/null
    wrapper_from_code "$dir" add race-a "$(ftitle race-a)" --objective O7 --kind docs >/dev/null
    wrapper_from_code "$dir" add race-b "$(ftitle race-b)" --objective O7 --kind docs >/dev/null
    wrapper_from_code "$dir" add race-c "$(ftitle race-c)" --objective O7 --kind docs >/dev/null
    if [ "$label" = dup ]; then proof=(--duplicate-of race-kept); else proof=(--moved-to sm-one race-open); fi
    cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = done ] && [ "\${2:-}" = race-a ]; then
  : > "$dir/done-entered"
  while [ ! -e "$dir/release-done" ]; do sleep 0.05; done
fi
if [ "\${1:-}" = hold ] && [ "\${2:-}" = race-b ]; then
  : > "$dir/hold-entered"
  while [ ! -e "$dir/release-hold" ]; do sleep 0.05; done
fi
exec "$real" "\$@"
SH
    chmod +x "$fakebin/tasks-axi"
    # Close first: a hold and a live-task record wait behind the proof and land after the close.
    PATH="$fakebin:$PATH" wrapper_from_code "$dir" "done" race-a "${proof[@]}" > "$dir/close-result" 2>&1 &
    closer=$!
    wait_mutation_fixture "$dir/done-entered" "$label proof close" "$closer" "$dir/close-result"
    PATH="$fakebin:$PATH" FAKE_LOCK_WAIT="$dir/hold-wait" wrapper_from_code "$dir" hold race-a --reason "which?" --kind captain \
      > "$dir/hold-result" 2>&1 &
    holder=$!
    wait_mutation_fixture "$dir/hold-wait" "hold behind the $label proof" "$holder" "$dir/hold-result"
    [ "$(row_state "$dir" race-a)" = " " ] || true
    : > "$dir/release-done"
    wait "$closer" || fail "the $label proof close failed: $(cat "$dir/close-result")"
    closer=''
    wait "$holder" || true
    holder=''
    [ "$(row_state "$dir" race-a)" = x ] || fail "a concurrent hold stopped or reopened a proved $label close"
    # Hold first: the proof reads the committed hold and stops.
    PATH="$fakebin:$PATH" wrapper_from_code "$dir" hold race-b --reason "which?" --kind captain > "$dir/hold-result" 2>&1 &
    holder=$!
    wait_mutation_fixture "$dir/hold-entered" "hold ahead of the $label proof" "$holder" "$dir/hold-result"
    PATH="$fakebin:$PATH" FAKE_LOCK_WAIT="$dir/proof-wait" wrapper_from_code "$dir" "done" race-b "${proof[@]}" > "$dir/close-result" 2>&1 &
    closer=$!
    wait_mutation_fixture "$dir/proof-wait" "$label proof behind a hold" "$closer" "$dir/close-result"
    [ "$(row_state "$dir" race-b)" = " " ] || fail "the $label proof closed an item while a hold was committing"
    : > "$dir/release-hold"
    wait "$holder" || fail "the concurrent hold failed"
    holder=''
    rc=0
    wait "$closer" || rc=$?
    closer=''
    expect_code 2 "$rc" "$label proof after a committed hold"
    out=$(cat "$dir/close-result")
    assert_contains "$out" "open owner call" "the $label proof did not read the committed hold"
    [ "$(row_state "$dir" race-b)" = " " ] || fail "the $label proof closed a concurrently held item"
    # A live-task record published while the proof runs waits for the close.
    rm -f "$dir/done-entered" "$dir/release-done"
    sed -i.bak 's/race-a/race-c/g' "$fakebin/tasks-axi" && rm -f "$fakebin/tasks-axi.bak"
    PATH="$fakebin:$PATH" wrapper_from_code "$dir" "done" race-c "${proof[@]}" > "$dir/close-result" 2>&1 &
    closer=$!
    wait_mutation_fixture "$dir/done-entered" "$label proof close of race-c" "$closer" "$dir/close-result"
    FM_HOME="$dir/home" bash -c '
      . "$1"
      lock=$(fm_meta_lock_path "$STATE/race-c.meta")
      : > "$2/publisher-waiting"
      fm_lock_acquire_wait "$lock"
      printf "kind=docs\n" > "$STATE/race-c.meta"
      : > "$2/published"
      fm_lock_release "$lock"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$dir" &
    holder=$!
    wait_mutation_fixture "$dir/publisher-waiting" "live-task publisher" "$holder"
    sleep 0.5
    assert_absent "$dir/published" "a live-task record was published inside the $label proof"
    : > "$dir/release-done"
    wait "$closer" || fail "the $label proof close of race-c failed: $(cat "$dir/close-result")"
    closer=''
    wait "$holder" || fail "the live-task publisher failed"
    holder=''
    [ "$(row_state "$dir" race-c)" = x ] || fail "the $label proof did not close race-c"
  done
  pass "a hold or a live-task record published during a closing proof waits for the close, and a committed hold stops the proof"
)

if [ "$#" -gt 0 ]; then
  fm_test_run_cases -- "$@"
  exit 0
fi

test_guard_reports_regular_code_root_backlog
test_guard_reports_foreign_link_and_archive
test_guard_silent_for_single_home
if [ "$HAVE_TASKS_AXI" = 1 ]; then
  test_bare_tasks_axi_fork_is_detected
  test_wrapper_writes_through_to_home
  test_wrapper_overrides_ambient_file
  test_wrapper_refusals
  test_wrapper_refuses_add_start
  test_wrapper_single_home
  test_completion_needs_proof_of_the_deliverable
  test_completion_by_the_captains_own_words
  test_completion_clears_the_finished_blocker_from_dependents
  test_completion_preserves_retained_captain_calls
  test_public_restart_retires_drop_provenance
  test_resumed_deliveries_reach_landed_output
  test_restart_handles_sole_drop_and_failed_body_update
  test_unsupported_leading_backend_preserves_the_row
  test_bounded_mutation_grammar_refuses_before_side_effects
  test_bounded_refusals_preserve_retained_words_with_ambient_backends
  test_exact_mutation_help_has_no_side_effects
  test_completion_keep_count_and_normal_options
  test_task_mutations_wait_for_lifecycle_custody || exit "$?"
  test_completion_serializes_with_a_concurrent_hold || exit "$?"
  test_restart_serializes_with_a_concurrent_body_change || exit "$?"
  test_failed_restart_reads_back_before_restoring_drop
  test_relative_home_and_overrides_keep_fleet_ledger
  test_add_records_task_filed_once
  test_add_ledger_off_and_failing_ledger_leave_add_alone
  test_completion_records_task_closed_once_with_its_proof
  test_add_requires_an_objective
  test_objective_rows_land_in_the_addressed_home
  test_failed_row_write_removes_the_filed_item
  test_json_add_records_its_objective_without_jq
  test_add_judges_near_duplicate_titles
  test_duplicate_check_boundaries_and_unreadable_sources
  test_dup_of_and_not_dup_do_what_the_refusal_says
  test_dup_of_repeat_needs_the_whole_block
  test_archived_blocked_by_rows_keep_their_title_score
  test_archived_merged_row_keeps_its_title_score
  test_archived_title_words_in_parentheses_stay_in_the_title
  test_intake_flags_refuse_empty_values_and_a_repeated_not_dup
  test_backlog_guards_log_each_refusal_and_escape
  test_duplicate_of_closes_on_checked_proof
  test_moved_to_closes_on_checked_proof
  test_closing_proofs_keep_open_dependents_blocked
  test_closing_proofs_leave_the_owners_items_alone
  test_closing_proofs_serialize_with_holds_and_live_tasks || exit "$?"
else
  echo "skip: tasks-axi not found; home-addressing cases not run"
fi
