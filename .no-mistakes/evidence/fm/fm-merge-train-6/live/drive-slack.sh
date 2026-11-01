#!/usr/bin/env bash
# Live drive: real fm-captain-hold.sh, fm-slack-mirror.sh, fm-slack-poll.sh in a disposable home.
# Slack itself is the product's --replay sandbox: no socket opened, no real DM posted.
set -eu
WT=$(pwd); T=$(mktemp -d /tmp/fm-slack-live.XXXXXX); trap 'rm -rf "$T"; echo "home removed"' EXIT
FIX=$WT/tests/fixtures/slack; H=$WT/tests/fm_slack_watch_test.py; C=$WT/bin/fm-captain-hold.sh
bash "$FIX/make-home.sh" card-payload "$T/h" >/dev/null
export FM_HOME=$T/h FM_STATE_OVERRIDE=$T/h/state FM_DATA_OVERRIDE=$T/h/data FM_CONFIG_OVERRIDE=$T/h/config
R=$FIX/card-payload/transcript.json; S=$T/h/state/slack-watch
"$C" bind slack-dm >/dev/null
rf() { python3 "$H" replay-file "$S"; }; of() { python3 "$H" outbound-count "$S/outbound.jsonl" "$1" "${2:-}"; }; tf() { python3 "$H" thread-field "$S/state.json" "$1" "$2"; }
"$WT/bin/fm-slack-mirror.sh" --replay "$R" >/dev/null
ts=$(tf with-options ts); echo "== posted card ts=$ts posts=$(of chat.postMessage) updates=$(of chat.update)"
python3 "$H" card-text "$(rf)" with-options | cut -c1-160
python3 "$H" react "$(rf)" "$ts" two U0DISPLAYNAME; react0=$(python3 "$H" reaction-state "$(rf)" "$ts"); opts0=$(tf with-options options); posts0=$(of chat.postMessage)
reason=$'Decision sought: Wait for approval?\nBrief: Rollout lacks approval.\nRecommendation: Wait because approval is required.\nAlternatives: Shipping now skips approval.'
"$C" hold with-options --reason "$reason" >/dev/null
out=$("$WT/bin/fm-slack-poll.sh" --replay "$R" 2>&1 || true); echo; echo "== after reason rewrite: poll printed: ${out:-<nothing>}"
echo "updates to same ts: $(of chat.update "$ts"); new posts: $(( $(of chat.postMessage) - posts0 )); root cards: $(python3 "$H" root-count "$(rf)" with-options); ts unchanged: $([ "$(tf with-options ts)" = "$ts" ] && echo yes || echo NO); options unchanged: $([ "$(tf with-options options)" = "$opts0" ] && echo yes || echo NO); reactions unchanged: $([ "$(python3 "$H" reaction-state "$(rf)" "$ts")" = "$react0" ] && echo yes || echo NO)"
python3 "$H" card-text "$(rf)" with-options | cut -c1-160
"$WT/bin/fm-slack-poll.sh" --replay "$R" >/dev/null 2>&1 || true; "$WT/bin/fm-slack-mirror.sh" --replay "$R" >/dev/null 2>&1 || true
echo; echo "== fresh processes on unchanged text: updates=$(of chat.update) (stays 1) posts delta=$(( $(of chat.postMessage) - posts0 ))"
echo; echo "== adversarial: a changed option set must not edit the card"
c0=$(python3 "$H" card-text "$(rf)" with-options)
mkdir -p "$FM_HOME/.lavish"; printf '<html><script id="bearings-data" type="application/json">{"schema":"fm-bearings-board.v1","generated":"2026-10-02T00:00Z","captains_call":[{"key":"with-options","options":[{"value":"changed","label":"Changed choice"}],"recommend_value":"changed"}]}</script></html>\n' > "$FM_HOME/.lavish/bearings-board.html"
"$C" hold with-options --reason "${reason/Wait for approval/Approve the new choice}" >/dev/null
"$WT/bin/fm-slack-poll.sh" --replay "$R" >/dev/null 2>&1 || true
echo "updates=$(of chat.update) (stays 1); posts delta=$(( $(of chat.postMessage) - posts0 )); card text unchanged: $([ "$(python3 "$H" card-text "$(rf)" with-options)" = "$c0" ] && echo yes || echo NO); options unchanged: $([ "$(tf with-options options)" = "$opts0" ] && echo yes || echo NO)"
echo; echo "== the edited card still answers: captain types 2 in the thread"
python3 "$H" reply "$(rf)" "$ts" 900.000099 U0TESTOWNER 2
out=$("$WT/bin/fm-slack-poll.sh" --replay "$R" 2>&1 || true); echo "poll printed: $out"
"$WT/bin/fm-tasks-axi.sh" show with-options --full | grep -o 'Answer: [^"]*' | sed 's/\\n.*//' | head -1
