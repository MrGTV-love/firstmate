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
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const reportUrl = pathToFileURL(`${process.env.AUDIT_ROOT}/bin/ten-levels/extensions/report.ts`).href;
const report = await import(reportUrl);
const state = process.env.AUDIT_TMP;
mkdirSync(`${state}/config`);
const context = { home: state, config: `${state}/config`, state, task: 'audit', project: 'firstmate', worktree: state, data: state, policy: report.GUARD_POLICY_VERSION };
const service = report.createGuardService(context);
let parts;
let next;
const answer = (noul = 0.05) => ({ model: 'fixture', answers: {
  kind: { type: 'choice', choice: 'code', confidence: 1 }, contains_secret: { type: 'noul', noul },
}, usage: { input_tokens: 3, output_tokens: 1 }, meta: { provider: 'typesafe', attempts: 1, elapsedMs: 7, cost: { amount: 0.001, source: 'reported' } } });
mock.module(reportUrl, { namedExports: { ...report, createGuardService: () => ({ ...service,
  plan: () => parts.map((_, i) => String(i)),
  planWrite: state => ({ pieces: parts.map((_, i) => String(i)), model_screened_bytes: Buffer.byteLength(state.content), local_only_bytes: 0 }),
  decide: async () => { const part = parts[next++]; if (part instanceof Error) throw part; return part; },
}) } });
const { installJevGuard } = await import(pathToFileURL(`${process.env.AUDIT_ROOT}/bin/fm-jev-guard.ts`));
const handlers = {};
installJevGuard({ on(name, fn) { handlers[name] = fn; } }, context);
const row = () => JSON.parse(readFileSync(`${state}/jev-guard.jsonl`, 'utf8').trim().split('\n').at(-1));
async function run(values) {
  parts = values; next = 0;
  await handlers.tool_call({ toolName: 'write', input: { path: 'file.ts', content: 'fixture' } }, { cwd: state });
  return row();
}
const failed = (attempts, ms) => new report.GuardUnavailableError('TimeoutError', true, undefined, { attempts, elapsedMs: ms });
await test('write: a fully answered estimated piece keeps its amount and source', async () => {
  const estimated = answer();
  estimated.meta.cost = { amount: 0.001, source: 'estimated' };
  const r = await run([estimated]);
  assert.equal(r.cost.amount, 0.001, 'an estimated charge must not be hidden');
  assert.equal(r.cost.source, 'estimated');
  assert.equal(r.cost.incomplete, false, 'a fully answered piece is not partial');
});
await test('write: a fully answered reported piece keeps its amount and source', async () => {
  const r = await run([answer()]);
  assert.equal(r.cost.amount, 0.001);
  assert.equal(r.cost.source, 'reported');
  assert.equal(r.cost.incomplete, false);
  assert.equal(r.cost.reported_amount, 0.001);
});
await test('write: an answered piece with an unsent planned piece stays incomplete', async () => {
  const r = await run([answer(), new report.GuardUnavailableError('CredentialUnavailableError')]);
  assert.equal(r.planned_chunks, 2);
  assert.equal(r.chunks, 1);
  assert.equal(r.cost.amount, null);
  assert.equal(r.cost.source, 'unknown');
  assert.equal(r.cost.incomplete, true);
  assert.equal(r.cost.reported_amount, 0.001, 'the partial reported charge stays visible');
});
for (const tool of ['write']) {
  await test(`${tool}: every failed chunk survives settlement`, async () => {
  const r = await run([answer(), failed(2, 40), failed(3, 90)]);
  assert.equal(r.attempts, 6, 'every failed chunk contributes its attempts');
  assert.equal(r.ms, 90, 'parallel elapsed time includes the slowest failure, not only the first');
  assert.deepEqual(r.failures.map(f => [f.chunk, f.attempts, f.ms]), [[2, 2, 40], [3, 3, 90]], 'each failed chunk keeps its own timing');
  assert.equal(r.chunks, 3);
  });
  await test(`${tool}: partial cost is incomplete and unsent chunks are not egress`, async () => {
  let r = await run([answer(), failed(2, 40), failed(3, 90)]);
  assert.equal(r.cost.source, 'unknown', 'an answered piece cannot certify unanswered charges');
  assert.equal(r.cost.amount, null);
  assert.equal(r.cost.incomplete, true);
  assert.equal(r.cost.reported_amount, 0.001, 'the known partial reported charge is retained');

  r = await run([new report.GuardUnavailableError('PrivacyWithheldError'), failed(2, 50)]);
  assert.equal(r.request_started, true, 'an unsent first failure cannot hide later egress');
  assert.equal(r.attempts, 2);
  assert.equal(r.chunks, 1, 'planned but unsent pieces are not provider egress');
  assert.equal(r.planned_chunks, 2);
  assert.equal(r.cost.incomplete, true);

  r = await run([answer(), new report.GuardUnavailableError('CredentialUnavailableError')]);
  assert.equal(r.chunks, 1);
  assert.equal(r.planned_chunks, 2);
  assert.equal(r.cost.incomplete, true);
  assert.equal(r.cost.reported_amount, 0.001);

  });
  await test(`${tool}: a planned payload with no request sent is not-called and not incomplete`, async () => {
  const r = await run([new report.GuardUnavailableError('CredentialUnavailableError')]);
  assert.equal(r.request_started, false);
  assert.equal(r.planned_chunks, 1);
  assert.equal(r.chunks, 0);
  assert.equal(r.cost.source, 'not_called', 'nothing was sent, so nothing was billed');
  assert.equal(r.cost.amount, null);
  assert.equal(r.cost.incomplete, false);
  assert.equal(r.cost.reported_amount, 0);
  });
  await test(`${tool}: complete runs retain full reported cost without failures`, async () => {
  const r = await run([answer(), answer()]);
  assert.equal(r.attempts, 2);
  assert.deepEqual(r.failures, [], 'a complete run invents no failed attempts');
  assert.equal(r.cost.amount, 0.002);
  assert.equal(r.cost.source, 'reported');
  assert.equal(r.cost.incomplete, false, 'a fully reported complete run is complete');
  });
}
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
    const { WRITE_QUESTIONS } = await import(new URL('../src/levels/level06/index.ts', reportUrl));
    const result = await service.decide({ path: 'file.ts', content: 'ordinary fixture' }, WRITE_QUESTIONS);
    assert.equal(calls, 2, 'the real service retried the failed client call');
    assert.equal(result.meta.attempts, attempts, 'attempts stay the final client metadata');
    assert.equal(result.meta.elapsedMs, elapsedMs, 'elapsed time stays the final client metadata, without the retry backoff');
    service.record({ hook: 'tool_call', tool: 'write', decision: 'allow', enforcement: 'pretool_allow', branch: 'policy',
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
assert.equal(blocked.decision, 'block');
assert.equal(blocked.attempts, 6);
assert.equal(blocked.cost.incomplete, true);
});
JS
pass 'offline guard settlement and cost completeness'
