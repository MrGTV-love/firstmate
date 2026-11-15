#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2329  # ok only prints, so not_ok never runs after a passing check; each child bash expands its own code; cases run by name from CASES.
# Helper-level tests for close at merge and typed completions (Main 1851, 1875; Main 1850
# limits). Each case sources bin/ libraries, or takes one named function or the typed branch out
# of a bin/ script, and runs it on fixture text with one read failure injected by a shell
# function. No case runs tasks-axi, a forge, a merge, a timed or progress runner, a kill, a
# process group, a spawn or a teardown, and this file does not source tests/lib.sh. Each
# witness calls code that exists at the reviewed head 1719e38d7 too, so its red there is a wrong
# result, not a missing function. The end-to-end cases for the same rulings are in
# tests/fm-pr-close-items.test.sh and are owed to CI.
#
# Usage: bash tests/fm-close-at-merge-helpers.test.sh [case...]
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-close-helpers.XXXXXX") || exit 1
trap 'chmod -R u+rw -- "$TMP" 2>/dev/null; rm -rf -- "$TMP"' EXIT
FAILED=0
BEGIN='<!-- firstmate-backlog-closes:begin -->'
END='<!-- firstmate-backlog-closes:end -->'
MERGED_URL=https://github.com/example/repo/pull/99

ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; FAILED=1; }
check() {  # <label> <want> <got>
  if [ "$3" = "$2" ]; then ok "$1"; else not_ok "$1: got '$(printf '%s' "$3" | tr '\n\t' '|:')', want '$(printf '%s' "$2" | tr '\n\t' '|:')'"; fi
}
# in_lib <library> <shell code>: runs the code in a fresh bash with the library sourced.
in_lib() { bash -c '. "$1"; eval "$2"' _ "$ROOT/bin/$1" "$2"; }
field() { awk -F '\t' -v t="$2" '$1 == t { print substr($0, length(t) + 2) }' <<< "$1"; }
# A definition text holding named functions from one bin/ script (those it has), for eval.
defs() {  # <script> <function...>
  local script=$ROOT/bin/$1 name
  shift
  for name in "$@"; do
    awk -v name="$name" '$0 ~ "^" name "\\(\\) \\{" {copy=1} copy {print} copy && /^}/ {exit}' "$script"
  done
}

# Main 1875 F1 (the reviewer's witness): the producer that feeds the member extractor prints a
# cut list and fails while its consumer succeeds; the parse must still refuse the invalid
# member. Controls: the same body without the injection refuses; a valid block is honored.
test_f1_a_failed_member_producer_refuses_the_block() {
  local body=$TMP/f1.md valid=$TMP/f1-valid.md out
  printf '%s\n' "$BEGIN" 'Closes-backlog-item: guard-failed' 'Train-member: https://example.com/not-a-pr' "$END" > "$body"
  printf '%s\n' "$BEGIN" 'Closes-backlog-item: guard-valid' 'Train-member: https://github.com/example/repo/pull/7' "$END" > "$valid"
  out=$(in_lib fm-pr-closes-lib.sh 'printf() {
      if [ "${FUNCNAME[1]-}" = fm_pr_closes_values ]; then builtin printf "status\tblock\nid\tguard-failed\n"; return 74; fi
      builtin printf "$@"; }
    r=$(fm_pr_closes_parse "'"$body"'" '"$MERGED_URL"'); builtin printf "%s\n" "$r"')
  check "f1: a cut, failed member producer still refuses the invalid member" "refused" "$(field "$out" status)"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" '"$MERGED_URL")
  check "f1 control: the invalid member refuses without the injection" "refused" "$(field "$out" status)"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$valid"'" '"$MERGED_URL")
  check "f1 control: a valid block is honored" "block guard-valid" "$(field "$out" status) $(field "$out" id)"
}

# Main 1875 F1: the NUL byte count is checked stage by stage. A byte count that fails must not
# pass for "no NUL byte". Control: with a real count, the NUL refuses the body.
test_f1_a_failed_byte_count_is_no_proof_of_no_nul() {
  local body=$TMP/f1-nul.md out
  { printf '%s\n' "$BEGIN" 'Closes-backlog-item: nul-guard' "$END"; printf 'prose with a NUL\000 byte\n'; } > "$body"
  out=$(in_lib fm-pr-closes-lib.sh 'wc() { return 74; }
    fm_pr_closes_parse "'"$body"'" '"$MERGED_URL")
  case "$(field "$out" status)" in
    block|none) not_ok "f1: a failed byte count let a body with a NUL byte through as $(field "$out" status)" ;;
    *) ok "f1: a failed byte count closes nothing ($(field "$out" status))" ;;
  esac
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" '"$MERGED_URL")
  check "f1 control: with a real count the NUL refuses the body" "refused" "$(field "$out" status)"
}

