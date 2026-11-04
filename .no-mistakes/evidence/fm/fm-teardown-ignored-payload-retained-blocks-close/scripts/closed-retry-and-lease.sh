#!/usr/bin/env bash
set -u
WT=$1
. "$WT/tests/fm-teardown-helpers.sh"
make_retained_case closed-retry enclosing
echo "== lease record before the close:"; sed "s#$FOREIGN_CASE#<case>#g" "$FOREIGN_CASE/pool/treehouse-state.json"
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
echo "== close: exit=$rc driver-calls=$(retained_call_count) tars=$(retained_tar_count)"
echo "== lease record after the close:"; sed "s#$FOREIGN_CASE#<case>#g" "$FOREIGN_CASE/pool/treehouse-state.json"
echo "== slot claim after the close:"; sed "s#$FOREIGN_CASE#<case>#g" "$FOREIGN_CASE/pool/1/.fm-slot-owner"
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
echo "== teardown again for the closed task: exit=$rc driver-calls=$(retained_call_count) tars=$(retained_tar_count) record=$([ -f "$(retained_record_path)" ] && echo present || echo absent)"
echo "-- stdout:"; sed "s#$FOREIGN_CASE#<case>#g" "$FOREIGN_CASE/stdout" | cut -c1-400
echo "-- stderr:"; sed "s#$FOREIGN_CASE#<case>#g" "$FOREIGN_CASE/stderr" | cut -c1-400
