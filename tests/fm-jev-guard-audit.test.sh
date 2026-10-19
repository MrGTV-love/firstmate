#!/usr/bin/env bash
# Offline settlement/audit regression: no provider or model requests.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-guard-audit)
export AUDIT_ROOT="$ROOT" AUDIT_TMP="$TMP_ROOT"
node --experimental-strip-types --experimental-test-module-mocks --no-warnings --input-type=module <<'JS' || fail 'guard settlement/audit regression'
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const reportUrl = pathToFileURL(`${process.env.AUDIT_ROOT}/bin/ten-levels/extensions/report.ts`).href;
const report = await import(reportUrl);
const state = process.env.AUDIT_TMP;
mkdirSync(`${state}/config`);
const context = { home: state, config: `${state}/config`, state, task: 'audit', project: 'firstmate', worktree: state, data: state, policy: report.GUARD_POLICY_VERSION };
const service = report.createGuardService(context);
let parts;
let next;
let realPlan = false;
const answer = (noul = 0.05) => ({ model: 'fixture', answers: {
  injection: { type: 'noul', noul },
  kind: { type: 'choice', choice: 'code', confidence: 1 }, contains_secret: { type: 'noul', noul },
}, usage: { input_tokens: 3, output_tokens: 1 }, meta: { provider: 'typesafe', attempts: 1, elapsedMs: 7, cost: { amount: 0.001, source: 'reported' } } });
mock.module(reportUrl, { namedExports: { ...report, createGuardService: () => ({ ...service,
  plan: (...args) => realPlan ? service.plan(...args) : parts.map((_, i) => String(i)),
  decide: async () => { const part = parts[next++]; if (part instanceof Error) throw part; return part; },
}) } });
const { installJevGuard } = await import(pathToFileURL(`${process.env.AUDIT_ROOT}/bin/fm-jev-guard.ts`));
const handlers = {};
installJevGuard({ on(name, fn) { handlers[name] = fn; } }, context);
const row = () => JSON.parse(readFileSync(`${state}/jev-guard.jsonl`, 'utf8').trim().split('\n').at(-1));
async function run(values, tool = 'result') {
  parts = values; next = 0;
  if (tool === 'write') await handlers.tool_call({ toolName: 'write', input: { path: 'file.ts', content: 'fixture' } }, { cwd: state });
  else await handlers.tool_result({ toolName: 'bash', content: [{ type: 'text', text: 'fixture' }] }, { cwd: state });
  return row();
}
const failed = (attempts, ms) => new report.GuardUnavailableError('TimeoutError', true, undefined, { attempts, elapsedMs: ms });
await test('result: a fully answered estimated piece keeps its amount and source', async () => {
  const estimated = answer();
  estimated.meta.cost = { amount: 0.001, source: 'estimated' };
  const r = await run([estimated]);
  assert.equal(r.cost.amount, 0.001, 'an estimated charge must not be hidden');
  assert.equal(r.cost.source, 'estimated');
  assert.equal(r.cost.incomplete, false, 'a fully answered piece is not partial');
});
await test('result: a fully answered reported piece keeps its amount and source', async () => {
  const r = await run([answer()]);
  assert.equal(r.cost.amount, 0.001);
  assert.equal(r.cost.source, 'reported');
  assert.equal(r.cost.incomplete, false);
  assert.equal(r.cost.reported_amount, 0.001);
});
await test('result: an answered piece with an unsent planned piece stays incomplete', async () => {
  const r = await run([answer(), new report.GuardUnavailableError('CredentialUnavailableError')]);
  assert.equal(r.planned_chunks, 2);
  assert.equal(r.chunks, 1);
  assert.equal(r.cost.amount, null);
  assert.equal(r.cost.source, 'unknown');
  assert.equal(r.cost.incomplete, true);
  assert.equal(r.cost.reported_amount, 0.001, 'the partial reported charge stays visible');
});
for (const tool of ['result', 'write']) {
  await test(`${tool}: every failed chunk survives settlement`, async () => {
  const r = await run([answer(), failed(2, 40), failed(3, 90)], tool);
  assert.equal(r.attempts, 6, 'every failed chunk contributes its attempts');
  assert.equal(r.ms, 90, 'parallel elapsed time includes the slowest failure, not only the first');
  assert.deepEqual(r.failures.map(f => [f.chunk, f.attempts, f.ms]), [[2, 2, 40], [3, 3, 90]], 'each failed chunk keeps its own timing');
  assert.equal(r.chunks, 3);
  });
  await test(`${tool}: partial cost is incomplete and unsent chunks are not egress`, async () => {
  let r = await run([answer(), failed(2, 40), failed(3, 90)], tool);
  assert.equal(r.cost.source, 'unknown', 'an answered piece cannot certify unanswered charges');
  assert.equal(r.cost.amount, null);
  assert.equal(r.cost.incomplete, true);
  assert.equal(r.cost.reported_amount, 0.001, 'the known partial reported charge is retained');

  r = await run([new report.GuardUnavailableError('PrivacyWithheldError'), failed(2, 50)], tool);
  assert.equal(r.request_started, true, 'an unsent first failure cannot hide later egress');
  assert.equal(r.attempts, 2);
  assert.equal(r.chunks, 1, 'planned but unsent pieces are not provider egress');
  assert.equal(r.planned_chunks, 2);
  assert.equal(r.cost.incomplete, true);

  r = await run([answer(), new report.GuardUnavailableError('CredentialUnavailableError')], tool);
  assert.equal(r.chunks, 1);
  assert.equal(r.planned_chunks, 2);
  assert.equal(r.cost.incomplete, true);
  assert.equal(r.cost.reported_amount, 0.001);

  });
  await test(`${tool}: a planned payload with no request sent is not-called and not incomplete`, async () => {
  const r = await run([new report.GuardUnavailableError('CredentialUnavailableError')], tool);
  assert.equal(r.request_started, false);
  assert.equal(r.planned_chunks, 1);
  assert.equal(r.chunks, 0);
  assert.equal(r.cost.source, 'not_called', 'nothing was sent, so nothing was billed');
  assert.equal(r.cost.amount, null);
  assert.equal(r.cost.incomplete, false);
  assert.equal(r.cost.reported_amount, 0);
  });
  await test(`${tool}: complete runs retain full reported cost without failures`, async () => {
  const r = await run([answer(), answer()], tool);
  assert.equal(r.attempts, 2);
  assert.deepEqual(r.failures, [], 'a complete run invents no failed attempts');
  assert.equal(r.cost.amount, 0.002);
  assert.equal(r.cost.source, 'reported');
  assert.equal(r.cost.incomplete, false, 'a fully reported complete run is complete');
  });
}
// A blank piece of an oversized result is cleared locally: it sends nothing, so it is not work the provider had to answer.
const { SCREEN_QUESTIONS } = await import(new URL('../src/levels/level06/index.ts', reportUrl));
async function runText(text, values) {
  parts = values; next = 0; realPlan = true;
  try {
    await handlers.tool_result({ toolName: 'bash', content: [{ type: 'text', text }] }, { cwd: state });
  } finally {
    realPlan = false;
  }
  return row();
}
await test('result: a blank middle piece is not planned screening work', async () => {
  const text = `A${' '.repeat(40_000)}B`;
  const pieces = service.plan({ tool: 'bash', source_role: 'tool_result', content: text }, 'content', SCREEN_QUESTIONS);
  assert.equal(pieces.length, 3, 'the oversized result splits into three pieces');
  assert.equal(pieces[1].trim(), '', 'the middle piece is blank');
  const r = await runText(text, [answer(), answer()]);
  assert.equal(next, 2, 'only the two pieces with text were judged; the blank middle piece made no request');
  assert.equal(r.chunks, 2);
  assert.equal(r.planned_chunks, 2, 'the blank piece is not planned screening work');
  assert.equal(r.cost.incomplete, false, 'every piece that needed screening answered with a reported cost');
  assert.equal(r.cost.source, 'reported');
  assert.equal(r.cost.amount, 0.002);
  assert.deepEqual(r.failures, []);
});
await test('result: an unsent failed piece stays planned beside a blank piece', async () => {
  const r = await runText(`A${' '.repeat(40_000)}B`, [answer(), new report.GuardUnavailableError('PrivacyWithheldError')]);
  assert.equal(r.chunks, 1);
  assert.equal(r.planned_chunks, 2, 'the unsent piece still needed screening; the blank piece did not');
  assert.equal(r.cost.incomplete, true);
  assert.equal(r.cost.reported_amount, 0.001);
});
await test('result: an all-blank result plans no screening and sends nothing', async () => {
  const r = await runText('   ', []);
  assert.equal(r.request_started, false);
  assert.equal(r.chunks, 0);
  assert.equal(r.planned_chunks, 0);
  assert.equal(r.cost.source, 'not_called');
  assert.equal(r.cost.incomplete, false);
});
// A failure before any piece exists has no chunk to report: no piece failed, none was planned, none was sent.
const rowCount = () => readFileSync(`${state}/jev-guard.jsonl`, 'utf8').trim().split('\n').length;
async function fresh(act) {
  const before = rowCount();
  await act();
  assert.equal(rowCount(), before + 1, 'the call wrote exactly one audit row');
  return row();
}
function assertNoPiece(r, errorType) {
  assert.equal(r.error_type, errorType);
  assert.equal(r.request_started, false);
  assert.deepEqual(r.failures, [], 'a failure before planning invents no failed piece');
  assert.equal(r.planned_chunks, 0);
  assert.equal(r.chunks, 0);
  assert.equal(r.attempts, null);
  assert.equal(r.ms, null);
}
await test('call: invalid tool input fails before planning and invents no piece', async () => {
  parts = []; next = 0;
  assertNoPiece(await fresh(() => handlers.tool_call({ toolName: 'bash', input: { command: 42 } }, { cwd: state })), 'InvalidToolInputError');
  assertNoPiece(await fresh(() => handlers.tool_call({ toolName: 'write', input: { path: 'file.ts', content: 42 } }, { cwd: state })), 'InvalidToolInputError');
});
await test('result: an oversize result no plan can cover fails before planning and invents no piece', async () => {
  const text = 'x'.repeat(report.MAX_CHUNKS * report.MAX_REQUEST_BYTES + 1);
  assertNoPiece(await fresh(() => runText(text, [])), 'RequestTooLargeError');
});
await test('result: a never-send refusal while planning invents no piece', async () => {
  writeFileSync(`${state}/config/dispatch-never-send`, 'audit-never-send-canary\n');
  try {
    assertNoPiece(await fresh(() => runText(`audit-never-send-canary${' '.repeat(40_000)}tail`, [])), 'PrivacyWithheldError');
  } finally {
    rmSync(`${state}/config/dispatch-never-send`);
  }
});
await test('result: an unsupported tool result fails before planning and invents no piece', async () => {
  parts = []; next = 0;
  for (const content of ['not a list of parts', [{ type: 'image' }]]) {
    assertNoPiece(await fresh(() => handlers.tool_result({ toolName: 'bash', content }, { cwd: state })), 'UnsupportedToolResultError');
  }
});
// The guard adds no retry accounting of its own: a retried success is exactly what the client reported.
await test('real decide: a guard-retried success keeps the client result and a complete reported cost', async () => {
  // Stub only the client boundary: the real preflight, retry loop and recorder run with no network or model request.
  const { JevClient } = await import(new URL('../src/core/client.ts', reportUrl));
  writeFileSync(`${state}/.env`, 'TYPESAFE_API_KEY=offline-audit-fixture\n');
  const final = answer();
  const { attempts, elapsedMs } = final.meta;
  let calls = 0;
  const client = mock.method(JevClient.prototype, 'systemOne', async () => {
    if (++calls === 1) throw new Error('offline transient failure');
    return final;
  });
  try {
    const result = await service.decide({ content: 'ordinary fixture' }, SCREEN_QUESTIONS);
    assert.equal(calls, 2, 'the real service retried the failed client call');
    assert.equal(result.meta.attempts, attempts, 'attempts stay the final client metadata');
    assert.equal(result.meta.elapsedMs, elapsedMs, 'elapsed time stays the final client metadata, without the retry backoff');
    service.record({ hook: 'tool_result', tool: 'bash', decision: 'clear', enforcement: 'result_pass', branch: 'policy',
      error_type: null, request_started: true, result });
    const r = row();
    assert.equal(r.attempts, attempts);
    assert.equal(r.ms, elapsedMs);
    assert.equal(r.chunks, 1);
    assert.equal(r.planned_chunks, 1);
    assert.equal(r.cost.incomplete, false, 'a retried success whose answer reported its cost is a complete charge');
    assert.equal(r.cost.source, 'reported');
    assert.equal(r.cost.amount, 0.001);
    assert.equal(r.cost.reported_amount, 0.001);
  } finally {
    client.mock.restore();
  }
});
// A policy verdict still outranks an outage, but must not discard its spend.
await test('policy verdict precedence never discards failed spend', async () => {
const blocked = await run([answer(0.95), failed(2, 40), failed(3, 90)]);
assert.equal(blocked.decision, 'flag');
assert.equal(blocked.attempts, 6);
assert.equal(blocked.cost.incomplete, true);
});
JS
pass 'offline guard settlement and cost completeness'
