#!/usr/bin/env bash
# Evidence driver (not a repository test). It runs the real bin/fm-teardown.sh
# against throwaway homes built by the repository's own fixture helpers, with a
# fake `gh` forge and a logging `treehouse` stub, and prints what an operator sees.
#
# Usage: drive-train-scenarios.sh <worktree root> [<alternate bin dir for teardown>]
set -u
ROOT_ARG=$1
ALT_BIN=${2:-}
# shellcheck disable=SC1090
. "$ROOT_ARG/tests/fm-teardown-helpers.sh" || exit 1
# The record-only fixture builder lives in the test file; take that one function.
eval "$(awk '/^train_absent_case\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "$ROOT_ARG/tests/fm-teardown.test.sh")"
[ -z "$ALT_BIN" ] || TEARDOWN="$ALT_BIN/fm-teardown.sh"
echo "teardown under test: $TEARDOWN"
echo

show() {  # <case-dir> <title> <expect>
  local case_dir=$1 title=$2 expect=$3 rc=0 before after
  before=$(git -C "$case_dir/wt" rev-parse HEAD 2>/dev/null || echo "(no copy)")
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  after=$(git -C "$case_dir/wt" rev-parse HEAD 2>/dev/null || echo "(no copy)")
  echo "=================================================================="
  echo "SCENARIO: $title"
  echo "EXPECT:   $expect"
  echo "member PR: ${TRAIN_MEMBER_URL:-}  listed head: ${TRAIN_MEMBER_HEAD:-}"
  echo "train PR:  ${TRAIN_URL:-}  train head: ${TRAIN_HEAD:-}"
  echo "copy HEAD before: $before"
  echo "--- exit code: $rc"
  echo "--- stderr:"
  sed "s|$TMP_ROOT|<sandbox>|g" "$case_dir/stderr"
  echo "--- pool (treehouse) calls:"
  if [ -e "$case_dir/treehouse.log" ]; then sed "s|$TMP_ROOT|<sandbox>|g" "$case_dir/treehouse.log"; else echo "(none)"; fi
  echo "--- task record still present: $([ -e "$case_dir/state/task-x1.meta" ] && echo yes || echo no)"
  echo "--- copy HEAD after: $after   copy dir present: $([ -d "$case_dir/wt" ] && echo yes || echo no)"
  if [ -e "$case_dir/data/backlog.md" ]; then
    echo "--- backlog rows for task-x1:"
    grep -n -A2 -F 'task-x1' "$case_dir/data/backlog.md" || true
  fi
  if [ -s "$case_dir/config/fleet-ledger" ]; then
    echo "--- fleet ledger task.closed rows:"
    ledger_closed_rows "$case_dir" 2>/dev/null || true
  fi
  echo "--- forge (fake gh) calls: $([ -e "$case_dir/gh-fixture/calls.log" ] && wc -l < "$case_dir/gh-fixture/calls.log" | tr -d ' ' || echo 0)"
  local verdict=MISMATCH
  case "$expect" in
    accept*) [ "$rc" = 0 ] && ! grep -q REFUSED "$case_dir/stderr" && [ ! -e "$case_dir/state/task-x1.meta" ] && verdict=AS-EXPECTED ;;
    unknown*) [ "$rc" != 0 ] && grep -q REFUSED "$case_dir/stderr" && grep -q "unknown, retry" "$case_dir/stderr" \
        && ! grep -q "ship deliverable is not landed" "$case_dir/stderr" \
        && [ ! -e "$case_dir/treehouse.log" ] && [ -e "$case_dir/state/task-x1.meta" ] && [ "$before" = "$after" ] && verdict=AS-EXPECTED ;;
    refuse*) [ "$rc" != 0 ] && grep -q REFUSED "$case_dir/stderr" && [ ! -e "$case_dir/treehouse.log" ] \
        && [ -e "$case_dir/state/task-x1.meta" ] && [ "$before" = "$after" ] && verdict=AS-EXPECTED ;;
  esac
  echo "RESULT: $verdict"
  echo
}

body() { train_body "$1" "$2"; }

# ---- accepts --------------------------------------------------------------
train_case A1-accept squash head
seed_backlog_in_flight "$TRAIN_CASE"
: > "$TRAIN_CASE/config/fleet-ledger"
show "$TRAIN_CASE" "A1 clean copy at the listed head; member CLOSED; train MERGED by squash and lists the member" "accept"

if [ -z "$ALT_BIN" ]; then
train_case A2-prerebase squash prerebase
show "$TRAIN_CASE" "A2 copy on pre-rebase commits whose patches the train carries" "accept"

train_case A3-inside squash inside
show "$TRAIN_CASE" "A3 copy at a later commit that is inside the verified train" "accept"

train_absent_case A4-record-only
show "$TRAIN_CASE" "A4 copy is gone (record-only route); recorded member PR CLOSED; verified train" "accept"

