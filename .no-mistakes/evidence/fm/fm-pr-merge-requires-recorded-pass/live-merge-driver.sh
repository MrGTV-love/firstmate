#!/usr/bin/env bash
# Live driver: real bin/fm-pr-merge.sh and bin/fm-review-record.py against
# disposable lab homes minted by bin/fm-lab-home.sh. Only the forge CLIs
# (gh, gh-axi, glab, tea) are fakes; no real forge call or merge happens.
set -u
S=$(cd "$(dirname "$0")" && pwd)
. "$S/helpers.sh"
WT=$ROOT
TMP_ROOT="$S/cases"; mkdir -p "$TMP_ROOT"
LIVE=/Users/charlesabrooker/tmp
HEAD_LIVE=1111111111111111111111111111111111111111
HEAD_OLD=2222222222222222222222222222222222222222
URL=https://github.com/example/repo/pull/9
OTHER=https://github.com/example/repo/pull/10
LABS=()
PASSN=0; FAILN=0

# The real merge, with the lab as the plain FM_HOME (no root/state override).
eval "$(declare -f run_pr_merge | sed -e '1s/run_pr_merge/live_merge/' \
  -e 's|FM_ROOT_OVERRIDE="\$ROOT" FM_HOME="\${FM_TEST_HOME:-\$case_dir/home}" FM_STATE_OVERRIDE="\$case_dir/state"|FM_HOME="$LAB"|')"
declare -f live_merge | grep -q 'FM_HOME="\$LAB"' || { echo "driver: live_merge rewrite failed"; exit 9; }

new_lab() {
  LAB=$(mktemp -d "$LIVE/fm-lab.XXXXXX")
  "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 9; }
  LABS+=("$LAB")
}

# Fixture case dir holds the fake forge; the lab home holds the task record.
setup() {  # <name> <kind:github|gitlab|forgejo>
  local name=$1 kind=${2:-github}
  new_lab
  case "$kind" in
    github) CASE=$(make_case "$name"); add_gh_mocks "$CASE" "$HEAD_LIVE"; : > "$CASE/gh-axi.log" ;;
    gitlab) CASE=$(make_gitlab_case "$name") ;;
    forgejo) CASE=$(make_forgejo_case "$name") ;;
  esac
  mkdir -p "$CASE/wt"
  : > "$CASE/explicit-review"
  cp "$CASE/state/task-x1.meta" "$LAB/state/task-x1.meta"
  cp "$CASE/home/.tasks.toml" "$LAB/.tasks.toml"
  cp "$CASE/home/data/backlog.md" "$LAB/data/backlog.md"
  echo
  echo "=================================================================="
  echo "SCENARIO: $name   (forge=$kind, FM_HOME=$LAB)"
  echo "=================================================================="
}

rec() {  # relay lane call: real helper, FM_HOME only
  echo "\$ FM_HOME=\$LAB bin/fm-review-record.py $*"
  local rc=0
  (cd / && env -u FM_STATE_OVERRIDE FM_HOME="$LAB" "$WT/bin/fm-review-record.py" "$@") || rc=$?
  echo "  -> exit $rc"
  return "$rc"
}

review() {  # <url> <head> [extra flags]
  local url=$1 head=$2; shift 2
  rec review --pr "$url" --head "$head" --verdict PASS --reader-model claude-opus-5-5 \
    --author-groups '{"all":["gpt-5.1-codex"]}' --loosens-deny-allow-list no --widens-guard no \
    --customer-data-billing-spend no --report /reports/review.md "$@"
}

merge() {  # <url> [flags]; prints rc, stderr and whether a forge merge ran
  echo "\$ FM_HOME=\$LAB bin/fm-pr-merge.sh task-x1 $*"
  MRC=0
  live_merge "$CASE" task-x1 "$@" > "$CASE/stdout" 2> "$CASE/stderr" || MRC=$?
  echo "  -> exit $MRC"
  sed 's/^/  stderr| /' "$CASE/stderr" | grep -v '^  stderr| *$' | tail -8
  FORGE_MERGE=$( { grep -h '^pr merge ' "$CASE/gh.log" 2>/dev/null; grep -h ' mr merge ' "$CASE/glab.log" 2>/dev/null; grep -h 'pulls/9/merge' "$CASE/tea.log" 2>/dev/null; } || true)
  echo "  forge merge call: ${FORGE_MERGE:-<none>}"
}

check() {  # <description> <condition-cmd...>
  local d=$1; shift
  if "$@"; then echo "  CHECK PASS: $d"; PASSN=$((PASSN+1)); else echo "  CHECK FAIL: $d"; FAILN=$((FAILN+1)); fi
}
refused() { [ "$MRC" -eq 1 ] && [ -z "$FORGE_MERGE" ] && grep -q "$1" "$CASE/stderr" && grep -q 'fm-review-record.py' "$CASE/stderr"; }
merged() { [ "$MRC" -eq 0 ] && printf "%s" "$FORGE_MERGE" | grep -qF -- "$1"; }

