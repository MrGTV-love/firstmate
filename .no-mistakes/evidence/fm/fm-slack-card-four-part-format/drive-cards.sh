#!/usr/bin/env bash
# Drive the real Slack decision-plane CLI (fm-captain-hold.sh, fm-slack-mirror.sh,
# fm-slack-poll.sh) against a disposable FM_HOME and the product's --replay Slack sandbox.
# Usage: drive-cards.sh <worktree-root>
set -euo pipefail
ROOT=${1:?worktree}
FIX="$ROOT/tests/fixtures/slack"; CAPTAIN="$ROOT/bin/fm-captain-hold.sh"; H="$ROOT/tests/fm_slack_watch_test.py"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-card-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bash "$FIX/make-home.sh" card-payload "$LAB" >/dev/null
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_DATA_OVERRIDE="$LAB/data" FM_CONFIG_OVERRIDE="$LAB/config"
unset FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE
cp "$FIX/card-payload/transcript.json" "$LAB/transcript.json"
T="$LAB/transcript.json"
mirror() { "$ROOT/bin/fm-slack-mirror.sh" --replay "$T"; }
poll() { "$ROOT/bin/fm-slack-poll.sh" --replay "$T"; }
R() { python3 "$H" replay-file "$LAB/state/slack-watch"; }
S="$LAB/state/slack-watch/state.json"; O="$LAB/state/slack-watch/outbound.jsonl"
card() { python3 "$H" card-text "$(R)" "$1"; }
field() { python3 "$H" thread-field "$S" "$1" "$2"; }
cnt() { python3 "$H" outbound-count "$O" "$@"; }
hr() { printf '\n===== %s =====\n' "$*"; }
"$CAPTAIN" bind slack-dm >/dev/null
mirror >/dev/null

hr "SCENARIO legacy: unlabeled reason, with options (task with-options)"
card with-options
hr "SCENARIO legacy: unlabeled reason, no options (task no-options)"
card no-options

hr "SCENARIO four-part: labels out of order, multiline Brief, reason option lines"
printf 'Choose the cache backend.\nOption 1: Redis (redis) - managed\nOption 2: Memcached (memcached) - simple\n' > "$LAB/fp.body"
(cd "$LAB" && tasks-axi add four-part "Cache backend" --kind captain --repo sample --body-file "$LAB/fp.body" >/dev/null)
reason=$'Alternatives: Memcached is simpler but has no persistence.\nRecommendation: Redis, because it persists and we already run it.\nBrief: Sessions are lost on every deploy.\nThe current in-process cache is wiped on restart.\nDecision sought: Which cache backend should sessions use?\nOption 3: Postgres table (pg)'
"$CAPTAIN" hold four-part --reason "$reason" >/dev/null
mirror >/dev/null
card four-part
printf -- '--- reason given to fm-captain-hold.sh ---\n%s\n' "$reason"

hr "SCENARIO in-place refresh: rewrite active hold reason of with-options"
ts=$(field with-options ts); opts=$(field with-options options)
posts=$(cnt chat.postMessage)
printf 'before: ts=%s postMessage=%s chat.update=%s\n' "$ts" "$posts" "$(cnt chat.update)"
"$CAPTAIN" hold with-options --reason $'Decision sought: Ship the release today?\nBrief: QA signed off; one flaky test remains.\nRecommendation: Ship, because the flake is known and unrelated.\nAlternatives: Waiting a day delays a customer fix for no gain.' >/dev/null
poll >/dev/null
printf 'after poll: ts=%s postMessage=%s chat.update(ts)=%s options_same=%s roots=%s\n' \
  "$(field with-options ts)" "$(cnt chat.postMessage)" "$(cnt chat.update "$ts")" \
  "$([ "$(field with-options options)" = "$opts" ] && echo yes || echo no)" "$(python3 "$H" root-count "$(R)" with-options)"
