#!/usr/bin/env bash
# Manual end-to-end drive of the Slack watch operator commands at the change head.
# Every Slack call goes to the checked-in replay double (--replay); no socket is opened,
# no real token exists, and every home is a fresh mktemp directory removed at the end.
# Usage: drive-slack-watch.sh <repo-worktree>
set -uo pipefail
ROOT=${1:?repo worktree}
FIX="$ROOT/tests/fixtures/slack"
CAPTAIN="$ROOT/bin/fm-captain-hold.sh"
HELPER="$ROOT/tests/fm_slack_watch_test.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-slack-drive.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
step() { printf '\n$ %s\n' "$*"; }
run() {  # echo the command, run it, show output and exit code
  step "$*"
  out=$("$@" 2>&1); rc=$?
  printf '%s\n[exit %s]\n' "$out" "$rc"
}
new_home() {
  HOME_DIR=$(mktemp -d "$TMP/home.XXXXXX")
  bash "$FIX/make-home.sh" "$1" "$HOME_DIR" >/dev/null
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
  printf '\n----- fresh disposable home (fixture %s) -----\n' "$1"
}
S() { printf '%s/slack-watch/state.json' "$FM_STATE_OVERRIDE"; }
R() { python3 "$HELPER" replay-file "$FM_STATE_OVERRIDE/slack-watch"; }
threads() { python3 "$HELPER" thread-count "$(S)" "${1:-}"; }
pending() { python3 "$HELPER" pending-count "$(S)"; }
ts_of() { python3 "$HELPER" thread-field "$(S)" "$1" ts; }
owner() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["user"])' "$(S)"; }
open_rc() { "$CAPTAIN" open "$1" >/dev/null 2>&1; printf '%s' $?; }
show() { printf '  observed: %s\n' "$*"; }

echo '===== SC1: --help names the retarget order and the last resort ====='
new_home arming
run "$ROOT/bin/fm-slack-check.sh" --help

echo; echo '===== SC2: arm refuses before the source is bound (binding order) ====='
new_home arming
run "$CAPTAIN" binding slack-dm
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/arm.json"
show "check files registered: $(ls "$FM_STATE_OVERRIDE" | grep -c '^slack.check' || true)"
run "$CAPTAIN" bind slack-dm
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/arm.json"
show "check files registered: $(ls "$FM_STATE_OVERRIDE" | grep -c '^slack.check' || true)"

echo; echo '===== SC3: bind, arm, mirror, owner types an option, poll records one answer ====='
new_home mirror
run "$CAPTAIN" bind slack-dm
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/mirror/transcript.json"
run "$ROOT/bin/fm-slack-mirror.sh" --replay "$FIX/mirror/transcript.json"
show "threads tracked: $(threads)"
python3 "$HELPER" reply "$(R)" "$(ts_of open-a)" 900.100001 U0TESTOWNER 'ship it'
step "owner U0TESTOWNER replies 'ship it' in the open-a thread"
run "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/mirror/transcript.json"
show "open-a open? rc=$(open_rc open-a) (1 = closed)"
show "thread texts: $(python3 "$HELPER" thread-texts "$(R)" "$(ts_of open-a)" | tr '\n' '|' )"

echo; echo '===== SC4 (adversarial): a reply from a non-allowlisted author is never an answer ====='
python3 "$HELPER" reply "$(R)" "$(ts_of open-b)" 900.100002 U0STRANGER9 '1'
step "stranger U0STRANGER9 replies '1' in the open-b thread"
run "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/mirror/transcript.json"
show "open-b open? rc=$(open_rc open-b) (0 = still open)"

echo; echo '===== SC5: retarget with an unread owner reply refuses, keeps all threads, then drains and succeeds ====='
new_home mirror
"$CAPTAIN" bind slack-dm >/dev/null
"$ROOT/bin/fm-slack-mirror.sh" --replay "$FIX/mirror/transcript.json" >/dev/null
python3 "$HELPER" reply "$(R)" "$(ts_of open-a)" 900.999999 U0TESTOWNER 'ship from old DM'
step "owner replies in open-a, then FM_SLACK_DM_USER changes"
run "$ROOT/bin/fm-slack-check.sh" disarm
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" retarget --replay "$FIX/mirror/transcript.json"
show "owner now: $(owner); threads: $(threads); pending: $(pending); open-a open rc=$(open_rc open-a)"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/mirror/transcript.json"
step "restore the old value and poll"
run "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/mirror/transcript.json"
show "pending: $(pending); open-a open rc=$(open_rc open-a)"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" retarget --replay "$FIX/mirror/transcript.json"
python3 "$HELPER" move-transcript "$FIX/mirror/transcript.json" "$TMP/moved.json" D0NEWOWNER01
old_posts=$(grep chat.postMessage "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" | grep -c D0123456789 || true)
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" arm --replay "$TMP/moved.json"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-mirror.sh" --replay "$TMP/moved.json"
show "new-owner threads: $(threads); posts to old DM D0123456789 before/after retarget mirror: $old_posts/$(grep chat.postMessage "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" | grep -c D0123456789 || true); posts to new DM D0NEWOWNER01: $(grep chat.postMessage "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" | grep -c D0NEWOWNER01 || true)"

