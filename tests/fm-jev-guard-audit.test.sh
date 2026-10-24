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
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
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
  planWrite: state => ({ pieces: parts.map((_, i) => String(i)), model_screened_bytes: Buffer.byteLength(state.content), local_only_bytes: 0 }),
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
await test('T4(a): xd://report_issue and SendFeedback report uploads are refused under every grant and never log the report body', async () => {
  const all = '["semantic-search","web","browser","provider","subagent","dynamic-code","remote-storage"]';
  for (const meta of [undefined, `egress=${all}\n`]) {
    if (meta) writeFileSync(`${state}/audit.meta`, meta);
    try {
      for (const event of [{ toolName: 'write', input: { path: 'xd://report_issue', content: 'private-report-canary' } },
        { toolName: 'report_issue', input: { body: 'private-report-canary' } },
        { toolName: 'sendfeedback', input: { description: 'private-report-canary' } }]) {
        let patch;
        const r = await fresh(async () => { patch = await handlers.tool_call(event, { cwd: state }); });
        assert.equal(patch?.block, true, `${event.toolName}: report upload must not execute (grant: ${meta ?? 'none'})`);
        assert.equal(r.branch, event.toolName === 'write' ? 'deterministic' : 'coverage');
        assert.equal(r.destination_class, undefined, 'no egress class can admit a report upload');
        assert.equal(r.request_started, false);
        assert.ok(!JSON.stringify(r).includes('private-report-canary'));
      }
    } finally { if (meta) rmSync(`${state}/audit.meta`); }
  }
});
await test('T4(c): eval explicitly records T5 as the write-boundary owner, not an egress permission', async () => {
  const { toolPolicy, egressClass } = await import(pathToFileURL(`${process.env.AUDIT_ROOT}/bin/fm-jev-egress.ts`));
  assert.equal(toolPolicy('eval')?.call, 'confinement');
  assert.equal(toolPolicy('eval')?.confinement_owner, 'T5');
  assert.equal(egressClass('eval'), undefined);
  const r = await fresh(async () => {
    assert.equal(await handlers.tool_call({ toolName: 'eval', input: { language: 'py', code: 'print("private-eval-canary")' } }, { cwd: state }), undefined);
  });
  assert.equal(r.branch, 'confinement');
  assert.equal(r.confinement_owner, 'T5');
  assert.equal(r.request_started, false);
  assert.ok(!JSON.stringify(r).includes('private-eval-canary'));
});
// T4(b): the previously invisible native paid search is decided at the tool boundary.
await test('T4(b): paid find requires a task grant and records exactly one content-free decision', async () => {
  const event = { toolName: 'find', input: { query: 'private-query-canary', endpoint: 'https://paid-provider.invalid/search' } };
  let patch;
  let r = await fresh(async () => { patch = await handlers.tool_call(event, { cwd: state }); });
  assert.equal(patch?.block, true, 'ungranted paid find must not execute');
  assert.equal(r.decision, 'block');
  assert.equal(r.branch, 'egress');
  assert.equal(r.destination_class, 'semantic-search');
  assert.equal(r.request_started, false, 'egress policy itself makes no provider request');
  writeFileSync(`${state}/audit.meta`, 'egress=["semantic-search"]\n');
  try {
    r = await fresh(async () => { patch = await handlers.tool_call(event, { cwd: state }); });
    assert.equal(patch, undefined, 'the same find is admitted under its task grant');
    assert.equal(r.decision, 'allow');
    assert.equal(r.destination_class, 'semantic-search');
    assert.equal(r.request_started, false);
    assert.ok(!JSON.stringify(r).includes('private-query-canary'));
    assert.ok(!JSON.stringify(r).includes('paid-provider.invalid'));
  } finally { rmSync(`${state}/audit.meta`); }
});
await test('T4(d): an installed tool absent from the policy table is rejected, not silently ignored', async () => {
  const { uncoveredTools } = await import(pathToFileURL(`${process.env.AUDIT_ROOT}/bin/fm-jev-egress.ts`));
  assert.deepEqual(uncoveredTools(['read', 'bash', 'write', 'edit', 'find']), []);
  assert.deepEqual(uncoveredTools(['read', 'new-paid-host-tool']), ['new-paid-host-tool']);
  let patch;
  const r = await fresh(async () => { patch = await handlers.tool_call({ toolName: 'new-paid-host-tool', input: {} }, { cwd: state }); });
  assert.equal(patch?.block, true);
  assert.equal(r.branch, 'coverage');
  assert.ok(patch.reason.includes('Unclassified host tool "new-paid-host-tool"'), patch.reason);
  assert.ok(patch.reason.includes('No call was made.'), patch.reason);
});
await test('T4(d): Claude built-in inventory is classified and an added tool fails coverage', async () => {
  // Every tool in the public host tool reference, retrieved 2026-10-24:
  // https://code.claude.com/docs/en/tools-reference
  const native = ['Agent', 'Artifact', 'AskUserQuestion', 'Bash', 'CronCreate', 'CronDelete', 'CronList',
    'Edit', 'EndConversation', 'EnterPlanMode', 'EnterWorktree', 'ExitPlanMode', 'ExitWorktree',
    'Glob', 'Grep', 'ListAgents', 'ListMcpResourcesTool', 'LSP', 'Monitor', 'NotebookEdit', 'PowerShell',
    'PushNotification', 'Read', 'ReadMcpResourceTool', 'RemoteTrigger', 'ReportFindings', 'ScheduleWakeup',
    'SendMessage', 'SendUserFile', 'ShareOnboardingGuide', 'Skill', 'SubagentHandback',
    'TaskCreate', 'TaskGet', 'TaskList', 'TaskOutput', 'TaskStop', 'TaskUpdate', 'TodoWrite', 'ToolSearch',
    'WaitForMcpServers', 'WebFetch', 'WebSearch', 'Workflow', 'Write'];
  const { uncoveredTools } = await import(pathToFileURL(`${process.env.AUDIT_ROOT}/bin/fm-jev-egress.ts`));
  assert.deepEqual(uncoveredTools(native.map(name => name.toLowerCase())), []);
  assert.deepEqual(uncoveredTools([...native, 'NewHostTool', 'MultiEdit', 'SendFeedback'].map(name => name.toLowerCase())), ['multiedit', 'newhosttool', 'sendfeedback']);
  const adapter = `${process.env.AUDIT_ROOT}/bin/fm-jev-guard-claude.ts`;
  for (const tool_name of ['NewHostTool', 'MultiEdit', 'SendFeedback']) {
    const output = execFileSync(process.execPath, ['--experimental-strip-types', '--no-warnings', adapter,
      state, `${state}/config`, state, 'audit', state, state, 'firstmate', report.GUARD_POLICY_VERSION],
      { input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name, tool_input: {}, cwd: state }), encoding: 'utf8' });
    assert.equal(JSON.parse(output).hookSpecificOutput.permissionDecision, 'deny', tool_name);
  }
});
await test('an unclassified tool elsewhere in the host registry does not refuse a classified call', async () => {
  const localHandlers = {};
  installJevGuard({ getAllTools: () => [{ name: 'read' }, { name: 'operator-mcp-tool' }], on(name, fn) { localHandlers[name] = fn; } }, context);
  const before = rowCount();
  assert.equal(await localHandlers.tool_call({ toolName: 'read', input: { path: 'file.ts' } }, { cwd: state }), undefined);
  assert.equal(rowCount(), before);
});
await test('Claude native WebSearch retains its outbound character at the CLI boundary', async () => {
  const adapter = `${process.env.AUDIT_ROOT}/bin/fm-jev-guard-claude.ts`;
  const args = ['--experimental-strip-types', '--no-warnings', adapter, state, `${state}/config`, state, 'audit', state, state, 'firstmate', report.GUARD_POLICY_VERSION];
  const call = (tool_name, tool_input) => execFileSync(process.execPath, args, { input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name, tool_input, cwd: state }), encoding: 'utf8' });
  assert.equal(JSON.parse(call('WebSearch', { query: 'synthetic-query' })).hookSpecificOutput.permissionDecision, 'deny');
  writeFileSync(`${state}/audit.meta`, 'egress=["web"]\n');
  try {
    const r = await fresh(async () => { assert.equal(call('WebSearch', { query: 'synthetic-query' }), ''); });
    assert.equal(r.decision, 'allow');
    assert.equal(r.destination_class, 'web');
    assert.equal(r.request_started, false);
  } finally { rmSync(`${state}/audit.meta`); }
  writeFileSync(`${state}/copied.meta`, 'egress=["semantic-search"]\n');
  symlinkSync(`${state}/copied.meta`, `${state}/audit.meta`);
  try {
    assert.equal((await handlers.tool_call({ toolName: 'find', input: {} }, { cwd: state }))?.block, true, 'a copied grant behind a symlink is not this task record');
  } finally { rmSync(`${state}/audit.meta`); rmSync(`${state}/copied.meta`); }
});
await test('coverage and egress refusals hold in an inactive project scope', async () => {
  const adapter = `${process.env.AUDIT_ROOT}/bin/fm-jev-guard-claude.ts`;
  const args = ['--experimental-strip-types', '--no-warnings', adapter, state, `${state}/config`, state, 'audit', state, state, 'other-project', report.GUARD_POLICY_VERSION];
  const call = (tool_name, tool_input) => execFileSync(process.execPath, args, { input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name, tool_input, cwd: state }), encoding: 'utf8' });
  for (const [tool, input] of [['WebSearch', { query: 'synthetic-query' }], ['Agent', { prompt: 'synthetic' }], ['mcp__synthetic__tool', {}]]) {
    assert.equal(JSON.parse(call(tool, input)).hookSpecificOutput.permissionDecision, 'deny', tool);
  }
  assert.equal(call('TaskStop', { task_id: 'synthetic' }), '');
});
await test('tools that move no data or run no worker code are local; unscreened writers name T5', async () => {
  for (const toolName of ['skill', 'listagents', 'waitformcpservers', 'subagenthandback', 'taskstop']) {
    const before = rowCount();
    assert.equal(await handlers.tool_call({ toolName, input: {} }, { cwd: state }), undefined, toolName);
    assert.equal(rowCount(), before, `${toolName}: local tools add no egress or confinement row`);
  }
  for (const toolName of ['ast_edit', 'init_experiment', 'log_experiment', 'notebook', 'lsp', 'manage_skill', 'notebookedit', 'python', 'debug', 'run_experiment']) {
    let patch;
    const r = await fresh(async () => { patch = await handlers.tool_call({ toolName, input: {} }, { cwd: state }); });
    assert.equal(patch, undefined, toolName);
    assert.equal(r.branch, 'confinement', toolName);
    assert.equal(r.confinement_owner, 'T5', toolName);
  }
});
await test('S2 egress classes are permissions, never a bypass of existing write checks', async () => {
  const cases = [
    ['web_search', { query: 'synthetic' }, 'web'],
    ['browser', { url: 'https://synthetic.invalid' }, 'browser'],
    ['generate_image', { prompt: 'synthetic' }, 'provider'],
    ['task', { task: 'synthetic' }, 'subagent'],
  ];
  for (const [toolName, input, destination] of cases) {
    let patch;
    const r = await fresh(async () => { patch = await handlers.tool_call({ toolName, input }, { cwd: state }); });
    assert.equal(patch?.block, true, `${toolName}: ungranted outbound call`);
    assert.equal(r.branch, 'egress');
    assert.equal(r.destination_class, destination);
    assert.equal(r.request_started, false);
  }
  for (const meta of ['egress=true\n', 'egress=["web"]\negress=["semantic-search"]\n', 'egress=["unknown-class"]\n']) {
    writeFileSync(`${state}/audit.meta`, meta);
    assert.equal((await handlers.tool_call({ toolName: 'web_search', input: {} }, { cwd: state }))?.block, true);
  }
  writeFileSync(`${state}/audit.meta`, 'egress=["provider"]\n');
  try {
    const r = await fresh(() => handlers.tool_call({ toolName: 'write', input: { path: 'xd://generate_image', content: '{}' } }, { cwd: state }));
    assert.equal(r.decision, 'block', 'an egress grant does not admit an otherwise refused device write');
    assert.equal(r.branch, 'deterministic');
    assert.equal(r.request_started, false);
  } finally { rmSync(`${state}/audit.meta`); }
});
await test('M4: each coverage and egress decision emits one content-free central guard event', async () => {
  delete process.env.FM_GUARD_EVENT_LOG;
  const log = `${state}/state/guard-events.jsonl`;
  const events = () => { try { return readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)); } catch { return []; } };
  const decide = async (event, expected) => {
    const before = events().length;
    await handlers.tool_call(event, { cwd: state });
    const added = events().slice(before);
    assert.deepEqual(added.map(e => [e.guard, e.decision, e.session]), expected, event.toolName);
    for (const e of added) {
      assert.deepEqual(Object.keys(e).sort(), ['cleared_by', 'decision', 'elapsed_ms', 'guard', 'override', 'repeat', 'session', 'source_ok', 'system', 'ts', 'version']);
      assert.equal(e.system, 'firstmate');
      assert.equal(e.source_ok, true);
      assert.ok(Number.isInteger(e.elapsed_ms));
      assert.ok(!JSON.stringify(e).includes('private-event-canary'), 'events carry no call content');
    }
  };
  await decide({ toolName: 'read', input: { path: 'private-event-canary' } }, [['jev-tool-coverage', 'allow', 'audit:read']]);
  await decide({ toolName: 'new-paid-host-tool', input: { q: 'private-event-canary' } }, [['jev-tool-coverage', 'deny', 'audit:new-paid-host-tool']]);
  await decide({ toolName: 'find', input: { query: 'private-event-canary' } },
    [['jev-tool-coverage', 'allow', 'audit:find'], ['jev-egress-grant', 'deny', 'audit:semantic-search']]);
  writeFileSync(`${state}/audit.meta`, 'egress=["semantic-search"]\n');
  try {
    await decide({ toolName: 'find', input: { query: 'private-event-canary' } },
      [['jev-tool-coverage', 'allow', 'audit:find'], ['jev-egress-grant', 'allow', 'audit:semantic-search']]);
  } finally { rmSync(`${state}/audit.meta`); }
});
await test('M4: an unrelated allow never clears a later deny in the real metrics reader', async () => {
  const log = `${state}/metrics-events.jsonl`;
  process.env.FM_GUARD_EVENT_LOG = log;
  writeFileSync(`${state}/audit.meta`, 'egress=["semantic-search"]\n');
  try {
    await handlers.tool_call({ toolName: 'read', input: { path: 'file.ts' } }, { cwd: state });
    await handlers.tool_call({ toolName: 'new-paid-host-tool', input: {} }, { cwd: state });
    await handlers.tool_call({ toolName: 'find', input: { query: 'synthetic' } }, { cwd: state });
    await handlers.tool_call({ toolName: 'web_search', input: { query: 'synthetic' } }, { cwd: state });
  } finally { rmSync(`${state}/audit.meta`); delete process.env.FM_GUARD_EVENT_LOG; }
  const out = JSON.parse(execFileSync('bash', [`${process.env.AUDIT_ROOT}/bin/fm-guard-metrics.sh`, '--log', log,
    '--registry', `${process.env.AUDIT_ROOT}/docs/guards/registry.json`, '--min-opportunities', '1', '--json'], { encoding: 'utf8' }));
  const metric = id => out.guards.find(g => g.id === id);
  for (const id of ['jev-tool-coverage', 'jev-egress-grant']) {
    assert.equal(metric(id).denies, 1, id);
    assert.equal(metric(id).recurrences, 0, `${id}: an allow of another subject is not a clear`);
    assert.equal(metric(id).median_clear_attempts, 0, id);
    assert.equal(metric(id).verdict, 'keep', id);
  }
  rmSync(log);
});
await test('worker brief shell commands are never refused for a missing egress grant', async () => {
  const commands = ['gh-axi pr create --title synthetic --body synthetic', 'gh pr checks 1 --watch',
    'no-mistakes axi run --wait', 'no-mistakes axi respond --action fix --wait', 'git push -u origin HEAD',
    'git fetch origin', 'git pull --ff-only', 'npm install', 'pnpm install', 'bun install', 'uv sync', 'uv run pytest',
    'npx tsc --noEmit', 'chrome-devtools-axi open https://synthetic.invalid', 'git commit -m "Fixes https://synthetic.invalid/1"'];
  for (const command of commands) {
    const safe = answer();
    safe.answers.effect = { type: 'choice', choice: 'reversible', confidence: 1 };
    safe.answers.destructive_intent = { type: 'noul', noul: 0.05 };
    parts = [safe]; next = 0;
    let patch;
    const r = await fresh(async () => { patch = await handlers.tool_call({ toolName: 'bash', input: { command } }, { cwd: state }); });
    assert.equal(patch, undefined, command);
    assert.equal(r.branch, 'policy', command);
    assert.equal(r.destination_class, undefined, command);
  }
});
await test('S2(d): local read stays unjudged, write/edit keep credential screening and bash keeps shell screening', async () => {
  const before = rowCount();
  assert.equal(await handlers.tool_call({ toolName: 'read', input: { path: 'file.ts' } }, { cwd: state }), undefined);
  assert.equal(rowCount(), before, 'a local read has no pre-tool model classification');
  for (const tool of ['bash', 'write', 'edit']) {
    const safe = answer();
    safe.answers.effect = { type: 'choice', choice: 'reversible', confidence: 1 };
    safe.answers.destructive_intent = { type: 'noul', noul: 0.05 };
    parts = [safe]; next = 0;
    // A plain filename matching a tool must remain a file write, not device dispatch.
    const input = tool === 'bash' ? { command: 'ls' } : { path: 'find', content: 'fixture', new_string: 'fixture' };
    let patch;
    const r = await fresh(async () => { patch = await handlers.tool_call({ toolName: tool, input }, { cwd: state }); });
    assert.equal(patch, undefined);
    assert.equal(r.branch, 'policy');
    assert.equal(r.decision, 'allow');
    assert.equal(r.request_started, true);
  }
});
JS
pass 'offline guard settlement, cost completeness and S2 egress acceptance'

