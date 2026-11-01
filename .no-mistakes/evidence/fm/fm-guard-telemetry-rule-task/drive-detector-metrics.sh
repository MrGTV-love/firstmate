#!/usr/bin/env bash
# Live driver: the heartbeat home scan finds a base-merge-only head change after
# a recorded merge refusal (and not without one), and fm-guard-metrics reports
# per-rule numbers, the refusal-to-bypass ratio, repeat denies per task across
# sessions, deny-only and zero-event flags from that real output.
set -u
WT=${1:?worktree}
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-detect.XXXXXX"); trap 'rm -rf "$S"' EXIT
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
g() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
# Origin with main, and three task copies.
git init -q -b main "$S/origin"; echo base > "$S/origin/f"; g "$S/origin" add f; g "$S/origin" commit -m base
mk() { # <task> -> copy with a real implementation commit on branch fm/<task>
  git clone -q "$S/origin" "$S/$1"; g "$S/$1" checkout -b "fm/$1"
  echo "impl $1" > "$S/$1/impl"; g "$S/$1" add impl; g "$S/$1" commit -m "impl $1"
  git -C "$S/$1" rev-parse HEAD
}
H1=$(mk refused-then-basemerge); H2=$(mk basemerge-no-refusal); H3=$(mk refused-then-real-fix)
mkdir -p "$S/home/state"; LOG="$S/home/state/guard-events.jsonl"
for t in refused-then-basemerge basemerge-no-refusal refused-then-real-fix; do
  printf 'kind=ship\nworktree=%s\nbranch=fm/%s\nbase_branch=main\n' "$S/$t" "$t" > "$S/home/state/$t.meta"
done
deny() { "$WT/bin/fm-guard-event.sh" merge-green-head deny --rule base-containment --task "$1" --head "$2" --base main --log "$LOG"; }
deny refused-then-basemerge "$H1"; deny refused-then-real-fix "$H3"
sleep 1
# Base moves; two copies only merge base; one makes a real fix.
echo base2 >> "$S/origin/f"; g "$S/origin" commit -am base2
for t in refused-then-basemerge basemerge-no-refusal refused-then-real-fix; do g "$S/$t" fetch -q origin; done
g "$S/refused-then-basemerge" merge --no-ff -m "merge base" origin/main
g "$S/basemerge-no-refusal" merge --no-ff -m "merge base" origin/main
echo fix >> "$S/refused-then-real-fix/impl"; g "$S/refused-then-real-fix" commit -am "real fix"
# A tree-equal merge on the no-refusal copy too (merge of an already-contained ref).
g "$S/basemerge-no-refusal" checkout -q -b side; echo side > "$S/basemerge-no-refusal/side"; g "$S/basemerge-no-refusal" add side; g "$S/basemerge-no-refusal" commit -m side
g "$S/basemerge-no-refusal" checkout -q fm/basemerge-no-refusal; g "$S/basemerge-no-refusal" merge --no-ff -s ours -m "tree-equal merge" side
echo "tree-equal merge made: $(git -C "$S/basemerge-no-refusal" log -1 --format=%H)"
echo "== home scan (what the heartbeat runs), text"
python3 "$WT/bin/fm-guard-workarounds.py" --state "$S/home/state"; echo "exit=$?"
echo "== home scan, json"
python3 "$WT/bin/fm-guard-workarounds.py" --state "$S/home/state" --json | tee "$S/wk.jsonl"; echo "exit=$?"
echo "== source copies unchanged (read-only): $(for t in refused-then-basemerge basemerge-no-refusal refused-then-real-fix; do git -C "$S/$t" status --porcelain | wc -l | tr -d ' '; done | tr '\n' ' ')"

echo "== metrics fixture log: repeat denies across sessions, overrides, bypasses, a deny-only guard"
E="$WT/bin/fm-guard-event.sh"
FM_SESSION_ID=sess-1 "$E" merge-green-head deny --rule checks-green --task t-red --log "$LOG"
FM_SESSION_ID=sess-2 "$E" merge-green-head deny --rule checks-green --task t-red --log "$LOG"
FM_SESSION_ID=sess-3 "$E" merge-green-head deny --rule checks-green --task t-red --log "$LOG"
"$E" merge-green-head bypass --rule checks-green --task t-red --override --cleared-by allow-red --log "$LOG"
"$E" merge-green-head allow --rule checks-green --task t-ok --log "$LOG"
"$E" teardown-unlanded deny --rule landed-work --task t-td --log "$LOG"
"$E" teardown-unlanded bypass --rule landed-work --task t-td --override --cleared-by force --log "$LOG"
"$E" only-denies deny --rule r1 --task t-x --log "$LOG"
"$E" only-denies deny --rule r1 --task t-y --log "$LOG"
echo "== fm-guard-metrics.sh (text, with the detector feed)"
"$WT/bin/fm-guard-metrics.sh" --log "$LOG" --workarounds "$S/wk.jsonl" --days 7; echo "exit=$?"
echo "== fm-guard-metrics.sh --json (rules and flags only)"
"$WT/bin/fm-guard-metrics.sh" --log "$LOG" --workarounds "$S/wk.jsonl" --days 7 --json \
  | jq -c '.rules[]? // empty' ; echo "exit=${PIPESTATUS[0]}"
"$WT/bin/fm-guard-metrics.sh" --log "$LOG" --workarounds "$S/wk.jsonl" --days 7 --json | jq -c 'del(.rules) | .guards |= map({id,denies,refusal_to_bypass_ratio,flags: (.flags // null), deny_only: (.deny_only // null), zero_events: (.zero_events_in_days // .zero_events // null)})'
echo "== without --workarounds: workarounds read as not measured"
"$WT/bin/fm-guard-metrics.sh" --log "$LOG" --guards merge-green-head --json | jq -c '.rules[]? | select(.id=="merge-green-head") | {rule, workarounds, refusal_to_bypass_ratio}'
echo "== log unchanged by metrics: $(wc -l < "$LOG" | tr -d ' ') rows"
