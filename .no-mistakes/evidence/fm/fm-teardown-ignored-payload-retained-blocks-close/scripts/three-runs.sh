#!/usr/bin/env bash
# Drives the real bin/fm-teardown.sh (TEARDOWN may be overridden to a base tree) through
# first / unchanged-retry / changed-retry against a disposable kept-copy fixture.
set -u
WT=$1; TD=${2:-}
. "$WT/tests/fm-teardown-helpers.sh"
[ -n "$TD" ] && TEARDOWN=$TD
echo "teardown under test: $TEARDOWN"
make_retained_case live-three enclosing
held_plain_get_slot "$FOREIGN_CASE"
held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
: > "$FOREIGN_CASE/no-lease-command"   # make run 1 refuse at the lease so a retry happens
show() {
  echo "--- $1: exit=$rc driver-calls=$(retained_call_count) tars=$(retained_tar_count) saved-outputs=$(ls "$FOREIGN_CASE/data/task-x1/" 2>/dev/null | grep -c vernant-closeout) task-record=$([ -f "$FOREIGN_CASE/state/task-x1.meta" ] && echo present || echo gone) copy=$([ -d "$FOREIGN_COPY/.git" ] || [ -f "$FOREIGN_COPY/.git" ] && echo present || echo gone)"
  grep -E 'REFUSED|notice|retained record|kept|closed' "$FOREIGN_CASE/stdout" "$FOREIGN_CASE/stderr" | sed "s#$FOREIGN_CASE#<case>#g" | head -8
}
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained; show "run 1 (slot cannot be leased)"
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained; show "run 2 (copy unchanged)"
printf 'three\n' > "$FOREIGN_COPY/.claude/channel-outbox/c.jsonl"
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained FM_STUB_UNIQUE=".claude/channel-outbox/a.jsonl .claude/channel-outbox/b.jsonl .claude/channel-outbox/c.jsonl"; show "run 3 (one more unique ignored file)"
rm -f "$FOREIGN_CASE/no-lease-command"
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained FM_STUB_UNIQUE=".claude/channel-outbox/a.jsonl .claude/channel-outbox/b.jsonl .claude/channel-outbox/c.jsonl"; show "run 4 (lease available, copy unchanged since run 3)"
rec=$(retained_record_path)
echo "--- retained record ($([ -f "$rec" ] && echo present || echo absent)):"
[ -f "$rec" ] && sed "s#$FOREIGN_CASE#<case>#g" "$rec"
echo "--- backlog row: $(backlog_row_state "$FOREIGN_CASE")"
echo "--- slot lease file unchanged: $(cmp -s "$FOREIGN_CASE/lease-before" "$FOREIGN_CASE/pool/treehouse-state.json" && echo yes || echo no); pool return ran: $([ -f "$FOREIGN_CASE/treehouse.log" ] && echo yes || echo no)"
