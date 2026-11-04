#!/usr/bin/env bash
set -u
WT=$1
. "$WT/tests/fm-teardown-helpers.sh"
make_retained_case chain-sweep enclosing
run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
echo "teardown: exit=$rc driver-calls=$(retained_call_count) tars=$(retained_tar_count)"
rec=$(retained_record_path); sha_before=$(shasum -a 256 < "$rec")
H=$FOREIGN_CASE/sweep-home; mkdir -p "$H"; ln -s "$FOREIGN_CASE/data" "$H/data"; ln -s "$FOREIGN_CASE/config" "$H/config"; mkdir -p "$H/state"
for mode in report --apply --apply; do
  args=(); [ "$mode" = report ] || args=(--apply)
  out=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE FM_STUB_CLOSEOUT=retained \
    FM_TEARDOWN_VERNANT_PYTHON="$FOREIGN_CASE/vernant-python" PATH="$FOREIGN_CASE/fakebin:$PATH" FM_HOME="$H" \
    FM_COPY_SWEEP_TREEHOUSE_ROOT="$FOREIGN_CASE" "$WT/bin/fm-copy-sweep.sh" ${args[@]+"${args[@]}"} 2>&1); src=$?
  echo "sweep $mode: exit=$src driver-calls=$(retained_call_count) tars=$(retained_tar_count) record-unchanged=$([ "$(shasum -a 256 < "$rec")" = "$sha_before" ] && echo yes || echo no) copy-intact=$(held_fingerprint "$FOREIGN_COPY" | cmp -s - "$FOREIGN_CASE/held-before.$(basename "$FOREIGN_COPY")" && echo yes || echo no)"
  printf '%s\n' "$out" | sed "s#$FOREIGN_CASE#<case>#g" | grep -vE "^summary: [A-Z-]+=0$" | cut -c1-400 | head -12
done
