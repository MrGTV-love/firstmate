#!/usr/bin/env bash
# "Before" run: the base commit's bin/ with head's test-only files (fixtures, replay helper, test helper).
# Expect: the owner's top-level DM message is ignored (no post, no wake line).
# Usage: drive-base-before.sh <worktree> <base-sha>
set -uo pipefail
W=${1:?worktree}; BASE=${2:?base}
B=$(mktemp -d "${TMPDIR:-/tmp}/fm-base.XXXXXX")
trap 'rm -rf "$B"' EXIT
git -C "$W" archive "$BASE" | tar -x -C "$B"
rm -rf "$B/tests/fixtures/slack"
cp -R "$W/tests/fixtures/slack" "$B/tests/fixtures/slack"
cp "$W/tests/fm_slack_watch_test.py" "$B/tests/fm_slack_watch_test.py"
cp "$W/bin/fm_slack_replay.py" "$B/bin/fm_slack_replay.py"
FIX=$B/tests/fixtures/slack; HELPER=$B/tests/fm_slack_watch_test.py; INTAKE=$FIX/intake/transcript.json
H=$(mktemp -d "$B/home.XXXXXX"); bash "$FIX/make-home.sh" intake "$H" >/dev/null
export FM_HOME=$H FM_STATE_OVERRIDE=$H/state FM_DATA_OVERRIDE=$H/data FM_CONFIG_OVERRIDE=$H/config
echo "== BASE $BASE bin/ (head fixtures + head replay helper, test-only files)"
echo '$ fm-slack-check.sh arm --replay intake'; "$B/bin/fm-slack-check.sh" arm --replay "$INTAKE"
"$B/bin/fm-slack-poll.sh" --replay "$INTAKE"
python3 "$HELPER" owner-message "$(python3 "$HELPER" replay-file "$H/state/slack-watch")" 2000.000100 U0TESTOWNER "please check the status of vernant d7"
echo "owner types top-level DM 2000.000100: please check the status of vernant d7"
echo '$ fm-slack-poll.sh --replay intake'; out=$("$B/bin/fm-slack-poll.sh" --replay "$INTAKE" 2>&1); echo "stdout> ${out:-<empty>}"
echo "chat.postMessage count: $(python3 "$HELPER" outbound-count "$H/state/slack-watch/outbound.jsonl" chat.postMessage)"
