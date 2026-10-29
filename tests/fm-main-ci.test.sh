#!/usr/bin/env bash
# Behavioral tests for bin/fm-main-ci.sh.
#
# CI coalesces main pushes, so a superseded commit has no run of its own and must
# read as covered by the newest completed run that contains it. The fake gh serves
# a workflow run list and the compare API over one linear history, newest run
# first, the way the real endpoints answer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-main-ci.sh"
TMP_ROOT=$(fm_test_tmproot fm-main-ci-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 \
  || fail "these tests parse API-shaped JSON with the real jq, which was not found"

c0=$(printf '0%.0s' {1..40})
c1=$(printf '1%.0s' {1..40})
c2=$(printf '2%.0s' {1..40})
c3=$(printf '3%.0s' {1..40})
FAKE_DIR="$TMP_ROOT/api"
mkdir -p "$FAKE_DIR"
printf '%s\n' "$c0" "$c1" "$c2" "$c3" > "$FAKE_DIR/history"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FAKE_API_DIR/unreadable" ] || { echo "gh: HTTP 502" >&2; exit 1; }
[ "$1" = api ] || { echo "unexpected gh call: $*" >&2; exit 91; }
case "$2" in
  repos/o/r/actions/workflows/ci.yml/runs\?branch=main\&event=push\&per_page=100)
    cat "$FAKE_API_DIR/runs.json"
    ;;
  repos/o/r/compare/*...*)
    spec=${2#repos/o/r/compare/}
    base=${spec%%...*}
    head=${spec#*...}
    base_at=$(grep -n "^$base\$" "$FAKE_API_DIR/history" | cut -d: -f1)
    head_at=$(grep -n "^$head\$" "$FAKE_API_DIR/history" | cut -d: -f1)
    [ -n "$base_at" ] && [ -n "$head_at" ] || { echo "gh: not found" >&2; exit 1; }
    if [ "$head_at" -gt "$base_at" ]; then status=ahead
    elif [ "$head_at" -lt "$base_at" ]; then status=behind
    else status=identical; fi
    printf '{"status":"%s"}\n' "$status"
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 91
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

# runs <id:head:status:conclusion>... in newest-first order.
set_runs() {
  local spec id head status conclusion rows=
  for spec in "$@"; do
    IFS=: read -r id head status conclusion <<<"$spec"
    rows="$rows${rows:+,}{\"id\":$id,\"head_sha\":\"$head\",\"status\":\"$status\",\"conclusion\":$([ -n "$conclusion" ] && printf '"%s"' "$conclusion" || printf null)}"
  done
  printf '{"total_count":%s,"workflow_runs":[%s]}\n' "$#" "$rows" > "$FAKE_DIR/runs.json"
}

judge() { # sha
  FAKE_API_DIR="$FAKE_DIR" PATH="$FAKEBIN:$PATH" "$SCRIPT" --repo o/r "$1"
}

test_superseded_commit_reads_green_from_the_later_passing_run() {
  local out
  set_runs "902:$c2:completed:success" "900:$c0:completed:success"
  out=$(judge "$c1") || fail "superseded commit was refused"
  assert_equals "state=green run=902 head=$c2" "$out" "C1 must read green from C2's passing run"
  pass "a superseded commit reads green from the later passing run"
}

test_superseded_commit_reads_red_from_the_later_failing_run() {
  local out
  set_runs "902:$c2:completed:failure" "900:$c0:completed:success"
  out=$(judge "$c1") || fail "superseded commit was refused"
  assert_equals "state=red run=902 head=$c2" "$out" "C1 must read red when C2's run failed"
  pass "a superseded commit reads red from the later failing run"
}

test_commit_with_no_run_yet_reads_pending() {
  local out
  set_runs "900:$c0:completed:success"
  out=$(judge "$c1") || fail "unrun commit was refused"
  assert_equals "state=pending run=none head=none" "$out" "a commit no run contains must read pending"
  set_runs
  out=$(judge "$c1") || fail "empty run list was refused"
  assert_equals "state=pending run=none head=none" "$out" "no runs at all must read pending"
  pass "a commit no completed run contains reads pending"
}

test_queued_and_running_runs_are_pending() {
  local out
  set_runs "902:$c2:in_progress:" "901:$c1:queued:" "900:$c0:completed:success"
  out=$(judge "$c1") || fail "running commit was refused"
  assert_equals "state=pending run=none head=none" "$out" "a commit whose runs are queued or running must read pending"
  pass "queued and running runs read pending"
}

test_cancelled_replacement_is_covered_not_red() {
  local out
  set_runs "902:$c2:completed:success" "901:$c1:completed:cancelled" "900:$c0:completed:success"
  out=$(judge "$c1") || fail "cancelled replacement was refused"
  assert_equals "state=green run=902 head=$c2" "$out" "a replaced (cancelled) run must read as covered by the later run"
  set_runs "902:$c2:in_progress:" "901:$c1:completed:cancelled" "900:$c0:completed:success"
  out=$(judge "$c1") || fail "cancelled replacement was refused"
  assert_equals "state=pending run=none head=none" "$out" "a cancelled run is never red or a verdict; the later run is still pending"
  pass "a cancelled replaced run reads as covered or pending, never red"
}

test_own_completed_run_beats_a_later_running_run() {
  local out
  set_runs "902:$c2:in_progress:" "901:$c1:completed:success"
  out=$(judge "$c1") || fail "own run was refused"
  assert_equals "state=green run=901 head=$c1" "$out" "the newest completed run containing C1 decides while C2 runs"
  set_runs "902:$c2:in_progress:" "901:$c1:completed:failure"
  out=$(judge "$c1") || fail "own run was refused"
  assert_equals "state=red run=901 head=$c1" "$out" "the newest completed run containing C1 decides while C2 runs"
  pass "the newest completed run containing the commit decides while a later run is running"
}

test_older_runs_never_judge_a_newer_commit() {
  local out
  set_runs "900:$c0:completed:success"
  out=$(judge "$c3") || fail "newer commit was refused"
  assert_equals "state=pending run=none head=none" "$out" "a run on an ancestor says nothing about a newer commit"
  pass "a run on an ancestor never judges a newer commit"
}

test_newest_containing_run_wins_over_an_older_failure() {
  local out
  set_runs "903:$c3:completed:success" "902:$c2:completed:failure" "900:$c0:completed:success"
  out=$(judge "$c1") || fail "red-then-green history was refused"
  assert_equals "state=green run=903 head=$c3" "$out" "the newest completed run containing C1 decides, even over a failing run between them"
  pass "the newest completed containing run wins"
}

test_unreadable_github_and_bad_usage_are_refusals() {
  local status=0 out
  : > "$FAKE_DIR/unreadable"
  set_runs "900:$c0:completed:success"
  out=$(judge "$c1" 2>&1) || status=$?
  rm -f "$FAKE_DIR/unreadable"
  [ "$status" -eq 1 ] || fail "an unreadable forge must exit 1, got $status: $out"
  assert_not_contains "$out" 'state=' "an unreadable forge must not print a state"
  status=0
  FAKE_API_DIR="$FAKE_DIR" PATH="$FAKEBIN:$PATH" "$SCRIPT" "$c1" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail "a missing --repo must exit 2, got $status"
  status=0
  FAKE_API_DIR="$FAKE_DIR" PATH="$FAKEBIN:$PATH" "$SCRIPT" --repo o/r main >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail "a branch name is not a commit id and must exit 2, got $status"
  pass "an unreadable forge exits 1 and bad usage exits 2"
}

test_superseded_commit_reads_green_from_the_later_passing_run
test_superseded_commit_reads_red_from_the_later_failing_run
test_commit_with_no_run_yet_reads_pending
test_queued_and_running_runs_are_pending
test_cancelled_replacement_is_covered_not_red
test_own_completed_run_beats_a_later_running_run
test_older_runs_never_judge_a_newer_commit
test_newest_containing_run_wins_over_an_older_failure
test_unreadable_github_and_bad_usage_are_refusals