train_case A5-flat squash head "" flat
show "$TRAIN_CASE" "A5 pipeline rebased the train flat; every member commit has an equal patch in the train" "accept"

# ---- one fact changed per run: each must refuse and keep the copy ------------
train_case R1-train-open squash head
train_list "$TRAIN_CASE" 9 OPEN main "$TRAIN_HEAD" "$(body "$TRAIN_MEMBER_URL" "$TRAIN_MEMBER_HEAD")"
show "$TRAIN_CASE" "R1 the train PR is OPEN" "refuse"

train_case R2-train-closed squash head
train_list "$TRAIN_CASE" 9 CLOSED main "$TRAIN_HEAD" "$(body "$TRAIN_MEMBER_URL" "$TRAIN_MEMBER_HEAD")"
show "$TRAIN_CASE" "R2 the train PR is CLOSED and not merged" "refuse"

train_case R3-other-base squash head
train_list "$TRAIN_CASE" 9 MERGED develop "$TRAIN_HEAD" "$(body "$TRAIN_MEMBER_URL" "$TRAIN_MEMBER_HEAD")"
show "$TRAIN_CASE" "R3 the train merged into 'develop', not the task base 'main'" "refuse"

train_case R4-sha-off-by-one squash head
last=${TRAIN_MEMBER_HEAD: -1}; [ "$last" = 0 ] && flip=1 || flip=0
train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$(body "$TRAIN_MEMBER_URL" "${TRAIN_MEMBER_HEAD%?}$flip")"
show "$TRAIN_CASE" "R4 the train lists the member with a sha that differs in the last character" "refuse"

train_case R5-number-prefix squash head
train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$(body "${TRAIN_MEMBER_URL}0" "$TRAIN_MEMBER_HEAD")"
show "$TRAIN_CASE" "R5 the train lists only pull/70; the member is pull/7" "refuse"

train_case R6-short-sha squash head
train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$(body "$TRAIN_MEMBER_URL" "${TRAIN_MEMBER_HEAD:0:12}")"
show "$TRAIN_CASE" "R6 the train lists the member with a 12-character sha only" "refuse"

train_case R7-mention-only squash head
train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "Merge train. See also $TRAIN_MEMBER_URL which we closed."
show "$TRAIN_CASE" "R7 a merged PR only mentions the member URL (no 'at <sha>')" "refuse"

train_case R8-no-train squash head
printf '[]\n' > "$TRAIN_CASE/gh-fixture/list.json"
show "$TRAIN_CASE" "R8 no PR lists the member" "refuse"

train_case R9-extra-commit squash extra
show "$TRAIN_CASE" "R9 the copy holds one commit the train never merged" "refuse"

train_case R10-dirty squash head
printf 'scratch\n' > "$TRAIN_CASE/wt/scratch.txt"
show "$TRAIN_CASE" "R10 the copy has an uncommitted file" "refuse"

TRAIN_REVERT_MEMBER=1 train_case R11-reverted squash head
show "$TRAIN_CASE" "R11 the train contains the member commit but reverted its change before landing" "refuse"

train_case R12-ours-landing ours head
show "$TRAIN_CASE" "R12 the forge says MERGED, but the landing commit took no change in (ours merge)" "refuse"

train_case R13-member-open squash head
printf 'OPEN\n' > "$TRAIN_CASE/gh-fixture/member-state"
show "$TRAIN_CASE" "R13 the member PR is still OPEN and a merged train lists it" "refuse"

train_case R14-member-moved squash head
printf 'dddddddddddddddddddddddddddddddddddddddd\n' > "$TRAIN_CASE/gh-fixture/member-head"
show "$TRAIN_CASE" "R14 the member PR head moved after the train listed it" "refuse"

train_absent_case R15-record-only-wrong-sha
train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$(body "$TRAIN_MEMBER_URL" dddddddddddddddddddddddddddddddddddddddd)"
show "$TRAIN_CASE" "R15 record-only route; the train lists another sha" "refuse"

train_absent_case R16-record-only-open-train
train_list "$TRAIN_CASE" 9 OPEN main "$TRAIN_HEAD" "$(body "$TRAIN_MEMBER_URL" "$TRAIN_MEMBER_HEAD")"
show "$TRAIN_CASE" "R16 record-only route; the train is OPEN" "refuse"

# ---- failed reads: unknown, never accepted, never 'not landed' ---------------
train_case U1-search-fails squash head
: > "$TRAIN_CASE/gh-fixture/list.fail"
show "$TRAIN_CASE" "U1 the forge search for the train fails" "unknown"

TRAIN_PREFETCH_TRAIN=0 train_case U2-fetch-fails squash head
git -C "$TRAIN_CASE/origin.git" update-ref -d refs/pull/9/head
show "$TRAIN_CASE" "U2 the train head cannot be fetched" "unknown"

train_absent_case U3-record-only-search-fails
: > "$TRAIN_CASE/gh-fixture/list.fail"
show "$TRAIN_CASE" "U3 record-only route; the forge search fails" "unknown"
fi