if command -v omp >/dev/null 2>&1; then
  node --experimental-strip-types --no-warnings --input-type=module <<'JS' || fail 'installed omp tool coverage'
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { uncoveredTools } = await import(pathToFileURL(`${process.env.AUDIT_ROOT}/bin/fm-jev-egress.ts`));
const lab = `${process.env.AUDIT_TMP}/inventory`;
mkdirSync(`${lab}/agent`, { recursive: true });
writeFileSync(`${lab}/agent/config.yml`, 'setupVersion: 2\nfind:\n  enabled: on\n');
const extension = `${lab}/inventory.ts`;
writeFileSync(extension, `import { writeFileSync } from 'node:fs';
export default function(pi: { on(name: string, fn: () => void): void; getAllTools(): {name: string}[] }) {
  pi.on('session_start', () => {
    writeFileSync(${JSON.stringify(`${lab}/tools.json`)}, JSON.stringify(pi.getAllTools().map(t => t.name).sort()));
    process.exit(0);
  });
}`);
execFileSync(`${process.env.AUDIT_ROOT}/bin/fm-proc-budget.sh`, ['--', 'omp', '--mode', 'rpc', '--no-session',
  '--no-extensions', '-e', extension, '--no-skills', '--no-rules', '--no-title', '--no-lsp', '--model', 'openai/gpt-4o'],
  { cwd: lab, input: '', env: { ...process.env, PI_CODING_AGENT_DIR: `${lab}/agent`, OMP_SKIP_SETUP: '1', TYPESAFE_API_KEY: 'synthetic-inventory-only' }, stdio: ['pipe', 'pipe', 'pipe'] });
const installed = JSON.parse(readFileSync(`${lab}/tools.json`, 'utf8'));
assert.ok(installed.includes('find'), 'the real host inventory must include the missed paid tool');
assert.deepEqual(uncoveredTools(installed), [], 'every installed host tool needs an explicit classification');
assert.deepEqual(uncoveredTools([...installed, 'new-paid-host-tool']), ['new-paid-host-tool'], 'S2(c): an added installed tool fails coverage');
console.log(`installed omp: ${installed.length} tools classified; injected unknown tool rejected; no model turn`);
JS
  pass 'installed omp registry coverage (no model turn submitted)'
else
  printf 'SKIP: installed tool coverage requires omp; offline added-tool regression ran above\n'
fi
