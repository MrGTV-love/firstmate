#!/usr/bin/env bash
# Manual drive of the real Slack watch CLIs in a throwaway home, Slack replaced by the replay double.
# No live Slack call, no real token. Usage: drive-slack-cli.sh <worktree>
set -uo pipefail
ROOT=$1; FIX="$ROOT/tests/fixtures/slack"; CAPTAIN="$ROOT/bin/fm-captain-hold.sh"; HELPER="$ROOT/tests/fm_slack_watch_test.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-slack-drive.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
new_home() { HOME_DIR=$(mktemp -d "$TMP/home.XXXXXX"); bash "$FIX/make-home.sh" "$1" "$HOME_DIR" >/dev/null
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"; cd "$HOME_DIR"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[rc=%s]\n' "$?"; }
st() { printf '%s/slack-watch/state.json' "$FM_STATE_OVERRIDE"; }
replay() { python3 "$HELPER" replay-file "$FM_STATE_OVERRIDE/slack-watch"; }
field() { python3 "$HELPER" thread-field "$(st)" "$1" "$2"; }
pending() { python3 "$HELPER" pending-count "$(st)"; }
holdstate() { set +e; "$CAPTAIN" open "$1" >/dev/null 2>&1; local rc=$?; [ "$rc" = 0 ] && echo "$1: hold OPEN" || echo "$1: hold CLOSED (open rc=$rc)"; }
T="$FIX/mirror/transcript.json"

echo "=== S1 ACT-1 rehearsal: bind, arm, mirror, owner reply, poll, disarm ==="
new_home mirror
"$CAPTAIN" unbind slack-dm >/dev/null   # fixture homes start bound; start this one unbound like a fresh home
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$T"            # before bind: must refuse
echo "registered slack check files after refused arm: $(ls "$FM_STATE_OVERRIDE" | grep -c '^slack.check')"
run "$CAPTAIN" bind slack-dm
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$T"
run "$ROOT/bin/fm-slack-mirror.sh" --replay "$T"
ts=$(field open-a ts); echo "open-a card thread ts=$ts"
python3 "$HELPER" reply "$(replay)" "$ts" 900.000101 U0TESTOWNER "ship it"
run "$ROOT/bin/fm-slack-check.sh" check --replay "$T"
holdstate open-a
echo "recorded answer on open-a: $("$ROOT/bin/fm-tasks-axi.sh" show open-a --full | grep -o 'Answer: [^"]*' | sed 's/\\n.*//')"
echo "thread posts on open-a:"; python3 "$HELPER" thread-texts "$(replay)" "$ts" | tail -n 3
echo "token printed anywhere in outbound/state?"; grep -rl fixture-token-not-a-secret "$FM_STATE_OVERRIDE" || echo "no"
run "$ROOT/bin/fm-slack-check.sh" disarm
ls "$FM_STATE_OVERRIDE" | grep -c '^slack.check' | sed 's/^/registered slack check files after disarm: /'

echo; echo "=== S2 adversarial: reply from a non-allowlisted author never answers ==="
new_home mirror; "$CAPTAIN" bind slack-dm >/dev/null; "$ROOT/bin/fm-slack-mirror.sh" --replay "$T" >/dev/null
ts=$(field open-b ts)
python3 "$HELPER" reply "$(replay)" "$ts" 900.000201 U0STRANGER01 "ship it"
run "$ROOT/bin/fm-slack-poll.sh" --replay "$T"
holdstate open-b
echo "stranger reply was read (seen-count on open-b thread): $(python3 "$HELPER" seen-count "$(st)" "$ts")"
echo "-- positive control: the allowlisted owner replies on the same thread --"
python3 "$HELPER" reply "$(replay)" "$ts" 900.000202 U0TESTOWNER "wait"
run "$ROOT/bin/fm-slack-poll.sh" --replay "$T"
holdstate open-b
echo "recorded answer on open-b: $("$ROOT/bin/fm-tasks-axi.sh" show open-b --full | grep -o 'Answer: [^"]*' | sed 's/\\n.*//')"

echo; echo "=== S3 adversarial: unbound source feeds nothing ==="
new_home typed-reply
"$CAPTAIN" unbind slack-dm >/dev/null
run "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/typed-reply/transcript.json"
holdstate typed-call
"$CAPTAIN" bind slack-dm >/dev/null
run "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/typed-reply/transcript.json"
holdstate typed-call

echo; echo "=== S4 disarm works with broken config ==="
new_home arming; "$CAPTAIN" bind slack-dm >/dev/null
"$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/arm.json" >/dev/null
run env SLACK_BOT_TOKEN= FM_SLACK_ALLOWED_AUTHORS=oops "$ROOT/bin/fm-slack-check.sh" disarm

echo; echo "=== S5 changed owner DM: poll/arm refuse, retarget refuses with pending work, unchanged no-op, drain then retarget ==="
new_home mirror; "$CAPTAIN" bind slack-dm >/dev/null; "$ROOT/bin/fm-slack-mirror.sh" --replay "$T" >/dev/null
python3 "$HELPER" move-transcript "$T" "$TMP/moved.json" D0NEWOWNER01
echo "postMessage sends to old DM before the change: $(grep chat.postMessage "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" | grep -c D0123456789)"
run "$ROOT/bin/fm-slack-check.sh" retarget --replay "$T"
python3 "$HELPER" stage-notice "$(st)" 900.000001 open-a 10
echo "pending rows: $(pending)"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-poll.sh" --replay "$TMP/moved.json"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" arm --replay "$TMP/moved.json"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" retarget --replay "$TMP/moved.json"
echo "pending rows after refused retarget: $(pending)"
echo "-- documented drain: old value restored, poll until the journal is empty --"
run "$ROOT/bin/fm-slack-poll.sh" --replay "$T"
echo "postMessage sends to old DM after the drain poll (old value restored): $(grep chat.postMessage "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" | grep -c D0123456789)"
echo "documented journal probe prints: $(python3 -c 'import json; print(len(json.load(open("state/slack-watch/state.json"))["pending"]))')"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" disarm
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" retarget --replay "$TMP/moved.json"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" arm --replay "$TMP/moved.json"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-mirror.sh" --replay "$TMP/moved.json"
echo "postMessage sends to new DM D0NEWOWNER01: $(grep chat.postMessage "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" | grep -c D0NEWOWNER01)"
echo "postMessage sends to old DM D0123456789 (all, incl. before the change): $(grep chat.postMessage "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" | grep -c D0123456789)"

echo; echo "=== S6 adversarial: nothing posts outside a DM; no raw post command ==="
new_home mirror; "$CAPTAIN" bind slack-dm >/dev/null; "$ROOT/bin/fm-slack-mirror.sh" --replay "$T" >/dev/null
python3 "$HELPER" move-transcript "$T" "$TMP/public.json" C0PUBLIC0001
python3 "$HELPER" set-state "$(st)" channel C0PUBLIC0001
(tasks-axi add late-call "Late call" --kind captain --repo sample >/dev/null)
FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z "$CAPTAIN" hold late-call --reason Late >/dev/null
run "$ROOT/bin/fm-slack-mirror.sh" --replay "$TMP/public.json"
echo "sends to C0PUBLIC0001: $(grep -c C0PUBLIC0001 "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl")"
run python3 "$ROOT/bin/fm_slack_watch.py" post
