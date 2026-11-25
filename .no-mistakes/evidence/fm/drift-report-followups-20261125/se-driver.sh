#!/usr/bin/env bash
# se-driver.sh <tree> <sampled-out> <marker-out>: run the real session-end relaunch scan on a dead lane, with the
# control command replaced by a recorder that replays a real fm-control relaunch output, and print the wake.
TREE=$1 SAMPLED=$(cat "$2") MARKER=$(cat "$3")
set -u
. "$TREE/tests/lib.sh"
. "$TREE/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-se-live); mkdir -p "$TMP_ROOT"; export FM_HOME="$TMP_ROOT"
ROOT=$TREE
eval "$(sed -n '/^make_tmux() {/,/^# <name> -> dir/p' "$TREE/tests/fm-session-end-relaunch.test.sh")"
scan() { # <name> <rc> <out>
  local dir="$TMP_ROOT/$1" fakebin recorder
  add_lane "$dir" lane; fakebin=$(make_tmux "$dir"); recorder=$(make_recorder "$dir"); : > "$dir/control.log"
  env FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WAKE_QUEUE="$dir/state/.wake-queue" \
    FM_TEST_SEAM=1 FM_SESSION_END_CONTROL="$recorder" FM_SESSION_END_CONTROL_LOG="$dir/control.log" \
    FM_SESSION_END_CONTROL_RC="$2" FM_SESSION_END_CONTROL_OUT="$3" FM_FAKE_TMUX_LOG="$dir/tmux.log" \
    bash -c 'export PATH="$3:$PATH"; . "$1/bin/fm-session-end-relaunch-lib.sh"; fm_session_end_relaunch_scan "$2/state"; printf "%s" "$FM_SESSION_END_WAKE" > "$2/wake"' _ "$TREE" "$dir" "$fakebin"
  printf '%s\n' "--- control called with: $(cat "$dir/control.log")"
  printf '%s\n' "--- wake:"; cat "$dir/wake"; echo
  printf '%s\n' "--- durable $dir/state/lane.relaunch-drift first line: $(head -n1 "$dir/state/lane.relaunch-drift" 2>/dev/null)"
}
echo "===== W1 relaunch printed a real sampled report ====="; scan sampled 0 "$SAMPLED"
echo; echo "===== W2 relaunch printed a real complete report whose path holds ': sampled: ' ====="; scan marker 0 "$MARKER"
echo; echo "===== W3 refused relaunch with that complete report ====="
scan marker-refused 1 "$(printf '%s\n' "$MARKER" 'error: slot provisioning refused: dirty_worktree; preserve and reconcile')"
fm_test_remove_tree "$TMP_ROOT" 2>/dev/null || rm -rf "$TMP_ROOT"