echo; echo '===== SC6 (adversarial): owner reply on a card whose call state can never be probed (bad$id) ====='
new_home mirror
"$CAPTAIN" bind slack-dm >/dev/null
"$ROOT/bin/fm-slack-mirror.sh" --replay "$FIX/mirror/transcript.json" >/dev/null
python3 "$HELPER" reply "$(R)" "$(ts_of 'bad$id')" 900.999997 U0TESTOWNER '1'
step "owner replies '1' on the uncertain bad\$id card"
run "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/mirror/transcript.json"
show "pending after poll: $(pending) (poll stages nothing it cannot verify)"
run "$ROOT/bin/fm-slack-check.sh" disarm
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" retarget --replay "$FIX/mirror/transcript.json"
show "owner now: $(owner); threads: $(threads)"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" retarget --replay "$FIX/mirror/transcript.json"
show "second retarget: still the same named refusal (no silent clear)"
step "documented last resort: read the thread by hand, disarm, remove state/slack-watch/"
rm -rf "$FM_STATE_OVERRIDE/slack-watch"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" retarget --replay "$TMP/moved.json"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" arm --replay "$TMP/moved.json"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-mirror.sh" --replay "$TMP/moved.json"
show "after reset: threads $(threads); posts to new DM D0NEWOWNER01: $(grep chat.postMessage "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" | grep -c D0NEWOWNER01 || true); posts to old DM D0123456789: $(grep chat.postMessage "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" | grep -c D0123456789 || true)"

echo; echo '===== SC7 (adversarial): retarget when a tapper users.info lookup fails refuses and keeps the tap ====='
new_home reaction-answer
"$CAPTAIN" bind slack-dm >/dev/null
"$ROOT/bin/fm-slack-mirror.sh" --replay "$FIX/reaction-answer/transcript.json" >/dev/null
python3 "$HELPER" fail-call "$(R)" users.info 400
step "replay double: users.info now fails with HTTP 400"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" retarget --replay "$FIX/reaction-answer/transcript.json"
show "reaction-call threads: $(threads reaction-call); reaction-call open rc=$(open_rc reaction-call)"
python3 "$HELPER" clear-fail "$(R)" users.info
step "users.info recovers; old owner polls"
run "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/reaction-answer/transcript.json"
show "reaction-call open rc=$(open_rc reaction-call)"

echo; echo '===== SC10: the plain poll (not retarget) still skips a tap whose users.info lookup fails, unchanged ====='
new_home reaction-answer
"$CAPTAIN" bind slack-dm >/dev/null
"$ROOT/bin/fm-slack-mirror.sh" --replay "$FIX/reaction-answer/transcript.json" >/dev/null
python3 "$HELPER" fail-call "$(R)" users.info 400
step "replay double: users.info now fails with HTTP 400"
run "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/reaction-answer/transcript.json"
show "reaction-call open rc=$(open_rc reaction-call) (0 = still open); pending: $(pending)"
python3 "$HELPER" clear-fail "$(R)" users.info
step "users.info recovers"
run "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/reaction-answer/transcript.json"
show "reaction-call open rc=$(open_rc reaction-call)"

echo; echo '===== SC11: the standing check delivers only while armed; after disarm it is silent ====='
new_home typed-reply
"$CAPTAIN" bind slack-dm >/dev/null
step "disarmed (never armed): standing check with an owner reply waiting"
run "$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/typed-reply/transcript.json"
show "typed-call open rc=$(open_rc typed-call) (0 = still open)"
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/typed-reply/transcript.json"
run "$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/typed-reply/transcript.json"
show "typed-call open rc=$(open_rc typed-call) (1 = closed)"
run "$ROOT/bin/fm-slack-check.sh" disarm

echo; echo '===== SC8: disarm works with a broken config ====='
new_home arming
"$CAPTAIN" bind slack-dm >/dev/null
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/arm.json"
run env SLACK_BOT_TOKEN= FM_SLACK_ALLOWED_AUTHORS=oops "$ROOT/bin/fm-slack-check.sh" disarm
show "check files left: $(ls "$FM_STATE_OVERRIDE" | grep -c '^slack.check' || true)"

echo; echo '===== SC9 (adversarial): nothing is posted to a DM that is not the owner DM ====='
new_home mirror
"$CAPTAIN" bind slack-dm >/dev/null
"$ROOT/bin/fm-slack-mirror.sh" --replay "$FIX/mirror/transcript.json" >/dev/null
python3 "$HELPER" split-transcript "$FIX/mirror/transcript.json" "$TMP/other-dm.json" D0OTHERDM01 D0123456789
python3 "$HELPER" set-state "$(S)" channel D0OTHERDM01
(cd "$FM_HOME" && tasks-axi add late-call "Late call" --kind captain --repo sample >/dev/null)
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z "$CAPTAIN" hold late-call --reason Late >/dev/null
step "stored channel tampered to D0OTHERDM01; a new call is held"
run "$ROOT/bin/fm-slack-mirror.sh" --replay "$TMP/other-dm.json"
show "writes to D0OTHERDM01: $(grep -c D0OTHERDM01 "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" || true)"

echo; echo '===== done ====='
