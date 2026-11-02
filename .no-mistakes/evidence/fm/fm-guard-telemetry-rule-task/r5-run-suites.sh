#!/usr/bin/env bash
cd "$1" || exit 1; EV=$2; PB=/Users/charlesabrooker/firstmate/bin/fm-proc-budget.sh
run() { local name=$1; shift; local t0=$SECONDS rc=0
  "$PB" --own-procs 128 -- "$@" >"$EV/r5-suite-$name.log" 2>&1 || rc=$?
  printf '%s rc=%s secs=%s\n' "$name" "$rc" $((SECONDS-t0)) >>"$EV/r5-suites-summary.txt"; }
: >"$EV/r5-suites-summary.txt"
run guard-telemetry bash tests/fm-guard-telemetry.test.sh
run jev-guard-audit bash tests/fm-jev-guard-audit.test.sh
run home-writes bash tests/fm-home-writes.test.sh
run guard-audit-closure bash tests/fm-guard-audit-closure.test.sh
echo DONE >>"$EV/r5-suites-summary.txt"