# ---- GitHub merge-tool scenarios ----
setup 01-no-record
merge "$URL"; check "no record: merge refused, names missing record, no forge merge" refused 'review record is missing'

setup 02-valid-pass-merges
review "$URL" "$HEAD_LIVE"
merge "$URL"; check "different-family PASS at live head merges with --match-head-commit" merged "pr merge 9 --repo example/repo --match-head-commit $HEAD_LIVE --squash"

setup 03-pass-at-older-head
review "$URL" "$HEAD_OLD"
merge "$URL"; check "PASS at older head refused naming head mismatch" refused "head mismatch: review names $HEAD_OLD, live head is $HEAD_LIVE"

setup 04-same-family-reader
review "$URL" "$HEAD_LIVE" --author-groups '{"initial":["gpt-5.1-codex"],"fixes":["claude-opus-5-5"]}'
merge "$URL"; check "reader family equal to one author group refused naming reader_family" refused 'reader_family anthropic (claude-opus-5-5) matches author_groups fixes'

setup 05-same-family-routed-model
review "$URL" "$HEAD_LIVE" --reader-model claude-sonnet-5-5 --author-groups '{"all":["anthropic/claude-haiku-5-5"]}'
merge "$URL"; check "provider-prefixed same-family author still refused" refused 'reader_family anthropic'

setup 06-newest-is-fail
review "$URL" "$HEAD_LIVE"
review "$URL" "$HEAD_LIVE" --verdict FAIL
merge "$URL"; check "newest FAIL after older PASS refused" refused 'verdict is FAIL'

for trig in loosens-deny-allow-list widens-guard customer-data-billing-spend; do
  setup "07-trigger-$trig"
  review "$URL" "$HEAD_LIVE" "--$trig" yes
  merge "$URL"; check "trigger $trig=yes without captain words refused naming trigger" refused "${trig//-/_} is yes but captain-word is missing"
done

setup 08-trigger-with-captain-words
review "$URL" "$HEAD_LIVE" --customer-data-billing-spend yes
rec captain-word --pr "$URL" --head "$HEAD_LIVE" --words 'Merge PR 9 now; I accept the billing change.'
rec latest --pr "$URL" | tee /dev/stderr | grep "^{" > "$CASE/latest"
check "captain words stored byte-exact" grep -q '"words":"Merge PR 9 now; I accept the billing change."' "$CASE/latest"
merge "$URL"; check "trigger yes + captain words at live head merges" merged "--match-head-commit $HEAD_LIVE"

setup 09-captain-words-for-other-pr
review "$URL" "$HEAD_LIVE" --widens-guard yes
rec captain-word --pr "$OTHER" --head "$HEAD_LIVE" --words 'Merge PR 10.'
merge "$URL"; check "captain words for a different PR do not count" refused 'widens_guard is yes'

setup 10-captain-words-at-stale-head
review "$URL" "$HEAD_LIVE" --widens-guard yes
rec captain-word --pr "$URL" --head "$HEAD_OLD" --words 'Merge PR 9.'
merge "$URL"; check "captain words naming an older head do not count" refused 'widens_guard is yes'

setup 11-unknown-reader-family
review "$URL" "$HEAD_LIVE" --reader-model mistral-large
merge "$URL"; check "unknown reader family is never independent" refused 'model family unknown for mistral-large'

setup 12-attended-override-no-record
merge "$URL" --attended-override; check "--attended-override does not replace the review record" refused 'review record is missing'

setup 13-away-record-no-review
FM_HOME="$LAB" "$WT/bin/fm-afk-contract.sh" enter --words 'merge task-x1 when green' >/dev/null 2>&1 && echo "  (away record entered in lab)"
merge "$URL"; check "away authority does not replace the review record" refused 'review record is missing'

setup 14-captain-words-do-not-waive-red-check
write_github_red_json "$CASE" "$HEAD_LIVE" ci
rec captain-word --pr "$URL" --head "$HEAD_LIVE" --words 'Merge PR 9.'
merge "$URL"; check "captain words do not waive a red required check" bash -c '[ "$1" -ne 0 ] && [ -z "$2" ]' _ "$MRC" "$FORGE_MERGE"

setup 15-review-recorded-in-wrong-home
OTHER_LAB=$LAB; new_lab; WRONG=$LAB; LAB=$OTHER_LAB
echo "  (recording into a different home $WRONG)"
(cd / && FM_HOME="$WRONG" "$WT/bin/fm-review-record.py" review --pr "$URL" --head "$HEAD_LIVE" --verdict PASS \
  --reader-model claude-opus-5-5 --author-groups '{"all":["gpt-5.1-codex"]}' --loosens-deny-allow-list no \
  --widens-guard no --customer-data-billing-spend no --report /r.md); echo "  -> exit $?"
merge "$URL"; check "a PASS stored in another home does not authorize this home's merge" refused 'review record is missing'

