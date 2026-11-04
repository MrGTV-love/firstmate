#!/usr/bin/env bash
set -u
WT=$1
. "$WT/tests/fm-teardown-helpers.sh"
summ() {
  echo "--- $1: exit=$rc driver-calls=$(retained_call_count) tars=$(retained_tar_count) task-record=$([ -f "$FOREIGN_CASE/state/task-x1.meta" ] && echo present || echo gone) copy=$([ -e "$FOREIGN_COPY/.git" ] && echo present || echo gone) retained-record=$([ -f "$(retained_record_path)" ] && echo present || echo absent) backlog=$(backlog_row_state "$FOREIGN_CASE") pool-return=$([ -f "$FOREIGN_CASE/treehouse.log" ] && echo ran || echo none)"
  grep -h 'REFUSED' "$FOREIGN_CASE/stderr" | sed "s#$FOREIGN_CASE#<case>#g" | cut -c1-420 | head -3
}
make_retained_case adv2-tamper enclosing
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained "FM_STUB_AFTER=printf 'changed\\n' > '$FOREIGN_COPY/.claude/channel-outbox/a.jsonl'"
summ "A: driver-named file a.jsonl changed after the preserve, run 1"
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
summ "A: retry (copy unchanged since run 1)"
make_retained_case adv2-unlanded enclosing
held_foreign_unlanded "$FOREIGN_COPY"
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
summ "D: copy has an unlanded content commit"
FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
summ "E: same copy, retry with --force --drop-file"
FOREIGN_TEARDOWN_ARGS=()
make_retained_case adv2-empty enclosing
git -C "$FOREIGN_COPY" -c user.name=t -c user.email=t@e commit -q --allow-empty -m 'empty commit, no content'
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
summ "G (probe): copy with one EMPTY commit not on the remote"
