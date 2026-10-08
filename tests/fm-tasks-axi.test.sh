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

empty_backlog() {  # <path>
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$1"
}

# A code root carrying the tracked .tasks.toml and an operational home beside
# it, with the code-root backlog linked into the home the way an operator
# would try to keep the two in sync.
make_split() {  # <name>; prints the case directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/data" "$dir/home/data" "$dir/home/state" "$dir/home/config"
  cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
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
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
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
    wrapper_from_code "$dir" add "ship-$i" "ship $i" >/dev/null || fail "add ship-$i failed"
    wrapper_from_code "$dir" start "ship-$i" >/dev/null || fail "start ship-$i failed"
    wrapper_from_code "$dir" "done" "ship-$i" >/dev/null || fail "done ship-$i failed"
  done
  wrapper_from_code "$dir" add call-1 "captain call" >/dev/null || fail "add call-1 failed"
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
  (cd "$dir/code" && TASKS_AXI_FILE="$dir/decoy.md" FM_HOME="$dir/home" "$WRAPPER" add amb-1 "ambient" >/dev/null) \
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
  out=$(wrapper_from_code "$dir" add r-1 "explicit" --file "$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file"
  assert_contains "$out" "drop --file" "--file refusal did not explain itself"
  out=$(wrapper_from_code "$dir" list --file="$dir/home/data/backlog.md" 2>&1)
  rc=$?
  expect_code 2 "$rc" "--file="

  mv "$dir/home/data/backlog.md" "$dir/home/real-backlog.md"
  ln -s "$dir/home/real-backlog.md" "$dir/home/data/backlog.md"
  out=$(wrapper_from_code "$dir" add r-2 "through a link" 2>&1)
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
  out=$(wrapper_from_code "$dir" add hs-1 "hand-started" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "add --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the add --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused add --start still wrote a row"
  out=$(wrapper_from_code "$dir" create hs-c "hand-started via alias" --start 2>&1)
  rc=$?
  expect_code 2 "$rc" "create --start"
  assert_contains "$out" "bin/fm-spawn.sh" "the create --start refusal did not name the dispatch path"
  assert_equals "$before" "$(cat "$dir/home/data/backlog.md")" "a refused create --start still wrote a row"
  wrapper_from_code "$dir" add hs-2 "queued" >/dev/null || fail "plain add was refused"
  assert_grep "hs-2" "$dir/home/data/backlog.md" "plain add did not write its row"
  wrapper_from_code "$dir" start hs-2 >/dev/null || fail "start <id> was refused"
  pass "fm-tasks-axi.sh refuses add --start while plain add and start <id> pass through"
}

test_wrapper_single_home() {
  local dir
  dir="$TMP_ROOT/single-wrapper"
  mkdir -p "$dir/data"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  empty_backlog "$dir/data/backlog.md"
  (cd "$dir" && FM_ROOT_OVERRIDE="$dir" "$WRAPPER" add solo-1 "single home" >/dev/null) \
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
  wrapper_from_code "$dir" add ship-a "ship a" --kind ship --repo p >/dev/null
  wrapper_from_code "$dir" add scout-a "scout a" --kind scout --repo p >/dev/null
  wrapper_from_code "$dir" add note-a "a plain note" --kind docs --repo p >/dev/null
  # Every spelling of a completion without proof is refused and leaves the row open.
  completion_refused "$dir" "bare done" "done" ship-a >/dev/null
  completion_refused "$dir" "close alias" "close" ship-a >/dev/null
  completion_refused "$dir" "task noun" "task" "done" ship-a >/dev/null
  completion_refused "$dir" "task noun and close" "task" "close" ship-a >/dev/null
  wrapper_from_code "$dir" add markdown "backend-value decoy" --kind docs >/dev/null \
    || fail "could not create backend-value decoy"
  completion_refused "$dir" "backend between done and id" done --backend markdown ship-a >/dev/null
  completion_refused "$dir" "backend between noun close and id" task close --backend=markdown ship-a >/dev/null
  completion_refused "$dir" "backend after target id" done ship-a --backend=markdown >/dev/null
  completion_refused "$dir" "split backend after target id" task close ship-a --backend markdown >/dev/null
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
  wrapper_from_code "$dir" add ship-d "ship d" --kind ship --repo p >/dev/null
  wrapper_from_code "$dir" add ship-e "ship e" --kind ship --repo p >/dev/null
  : > "$words"
  completion_refused "$dir" "empty words" "done" ship-d --drop-file "$words" >/dev/null
  ln -s "$words" "$dir/words-link.txt"
  printf 'Drop it; the premise is gone.\n' > "$words"
  completion_refused "$dir" "symbolic link words" "done" ship-d --drop-file "$dir/words-link.txt" >/dev/null
  completion_refused "$dir" "words with a pull request" "done" ship-d --drop-file "$words" --pr https://github.com/o/r/pull/9 >/dev/null
  out=$(wrapper_from_code "$dir" task done ship-d --drop-file "$words" 2>&1) \
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

test_completion_preserves_retained_captain_calls() {
  local dir fakebin words before spelling evidence out
  local command_args=() evidence_args=()
  dir=$(make_split retained-captain-call)
  fakebin=$(fm_fakebin "$dir")
  words="$dir/drop.txt"
  printf 'Discard the finished work.\n' > "$words"
  wrapper_from_code "$dir" add held-ship "retained ship call" --kind ship --repo p >/dev/null \
    || fail "could not create the retained ship"
  wrapper_from_code "$dir" add held-scout "retained scout call" --kind scout --repo p >/dev/null \
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
  for spelling in done close task-done task-close; do
    case "$spelling" in
      done|close) command_args=("$spelling") ;;
      task-done) command_args=(task done) ;;
      task-close) command_args=(task close) ;;
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
  local dir verb noun layout id stored out data
  local prefix=()
  dir=$(make_split public-restart-drop)
  printf 'Keep these exact captain words: café 航海.\n' > "$dir/words.txt"
  printf '%s\n' 'Body café 航海' '  dropped  ' ' Deliverable of the finished work: dropped ' \
    'Question: keep dropped as a word?' 'dropped later' > "$dir/body.txt"
  for layout in home relative; do
    if [ "$layout" = relative ]; then
      export FM_DATA_OVERRIDE=relocated/data
      data="$dir/code/relocated/data"
      mkdir -p "$data"
      empty_backlog "$data/backlog.md"
    else
      unset FM_DATA_OVERRIDE
      data="$dir/home/data"
    fi
    for verb in reopen start; do
      for noun in bare task; do
        id="$layout-$verb-$noun"
        if [ "$noun" = task ]; then prefix=(task "$verb"); else prefix=("$verb"); fi
        wrapper_from_code "$dir" add "$id" "$id" --kind scout >/dev/null \
          || fail "could not add restart fixture"
        wrapper_from_code "$dir" done "$id" --drop-file "$dir/words.txt" >/dev/null \
          || fail "could not drop restart fixture"
        wrapper_from_code "$dir" update "$id" --body-file "$dir/body.txt" >/dev/null \
          || fail "could not attach restart body"
        out=$(wrapper_from_code "$dir" "${prefix[@]}" "$id" 2>&1) \
          || fail "public $layout $noun $verb failed: $out"
        stored=$(wrapper_from_code "$dir" show "$id" --full) || fail "could not read restarted row"
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
  wrapper_from_code "$dir" add sole-drop "sole dropped body" --kind scout >/dev/null || fail "could not add sole drop"
  printf 'dropped\n' > "$dir/body"
  wrapper_from_code "$dir" update sole-drop --body-file "$dir/body" >/dev/null || fail "could not set sole body"
  wrapper_from_code "$dir" start sole-drop >/dev/null || fail "sole drop restart failed"
  assert_contains "$(wrapper_from_code "$dir" show sole-drop --full)" \
    "Historical captain disposition: dropped" "sole dropped body was not retired"
  wrapper_from_code "$dir" add failed-drop "failed body update" --kind scout >/dev/null || fail "could not add failed drop"
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
  wrapper_from_code "$dir" add leading-drop "unsupported leading backend" --kind scout >/dev/null \
    || fail "could not create leading backend fixture"
  printf 'Keep the original drop.\n' > "$dir/words"
  wrapper_from_code "$dir" done leading-drop --drop-file "$dir/words" >/dev/null \
    || fail "could not drop leading backend fixture"
  before=$(cat "$dir/home/data/backlog.md")
  for verb in done close start reopen; do
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
  wrapper_from_code "$dir" add custody "custody fixture" --kind scout >/dev/null || fail "could not add custody row"
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
    for verb in done close start reopen; do
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
        done) args=(done custody --report data/custody/report.md) ;;
        close) args=(task close custody --report data/custody/report.md) ;;
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
  wrapper_from_code "$dir" add hold-first "hold before completion" --kind ship >/dev/null || fail "could not add held row"
  wrapper_from_code "$dir" add completion-first "completion before hold" --kind ship >/dev/null || fail "could not add completion row"
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
  PATH="$fakebin:$PATH" wrapper_from_code "$dir" done completion-first --pr https://github.com/o/r/pull/9 \
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
    wrapper_from_code "$dir" add "body-$verb" "body $verb" --kind scout >/dev/null || fail "could not add body race row"
    wrapper_from_code "$dir" done "body-$verb" --drop-file "$dir/words" >/dev/null || fail "could not drop body race row"
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
  local dir fakebin real verb noun layout outcome id out rc stored data
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
      export FM_DATA_OVERRIDE=relocated/data
      data="$dir/code/relocated/data"
      mkdir -p "$data"
      empty_backlog "$data/backlog.md"
    else
      unset FM_DATA_OVERRIDE
      data="$dir/home/data"
    fi
    for verb in start reopen; do
      for noun in bare task; do
        if [ "$noun" = task ]; then prefix=(task "$verb"); else prefix=("$verb"); fi
        for outcome in before committed unreadable; do
          id="$layout-$verb-$noun-$outcome"
          wrapper_from_code "$dir" add "$id" "$id" --kind scout >/dev/null || fail "could not add restart failure fixture"
          wrapper_from_code "$dir" done "$id" --drop-file "$dir/words" >/dev/null || fail "could not drop restart failure fixture"
          rm -f "$dir/restart-failed"
          rc=0
          out=$(PATH="$fakebin:$PATH" FAKE_RESTART_VERB="$verb" FAKE_RESTART_OUTCOME="$outcome" \
            wrapper_from_code "$dir" "${prefix[@]}" "$id" 2>&1) || rc=$?
          expect_code 47 "$rc" "$layout $noun $verb $outcome failure"
          assert_contains "$out" "restart command failed" "$verb $outcome lost the original command error"
          stored=$(wrapper_from_code "$dir" show "$id" --full) || fail "could not read failed restart row"
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
    wrapper_from_code "$dir" add "$id" "$id" --kind "$kind" >/dev/null || fail "could not create landed fixture"
    out=$(wrapper_from_code "$dir" task done "$id" --drop-file "$dir/words" 2>&1) \
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
  out=$(wrapper_from_code "$dir" task done resumed-scout --report data/resumed-scout/report.md 2>&1) \
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
  wrapper_from_code "$dir" add bounded "bounded scout" --kind scout >/dev/null || fail "could not add bounded row"
  wrapper_from_code "$dir" add decoy "decoy docs" --kind docs >/dev/null || fail "could not add decoy row"
  wrapper_from_code "$dir" add ship-row "ship row" --kind ship >/dev/null || fail "could not add ship fixture"
  wrapper_from_code "$dir" add docs-row "docs row" --kind docs >/dev/null || fail "could not add docs fixture"
  wrapper_from_code "$dir" add retained-row "retained drop" --kind scout >/dev/null || fail "could not add retained fixture"
  printf 'dropped\n' > "$dir/body"
  wrapper_from_code "$dir" update bounded --body-file "$dir/body" >/dev/null || fail "could not set dropped provenance"
  printf 'Captain words stay private.\n' > "$dir/words"
  printf 'Replacement must never be retained.\n' > "$dir/replacement"
  wrapper_from_code "$dir" done retained-row --drop-file "$dir/words" >/dev/null || fail "could not retain original words"
  before=$(cat "$dir/home/data/backlog.md")
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
: > "$dir/sdk-called"
exec "$real" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
  for verb in done close start reopen; do
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
            [ "$verb" = done ] || continue
            args=(--pr --backend=markdown https://github.com/o/r/pull/9 ship-row)
            ;;
          consumed-note)
            [ "$verb" = done ] || continue
            args=(--note --backend=markdown docs-row ship-row)
            ;;
          consumed-keep)
            [ "$verb" = done ] || continue
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
  for verb in done close; do
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
  wrapper_from_code "$dir" add retained-row "retained drop" --kind scout >/dev/null || fail "could not add retained fixture"
  printf 'Original captain words café 航海.\n' > "$dir/words"
  wrapper_from_code "$dir" done retained-row --drop-file "$dir/words" >/dev/null || fail "could not retain original words"
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
    for verb in done close start reopen; do
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
  wrapper_from_code "$dir" add help-row "help scout" --kind scout >/dev/null || fail "could not create help fixture"
  printf 'dropped\n' > "$dir/body"
  wrapper_from_code "$dir" update help-row --body-file "$dir/body" >/dev/null || fail "could not set help body"
  printf 'Do not retain these words for help.\n' > "$dir/words"
  before=$(cat "$dir/home/data/backlog.md")
  for verb in done close start reopen; do
    for noun in bare task; do
      if [ "$noun" = task ]; then prefix=(task "$verb"); else prefix=("$verb"); fi
      out=$(wrapper_from_code "$dir" "${prefix[@]}" --help 2>&1) || fail "$noun $verb help failed: $out"
      assert_contains "$out" "usage: tasks-axi" "$noun $verb did not print production help"
      if [ "$verb" = done ] || [ "$verb" = close ]; then
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
    wrapper_from_code "$dir" add "$id" "$id" --kind docs >/dev/null || fail "could not add keep fixture"
    case "$form" in
      split) out=$(wrapper_from_code "$dir" done "$id" --keep 0 --note "Count zero" --json 2>&1) ;;
      equals) out=$(wrapper_from_code "$dir" task close "$id" --keep=0 --note="Count zero" --json 2>&1) ;;
      no-prune) out=$(wrapper_from_code "$dir" close "$id" --keep 0 --no-prune --note "Retain this row" --json 2>&1) ;;
    esac
    [ "$?" -eq 0 ] || fail "$form keep completion failed: $out"
    if [ "$form" = no-prune ]; then
      assert_grep "$id" "$dir/home/data/backlog.md" "--no-prune did not retain the completed row"
    else
      assert_not_contains "$(cat "$dir/home/data/backlog.md")" "$id" "--keep 0 did not prune the completed row"
      assert_grep "$id" "$dir/home/data/done-archive.md" "--keep 0 did not archive the completed row"
    fi
  done
  pass "documented numeric keep forms, no-prune, note, json, and optional noun preserve ordinary completion"
}

if [ "$#" -gt 0 ]; then
  for selected_test in "$@"; do
    case "$selected_test" in test_*) ;; *) fail "unknown test: $selected_test" ;; esac
    declare -F "$selected_test" >/dev/null || fail "unknown test: $selected_test"
    "$selected_test" || exit "$?"
  done
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
else
  echo "skip: tasks-axi not found; home-addressing cases not run"
fi
