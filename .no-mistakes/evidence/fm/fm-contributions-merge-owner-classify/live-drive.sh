#!/usr/bin/env bash
# Live drive of the contribution merge-owner classifier.
# Real CLIs: fm-contributions.sh poll/snapshot, fm-review-record.py review/verify,
# fm-captain-hold.sh hold/answer, fm-contributions.sh verdict, fm-bearings-snapshot.sh --json.
# Disposable pieces: a private home per scenario, a fake GitHub transport (gh on PATH),
# a real git worktree, and an empty NM_HOME. The fixture builders come from
# tests/fm-contributions.test.sh so the fake forge is the one the suite owns.
# Usage: live-drive.sh <worktree> <base-tree>
set -u
WT=$1 BASE_TREE=$2
cd "$WT" || exit 1
# shellcheck source=/dev/null
. tests/lib.sh
# shellcheck source=/dev/null
HELPERS=$(mktemp /tmp/fm-live-helpers.XXXXXX)
sed -n '6,1853p' tests/fm-contributions.test.sh > "$HELPERS"
# shellcheck source=/dev/null
. "$HELPERS"; rm -f "$HELPERS"
type merge_home >/dev/null 2>&1 || { echo 'fixture helpers did not load'; exit 2; }
results=0
row() { # home label -> prints head row and bearings summary
  local home=$1 label=$2 all base_all board
  with_home "$home" bash "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" || { echo "input failed"; return 1; }
  all=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || return 1
  base_all=$(with_home "$home" bash "$BASE_TREE/bin/fm-contributions.sh" snapshot "$home/input.json" --all 2>/dev/null || printf '{"rows":[{"actor":"(base error)","reason":""}]}')
  board=$(FM_BEARINGS_NOW="$NOW" with_home "$home" bash "$ROOT/bin/fm-bearings-snapshot.sh" --json) || return 1
  printf '\n### %s\n' "$label"
  printf 'HEAD row : %s\n' "$(printf '%s' "$all" | jq -c '.rows[0] | {actor,reason,hold,tasks}')"
  printf 'BASE row : %s\n' "$(printf '%s' "$base_all" | jq -c '.rows[0] | {actor,reason}')"
  printf 'saved facts: %s\n' "$(jq -c '.records[0].observation | {base_containment,review:(.review_verification.answer | if . == null then null else {ok,basis,kind:.error.kind} end)}' "$home/data/delivery/contributions.json" 2>/dev/null)"
  printf 'bearings --json contributions: %s\n' "$(printf '%s' "$board" | jq -c '.contributions | {known,checked,counts,complete,proven_clear,captain:[.captain[]? | {task,reason,hold}]}')"
  LAST_ALL=$all
}
expect() { # actor reason
  if printf '%s' "$LAST_ALL" | jq -e --arg a "$1" --arg r "$2" '.rows[0].actor == $a and .rows[0].reason == $r' >/dev/null; then
    printf 'RESULT: PASS (expected %s / %s)\n' "$1" "$2"
  else
    printf 'RESULT: FAIL (expected %s / %s)\n' "$1" "$2"; results=$((results + 1))
  fi
}
poll() { with_home "$1" bash "$ROOT/bin/fm-contributions.sh" poll >/dev/null || echo "poll rc=$?"; }

echo "## S1 green PR, fresh base, no review record (claim only in PR body)"
h=$(new_home s1); merge_home "$h"; poll "$h"; row "$h" 'S1'; expect fleet 'route the independent review'

echo; echo "## S2 PASS recorded by same model family as the author"
merge_review "$h" PASS gpt-5.1; poll "$h"; row "$h" 'S2'; expect fleet 'route the independent review'

echo; echo "## S3 PASS limited to the pr-body group"
rm -f "$h/state/review-records.jsonl"; merge_review "$h" PASS sonnet '' no pr-body; poll "$h"; row "$h" 'S3'; expect fleet 'route the independent review'

echo; echo "## S4 independent different-family exact-head PASS, fresh base, green"
rm -f "$h/state/review-records.jsonl"; merge_review "$h" PASS sonnet; poll "$h"; row "$h" 'S4'; expect fleet 'merge under the standing merge rule'