# Main 1875 (Main 1741 stands): a carriage return is a control byte, so a CRLF block refuses.
# Control: the same block with LF line ends is honored.
test_crlf_a_carriage_return_in_a_block_refuses() {
  local crlf=$TMP/crlf.md lf=$TMP/lf.md out
  printf '%s\r\n' "$BEGIN" 'Closes-backlog-item: carriage-case' "$END" > "$crlf"
  printf '%s\n' "$BEGIN" 'Closes-backlog-item: carriage-case' "$END" > "$lf"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$crlf"'" '"$MERGED_URL")
  check "crlf: a block with CRLF line ends is refused" "refused" "$(field "$out" status)"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$lf"'" '"$MERGED_URL")
  check "crlf control: the same block with LF line ends is honored" "block" "$(field "$out" status)"
}

# Main 1875 rule P: a parse result is read whole or not at all. A result cut short (the second
# id lost) must not load; a complete one loads with every record the close step reports from.
test_p_a_cut_parse_result_does_not_load() {
  local body=$TMP/p.md out
  printf '%s\n' "$BEGIN" 'Closes-backlog-item: first-id' 'Closes-backlog-item: second-id' "$END" 'Closes: old-id' > "$body"
  in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" '"$MERGED_URL" > "$body.parse"
  head -n 2 "$body.parse" > "$body.cut.parse"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_load "'"$body.cut.parse"'"; builtin printf "rc=%s ids=%s" "$?" "$(tr "\n" , <<< "$FM_PR_CLOSES_IDS")"')
  case "$out" in rc=0*) not_ok "p: a cut parse result loaded: $out" ;; *) ok "p: a cut parse result does not load" ;; esac
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_load "'"$body.parse"'"; builtin printf "rc=%s ids=%s legacy=%s" "$?" "$(tr "\n" , <<< "$FM_PR_CLOSES_IDS")" "${FM_PR_CLOSES_LEGACY:-unset}"')
  check "p: a complete result loads with its ids and its report records" "rc=0 ids=first-id,second-id, legacy=old-id" "$out"
  out=$(in_lib fm-pr-closes-lib.sh 'cat() { return 74; }; fm_pr_closes_load "'"$body.parse"'"; builtin printf "rc=%s ids=%s" "$?" "$FM_PR_CLOSES_IDS"')
  case "$out" in 'rc=0 '*) not_ok "p: a failed read of the result loaded: $out" ;; *) ok "p: a failed read of the result loads nothing" ;; esac
}

# Main 1875 F5 (the reviewer's witness): when the parse result cannot be read, the refusal
# report must not vanish: a line is printed and the body counts as left open. The witness
# fails every reader of the result (the per-type reader and the whole-result loader).
test_f5_an_unreadable_result_is_reported_never_silent() {
  local out
  out=$(bash -c 'eval "$1"; set -u
    fm_pr_closes_load() { return 74; }
    fm_pr_closes_get() { return 74; }
    TASK_ID=review-task URL=https://github.com/example/repo/pull/99 LEFT=0 FM_PR_CLOSES_LOADED=""
    FM_PR_CLOSES_BEGIN=b FM_PR_CLOSES_END=e
    report_refusal "$2/fixture" "the body of the fixture" 2>"$2/f5.err"
    builtin printf "left=%s lines=%s" "$LEFT" "$(grep -c . "$2/f5.err")"' _ \
    "$(defs fm-pr-close-items.sh got report_read joined report_refusal body_unread load_body loaded_for left_open)" "$TMP")
  case "$out" in 'left=0 '*|*' lines=0') not_ok "f5: an unreadable result gave no report: $out" ;; *) ok "f5: an unreadable result is reported and counted ($out)" ;; esac
}

