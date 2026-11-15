#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2329  # ok only prints, so not_ok never runs after a passing check; the child bash expands each case's library code; cases run by name from CASES.
# Helper-level tests for close at merge and typed completions (Main 1851; Main 1850 limits).
# Each case sources only bin/ libraries and calls their functions on fixture text: no case runs
# tasks-axi, a merge, a timed or progress runner, a kill, a process group, a spawn or a
# teardown, and this file does not source tests/lib.sh. The end-to-end cases for the same
# rulings are in tests/fm-pr-close-items.test.sh.
#
# Usage: bash tests/fm-close-at-merge-helpers.test.sh [case...]
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-close-helpers.XXXXXX") || exit 1
trap 'rm -rf -- "$TMP"' EXIT
FAILED=0
BEGIN='<!-- firstmate-backlog-closes:begin -->'
END='<!-- firstmate-backlog-closes:end -->'

ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; FAILED=1; }
# in_lib <library> <shell code>: runs the code in a fresh bash with the library sourced.
in_lib() { bash -c '. "$1"; eval "$2"' _ "$ROOT/bin/$1" "$2"; }
field() { printf '%s\n' "$1" | awk -F '\t' -v t="$2" '$1 == t { print substr($0, length(t) + 2) }'; }

# Main 1851 F1: when the member list cannot be read for validation, the whole block is refused
# before any item in it can act. Controls: the same block without the failure is honored; an
# ordinary invalid member refuses.
test_f1_a_member_read_failure_refuses_the_whole_block() {
  local body=$TMP/f1.md out
  printf '%s\n' "$BEGIN" 'Closes-backlog-item: guard-failed' 'Train-member: https://github.com/example/repo/pull/7' "$END" > "$body"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_values() { [ "$2" = member ] && return 1; printf "%s\n" "$1" | awk -F "\t" -v t="$2" "\$1 == t { print substr(\$0, length(t) + 2) }"; }
    fm_pr_closes_parse "'"$body"'" https://github.com/example/repo/pull/99')
  if [ "$(field "$out" status)" = refused ] && [ -z "$(field "$out" id)" ] && field "$out" reason | grep -q 'Train-member values could not be read'; then
    ok "f1: a failed member read refuses the whole block, with no id to act on"
  else
    not_ok "f1: a failed member read did not refuse the block: $(printf '%s' "$out" | tr '\n\t' '|:')"
  fi
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" https://github.com/example/repo/pull/99')
  [ "$(field "$out" status)" = block ] && [ "$(field "$out" id)" = guard-failed ] \
    && ok "f1 control: the same block is honored when the member read succeeds" \
    || not_ok "f1 control: the valid block was not honored"
  printf '%s\n' "$BEGIN" 'Closes-backlog-item: guard-failed' 'Train-member: https://example.com/not-a-pr' "$END" > "$body"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" https://github.com/example/repo/pull/99')
  [ "$(field "$out" status)" = refused ] && [ -z "$(field "$out" id)" ] \
    && ok "f1 control: an ordinary invalid member refuses the block" \
    || not_ok "f1 control: an invalid member did not refuse"
}

# Main 1851 F2: a parse result is loaded whole; when any reader fails part way, the loader fails
# with nothing loaded, so no item of that body can act. Control: a normal load gives both ids.
test_f2_a_partial_result_read_loads_nothing() {
  local body=$TMP/f2.md out
  printf '%s\n' "$BEGIN" 'Closes-backlog-item: first-id' 'Closes-backlog-item: second-id' "$END" > "$body"
  in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" https://github.com/example/repo/pull/9' > "$body.parse"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_load "'"$body.parse"'"; printf "rc=%s status=%s ids=%s\n" "$?" "$FM_PR_CLOSES_STATUS" "$(printf "%s" "$FM_PR_CLOSES_IDS" | tr "\n" ",")"')
  [ "$out" = 'rc=0 status=block ids=first-id,second-id' ] \
    && ok "f2 control: a normal load gives the status and both ids" \
    || not_ok "f2 control: the normal load gave: $out"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_get() { if [ "$2" = id ]; then echo first-id; return 1; fi; awk -F "\t" -v t="$2" "\$1 == t { print substr(\$0, length(t) + 2) }" "$1"; }
    fm_pr_closes_load "'"$body.parse"'"; printf "rc=%s status=%s ids=%s\n" "$?" "$FM_PR_CLOSES_STATUS" "$FM_PR_CLOSES_IDS"')
  [ "$out" = 'rc=1 status= ids=' ] \
    && ok "f2: a reader that emits the first id and then fails loads nothing" \
    || not_ok "f2: a partial read was loaded: $out"
}

# Main 1853 (Main 1851 F3): after exit 0 and an unreadable row, the store's active rows decide:
# any row with that id that is not done keeps every edge; absent or done clears.
test_f3_the_store_verdict_keeps_an_unfinished_item_under_the_id() {
  local out
  out=$(in_lib fm-tasks-axi-lib.sh 'printf "%s\n" "other:done" "pf-x:queued" | fm_typed_completion_store_verdict pf-x')
  [ "$out" = 'keep queued' ] && ok "f3: a queued item under the id keeps the edges" || not_ok "f3: a queued item under the id gave: $out"
  out=$(in_lib fm-tasks-axi-lib.sh 'printf "%s\n" "pf-x:done" "pf-x:in_flight" | fm_typed_completion_store_verdict pf-x')
  [ "$out" = 'keep in_flight' ] && ok "f3: any unfinished row under the id keeps the edges" || not_ok "f3: a mixed id gave: $out"
  out=$(in_lib fm-tasks-axi-lib.sh 'printf "%s\n" "pf-x:done" "pf-xx:queued" | fm_typed_completion_store_verdict pf-x')
  [ "$out" = 'clear' ] && ok "f3 control: a done row under the id clears" || not_ok "f3 control: a done row gave: $out"
  out=$(in_lib fm-tasks-axi-lib.sh 'printf "%s\n" "other:queued" | fm_typed_completion_store_verdict pf-x')
  [ "$out" = 'clear' ] && ok "f3 control: an id absent from the active backlog clears" || not_ok "f3 control: an absent id gave: $out"
}

