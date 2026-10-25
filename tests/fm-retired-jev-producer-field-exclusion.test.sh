#!/usr/bin/env bash
# Retirement test for jev-producer-field-exclusion.
# The producer-field exclusion matched local AXI commands, reproduced the omp
# shell trailer and removed root help arrays so the result screen would not
# withhold a tool's own next-step help.
# Pass case (T1 b): the recorded nm-drive-45.log bounded-wait output, help[3]
# line included, reaches the worker verbatim under both result states from a
# command no list names, with no audit row and no model call.
# Every judgment comes from an offline fixture; nothing reaches a provider.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-retired-jev-result-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-retired-jev-result-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-retired-jev-producer-field-exclusion)
trap fm_test_cleanup EXIT
retired_result_run "$ROOT/bin/ten-levels/extensions/report.ts" <<'JS' || fail 'local tool help reaches the worker without a producer exclusion'
const boundedWait = `measured: "no-mistakes.run host=Mac-Studio.local p99=479920ms margin=3 samples=43 measured=1440s bound=0s"
run: running
  intent: completed
  rebase: completed
  review: completed
  test: completed
  document: completed
  lint: completed
  push: completed
  pr: completed
  ci: running
progress: "no-mistakes.run elapsed=0.7s output_bytes=179 tree_cpu=0.05s"
progress: "no-mistakes.run elapsed=91.7s output_bytes=179 tree_cpu=0.06s"
progress: "no-mistakes.run elapsed=242.2s output_bytes=179 tree_cpu=0.07s"
  ci: fixing
progress: "no-mistakes.run elapsed=376.5s output_bytes=192 tree_cpu=0.08s"
error: wait of 8m0s elapsed while driving the run
help[3]: This bounded hold ended; it is not a pipeline failure and does not mean the daemon is dead.,Run \`no-mistakes axi status\` to inspect progress,Re-run \`no-mistakes axi run\` to reattach for another 8m0s
progress: "no-mistakes.run elapsed=480.2s output_bytes=450 tree_cpu=0.08s"
`;
for (const isError of [false, true]) await deliver({ ...bash(boundedWait), isError });
JS
pass 'T1(b): the recorded bounded wait keeps help[3] and its error state, with no audit row or model call'
