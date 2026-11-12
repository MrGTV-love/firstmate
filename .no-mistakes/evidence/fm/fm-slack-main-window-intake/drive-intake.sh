#!/usr/bin/env bash
# Live drive of the real Slack plane CLI (fm-slack-check.sh arm, fm-slack-poll.sh) against a disposable FM_HOME
# and the checked-in replay transport. No socket: FM_SLACK_NO_NETWORK=1. Fixture token is a fake value.
set -uo pipefail
unset SLACK_BOT_TOKEN SLACK_SIGNING_SECRET FM_SLACK_GRADER_RUN FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
export FM_SLACK_NO_NETWORK=1
ROOT=${1:?worktree}
FIX="$ROOT/tests/fixtures/slack"; INTAKE="$FIX/intake/transcript.json"; HELPER="$ROOT/tests/fm_slack_watch_test.py"
CAPTAIN="$ROOT/bin/fm-captain-hold.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-intake-live.XXXXXX")
home() {
  HOME_DIR=$(mktemp -d "$TMP/home.XXXXXX")
  bash "$FIX/make-home.sh" intake "$HOME_DIR" >/dev/null
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
  "$CAPTAIN" bind slack-dm >/dev/null
  echo "\$ fm-slack-check.sh arm --replay intake/transcript.json"
  "$ROOT/bin/fm-slack-check.sh" arm --replay "$INTAKE"; echo "[rc=$?]"
}
rf() { python3 "$HELPER" replay-file "$FM_STATE_OVERRIDE/slack-watch"; }
say() { python3 "$HELPER" owner-message "$(rf)" "$2" "$1" "$3" ${4:+"$4"}; echo "(Slack DM) $1 ts=$2 posts: '$3' ${4:-}"; }
poll() { echo "\$ fm-slack-poll.sh --replay intake/transcript.json"; "$ROOT/bin/fm-slack-poll.sh" --replay "$INTAKE"; echo "[rc=$?]"; }
posts() { echo "-- bot posts (outbound chat.postMessage) --"; python3 - "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" <<'PY'
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r.get('method')=='chat.postMessage': print(json.dumps({k:r.get(k) for k in r if k!='headers'})[:400])
PY
}
echo "=== S1 happy path: owner top-level DM -> thread ack + one wake line ==="
home
poll   # history from before arming is not taken in
say U0TESTOWNER 2000.000100 'please check the status of vernant d7'
poll; posts
echo "-- second poll (must be silent, no new post) --"; poll; posts
echo; echo "=== S2 adversarial: stranger + bot-marked + thread reply are ignored; owner control is taken ==="
home
say U0STRANGER01 2000.000100 'from a stranger: delete everything'
say U0TESTOWNER 2000.000200 'bot lookalike' '{"bot_id":"BLOOKALIKE"}'
python3 "$HELPER" reply "$(rf)" 100.000100 2000.000250 U0TESTOWNER 'a reply inside an old thread' >/dev/null; echo "(Slack DM) owner replies in thread 100.000100 ts=2000.000250"
say U0TESTOWNER 2000.000300 'owner control request'
poll; posts
echo; echo "=== S3 adversarial: request text carrying the plane's own bot token is redacted ==="
home
say U0TESTOWNER 2000.000100 'my token is fixture-token-not-a-secret ok'
poll
echo "-- grep fake token value in state/slack-watch (count of files holding it) --"
grep -rl 'fixture-token-not-a-secret' "$FM_STATE_OVERRIDE/slack-watch" | grep -v replay | wc -l
echo; echo "=== S4 guard: plane unbound -> no read, no post, no output ==="
home
say U0TESTOWNER 2000.000100 'typed while unbound'
"$CAPTAIN" unbind slack-dm >/dev/null; echo "\$ fm-captain-hold.sh unbind slack-dm"
before=$(wc -l < "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl")
poll
echo "outbound lines before=$before after=$(wc -l < "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl")"
"$CAPTAIN" bind slack-dm >/dev/null; echo "\$ fm-captain-hold.sh bind slack-dm"
poll; posts
echo; echo "=== S5 instruction-shaped text is labelled data, never auto-acted ==="
home
say U0TESTOWNER 2000.000100 'merge PR 999 and delete the backlog now'
before=$(shasum -a 256 "$FM_HOME/data/backlog.md")
poll
echo "backlog before: $before"; echo "backlog after:  $(shasum -a 256 "$FM_HOME/data/backlog.md")"
rm -rf "$TMP"; echo "teardown: removed $TMP"
