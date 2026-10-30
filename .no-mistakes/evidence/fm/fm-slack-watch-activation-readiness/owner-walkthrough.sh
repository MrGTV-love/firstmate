#!/usr/bin/env bash
# Owner-style walk-through of the Slack watch CLI in disposable homes.
# Every Slack call goes to the checked-in replay double; no network, no real token.
set -uo pipefail
ROOT=${1:?usage: owner-walkthrough.sh <worktree>}
FIX="$ROOT/tests/fixtures/slack"; CAPTAIN="$ROOT/bin/fm-captain-hold.sh"; HELPER="$ROOT/tests/fm_slack_watch_test.py"
SCRATCH=$(mktemp -d /tmp/fm-slack-walk.XXXXXX); trap 'rm -rf "$SCRATCH"' EXIT
say() { printf '\n$ %s\n' "$*"; }
run() { say "$*"; "$@" 2>&1; printf '[rc=%s]\n' "$?"; }
home() { HOME_DIR=$(mktemp -d "$SCRATCH/home.XXXXXX"); bash "$FIX/make-home.sh" "$1" "$HOME_DIR" >/dev/null
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
  printf '\n===== home: %s (scenario fixture %s) =====\n' "${HOME_DIR/#$SCRATCH/<scratch>}" "$1"; }
cd "$ROOT"
state() { printf '%s/slack-watch/state.json' "$FM_STATE_OVERRIDE"; }

echo '##### A. Activation order: bind, arm, one typed answer, disarm'
home typed-reply
"$CAPTAIN" unbind slack-dm >/dev/null  # the fixture home starts bound; start this owner path unbound
run "$CAPTAIN" open typed-call
run "$CAPTAIN" binding slack-dm
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/typed-reply/transcript.json"
say "check registration after refused arm:"; ls "$FM_STATE_OVERRIDE" | grep slack.check || echo '(none)'
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/typed-reply/transcript.json"
run "$CAPTAIN" bind slack-dm
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/typed-reply/transcript.json"
run "$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/typed-reply/transcript.json"
run "$CAPTAIN" open typed-call
say "outbound DM posts (method, channel, thread)"; python3 -I -c 'import json,sys
for l in open(sys.argv[1]):
  r=json.loads(l)
  if r.get("method")=="chat.postMessage": print(r.get("method"), "recipient=%s channel=%s" % (r.get("recipient"), r.get("channel")), "thread=%s" % r.get("thread_ts"))' "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl"
run "$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/typed-reply/transcript.json"
run env SLACK_BOT_TOKEN= "$ROOT/bin/fm-slack-check.sh" disarm

echo; echo '##### B. Allowlist is the lock: only the owner id answers'
home allowlist
"$CAPTAIN" bind slack-dm >/dev/null
run "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/allowlist/transcript.json"
for t in allow-a allow-b allow-c allow-d; do run "$CAPTAIN" open "$t"; done

echo; echo '##### C. Unbound source feeds nothing'
home typed-reply
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/typed-reply/transcript.json"
run "$CAPTAIN" unbind slack-dm
run "$ROOT/bin/fm-slack-check.sh" check --replay "$FIX/typed-reply/transcript.json"
run "$CAPTAIN" open typed-call

echo; echo '##### D. Changed owner DM: refused everywhere except retarget'
home mirror
"$CAPTAIN" bind slack-dm >/dev/null
"$ROOT/bin/fm-slack-mirror.sh" --replay "$FIX/mirror/transcript.json" >/dev/null
python3 "$HELPER" move-transcript "$FIX/mirror/transcript.json" "$SCRATCH/moved.json" D0NEWOWNER01
run "$ROOT/bin/fm-slack-check.sh" retarget --replay "$FIX/mirror/transcript.json"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-poll.sh" --replay "$SCRATCH/moved.json"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" arm --replay "$SCRATCH/moved.json"
python3 "$HELPER" stage-notice "$(state)" 900.000001 open-a 10
say "pending rows in journal (old value restored)"; (cd "$FM_HOME" && python3 -c 'import json; print(len(json.load(open("state/slack-watch/state.json"))["pending"]))')
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" retarget --replay "$SCRATCH/moved.json"
say "drain: poll with the OLD value until the journal is empty"
for i in 1 2 3; do "$ROOT/bin/fm-slack-poll.sh" --replay "$FIX/mirror/transcript.json" 2>&1; n=$(cd "$FM_HOME" && python3 -c 'import json; print(len(json.load(open("state/slack-watch/state.json"))["pending"]))'); echo "poll $i -> pending=$n"; [ "$n" = 0 ] && break; done
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" disarm
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" retarget --replay "$SCRATCH/moved.json"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-check.sh" arm --replay "$SCRATCH/moved.json"
run env FM_SLACK_DM_USER=U0OTHEROWNER1 "$ROOT/bin/fm-slack-mirror.sh" --replay "$SCRATCH/moved.json"
say "post targets (user@channel) for every chat.postMessage"; python3 -I -c 'import json,sys,collections
c=collections.Counter("%s@%s" % (r.get("recipient"), r.get("channel")) for r in map(json.loads, open(sys.argv[1])) if r.get("method")=="chat.postMessage")
[print(n, k) for k, n in sorted(c.items())]' "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl"

echo; echo '##### E. Disarm is the hard off switch even with broken config'
home arming
"$CAPTAIN" bind slack-dm >/dev/null
run "$ROOT/bin/fm-slack-check.sh" arm --replay "$FIX/arming/arm.json"
run env FM_SLACK_ALLOWED_AUTHORS=oops "$ROOT/bin/fm-slack-check.sh" disarm
say "check registration left behind:"; ls "$FM_STATE_OVERRIDE" | grep slack.check || echo '(none)'