echo; echo "## S5 same PR, base branch advanced one commit (behind_by 1)"
printf '%s\n' "$HEAD_B" > "$h/forge/base-tip"; printf '1\n' > "$h/forge/behind"; poll "$h"; row "$h" 'S5'; expect fleet 'update the branch; base is stale'
printf '0\n' > "$h/forge/behind"; rm -f "$h/forge/base-tip"

echo; echo "## S6 real owner hold filed with fm-captain-hold.sh hold (PR green with PASS)"
poll "$h"
FM_CAPTAIN_HOLD_NOW="$NOW" with_home "$h" bash "$ROOT/bin/fm-captain-hold.sh" hold delivery --reason 'pick the API contract' >/dev/null || echo 'hold failed'
row "$h" 'S6'; expect captain 'pick the API contract'

echo; echo "## S7 hold answered with fm-captain-hold.sh answer --release"
printf 'Use contract B.\n' > "$h/decision.txt"
with_home "$h" bash "$ROOT/bin/fm-captain-hold.sh" answer delivery --decision-file "$h/decision.txt" --release >/dev/null || echo 'answer failed'
row "$h" 'S7'; expect fleet 'merge under the standing merge rule'

echo; echo "## S8 explicit pause line in state/delivery.status, no hold"
printf 'paused: waiting for external CI\n' > "$h/state/delivery.status"; row "$h" 'S8'; expect fleet 'merge under the standing merge rule'
rm -f "$h/state/delivery.status"

echo; echo "## S9 recorded captain-actor verdict, no live hold"
h=$(new_home s9); merge_home "$h"; poll "$h"
with_home "$h" bash "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$(cat "$h/forge/head")" \
  https://github.com/o/r/pull/8#issuecomment-1 captain 'choose X' >/dev/null || echo 'verdict failed'
row "$h" 'S9'; expect fleet 'record the unresolved arbitration as a captain hold'

echo; echo "## S10 adversarial: good PASS poll, then compare read goes silent (stall)"
h=$(new_home s10); merge_home "$h"; merge_review "$h" PASS; poll "$h"; row "$h" 'S10 before'; expect fleet 'merge under the standing merge rule'
: > "$h/forge/compare-silent"
NOW=$(jq -nr --arg now "$NOW" '$now | fromdateiso8601 + 300 | todateiso8601')
poll "$h"; row "$h" 'S10 after stalled compare'; expect fleet 'base freshness unknown; refresh the base comparison'
printf 'deferred URLs: %s\n' "$(tr '\n' ' ' < "$h/state/.contributions-deferred" 2>/dev/null)"
rm -f "$h/forge/compare-silent"; NOW=2026-09-16T08:00:00Z

echo; echo "## S11 adversarial: good PASS poll, then verifier fails"
h=$(new_home s11); merge_home "$h"; merge_review "$h" PASS; poll "$h"
printf 'fail\n' > "$h/forge/verifier-mode"; poll "$h"; row "$h" 'S11'; expect fleet 'PASS fact unknown; recheck the independent review'
rm -f "$h/forge/verifier-mode"

echo; echo "## S12 snapshot makes no forge or verifier call"
calls_before=$(cat "$h/forge/shim.log" "$h/forge/review-calls" 2>/dev/null | wc -l)
sum_before=$(shasum -a 256 "$h/data/delivery/contributions.json")
with_home "$h" bash "$ROOT/bin/fm-contributions.sh" snapshot "$h/input.json" --all >/dev/null
calls_after=$(cat "$h/forge/shim.log" "$h/forge/review-calls" 2>/dev/null | wc -l)
sum_after=$(shasum -a 256 "$h/data/delivery/contributions.json")
printf 'forge+verifier log lines before=%s after=%s; record bytes equal=%s\n' "$calls_before" "$calls_after" "$([ "$sum_before" = "$sum_after" ] && echo yes || echo no)"
if [ "$calls_before" = "$calls_after" ] && [ "$sum_before" = "$sum_after" ]; then echo 'RESULT: PASS'; else echo 'RESULT: FAIL'; results=$((results+1)); fi

echo; echo "## S13 poll forge calls are read-only"
if merge_read_calls_are_safe "$h/forge/shim.log"; then echo 'RESULT: PASS (every logged forge call is a GET read or pr view)'; else echo 'RESULT: FAIL'; results=$((results+1)); fi
sed 's/^/  /' "$h/forge/shim.log" | sort -u | head -20

echo; echo "TOTAL FAILURES: $results"
exit "$results"