# Main 1875 F6: a forge answer without its body field is a failed read, never an empty body.
# Controls: a present empty body reads as empty; a present body reads as itself.
test_f6_a_missing_body_field_is_a_failed_read() {
  local out provider json want
  while IFS='|' read -r provider json want; do
    out=$(bash -c 'eval "$1"; . "$2/bin/fm-pr-lib.sh"; set -u
      FIXTURE=$3
      fm_pr_forgejo_login() { builtin printf "login\n"; }
      tea() { builtin printf "%s\n" "$FIXTURE"; }
      glab() { builtin printf "%s\n" "$FIXTURE"; }
      gh() { local q="" prev="" a; for a in "$@"; do [ "$prev" != --jq ] || q=$a; prev=$a; done; jq -r "$q" <<< "$FIXTURE"; }
      case "$4" in
        forgejo) u=https://codeberg.org/example/repo/pulls/5 ;;
        gitlab) u=https://gitlab.com/example/repo/-/merge_requests/5 ;;
        *) u=https://github.com/example/repo/pull/5 ;;
      esac
      if read_body "$u" "$5/f6-$4"; then builtin printf "read:%s" "$(cat "$5/f6-$4")"; else builtin printf "failed"; fi' _ \
      "$(defs fm-pr-close-items.sh read_body)" "$ROOT" "$json" "$provider" "$TMP" 2>/dev/null)
    check "f6: $provider $json" "$want" "$out"
  done <<'CASES'
forgejo|{"merged":true}|failed
gitlab|{"state":"merged"}|failed
github|{"state":"MERGED"}|failed
forgejo|{"merged":true,"body":""}|read:
gitlab|{"state":"merged","description":null}|read:
github|{"state":"MERGED","body":"text"}|read:text
CASES
}

# Main 1875 F7: a task record that cannot be read while train members are matched is unknown,
# never "no match": it is reported and counted. Controls: a readable record whose last pr= is the
# member matches; one whose last pr= is another URL does not.
test_f7_an_unreadable_task_record_is_reported() {
  local state=$TMP/f7-state url=https://github.com/example/repo/pull/7 out
  mkdir -p "$state"
  printf 'pr=%s\n' "$url" > "$state/task-readable.meta"
  printf 'pr=%s\npr=https://github.com/example/repo/pull/8\n' "$url" > "$state/task-moved.meta"
  printf 'pr=%s\n' "$url" > "$state/task-locked.meta"
  chmod 000 "$state/task-locked.meta"
  out=$(bash -c 'eval "$1"; . "$2/bin/fm-pr-lib.sh"; set -u
    STATE=$3 TASK_ID=review-task URL=https://github.com/example/repo/pull/99 LEFT=0 RECORDING_TASKS=""
    # One call in this shell, so its count and its list are read here; its stdout is kept too.
    tasks_recording_pr "$4" >"$3/../f7.out" 2>"$3/../f7.err"
    found=$(tr "\n" " " < "$3/../f7.out")$(tr "\n" " " <<< "$RECORDING_TASKS")
    builtin printf "left=%s err=%s found=%s" "$LEFT" "$(grep -c task-locked "$3/../f7.err")" "$found"' _ \
    "$(defs fm-backend.sh fm_meta_get fm_meta_get_to; defs fm-pr-close-items.sh tasks_recording_pr)" "$ROOT" "$state" "$url")
  chmod 600 "$state/task-locked.meta"
  case "$out" in 'left=0 '*|*' err=0 '*) not_ok "f7: an unreadable task record was taken as no match: $out" ;; *) ok "f7: an unreadable task record is reported and counted" ;; esac
  case "$out" in *task-readable*) ok "f7 control: a record whose last pr= is the member matches" ;; *) not_ok "f7 control: the matching record was not found: $out" ;; esac
  case "$out" in *task-moved*) not_ok "f7 control: a record whose last pr= is another URL matched" ;; *) ok "f7 control: a record whose last pr= is another URL does not match" ;; esac
}

