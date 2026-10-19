#!/usr/bin/env bash
# S1: mirror open held decisions; typed answer; tap answer; allowlist; terminal-close resolution.
set -uo pipefail
. "$(dirname "$0")/lab.sh"
FAILED=0
lab_start || exit 1
trap lab_stop EXIT
new_home allowlist
step "S1.0 four held decisions exist (real tasks-axi + captain-hold)"
for k in allow-a allow-b allow-c allow-d; do expect_eq "$(is_open $k)" open "$k open before mirror"; done

step "S1.1 mirror creates one DM thread per open held decision (real HTTP client)"
out=$(mirror); echo "mirror stdout: [$out]"
expect_eq "$out" "" "mirror prints nothing when it only mirrors"
A=$(thread_ts allow-a); B=$(thread_ts allow-b); C=$(thread_ts allow-c); D=$(thread_ts allow-d)
echo "threads: A=$A B=$B C=$C D=$D"
[ -n "$A$B$C$D" ] && [ "$(admin state | python3 -c 'import json,sys; print(sum(1 for m in json.load(sys.stdin)["messages"] if not m.get("thread_ts")))')" = 4 ] && ok "4 top-level cards posted" || bad "card count"
step "card text for allow-a as posted to Slack"
thread_texts "$A"
expect_has "$(thread_texts "$A")" 'Options:' "card lists options"
expect_has "$(thread_texts "$A")" '1. Ship it (ship)' "option 1 line"
expect_has "$(thread_texts "$A")" 'Affordance: reaction' "reaction affordance with scopes granted"
expect_has "$(thread_texts "$A")" 'Messages typed in the main DM window are not read.' "main-window note"
seed=$(admin state | python3 -c 'import json,sys; r=json.load(sys.stdin)["reactions"]; print(",".join(x["name"] for x in r.get(sys.argv[1],[])))' "$A")
expect_eq "$seed" "one,two,three" "bot seeded numbered reactions on the card"

step "S1.2 mirror again is idempotent (no second thread per hold occurrence)"
mirror >/dev/null
expect_eq "$(admin state | python3 -c 'import json,sys; print(sum(1 for m in json.load(sys.stdin)["messages"] if not m.get("thread_ts")))')" 4 "still 4 cards"

step "S1.3 owner types '2' in thread A -> option 2 recorded through keyed-answer intake"
reply "$A" "2" "user=$OWNER"
out=$(poll); echo "poll stdout: [$out]"
expect_has "$out" 'closed: allow-a' "wake line names closed key"
expect_eq "$(answer_line allow-a)" wait "recorded keyed answer is option 2's value"
expect_eq "$(label_line allow-a)" Wait "recorded label"
expect_eq "$(is_open allow-a)" closed "allow-a closed in the real backlog"
thread_texts "$A" | tail -8
expect_has "$(thread_texts "$A")" 'Answer recorded.' "ack posted in thread"
expect_has "$(thread_texts "$A")" 'Resolved: allow-a' "resolution posted back in thread"
expect_eq "$(thread_field allow-a retired)" True "thread retired"

step "S1.4 owner taps reaction :one: on card B -> option 1 recorded"
react "$B" one "user=$OWNER"
out=$(poll); echo "poll stdout: [$out]"
expect_has "$out" 'closed: allow-b' "tap closes allow-b"
expect_eq "$(answer_line allow-b)" ship "tap recorded option 1 value"
expect_eq "$(label_line allow-b)" "Ship it" "tap label"

step "S1.5 adversarial: stranger, bot-flagged owner id, main-window DM, bot reaction all refused"
reply "$C" "1" "user=U0STRANGER9"
reply "$D" "1" "user=$OWNER" "bot_id=BEVIL000001"
admin main "text=3" "user=$OWNER" >/dev/null
react "$C" three "user=U0STRANGER9"
out=$(poll); echo "poll stdout: [$out]"
expect_not "$out" 'closed:' "nothing closed by unauthorized input"
expect_eq "$(is_open allow-c)" open "allow-c still open"
expect_eq "$(is_open allow-d)" open "allow-d still open"

step "S1.6 terminal close still works; Slack thread gets the resolution and retires"
printf 'terminal fixture answer\n' > "$FM_HOME/decision.txt"
"$CAPTAIN" answer allow-c --decision-file "$FM_HOME/decision.txt" >/dev/null
out=$(poll); echo "poll stdout: [$out]"
expect_not "$out" 'closed:' "plane does not claim a terminal close as its own"
expect_has "$(thread_texts "$C")" 'Resolved: allow-c' "resolution in thread after terminal close"
expect_eq "$(thread_field allow-c retired)" True "thread retired after terminal close"

step "S1.7 owner reply that Slack tags thread_broadcast ('also send to channel') is still read"
reply "$D" "ship it now" "user=$OWNER" "subtype=thread_broadcast"
out=$(poll); echo "poll stdout: [$out]"
expect_has "$out" 'closed: allow-d' "broadcast reply closes allow-d"
expect_eq "$(answer_line allow-d)" "ship it now" "free text recorded verbatim"

step "S1.8 every request carried the bot token; token never reached state/output"
expect_eq "$(requests_unauth)" 0 "no unauthenticated request"
echo "total requests seen by fake: $(requests_total)"
leaks=$(grep -rl -- "$FAKE_TOKEN" "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE" 2>/dev/null | wc -l | tr -d ' ')
expect_eq "$leaks" 0 "token not written into state or data"
[ "$FAILED" = 0 ] && echo "S1 RESULT: ALL PASS" || echo "S1 RESULT: FAILURES"
exit $FAILED
