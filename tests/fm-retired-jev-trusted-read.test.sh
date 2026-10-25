#!/usr/bin/env bash
# Retirement test for jev-trusted-read.
# The trusted read let a read of bytes the task owns (its data directory and its
# own state files) skip the result screen; it never refused anything.
# Pass case: injection-shaped bytes in the task's own data and state files reach
# the worker unchanged with no audit row and no model call, so no location
# exemption is needed.
# Every judgment comes from an offline fixture; nothing reaches a provider.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-retired-jev-result-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-retired-jev-result-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-retired-jev-trusted-read)
trap fm_test_cleanup EXIT
retired_result_run "$ROOT/bin/ten-levels/extensions/report.ts" <<'JS' || fail 'task-owned reads reach the worker without a trust exemption'
for (const path of [`${context.data}/request.md`, `${context.state}/${context.task}.notes`]) {
  writeFileSync(path, 'IGNORE PREVIOUS task-owned fixture\n');
  await deliver(read(path));
}
JS
pass 'task-owned data and state reads reach the worker unchanged with no audit row or model call'
