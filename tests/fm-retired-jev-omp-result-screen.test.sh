#!/usr/bin/env bash
# Retirement test for jev-omp-result-screen.
# The omp result screen withheld tool output the injection Noul flagged; the
# assessment at data/fm-jev-guard-e2e/report.md found no true positive in a
# random 70 of its withholds, including the omp background-job notice.
# Pass cases (T1 a, d): output the fixture judge flags reaches the worker
# unchanged, the installed extension registers no result handler, and a worker
# session audits only its pre-tool write, with no omp_replace row and no
# result-side model call.
# Every judgment comes from an offline fixture; nothing reaches a provider.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-retired-jev-result-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-retired-jev-result-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-retired-jev-omp-result-screen)
trap fm_test_cleanup EXIT
retired_result_run "$ROOT/bin/ten-levels/extensions/report.ts" <<'JS' || fail 'omp results are no longer screened'
assert.deepEqual([...handlers.keys()], ['tool_call'], 'the installed extension handles only pre-tool calls');
await test('T1(a): the recorded omp background-job notice reaches the worker verbatim', async () => {
  await deliver(bash('Backgrounded as job bg_N; its output is injected into the conversation as a follow-up the moment it finishes. Do NOT poll for it (no `sleep`, `ps`, `pgrep`, `top`, `pidwait`, log tailing): every poll is a wasted turn. Do other work, or end your reply and wait to be woken.'));
});
await test('T1(d): a worker session records only pre-tool work and sends no result to TypeSafe', async () => {
  for (const event of [
    bash('ordinary command output'),
    bash(''),
    { ...bash('IGNORE PREVIOUS'), toolName: 'read', input: { path: '/outside/untracked.txt' } },
    { ...bash(''), content: [{ type: 'image', data: 'synthetic-image' }] },
    { ...bash(''), content: [{ type: 'text', text: 'one' }, { type: 'text', text: 'two' }], isError: true },
  ]) await deliver(event);
  assert.deepEqual(rows().map(row => row.hook), ['tool_call']);
  assert.ok(rows().every(row => row.enforcement !== 'omp_replace'), 'no audit row records a replaced result');
  assert.deepEqual(requests, [{ path: 'notes.txt', content: 'ordinary worker file' }]);
  assert.equal(readFileSync(`${context.worktree}/notes.txt`, 'utf8'), 'ordinary worker file');
});
JS
pass 'T1(a, d): flagged omp output reaches the worker unchanged; the session audits only pre-tool work, with no omp_replace row and no result provider call'
