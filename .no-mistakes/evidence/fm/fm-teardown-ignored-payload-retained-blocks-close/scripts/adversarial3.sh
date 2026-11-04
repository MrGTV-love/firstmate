#!/usr/bin/env bash
set -u
WT=$1
. "$WT/tests/fm-teardown-helpers.sh"
make_retained_case adv3-tamper enclosing
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained "FM_STUB_AFTER=printf 'changed\\n' > '$FOREIGN_COPY/.claude/channel-outbox/a.jsonl'"
h=$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
echo "A: exit=$rc"
echo "A: copy a.jsonl    sha256 $(shasum -a 256 < "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl" | cut -c1-16) bytes=$(cat "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl")"
echo "A: preserve a.jsonl sha256 $(shasum -a 256 < "$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$h/.claude/channel-outbox/a.jsonl" | cut -c1-16) bytes=$(cat "$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$h/.claude/channel-outbox/a.jsonl")"
make_retained_case adv3-force enclosing
held_foreign_unlanded "$FOREIGN_COPY"
FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
for i in 1 2 3; do
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  echo "E forced unlanded run $i: exit=$rc driver-calls=$(retained_call_count) tars=$(retained_tar_count) saved-outputs=$(ls "$FOREIGN_CASE/data/task-x1/" | grep -c vernant-closeout) refusal-record=$([ -f "$(retained_refused_record_path)" ] && echo present || echo absent) task-record=$([ -f "$FOREIGN_CASE/state/task-x1.meta" ] && echo present || echo gone) copy=$([ -e "$FOREIGN_COPY/.git" ] && echo present || echo gone)"
  grep -h 'REFUSED' "$FOREIGN_CASE/stderr" | sed "s#$FOREIGN_CASE#<case>#g" | cut -c1-300 | tail -1
done