# Main 1851 F4: the id is resolved with tasks-axi's own grammar in every form it accepts.
test_f4_every_typed_form_resolves_its_id() {
  local args want got
  while IFS='|' read -r want args; do
    got=$(in_lib fm-tasks-axi-lib.sh "fm_typed_completion_resolve $args; printf '%s %s %s' \"\$?\" \"\$FM_TYPED_COMPLETION\" \"\$FM_TYPED_COMPLETION_ID\"")
    [ "$got" = "$want" ] && ok "f4: $args -> $want" || not_ok "f4: $args gave '$got', not '$want'"
  done <<'CASES'
0 waive pf-a|public-followup waive pf-a --reason r --approved-by captain
0 waive pf-flags|public-followup waive --json pf-flags --reason r --approved-by captain
0 waive pf-noun|task public-followup waive pf-noun --reason r --approved-by captain --json
0 waive pf-eq|public-followup waive --reason=r --approved-by=captain pf-eq
0 waive pf-last|public-followup waive --reason r --approved-by captain --json pf-last
0 record-delivery pf-rd|public-followup record-delivery --receipt-file f.json pf-rd
0 record-delivery pf-rd2|task public-followup record-delivery --json --receipt-file=f.json pf-rd2
2 waive |public-followup waive pf-one pf-two --reason r --approved-by captain
2 waive |public-followup waive pf-a --reason --json --approved-by captain
2 record-delivery |public-followup record-delivery --receipt-file f.json
3 waive |public-followup waive --help
1  |done pf-a --note x
1  |public-followup begin-delivery pf-a --payload-hash x
CASES
}

# Main 1851 F5: a NUL byte refuses the body even with no marker, with that reason. Controls: an
# ordinary body with no marker is no block; a NUL inside a block refuses.
test_f5_a_nul_without_a_marker_is_refused() {
  local body=$TMP/f5.md out
  printf 'Prose with a NUL\000 byte and no marker.\n' > "$body"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" https://github.com/example/repo/pull/9')
  [ "$(field "$out" status)" = refused ] && field "$out" reason | grep -q 'body contains a NUL byte' \
    && ok "f5: a NUL in a body with no marker is refused with that reason" \
    || not_ok "f5: a NUL body with no marker gave: $(printf '%s' "$out" | tr '\n\t' '|:')"
  printf 'Prose with no marker.\n' > "$body"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" https://github.com/example/repo/pull/9')
  [ "$(field "$out" status)" = none ] && ok "f5 control: a plain body with no marker is no block" || not_ok "f5 control: a plain body was not status none"
  { printf '%s\n' "$BEGIN" 'Closes-backlog-item: nul-a'; printf 'Train-member: https://github.com/example/re\000po/pull/7\n'; printf '%s\n' "$END"; } > "$body"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" https://github.com/example/repo/pull/9')
  [ "$(field "$out" status)" = refused ] && [ -z "$(field "$out" id)" ] && ok "f5 control: a NUL inside a block refuses it" || not_ok "f5 control: a NUL inside a block was not refused"
}

# The callers use these helpers (text checks of the scripts).
test_the_callers_use_the_checked_helpers() {
  grep -q 'fm_pr_closes_load "\$1.parse"' "$ROOT/bin/fm-pr-close-items.sh" \
    && ! grep -q 'done < <(got "\$WORK/body" id)' "$ROOT/bin/fm-pr-close-items.sh" \
    && ok "f2: the close step loads each parse result whole" || not_ok "f2: the close step still reads ids through a process substitution"
  grep -q '|| close_rc=\$?' "$ROOT/bin/fm-pr-merge.sh" \
    && ok "f2: the merge script checks the close step's status" || not_ok "f2: the merge script ignores the close step's status"
  grep -q 'fm_typed_completion_resolve "\${ARGS\[@\]}"' "$ROOT/bin/fm-tasks-axi.sh" \
    && grep -q 'fm_typed_completion_store_verdict "\$pf_id"' "$ROOT/bin/fm-tasks-axi.sh" \
    && ok "f3 and f4: the wrapper resolves every typed form and asks the store before clearing" \
    || not_ok "f3 and f4: the wrapper does not use the resolver and the store verdict"
}

CASES=(
test_f1_a_member_read_failure_refuses_the_whole_block
test_f2_a_partial_result_read_loads_nothing
test_f3_the_store_verdict_keeps_an_unfinished_item_under_the_id
test_f4_every_typed_form_resolves_its_id
test_f5_a_nul_without_a_marker_is_refused
test_the_callers_use_the_checked_helpers
)
if [ "$#" -gt 0 ]; then CASES=("$@"); fi
for case_name in "${CASES[@]}"; do
  declare -F "$case_name" >/dev/null || { not_ok "unknown case $case_name"; continue; }
  "$case_name"
done
exit "$FAILED"
