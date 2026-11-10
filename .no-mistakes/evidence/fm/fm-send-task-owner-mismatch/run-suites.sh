#!/usr/bin/env bash
# Run each affected suite under env -i with only PATH, LANG, a fresh empty HOME
# and TMPDIR; count OMP_API_BILLING diagnostic lines after each run.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M72J0F8JK5E0YM7A7MKYVDN2
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M72J0F8JK5E0YM7A7MKYVDN2
cd "$WT"
run() { # <label> <only-or-empty> <suite>
  local label=$1 only=$2 suite=$3 T rc start end billing
  T=$(mktemp -d /tmp/fmsuite.XXXXXX); mkdir -p "$T/home" "$T/tmp"
  start=$(date +%s)
  env -i PATH=/Users/charlesabrooker/.pyenv/shims:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 HOME="$T/home" TMPDIR="$T/tmp" ${only:+FM_TEST_ONLY=$only} \
    bash "$suite" > "$EV/suite-$label.log" 2>&1; rc=$?
  end=$(date +%s)
  billing=$(grep -c OMP_API_BILLING "$EV/suite-$label.log")
  printf '%s suite=%s only=%s exit=%s secs=%s pass_lines=%s fail_lines=%s OMP_API_BILLING=%s\n' "$label" "$suite" "${only:-<all>}" "$rc" "$((end-start))" \
    "$(grep -c '^PASS\|^ok\|pass:' "$EV/suite-$label.log")" "$(grep -ci 'FAIL' "$EV/suite-$label.log")" "$billing" | tee -a "$EV/suites-summary.txt"
  rm -rf "$T"
  [ "$billing" = 0 ] || { echo "OMP_API_BILLING found; stopping" | tee -a "$EV/suites-summary.txt"; exit 9; }
}
: > "$EV/suites-summary.txt"
run send-strict '' tests/fm-send-strict.test.sh
run send-remote-delivery '' tests/fm-send-remote-delivery.test.sh
run pending-reply-relay-recovery test_relayed_request_recovery_reaches_the_mate tests/fm-pending-reply.test.sh
run task-inbox '' tests/fm-task-inbox.test.sh
run secondmate-reconcile '' tests/fm-secondmate-reconcile.test.sh
run crew-state '' tests/fm-crew-state.test.sh