# The typed branch of bin/fm-tasks-axi.sh, run with every I/O and mutation stubbed: no
# tasks-axi, no backlog, no runner.
typed_branch() {  # <probe: done|missing|unreadable> <replay: ok|cut> [args...]
  local probe=$1 replay=$2
  shift 2
  bash -c 'branch=$(awk "/^pf_form=0\$/ {copy=1} /^exec tasks-axi / {exit} copy {print}" "$1/bin/fm-tasks-axi.sh")
    . "$1/bin/fm-tasks-axi-lib.sh"; set -u
    PROBE=$2 REPLAY=$3; shift 3
    ARGS=("$@") DATA=/dev/null
    mktemp() { builtin printf "/dev/null\n"; }
    rm() { :; }
    tasks-axi() { builtin printf "{\"ok\":true}\n"; }
    cat() { if [ "$REPLAY" = ok ]; then builtin printf "{\"ok\":true}\n"; else builtin printf "{\"ok\":"; return 74; fi; }
    fm_backlog_row_probe() {
      case "$PROBE" in
        done) FM_BACKLOG_ROW_STATE=done FM_BACKLOG_ROW_RESULT=found; return 0 ;;
        missing) FM_BACKLOG_ROW_RESULT=not_found; return 1 ;;
        *) FM_BACKLOG_ROW_RESULT=error FM_BACKLOG_ROW_ERROR="simulated read failure"; return 1 ;;
      esac
    }
    fm_backlog_row_states() { builtin printf "pf-x:done\n"; }
    fm_backlog_unblock_dependents() { builtin printf "UNBLOCK %s\n" "$2"; }
    eval "$branch"' _ "$ROOT" "$probe" "$replay" "$@"
}

# Main 1875: after exit 0 and an unreadable row, every edge and hold is kept and the item is
# reported "closed, edges kept: row unreadable". Controls: a row that reads done, or that is no
# longer in the backlog, clears.
test_subtraction_an_unreadable_row_keeps_every_edge() {
  local out
  out=$(typed_branch unreadable ok public-followup waive pf-x --reason r --approved-by captain 2>&1)
  case "$out" in *UNBLOCK*) not_ok "subtraction: an unreadable row cleared edges: $(tr '\n' '|' <<< "$out")" ;; *) ok "subtraction: an unreadable row clears no edge" ;; esac
  case "$out" in *'pf-x: closed, edges kept: row unreadable'*) ok "subtraction: the item is reported as closed, edges kept: row unreadable" ;; *) not_ok "subtraction: the report is missing: $(tr '\n' '|' <<< "$out")" ;; esac
  out=$(typed_branch "done" ok public-followup waive pf-x --reason r --approved-by captain 2>&1)
  case "$out" in *'UNBLOCK pf-x'*) ok "subtraction control: a row that reads done clears" ;; *) not_ok "subtraction control: a done row did not clear" ;; esac
  out=$(typed_branch missing ok public-followup waive pf-x --reason r --approved-by captain 2>&1)
  case "$out" in *'UNBLOCK pf-x'*) ok "subtraction control: a row no longer in the backlog clears" ;; *) not_ok "subtraction control: an archived row did not clear" ;; esac
}

# Main 1875 F8: a replay of the kept output that fails is reported and the wrapper exits 1, so a
# JSON caller is not handed cut output as success. Control: an intact replay exits 0 with it.
test_f8_a_failed_replay_is_not_success() {
  local out rc
  out=$(typed_branch "done" cut public-followup waive pf-x --reason r --approved-by captain --json 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && ok "f8: a cut replay does not exit 0 (status $rc)" || not_ok "f8: a cut replay exited 0 with '$out'"
  out=$(typed_branch "done" ok public-followup waive pf-x --reason r --approved-by captain --json 2>/dev/null); rc=$?
  check "f8 control: an intact replay exits 0 with the output" '0 {"ok":true}' "$rc $out"
}

# A bare wrapper call has no arguments; under `set -u` the typed branch must not stop bash 3.2.
test_f4_a_call_with_no_arguments_runs() {
  local out
  out=$(typed_branch "done" ok 2>&1; printf 'rc=%s' "$?")
  case "$out" in *unbound*) not_ok "f4: a bare call stopped: $out" ;; *) ok "f4: a bare call passes the typed branch under set -u" ;; esac
}

