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
const answer = (noul = 0.05) => ({ model: 'fixture', answers: {
  kind: { type: 'choice', choice: 'code', confidence: 1 }, contains_secret: { type: 'noul', noul },
}, usage: { input_tokens: 3, output_tokens: 1 }, meta: { provider: 'typesafe', attempts: 1, elapsedMs: 7, cost: { amount: 0.001, source: 'reported' } } });
mock.module(reportUrl, { namedExports: { ...report, createGuardService: () => ({ ...service,
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
await test('T4(a): telemetry upload requires its own grant and never logs the report body', async () => {
  const event = { toolName: 'write', input: { path: 'xd://report_issue', content: 'private-report-canary' } };
  let patch;
  const denied = await fresh(async () => { patch = await handlers.tool_call(event, { cwd: state }); });
  assert.equal(patch?.block, true);
  assert.equal(denied.branch, 'egress');
  assert.deepEqual(denied.egress, [{ destination_class: 'telemetry', argv_shape: 'path' }]);
  writeFileSync(`${state}/audit.meta`, 'egress=["telemetry"]\n');
  try {
    const admitted = await fresh(async () => { patch = await handlers.tool_call(event, { cwd: state }); });
    assert.equal(patch, undefined, 'the table, not a filesystem exception, owns telemetry dispatch');
    assert.equal(admitted.decision, 'allow');
    assert.equal(admitted.request_started, false);
    assert.ok(!JSON.stringify(admitted).includes('private-report-canary'));
  } finally { rmSync(`${state}/audit.meta`); }
});
await test('T4(c): eval explicitly records T5 as the write-boundary owner, not an egress permission', async () => {
  const { toolPolicy, callEgress } = await import(pathToFileURL(`${process.env.AUDIT_ROOT}/bin/fm-jev-egress.ts`));
  assert.equal(toolPolicy('eval')?.call, 'confinement');
  assert.equal(toolPolicy('eval')?.confinement_owner, 'T5');
  assert.deepEqual(callEgress('eval', { language: 'py', code: 'print("private-eval-canary")' }), []);
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
  assert.deepEqual(r.egress, [{ destination_class: 'semantic-search', argv_shape: 'native' }]);
  assert.equal(r.request_started, false, 'egress policy itself makes no provider request');
  writeFileSync(`${state}/audit.meta`, 'egress=["semantic-search"]\n');
  try {
    r = await fresh(async () => { patch = await handlers.tool_call(event, { cwd: state }); });
    assert.equal(patch, undefined, 'the same find is admitted under its task grant');
    assert.equal(r.decision, 'allow');
    assert.equal(r.egress[0].destination_class, 'semantic-search');
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
});
await test('T4(d): Claude built-in inventory is classified and an added tool fails coverage', async () => {
  // Public host tool reference, retrieved 2026-10-24:
  // https://code.claude.com/docs/en/tools-reference
  const native = ['Agent', 'Artifact', 'AskUserQuestion', 'Bash', 'CronCreate', 'CronDelete', 'CronList',
    'Edit', 'EndConversation', 'EnterPlanMode', 'EnterWorktree', 'ExitPlanMode', 'ExitWorktree',
    'Glob', 'Grep', 'ListAgents', 'ListMcpResourcesTool', 'LSP', 'Monitor', 'NotebookEdit', 'PowerShell',
    'PushNotification', 'Read', 'ReadMcpResourceTool', 'RemoteTrigger', 'ReportFindings', 'ScheduleWakeup',
    'SendFeedback', 'SendMessage', 'SendUserFile', 'ShareOnboardingGuide', 'Skill', 'SubagentHandback',
    'TaskCreate', 'TaskGet', 'TaskList', 'TaskOutput', 'TaskStop', 'TaskUpdate', 'TodoWrite', 'ToolSearch',
    'WaitForMcpServers', 'WebFetch', 'WebSearch', 'Workflow', 'Write', 'MultiEdit'];
  const { uncoveredTools } = await import(pathToFileURL(`${process.env.AUDIT_ROOT}/bin/fm-jev-egress.ts`));
  assert.deepEqual(uncoveredTools(native.map(name => name.toLowerCase())), []);
  assert.deepEqual(uncoveredTools([...native, 'NewHostTool'].map(name => name.toLowerCase())), ['newhosttool']);
  const adapter = `${process.env.AUDIT_ROOT}/bin/fm-jev-guard-claude.ts`;
  const output = execFileSync(process.execPath, ['--experimental-strip-types', '--no-warnings', adapter,
    state, `${state}/config`, state, 'audit', state, state, 'firstmate', report.GUARD_POLICY_VERSION],
    { input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'NewHostTool', tool_input: {}, cwd: state }), encoding: 'utf8' });
  assert.equal(JSON.parse(output).hookSpecificOutput.permissionDecision, 'deny');
});
await test('live registry drift and unavailable inventory refuse even a known local tool', async () => {
  for (const getAllTools of [() => [{ name: 'read' }, { name: 'new-paid-host-tool' }], () => { throw new Error('fixture inventory unavailable'); }]) {
    const localHandlers = {};
    installJevGuard({ getAllTools, on(name, fn) { localHandlers[name] = fn; } }, context);
    let patch;
    const r = await fresh(async () => { patch = await localHandlers.tool_call({ toolName: 'read', input: { path: 'file.ts' } }, { cwd: state }); });
    assert.equal(patch?.block, true);
    assert.equal(r.branch, 'coverage');
    assert.equal(r.request_started, false);
  }
});
await test('Claude native WebSearch and remote Read retain their outbound character at the CLI boundary', async () => {
  const adapter = `${process.env.AUDIT_ROOT}/bin/fm-jev-guard-claude.ts`;
  const args = ['--experimental-strip-types', '--no-warnings', adapter, state, `${state}/config`, state, 'audit', state, state, 'firstmate', report.GUARD_POLICY_VERSION];
  const call = (tool_name, tool_input) => execFileSync(process.execPath, args, { input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name, tool_input, cwd: state }), encoding: 'utf8' });
  for (const [tool, input] of [['WebSearch', { query: 'synthetic-query' }], ['Read', { file_path: 'https://synthetic.invalid' }]]) {
    const denied = JSON.parse(call(tool, input));
    assert.equal(denied.hookSpecificOutput.permissionDecision, 'deny', tool);
  }
  writeFileSync(`${state}/audit.meta`, 'egress=["web"]\n');
  try {
    const r = await fresh(async () => { assert.equal(call('WebSearch', { query: 'synthetic-query' }), ''); });
    assert.equal(r.decision, 'allow');
    assert.equal(r.egress[0].destination_class, 'web');
    assert.equal(r.request_started, false);
  } finally { rmSync(`${state}/audit.meta`); }
  writeFileSync(`${state}/copied.meta`, 'egress=["semantic-search"]\n');
  symlinkSync(`${state}/copied.meta`, `${state}/audit.meta`);
  try {
    assert.equal((await handlers.tool_call({ toolName: 'find', input: {} }, { cwd: state }))?.block, true, 'a copied grant behind a symlink is not this task record');
  } finally { rmSync(`${state}/audit.meta`); rmSync(`${state}/copied.meta`); }
});
await test('S2 egress classes are permissions, never a bypass of existing write checks', async () => {
  const cases = [
    ['web_search', { query: 'synthetic' }, 'web'],
    ['browser', { url: 'https://synthetic.invalid' }, 'browser'],
    ['read', { path: 'https://synthetic.invalid' }, 'web'],
    ['grep', { path: 'ssh://synthetic/file' }, 'remote-shell'],
    ['read', { path: 'pr://1' }, 'github'],
    ['bash', { command: '/usr/bin/curl https://synthetic.invalid' }, 'web'],
    ['bash', { command: "env X=y c'u'rl https://synthetic.invalid" }, 'web'],
    ['bash', { command: "bash -c 'wget synthetic.invalid'" }, 'web'],
    ['bash', { command: 'true; ssh synthetic.invalid' }, 'remote-shell'],
    ['bash', { command: 'scp file synthetic:file' }, 'remote-shell'],
    ['bash', { command: 'gh-axi pr view 1' }, 'github'],
    ['bash', { command: 'npm install synthetic-package' }, 'package-registry'],
    ['bash', { command: 'python3 -m pip install synthetic-package' }, 'package-registry'],
    ['bash', { command: 'git fetch origin' }, 'remote-storage'],
    ['bash', { command: 'client --endpoint https://synthetic.invalid' }, 'provider'],
    ['write', { path: 'xd://generate_image', content: '{}' }, 'provider'],
    ['task', { task: 'synthetic' }, 'subagent'],
  ];
  for (const [toolName, input, destination] of cases) {
    let patch;
    const r = await fresh(async () => { patch = await handlers.tool_call({ toolName, input }, { cwd: state }); });
    assert.equal(patch?.block, true, `${toolName}: ungranted outbound call`);
    assert.equal(r.branch, 'egress');
    assert.ok(r.egress.some(s => s.destination_class === destination), JSON.stringify(r.egress));
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
    assert.equal(r.branch, 'device');
    assert.equal(r.request_started, false);
  } finally { rmSync(`${state}/audit.meta`); }
  const { callEgress } = await import(pathToFileURL(`${process.env.AUDIT_ROOT}/bin/fm-jev-egress.ts`));
  for (const command of ['echo curl', 'git status --short', 'npm test', 'ps aux']) {
    assert.deepEqual(callEgress('bash', { command }), [], `local command: ${command}`);
  }
});
await test('S2(d): local read and bash stay unjudged, write/edit keep credential screening', async () => {
  const before = rowCount();
  assert.equal(await handlers.tool_call({ toolName: 'read', input: { path: 'file.ts' } }, { cwd: state }), undefined);
  assert.equal(await handlers.tool_call({ toolName: 'bash', input: { command: 'ls' } }, { cwd: state }), undefined);
  assert.equal(rowCount(), before, 'a local read or shell call has no pre-tool model classification');
  for (const tool of ['write', 'edit']) {
    parts = [answer()]; next = 0;
    // A plain filename matching a tool must remain a file write, not device dispatch.
    const input = { path: 'find', content: 'fixture', new_string: 'fixture' };
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