card with-options
poll >/dev/null; mirror >/dev/null
printf 'after restart (fresh poll + mirror processes): chat.update(ts)=%s postMessage=%s\n' "$(cnt chat.update "$ts")" "$(cnt chat.postMessage)"
hr "SCENARIO answer binding unchanged: owner types 1 in edited thread"
python3 "$H" reply "$(R)" "$ts" 900.000501 U0TESTOWNER 1
out=$(poll); printf '%s\n' "$out" | grep -E '^(closed|check):' || true
"$ROOT/bin/fm-tasks-axi.sh" show with-options --full | grep -o 'Answer: [a-z]*' | head -1
printf 'retired=%s\n' "$(field with-options retired)"

hr "SCENARIO options changed: no-recommendation board options change + reason rewrite"
nts=$(field no-recommendation ts); before=$(card no-recommendation); u0=$(cnt chat.update)
mkdir -p "$LAB/.lavish"
printf '<html><script id="bearings-data" type="application/json">{"schema":"fm-bearings-board.v1","generated":"2026-10-02T00:00Z","captains_call":[{"key":"no-recommendation","options":[{"value":"gamma","label":"Gamma"}]}]}</script></html>\n' > "$LAB/.lavish/bearings-board.html"
"$CAPTAIN" hold no-recommendation --reason $'Decision sought: Pick gamma?\nBrief: New option appeared.' >/dev/null
poll >/dev/null
printf 'chat.update total before=%s after=%s ; chat.update(ts)=%s ; card unchanged=%s\n' "$u0" "$(cnt chat.update)" "$(cnt chat.update "$nts")" \
  "$([ "$(card no-recommendation)" = "$before" ] && echo yes || echo no)"

hr "SCENARIO replaced hold: release no-options, start a new hold lifecycle, rewrite"
ots=$(field no-options ts)
printf 'release for new lifecycle\n' > "$LAB/d.txt"
"$CAPTAIN" answer no-options --decision-file "$LAB/d.txt" --release >/dev/null
FM_CAPTAIN_HOLD_NOW=2026-10-05T00:00:00Z "$CAPTAIN" hold no-options --reason $'Decision sought: New question?\nBrief: second lifecycle' >/dev/null
poll >/dev/null; mirror >/dev/null
printf 'old ts=%s chat.update(old)=%s root cards for no-options=%s\n' "$ots" "$(cnt chat.update "$ots")" "$(python3 "$H" root-count "$(R)" no-options)"
FM_CAPTAIN_HOLD_NOW=2026-10-05T00:00:00Z "$CAPTAIN" hold no-options --reason $'Decision sought: New question v2?\nBrief: second lifecycle' >/dev/null
poll >/dev/null
printf 'after rewriting new lifecycle: chat.update(old)=%s\n' "$(cnt chat.update "$ots")"
printf 'old thread texts:\n'; python3 "$H" thread-texts "$(R)" "$ots"

hr "SCENARIO rejected refresh: A rejected, suppressed, B succeeds, A restored"
fts=$(field four-part ts)
python3 "$H" fail-call "$(R)" "chat.update:$fts" 400 1
A=$'Decision sought: Which cache backend (A)?\nBrief: A text.'
B=$'Decision sought: Which cache backend (B)?\nBrief: B text.'
"$CAPTAIN" hold four-part --reason "$A" >/dev/null
printf 'poll1 (A, Slack rejects): '; poll | grep 'card update failed' || echo '(no failure line)'
printf 'poll2 (A unchanged): '; out=$(poll); printf '%s\n' "$out" | grep 'card update' || echo '(no retry, no failure line)'
printf 'chat.update(four-part) successes so far=%s\n' "$(cnt chat.update "$fts")"
"$CAPTAIN" hold four-part --reason "$B" >/dev/null; poll >/dev/null
printf 'after B: chat.update(four-part)=%s card has (B)=%s\n' "$(cnt chat.update "$fts")" "$(card four-part | grep -c '(B)')"
"$CAPTAIN" hold four-part --reason "$A" >/dev/null; poll >/dev/null
printf 'after A restored: chat.update(four-part)=%s card has (A)=%s\n' "$(cnt chat.update "$fts")" "$(card four-part | grep -c '(A)')"
printf 'postMessage roots for four-part=%s\n' "$(python3 "$H" root-count "$(R)" four-part)"
grep -c 'none recorded' "$(R)" | sed 's/^/"none recorded" occurrences in all Slack messages: /' || true