# Main 1851 F4 and Main 1875 F3: the id is resolved with tasks-axi's own grammar in every form
# it accepts, the global --backend flag included wherever cli.js takes it out.
test_f4_every_typed_form_resolves_its_id() {
  local args want got
  while IFS='|' read -r want args; do
    got=$(in_lib fm-tasks-axi-lib.sh "fm_typed_completion_resolve $args; printf '%s %s %s' \"\$?\" \"\$FM_TYPED_COMPLETION\" \"\$FM_TYPED_COMPLETION_ID\"")
    check "f4: $args" "$want" "$got"
  done <<'CASES'
0 waive pf-a|public-followup waive pf-a --reason r --approved-by captain
0 waive pf-flags|public-followup waive --json pf-flags --reason r --approved-by captain
0 waive pf-noun|task public-followup waive pf-noun --reason r --approved-by captain --json
0 waive pf-eq|public-followup waive --reason=r --approved-by=captain pf-eq
0 waive pf-last|public-followup waive --reason r --approved-by captain --json pf-last
0 record-delivery pf-rd|public-followup record-delivery --receipt-file f.json pf-rd
0 record-delivery pf-rd2|task public-followup record-delivery --json --receipt-file=f.json pf-rd2
0 waive pf-be|public-followup --backend=markdown waive pf-be --reason r --approved-by captain
0 waive pf-bt|public-followup waive pf-bt --reason r --approved-by captain --backend=markdown
0 waive pf-bs|public-followup --backend markdown waive pf-bs --reason r --approved-by captain
0 record-delivery pf-bm|task public-followup record-delivery pf-bm --backend markdown --receipt-file f.json
0 waive pf-dash|public-followup waive pf-dash --reason -h --approved-by captain
2 waive |public-followup waive pf-one pf-two --reason r --approved-by captain
2 waive |public-followup waive pf-a --reason --json --approved-by captain
2 waive |public-followup waive pf-a --reason r --approved-by captain --backend
2 waive |public-followup --backend= waive pf-a --reason r --approved-by captain
2 record-delivery |public-followup record-delivery --receipt-file f.json
2 waive |public-followup waive pf-a --reason r --approved-by captain -h
3 waive |public-followup waive --help
3 waive |public-followup waive pf-a --reason --help --approved-by captain
3 record-delivery |task public-followup record-delivery pf-a --receipt-file f.json --help
1  |done pf-a --note x
1  |public-followup begin-delivery pf-a --payload-hash x
1  |public-followup --backend=markdown ready
CASES
}

# Main 1851 F5: a NUL byte refuses the body even with no marker, with that reason. Controls: an
# ordinary body with no marker is no block; a NUL inside a block refuses.
test_f5_a_nul_without_a_marker_is_refused() {
  local body=$TMP/f5.md out
  printf 'Prose with a NUL\000 byte and no marker.\n' > "$body"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" '"$MERGED_URL")
  [ "$(field "$out" status)" = refused ] && grep -q 'body contains a NUL byte' <<< "$(field "$out" reason)" \
    && ok "f5: a NUL in a body with no marker is refused with that reason" \
    || not_ok "f5: a NUL body with no marker gave: $(tr '\n\t' '|:' <<< "$out")"
  printf 'Prose with no marker.\n' > "$body"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" '"$MERGED_URL")
  check "f5 control: a plain body with no marker is no block" none "$(field "$out" status)"
  { printf '%s\n' "$BEGIN" 'Closes-backlog-item: nul-a'; printf 'Train-member: https://github.com/example/re\000po/pull/7\n'; printf '%s\n' "$END"; } > "$body"
  out=$(in_lib fm-pr-closes-lib.sh 'fm_pr_closes_parse "'"$body"'" '"$MERGED_URL")
  check "f5 control: a NUL inside a block refuses it, with no id" "refused " "$(field "$out" status) $(field "$out" id)"
}

CASES=(
test_f1_a_failed_member_producer_refuses_the_block
test_f1_a_failed_byte_count_is_no_proof_of_no_nul
test_crlf_a_carriage_return_in_a_block_refuses
test_p_a_cut_parse_result_does_not_load
test_f5_an_unreadable_result_is_reported_never_silent
test_f6_a_missing_body_field_is_a_failed_read
test_f7_an_unreadable_task_record_is_reported
test_subtraction_an_unreadable_row_keeps_every_edge
test_f8_a_failed_replay_is_not_success
test_f4_a_call_with_no_arguments_runs
test_f4_every_typed_form_resolves_its_id
test_f5_a_nul_without_a_marker_is_refused
)
if [ "$#" -gt 0 ]; then CASES=("$@"); fi
for case_name in "${CASES[@]}"; do
  declare -F "$case_name" >/dev/null || { not_ok "unknown case $case_name"; continue; }
  "$case_name"
done
exit "$FAILED"
