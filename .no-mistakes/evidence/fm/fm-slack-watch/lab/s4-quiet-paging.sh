#!/usr/bin/env bash
# S4: armed check stays silent on config typos; idle home makes zero Slack requests; >100-reply thread paging.
set -uo pipefail
. "$(dirname "$0")/lab.sh"
FAILED=0
lab_start || exit 1
trap lab_stop EXIT
watcher_run_check() {
  ( . "$REPO/bin/fm-pr-lib.sh"; . "$REPO/bin/fm-check-lib.sh"
    fm_custom_check_snapshot_prepare "$FM_STATE_OVERRIDE" slack || { echo "WATCHER-REJECTED-CHECK"; exit 0; }
    out=$(timeout 30 bash "$FM_CUSTOM_CHECK_SNAPSHOT" 2>/dev/null); fm_custom_check_snapshot_cleanup
    printf '%s' "$out"; exit 0 )
}

step "S4.1 armed check never wakes firstmate for .env typos (every 5-minute sweep stays silent)"
new_home allowlist
"$REPO/bin/fm-slack-check.sh" arm >/dev/null 2>&1 || bad "arm failed"
mirror >/dev/null
base=$(requests_total)
for typo in "FM_SLACK_ALLOWED_AUTHORS=oops" "FM_SLACK_DM_USER=not-a-member" "FM_SLACK_POLL_MAX_ANSWERS=0" "FM_SLACK_ALLOWED_AUTHORS="; do
  cp "$FM_HOME/.env" "$LABROOT/env.bak"
  printf '%s\n' "$typo" >> "$FM_HOME/.env"
  out1=$(watcher_run_check); out2=$(watcher_run_check)
  expect_eq "[$out1][$out2]" "[][]" "armed sweep x2 with $typo"
  cp "$LABROOT/env.bak" "$FM_HOME/.env"
done
expect_eq "$(requests_total)" "$base" "typo'd sweeps sent no Slack request"

step "S4.2 a home with no open held decision and no tracked thread makes zero Slack requests"
new_home unmatched
before=$(requests_total)
out=$(poll 2>&1); o2=$(mirror 2>&1); o3=$("$REPO/bin/fm-slack-check.sh" check 2>&1)
expect_eq "[$out][$o2][$o3]" "[][][]" "idle poll/mirror/check silent"
expect_eq "$(requests_total)" "$before" "zero requests while idle"

step "S4.3 thread with 130 replies: the owner's reply on page 2 of conversations.replies is still found"
new_home typed-reply
mirror >/dev/null; T=$(thread_ts typed-call)
for i in $(seq 1 130); do reply "$T" "noise $i" "user=U0STRANGER9"; done
reply "$T" "3" "user=$OWNER"
admin log | python3 -c 'import json,sys; print("replies requests before poll:", sum(1 for r in json.load(sys.stdin) if r["method"]=="conversations.replies"))'
out=$(poll); echo "poll: [$out]"
expect_has "$out" 'closed: typed-call' "owner reply beyond page 1 delivered"
expect_eq "$(answer_line typed-call)" abort "option 3 value recorded"
[ "$FAILED" = 0 ] && echo "S4 RESULT: ALL PASS" || echo "S4 RESULT: FAILURES"
exit $FAILED
