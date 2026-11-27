#!/usr/bin/env bash
# One CLI run of bin/fm-control.sh <id> rerecord-slot (write, with the reviewed --manifest-sha) per guard, each on its
# own disposable fixture built by the suite's setup function of the same name. Prints the verb's own refusal line and
# whether the record, archives, audits and temporaries stayed byte-identical.
. "$(dirname "${BASH_SOURCE[0]}")/rr-lib.sh"
for c in H1:owner H2:copy-path N6:branch H3:base-backwards H4:base-off-default H5:base-not-merge-base \
         H6:scope-untouched-file H7:scope-untouched-dir H8:scope-uncovered-change H9:scope-release-strands-work \
         H11:agent-alive H13c:no-note H14:manifest-sha; do
  id=${c%%:*}
  "rr_setup_$id" "$id" >/dev/null 2>&1
  before=$(rec_inventory)
  if [ "$id" = H13c ]; then out=$(rr_run --manifest-sha "$(rr_msha)"); rc=$?
  elif [ "$id" = H14 ]; then out=$(rr_run --manifest-sha "$RR_STALE_SHA" --note "$RR_NOTE"); rc=$?
  else out=$(rr_write); rc=$?; fi
  same=$([ "$before" = "$(rec_inventory)" ] && echo unchanged || echo CHANGED)
  printf '[%s %s] exit=%s record=%s\n  %s\n' "$id" "${c#*:}" "$rc" "$same" "$(printf '%s\n' "$out" | grep '^error:' | head -n 1)"
done