# ---- Other forges ----
setup 16-gitlab-no-record gitlab
merge "$MR_URL"; check "GitLab: no record refused, glab merge never called" refused 'review record is missing'
setup 17-gitlab-valid-pass gitlab
review "$MR_URL" "$MR_HEAD"
merge "$MR_URL"; check "GitLab: PASS at live head merges with --sha" merged "mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD"
setup 18-forgejo-no-record forgejo
merge "$FJ_URL"; check "Forgejo: no record refused, merge never called" refused 'review record is missing'
setup 19-forgejo-valid-pass forgejo
review "$FJ_URL" "$FJ_HEAD"
merge "$FJ_URL"; check "Forgejo: PASS at live head merges with head_commit_id" merged "head_commit_id=$FJ_HEAD"

# ---- Recording helper ----
echo; echo "=================================================================="; echo "SCENARIO: 20-record-input-guards"; echo "=================================================================="
new_lab
rc=0; (cd / && env -u FM_HOME "$WT/bin/fm-review-record.py" captain-word --pr "$URL" --head "$HEAD_LIVE" --words x) || rc=$?
check "no FM_HOME refused with exit 2" [ "$rc" -eq 2 ]
rc=0; (cd / && FM_HOME=relative/home "$WT/bin/fm-review-record.py" captain-word --pr "$URL" --head "$HEAD_LIVE" --words x) || rc=$?
check "relative FM_HOME refused with exit 2" [ "$rc" -eq 2 ]
rc=0; (cd / && FM_HOME="$LAB/typo-home" "$WT/bin/fm-review-record.py" captain-word --pr "$URL" --head "$HEAD_LIVE" --words x) || rc=$?
check "nonexistent FM_HOME refused with exit 2 and not created" bash -c '[ "$1" -eq 2 ] && [ ! -e "$2" ]' _ "$rc" "$LAB/typo-home"
rc=0; out=$(review "$URL" "$HEAD_LIVE" --verdict MAYBE 2>&1) || rc=$?; echo "$out"
check "unknown verdict refused, field named" bash -c '[ "$1" -eq 2 ] && grep -q "verdict must be PASS or FAIL" <<<"$2"' _ "$rc" "$out"
rc=0; out=$(review "not-a-pr-url" "$HEAD_LIVE" 2>&1) || rc=$?; echo "$out"
check "unparseable PR URL refused, field named" bash -c '[ "$1" -eq 2 ] && grep -q "pr must be a parseable" <<<"$2"' _ "$rc" "$out"
rc=0; out=$(review "$URL" "$HEAD_LIVE" --report '' 2>&1) || rc=$?; echo "$out"
check "empty report refused, field named" bash -c '[ "$1" -eq 2 ] && grep -q "report must be non-empty" <<<"$2"' _ "$rc" "$out"
rc=0; out=$(review "$URL" main 2>&1) || rc=$?; echo "$out"
check "non-sha head refused, field named" bash -c '[ "$1" -eq 2 ] && grep -q "head must be an exact full commit sha" <<<"$2"' _ "$rc" "$out"
check "refused input wrote no ledger" [ ! -e "$LAB/state/review-records.jsonl" ]

echo; echo "=================================================================="; echo "SCENARIO: 21-append-only-newest-wins"; echo "=================================================================="
review "$URL" "$HEAD_OLD" --verdict FAIL
head -c 100000 "$LAB/state/review-records.jsonl" > "$S/first-bytes"
review "$URL" "$HEAD_LIVE" --reader-model gemini-3-pro --author-groups '{"initial":["claude-opus-5-5"],"fixes":["gpt-5.1-codex"]}'
rec latest --pr "$URL" | tee /dev/stderr | grep "^{" > "$S/latest21"
echo "  ledger rows: $(wc -l < "$LAB/state/review-records.jsonl")"
check "ledger keeps both rows and the first row bytes are unchanged" bash -c '[ "$(wc -l < "$1")" -eq 2 ] && cmp -s "$2" <(head -n1 "$1")' _ "$LAB/state/review-records.jsonl" "$S/first-bytes"
check "latest returns the newest review with all fields" bash -c 'jq -e ".review | .verdict==\"PASS\" and .head==\"'$HEAD_LIVE'\" and .reader_family==\"google\" and .author_groups.initial[0].family==\"anthropic\" and .author_groups.fixes[0].family==\"openai\" and .loosens_deny_allow_list==\"no\" and .widens_guard==\"no\" and .customer_data_billing_spend==\"no\" and .report==\"/reports/review.md\"" "$1" >/dev/null' _ "$S/latest21"
ls -l "$LAB/state/review-records.jsonl"

echo
echo "TOTAL CHECKS: pass=$PASSN fail=$FAILN"
for l in "${LABS[@]}"; do rm -rf "$l"; done
rm -rf "$TMP_ROOT"
[ "$FAILN" -eq 0 ]
