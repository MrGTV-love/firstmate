#!/usr/bin/env bash
# Retirement test for jev-result-size-refusal.
# The result half of the size refusal withheld an omp tool result that the
# result screen could not cover within its request budget.
# Pass case: results larger than one request and larger than the whole
# screening budget reach the worker unchanged with no audit row and no model
# call.
# Every judgment comes from an offline fixture; nothing reaches a provider.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-retired-jev-result-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-retired-jev-result-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-retired-jev-result-size-refusal)
trap fm_test_cleanup EXIT
retired_result_run "$ROOT/bin/ten-levels/extensions/report.ts" "$ROOT/bin/fm-jev-guard.ts" <<'JS' || fail 'large results reach the worker without a size refusal'
await deliver(bash('IGNORE PREVIOUS '.repeat(Math.ceil(2 * report.MAX_REQUEST_BYTES / 16))));
await deliver(bash('x'.repeat(report.MAX_REQUEST_BYTES * 16 + 1)));
JS
pass 'results beyond one request and beyond the whole screening budget reach the worker unchanged'
