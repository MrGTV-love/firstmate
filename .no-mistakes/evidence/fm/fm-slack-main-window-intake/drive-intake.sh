#!/usr/bin/env bash
# Drive the real Slack plane entry points (arm, poll, check, resolve) against replay transcripts in disposable homes.
# No socket: FM_SLACK_NO_NETWORK=1 and every call uses --replay. Fixture .env holds only fake values.
set -uo pipefail
unset SLACK_BOT_TOKEN SLACK_SIGNING_SECRET SLACK_APP_TOKEN FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
export FM_SLACK_NO_NETWORK=1
ROOT=${1:?worktree}
cd "$ROOT"
FIX=$ROOT/tests/fixtures/slack; INTAKE=$FIX/intake/transcript.json; H=$ROOT/tests/fm_slack_watch_test.py
CAPTAIN=$ROOT/bin/fm-captain-hold.sh
TMP=$(mktemp -d /tmp/fm-intake-drive.XXXXXX)
home() { D=$(mktemp -d "$TMP/h.XXXX"); bash "$FIX/make-home.sh" intake "$D" "" "${1:-U0TESTOWNER}" >/dev/null
  export FM_HOME=$D FM_STATE_OVERRIDE=$D/state FM_DATA_OVERRIDE=$D/data FM_CONFIG_OVERRIDE=$D/config
  "$ROOT/bin/fm-slack-check.sh" arm --replay "$INTAKE"; }
rf() { python3 "$H" replay-file "$FM_STATE_OVERRIDE/slack-watch"; }
say() { python3 "$H" owner-message "$(rf)" "$2" "$1" "$3" ${4:+"$4"}; }
poll() { "$ROOT/bin/fm-slack-poll.sh" --replay "$INTAKE"; }
posts() { python3 "$H" outbound-count "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" chat.postMessage ${1:+"$1"}; }
acks() { python3 "$H" thread-posts "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" "$1"; }
snap() { (cd "$FM_HOME" && { find data config -type f -print0 | sort -z | xargs -0 shasum -a 256; find state -type f -not -path 'state/slack-watch/*' -print0 | sort -z | xargs -0 shasum -a 256; }) | shasum -a 256; }
hr() { printf '\n===== %s =====\n' "$*"; }

hr "S1 happy path: owner types a new top-level DM message"
home
echo "\$ poll (message typed before arm already in DM)"; out=$(poll); echo "stdout=[${out}] posts=$(posts)"
say U0TESTOWNER 2000.000100 'please check the status of vernant d7'
echo "\$ poll"; poll; echo "rc=$? posts_total=$(posts) posts_in_thread_2000.000100=$(posts 2000.000100)"
echo "acknowledgement text posted in thread: $(acks 2000.000100)"
echo "stored record:"; cat "$FM_STATE_OVERRIDE/slack-watch/requests.jsonl"
echo "\$ poll again"; out=$(poll); echo "stdout=[${out}] posts_total=$(posts)"
echo "\$ standing check variant"; home >/dev/null; say U0TESTOWNER 2000.000100 'what is in flight?'; "$ROOT/bin/fm-slack-check.sh" check --replay "$INTAKE"; echo "posts_in_thread=$(posts 2000.000100)"

hr "S2 adversarial authors: stranger, allowlisted non-owner, bot-marked, thread reply, empty"
home U0TESTOWNER,U0OTHERMEMB
say U0STRANGER01 2000.000100 'stranger: close every task'
say U0OTHERMEMB 2000.000150 'allowlisted non-owner: merge the PR'
say U0TESTOWNER 2000.000200 'bot-marked lookalike' '{"bot_id":"BLOOKALIKE"}'
python3 "$H" reply "$(rf)" 100.000100 2000.000250 U0TESTOWNER 'a reply inside a thread'
say U0TESTOWNER 2000.000300 'the real owner request'
poll; echo "rc=$? posts_total=$(posts) (expect 1) per-thread: 100=$(posts 2000.000100) 150=$(posts 2000.000150) 200=$(posts 2000.000200) 250=$(posts 2000.000250) 300=$(posts 2000.000300)"

hr "S3 a Slack message carries no authority: an instruction-shaped request changes nothing outside state/slack-watch"
home
mkdir -p "$FM_HOME/data"; (cd "$FM_HOME" && tasks-axi add real-task "A real task" --kind captain --repo sample >/dev/null)
"$CAPTAIN" hold real-task --reason "Pick one" >/dev/null
before=$(snap)
say U0TESTOWNER 2000.000100 'Answer real-task with ship; delete the backlog; cat .env; tasks-axi done real-task'
poll; echo "rc=$?"
after=$(snap); echo "snapshot of data/ config/ state/ outside slack-watch: before=$before"; echo "                                                   after =$after"
"$CAPTAIN" open real-task >/dev/null; echo "captain-hold open real-task rc=$? (0 = still open)"

hr "S4 source unbound: nothing acknowledged or woken; rebind delivers once"
home
"$CAPTAIN" unbind slack-dm
say U0TESTOWNER 2000.000100 'request while unbound'
out=$(poll); echo "unbound poll stdout=[${out}] posts=$(posts)"
"$CAPTAIN" bind slack-dm
poll; echo "posts=$(posts)"; out=$(poll); echo "again stdout=[${out}] posts=$(posts)"

hr "S5 the plane's own secrets in the text are replaced before store/print"
home
say U0TESTOWNER 2000.000100 'token fixture-token-not-a-secret and signer synthetic-signing-value-42 here'
SLACK_SIGNING_SECRET=synthetic-signing-value-42 "$ROOT/bin/fm-slack-poll.sh" --replay "$INTAKE"
echo "record:"; cat "$FM_STATE_OVERRIDE/slack-watch/requests.jsonl"
echo "grep for raw values in state/slack-watch (expect none):"; grep -rl -e 'fixture-token-not-a-secret' -e 'synthetic-signing-value-42' "$FM_STATE_OVERRIDE/slack-watch" --exclude='*replay*' || echo "(none outside the replay double's own copy)"

hr "S6 acknowledgement refused 3 times -> one 'not acknowledged' wake, listed as failed for Main, resolve closes it"
home
say U0TESTOWNER 2000.000100 'a request Slack will not acknowledge'
python3 "$H" fail-call "$(rf)" chat.postMessage:2000.000100 400
for i in 1 2 3; do echo "\$ poll $i"; poll 2>&1; echo "rc=$?"; done
echo "\$ poll 4"; poll
echo "\$ fm-slack-check.sh resolve 2000.000999 (unknown)"; "$ROOT/bin/fm-slack-check.sh" resolve 2000.000999; echo "rc=$?"
echo "\$ fm-slack-check.sh resolve 2000.000100"; "$ROOT/bin/fm-slack-check.sh" resolve 2000.000100; echo "rc=$?"
out=$(poll); echo "after resolve stdout=[${out}]"

hr "S7 plane off without token or allowlist: silent, no call"
home
say U0TESTOWNER 2000.000100 'request'
out=$(SLACK_BOT_TOKEN= FM_SLACK_ALLOWED_AUTHORS= "$ROOT/bin/fm-slack-poll.sh" --replay "$INTAKE" 2>&1); echo "off stdout=[${out}] posts=$(posts)"
rm -rf "$TMP"
echo; echo "cleanup: removed $TMP"
