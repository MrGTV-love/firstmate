#!/usr/bin/env bash
# Prints the real bin/fm-control.sh output for adopt/interrupt against the
# fake-backend fixtures from tests/fm-control-relaunch-backends.test.sh.
# Usage (from the run worktree): bash <this> 
W=$PWD
. "$W/tests/fm-control-relaunch-helpers.sh"
CASES_SRC=$(mktemp "${TMPDIR:-/tmp}/adopt-cases.XXXXXX")
sed -e '/^\. "\$(dirname/d' -e '/^control_relaunch_run "\$@"$/d' "$W/tests/fm-control-relaunch-backends.test.sh" > "$CASES_SRC"
. "$CASES_SRC"; rm -f "$CASES_SRC"
show() { printf '\n$ fm-control.sh %s %s\n' "$2" "$3"; local out rc=0; out=$(FM_CONTROL_SETTLE_WAIT=.05 "$1" "$DIR" "$ID" "$3" 2>&1) || rc=$?; printf '%s\n[exit=%s]\n' "$out" "$rc"; }
rec() { printf 'record: '; jq -c . "$DIR/home/state/$ID.omp-session.json" | sed "s#$DIR#<case>#g"; }
echo "=== Scenario: stuck record (dead pid, empty current_session_file) -> adopt -> interrupt"
prepare_omp_adoption transcript-matching; DIR=$HERDR_CASE_DIR ID=$HERDR_CASE_ID
rec; show run_control "$ID" interrupt; show run_continuation_control "$ID" adopt; rec
echo "herdr send-* calls during adopt: $(grep -c 'send-' "$DIR/fake/herdr-log" || true)"
show run_control "$ID" interrupt
echo; echo "=== Adversarial: cwd inside another task's worktree"
prepare_omp_adoption transcript-foreign; DIR=$HERDR_CASE_DIR ID=$HERDR_CASE_ID
printf 'worktree=%s\n' "$DIR/wt/subdirectory" > "$DIR/home/state/foreign.meta"
show run_continuation_control "$ID" adopt; rec
echo; echo "=== Adversarial: two metas claim the pane"
prepare_omp_adoption transcript-dup; DIR=$HERDR_CASE_DIR ID=$HERDR_CASE_ID
printf 'window=fmlab:%%7\nworktree=%s\nremote_host=\n' "$DIR" > "$DIR/home/state/duplicate.meta"
show run_continuation_control "$ID" adopt
echo; echo "=== Adversarial: ambiguous foreground"
prepare_omp_adoption transcript-amb; DIR=$HERDR_CASE_DIR ID=$HERDR_CASE_ID
: > "$DIR/fake/adoption-ambiguous"; show run_continuation_control "$ID" adopt
echo; echo "=== Adversarial: record spawn_gen differs from meta"
prepare_omp_adoption transcript-gen; DIR=$HERDR_CASE_DIR ID=$HERDR_CASE_ID
R="$DIR/home/state/$ID.omp-session.json"; jq '.spawn_gen="different"' "$R" > "$R.new" && mv "$R.new" "$R"
show run_continuation_control "$ID" adopt; rec
echo; echo "=== Adversarial: recorded PID is a live omp process"
prepare_omp_adoption transcript-liveomp; DIR=$HERDR_CASE_DIR ID=$HERDR_CASE_ID
R="$DIR/home/state/$ID.omp-session.json"; start_stand_in omp
jq --argjson pid "$STAND_IN_PID" '.pid=$pid' "$R" > "$R.new" && mv "$R.new" "$R"
show run_continuation_control "$ID" adopt; stop_stand_in
echo; echo "=== Recorded PID reused by a live claude process (not omp): repair proceeds"
prepare_omp_adoption transcript-claude; DIR=$HERDR_CASE_DIR ID=$HERDR_CASE_ID
R="$DIR/home/state/$ID.omp-session.json"; start_stand_in claude
jq --argjson pid "$STAND_IN_PID" '.pid=$pid' "$R" > "$R.new" && mv "$R.new" "$R"
show run_continuation_control "$ID" adopt; stop_stand_in; rec
echo; echo "=== Worker caller (FM_TASK_ID set) refused"
prepare_omp_adoption transcript-worker; DIR=$HERDR_CASE_DIR ID=$HERDR_CASE_ID
FM_FAKE_TASK_ID=$ID show run_continuation_control "$ID" adopt
