#!/usr/bin/env bash
# Offline settlement/audit regression: no provider or model requests.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-guard-audit)
export AUDIT_ROOT="$ROOT" AUDIT_TMP="$TMP_ROOT"
node --experimental-strip-types --experimental-test-module-mocks --no-warnings --input-type=module <<'JS' || fail 'guard settlement/audit regression'
import assert from 'node:assert/strict';
const { readGuardAudit } = await import(process.env.FM_GUARD_AUDIT_READER);
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
await test('audit history merges legacy and task rows without reading unrelated state', () => {
  const dir = `${state}/reader`;
  mkdirSync(dir);
  const legacy = { at: 20, task: 'legacy', decision: 'clear' };
  const earlier = { at: 10, task: 'a', decision: 'block' };
  const later = { at: 30, task: 'b', decision: 'review' };
  writeFileSync(`${dir}/jev-guard.jsonl`, JSON.stringify(legacy) + '\n');
  writeFileSync(`${dir}/a.jev-guard.jsonl`, JSON.stringify(earlier) + '\n');
  writeFileSync(`${dir}/b.jev-guard.jsonl`, JSON.stringify(later) + '\n');
  writeFileSync(`${dir}/b.omp-session.json`, 'not an audit row');
  const rows = () => readGuardAudit(dir).trim().split('\n').map(JSON.parse);
  assert.deepEqual(rows(), [earlier, legacy, later]);
  rmSync(`${dir}/jev-guard.jsonl`);
  assert.deepEqual(rows(), [earlier, later], 'a home with only task logs retains all history');
  writeFileSync(`${dir}/a.jev-guard.jsonl`, 'invalid audit row\n');
  assert.throws(() => readGuardAudit(dir), SyntaxError, 'corrupt history must not be silently omitted');
});
// A failure before any piece exists has no chunk to report: no piece failed, none was planned, none was sent.
const rowCount = () => readGuardAudit(state).split('\n').filter(Boolean).length;
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
const { installJevGuard } = await import(pathToFileURL(`${process.env.AUDIT_ROOT}/bin/fm-jev-guard.ts`));
const handlers = {};
installJevGuard({ on(name, fn) { handlers[name] = fn; } }, context);
const row = () => JSON.parse(readGuardAudit(state).trim().split('\n').at(-1));
const answer = (noul = 0.05) => ({ model: 'fixture', answers: {
  fixture: { type: 'noul', noul },
}, usage: { input_tokens: 3, output_tokens: 1 }, meta: { provider: 'typesafe', attempts: 1, elapsedMs: 7, cost: { amount: 0.001, source: 'reported' } } });
await test('write: deterministic admission records no request, piece or cost', async () => {
  const r = await fresh(() => handlers.tool_call({ toolName: 'write', input: { path: 'file.ts', content: 'fixture' } }, { cwd: state }));
  assert.equal(r.decision, 'allow');
  assert.equal(r.branch, 'deterministic');
  assertNoPiece(r, null);
  assert.equal(r.cost.source, 'not_called');
  assert.equal(r.cost.incomplete, false);
});
await test('call: invalid tool input fails before planning and invents no piece', async () => {
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
    const { noul } = await import(new URL('../src/core/helpers.ts', reportUrl));
    const result = await service.decide({ path: 'file.ts', content: 'ordinary fixture' }, { fixture: noul('Is `content` an ordinary fixture?') });
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
await test('T4(a): xd://report_issue and SendFeedback report uploads are refused under every grant and never log the report body', async () => {
  const all = '["semantic-search","web","browser","provider","remote-storage"]';
  for (const meta of [undefined, `egress=${all}\n`]) {
    if (meta) writeFileSync(`${state}/audit.meta`, meta);
    try {
      for (const event of [{ toolName: 'write', input: { path: 'xd://report_issue', content: 'private-report-canary' } },
        { toolName: 'report_issue', input: { body: 'private-report-canary' } },
        { toolName: 'sendfeedback', input: { description: 'private-report-canary' } }]) {
        let patch;
        const r = await fresh(async () => { patch = await handlers.tool_call(event, { cwd: state }); });
        assert.equal(patch?.block, true, `${event.toolName}: report upload must not execute (grant: ${meta ?? 'none'})`);
        assert.equal(r.branch, event.toolName === 'write' ? 'device' : 'coverage');
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
await test('omp github read ops need a remote-storage grant while write ops refuse under every grant', async () => {
  const read = { toolName: 'github', input: { op: 'repo_view', repo: 'synthetic/repo' } };
  let patch;
  let r = await fresh(async () => { patch = await handlers.tool_call(read, { cwd: state }); });
  assert.equal(patch?.block, true, 'an ungranted GitHub read must not execute');
  assert.equal(r.branch, 'egress');
  assert.equal(r.destination_class, 'remote-storage');
  for (const meta of [undefined, 'egress=["remote-storage"]\n']) {
    if (meta) writeFileSync(`${state}/audit.meta`, meta);
    try {
      for (const op of ['pr_checkout', 'pr_create', 'pr_push', 'synthetic_op', undefined]) {
        r = await fresh(async () => { patch = await handlers.tool_call({ toolName: 'github', input: { op, pr: '12', force: true } }, { cwd: state }); });
        assert.equal(patch?.block, true, `${op}: a GitHub write op must not execute (grant: ${meta ?? 'none'})`);
        assert.ok(patch.reason.includes(`GitHub op ${JSON.stringify(op ?? null)} refused under every grant`), patch.reason);
        assert.ok(patch.reason.includes('no-mistakes pipeline') && patch.reason.includes('gh-axi'), patch.reason);
        assert.equal(r.decision, 'block');
        assert.equal(r.branch, 'github-write-op', 'a write-op refusal is not recorded as a missing grant');
        assert.equal(r.destination_class, 'remote-storage');
        assert.equal(r.request_started, false);
      }
    } finally { if (meta) rmSync(`${state}/audit.meta`); }
  }
  writeFileSync(`${state}/audit.meta`, 'egress=["remote-storage"]\n');
  try {
    r = await fresh(async () => { patch = await handlers.tool_call(read, { cwd: state }); });
    assert.equal(patch, undefined, 'the same GitHub read is admitted under its task grant');
    assert.equal(r.decision, 'allow');
    assert.equal(r.destination_class, 'remote-storage');
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
  assert.ok(patch.reason.includes('add a TOOL_POLICY row for it in fm-jev-egress.ts, classified by its real effect'), patch.reason);
  assert.ok(patch.reason.includes('No call was made.'), patch.reason);
});
await test('T4(d): an added Claude host tool fails coverage at the adapter boundary', async () => {
  const adapter = `${process.env.AUDIT_ROOT}/bin/fm-jev-guard-claude.ts`;
  for (const tool_name of ['NewHostTool', 'MultiEdit', 'SendFeedback']) {
    const output = execFileSync(process.execPath, ['--experimental-strip-types', '--no-warnings', adapter,
      state, `${state}/config`, state, 'audit', state, state, 'firstmate', report.GUARD_POLICY_VERSION],
      { input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name, tool_input: {}, cwd: state }), encoding: 'utf8' });
    const decision = JSON.parse(output).hookSpecificOutput;
    assert.equal(decision.permissionDecision, 'deny', tool_name);
    assert.ok(decision.permissionDecisionReason.includes(`Unclassified host tool ${JSON.stringify(tool_name.toLowerCase())}`), decision.permissionDecisionReason);
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
await test('observed Claude signed-in artifact tools require provider grants at the CLI boundary', async () => {
  const adapter = `${process.env.AUDIT_ROOT}/bin/fm-jev-guard-claude.ts`;
  const args = ['--experimental-strip-types', '--no-warnings', adapter, state, `${state}/config`, state, 'audit', state, state, 'firstmate', report.GUARD_POLICY_VERSION];
  const call = tool_name => execFileSync(process.execPath, args, { input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name, tool_input: { artifact: 'private-artifact-canary' }, cwd: state }), encoding: 'utf8' });
  for (const tool of ['ArtifactCheck', 'ArtifactComments', 'ArtifactData']) {
    const denied = await fresh(async () => { assert.equal(JSON.parse(call(tool)).hookSpecificOutput.permissionDecision, 'deny', tool); });
    assert.equal(denied.branch, 'egress', tool);
    assert.equal(denied.destination_class, 'provider', tool);
    assert.equal(denied.request_started, false);
    assert.ok(!JSON.stringify(denied).includes('private-artifact-canary'));
    writeFileSync(`${state}/audit.meta`, 'egress=["provider"]\n');
    try {
      const allowed = await fresh(async () => { assert.equal(call(tool), '', tool); });
      assert.equal(allowed.decision, 'allow', tool);
      assert.equal(allowed.destination_class, 'provider', tool);
      assert.equal(allowed.request_started, false);
    } finally { rmSync(`${state}/audit.meta`); }
  }
});
await test('coverage and egress refusals hold in an inactive project scope', async () => {
  const adapter = `${process.env.AUDIT_ROOT}/bin/fm-jev-guard-claude.ts`;
  const args = ['--experimental-strip-types', '--no-warnings', adapter, state, `${state}/config`, state, 'audit', state, state, 'other-project', report.GUARD_POLICY_VERSION];
  const call = (tool_name, tool_input) => execFileSync(process.execPath, args, { input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name, tool_input, cwd: state }), encoding: 'utf8' });
  for (const [tool, input] of [['WebSearch', { query: 'synthetic-query' }], ['PushNotification', { message: 'synthetic' }], ['mcp__synthetic__tool', {}]]) {
    assert.equal(JSON.parse(call(tool, input)).hookSpecificOutput.permissionDecision, 'deny', tool);
  }
  assert.equal(call('TaskStop', { task_id: 'synthetic' }), '');
});
await test('tools that move no data or run no worker code are local; unscreened writers name T5', async () => {
  for (const toolName of ['skill', 'listagents', 'waitformcpservers', 'subagenthandback', 'taskstop', 'structuredoutput',
    'think', 'yield', 'checkpoint', 'rewind', 'context_notes', 'new_context']) {
    const before = rowCount();
    assert.equal(await handlers.tool_call({ toolName, input: {} }, { cwd: state }), undefined, toolName);
    assert.equal(rowCount(), before, `${toolName}: local tools add no egress or confinement row`);
  }
  for (const toolName of ['ast_edit', 'init_experiment', 'log_experiment', 'notebook', 'lsp', 'manage_skill', 'notebookedit', 'python', 'debug', 'run_experiment', 'ida']) {
    let patch;
    const r = await fresh(async () => { patch = await handlers.tool_call({ toolName, input: {} }, { cwd: state }); });
    assert.equal(patch, undefined, toolName);
    assert.equal(r.branch, 'confinement', toolName);
    assert.equal(r.confinement_owner, 'T5', toolName);
  }
});
await test('subagent dispatch needs no grant while the outbound tools a subagent calls still refuse', async () => {
  for (const toolName of ['task', 'agent', 'sendmessage', 'workflow']) {
    const before = rowCount();
    assert.equal(await handlers.tool_call({ toolName, input: { prompt: 'synthetic' } }, { cwd: state }), undefined, toolName);
    assert.equal(rowCount(), before, `${toolName}: local dispatch adds no egress row`);
  }
  const adapter = `${process.env.AUDIT_ROOT}/bin/fm-jev-guard-claude.ts`;
  const args = ['--experimental-strip-types', '--no-warnings', adapter, state, `${state}/config`, state, 'audit', state, state, 'firstmate', report.GUARD_POLICY_VERSION];
  const call = tool_name => execFileSync(process.execPath, args, { input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name, tool_input: { prompt: 'synthetic' }, cwd: state }), encoding: 'utf8' });
  assert.equal(call('Agent'), '', 'a Claude worker with no egress= line can dispatch a subagent');
  assert.equal(JSON.parse(call('WebSearch')).hookSpecificOutput.permissionDecision, 'deny', 'a subagent web search still needs its own grant');
  for (const toolName of ['find', 'web_search']) {
    assert.equal((await handlers.tool_call({ toolName, input: { query: 'synthetic' } }, { cwd: state }))?.block, true, toolName);
  }
});
await test('memory operations need a provider grant unless the live worker settings prove them local', async () => {
  const live = { 'memory.backend': 'mnemopi', 'mnemopi.noEmbeddings': true, 'mnemopi.llmMode': 'smol' };
  let settings = live;
  const memory = {};
  installJevGuard({ on(name, fn) { memory[name] = fn; } }, { ...context, ompSetting: id => { if (settings instanceof Error) throw settings; return settings[id]; } });
  const call = toolName => memory.tool_call({ toolName, input: { query: 'private-memory-canary', items: [{ content: 'private-memory-canary' }] } }, { cwd: state });
  for (const toolName of ['recall', 'reflect', 'memory_edit']) {
    const before = rowCount();
    assert.equal(await call(toolName), undefined, `${toolName}: a local FTS store call without embeddings needs no grant`);
    assert.equal(rowCount(), before, toolName);
  }
  for (const toolName of ['retain', 'learn']) {
    let patch;
    const r = await fresh(async () => { patch = await call(toolName); });
    assert.equal(patch?.block, true, `${toolName}: extraction with llmMode smol is a model call`);
    assert.ok(patch.reason.includes(`memory operation "${toolName}" makes a Mnemopi extraction model call (mnemopi.llmMode=smol)`), patch.reason);
    assert.ok(patch.reason.includes('egress=["provider"]'), patch.reason);
    assert.equal(r.branch, 'egress');
    assert.equal(r.destination_class, 'provider');
    assert.ok(!JSON.stringify(r).includes('private-memory-canary'));
  }
  writeFileSync(`${state}/audit.meta`, 'egress=["provider"]\n');
  try {
    const r = await fresh(async () => { assert.equal(await call('retain'), undefined, 'the provider grant admits the model-calling retain'); });
    assert.equal(r.decision, 'allow');
    assert.equal(r.destination_class, 'provider');
  } finally { rmSync(`${state}/audit.meta`); }
  settings = { ...live, 'mnemopi.llmMode': 'none' };
  assert.equal(await call('retain'), undefined, 'retain without extraction or embeddings stays local');
  const skill = { action: 'create', name: 'synthetic-skill', description: 'synthetic', body: 'private-memory-canary' };
  for (const backend of ['mnemopi', 'local']) {
    settings = { ...live, 'mnemopi.llmMode': 'none', 'memory.backend': backend };
    const before = rowCount();
    assert.equal(await memory.tool_call({ toolName: 'learn', input: { memory: 'synthetic' } }, { cwd: state }), undefined, `${backend}: learn without skill stays local`);
    assert.equal(rowCount(), before, `${backend}: learn without skill adds no row`);
    let patch;
    const r = await fresh(async () => { patch = await memory.tool_call({ toolName: 'learn', input: { memory: 'synthetic', skill } }, { cwd: state }); });
    assert.equal(patch, undefined, `${backend}: a learn skill write is left to T5 confinement`);
    assert.equal(r.branch, 'confinement', `${backend}: a learn skill write is not silently allowed`);
    assert.equal(r.confinement_owner, 'T5');
    assert.ok(!JSON.stringify(r).includes('private-memory-canary'));
  }
  for (const backend of ['mnemopi', 'local']) {
    settings = { ...live, 'memory.backend': backend };
    let patch;
    const r = await fresh(async () => { patch = await memory.tool_call({ toolName: 'learn', input: { memory: 'synthetic', skill } }, { cwd: state }); });
    assert.equal(r.confinement_owner, 'T5', `${backend}: skill ownership is recorded independently of memory authorization`);
    assert.equal(r.request_started, false);
    assert.ok(!JSON.stringify(r).includes('private-memory-canary'));
    if (backend === 'mnemopi') {
      assert.equal(patch?.block, true, 'a skill argument never admits a model-calling learn without its provider grant');
      assert.equal(r.decision, 'block');
      assert.equal(r.branch, 'egress');
      assert.equal(r.destination_class, 'provider');
    } else {
      assert.equal(patch, undefined, 'the local memory effect needs no provider grant');
      assert.equal(r.decision, 'allow');
      assert.equal(r.branch, 'confinement');
      assert.equal(r.destination_class, undefined);
    }
  }
  settings = { ...live, 'mnemopi.llmMode': 'none' };
  for (const [indeterminate, toolName, effect] of [
    [new Error('unreadable'), 'recall', 'could not be proven local because the worker\'s live memory settings are unreadable'],
    [{ ...live, 'mnemopi.noEmbeddings': false }, 'recall', 'could not be proven local because mnemopi.noEmbeddings is not true'],
    [{ ...live, 'memory.backend': 'sharpshooter' }, 'recall', 'could not be proven local because memory.backend is not mnemopi'],
    [{ ...live, 'memory.backend': 'hindsight' }, 'recall', 'makes a remote Hindsight memory call'],
  ]) {
    settings = indeterminate;
    const patch = await call(toolName);
    assert.equal(patch?.block, true, effect);
    assert.ok(patch.reason.includes(`memory operation "${toolName}" ${effect}`), patch.reason);
  }
  assert.equal((await handlers.tool_call({ toolName: 'recall', input: {} }, { cwd: state }))?.block, true, 'a host without live omp settings proves nothing local');
});
await test('S2 egress classes are permissions, never a bypass of existing write checks', async () => {
  const cases = [
    ['web_search', { query: 'synthetic' }, 'web'],
    ['browser', { url: 'https://synthetic.invalid' }, 'browser'],
    ['generate_image', { prompt: 'synthetic' }, 'provider'],
    ['designsync', { method: 'list_projects' }, 'remote-storage'],
    ['github', { op: 'repo_view' }, 'remote-storage'],
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
    assert.equal(r.branch, 'device');
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
    assert.deepEqual(added.map(e => [e.guard, e.decision, e.session, e.source_ok]), expected, event.toolName);
    for (const e of added) {
      assert.deepEqual(Object.keys(e).sort(), ['cleared_by', 'decision', 'elapsed_ms', 'guard', 'override', 'repeat', 'session', 'source_ok', 'system', 'ts', 'version']);
      assert.equal(e.system, 'firstmate');
      assert.ok(Number.isInteger(e.elapsed_ms));
      assert.ok(!JSON.stringify(e).includes('private-event-canary'), 'events carry no call content');
    }
  };
  await decide({ toolName: 'read', input: { path: 'private-event-canary' } }, [['jev-tool-coverage', 'allow', 'audit:read', true]]);
  await decide({ toolName: 'new-paid-host-tool', input: { q: 'private-event-canary' } }, [['jev-tool-coverage', 'deny', 'audit:new-paid-host-tool', true]]);
  const find = { toolName: 'find', input: { query: 'private-event-canary' } };
  const denied = sourceOk => [['jev-tool-coverage', 'allow', 'audit:find', true], ['jev-egress-grant', 'deny', 'audit:semantic-search', sourceOk]];
  await decide(find, denied(false)); // Missing record is not a readable authorization source.
  for (const meta of ['project=firstmate\n', 'egress=["web"]\n', 'egress=invalid-json\n']) {
    writeFileSync(`${state}/audit.meta`, meta);
    try { await decide(find, denied(true)); }
    finally { rmSync(`${state}/audit.meta`); }
  }
  mkdirSync(`${state}/audit.meta`);
  try { await decide(find, denied(false)); }
  finally { rmSync(`${state}/audit.meta`, { recursive: true }); }
  writeFileSync(`${state}/audit.meta`, 'egress=["semantic-search"]\n');
  try {
    await decide(find,
      [['jev-tool-coverage', 'allow', 'audit:find', true], ['jev-egress-grant', 'allow', 'audit:semantic-search', true]]);
  } finally { rmSync(`${state}/audit.meta`); }
  await decide({ toolName: 'github', input: { op: 'pr_push', body: 'private-event-canary' } },
    [['jev-tool-coverage', 'allow', 'audit:github', true], ['jev-github-write-op', 'deny', 'audit:github-write', true]]);
  await decide({ toolName: 'github', input: { op: 'repo_view', repo: 'private-event-canary' } },
    [['jev-tool-coverage', 'allow', 'audit:github', true], ['jev-github-write-op', 'allow', 'audit:github-read', true], ['jev-egress-grant', 'deny', 'audit:remote-storage', false]]);
});
await test('M4: an unrelated allow never clears a later deny in the real metrics reader', async () => {
  const log = `${state}/metrics-events.jsonl`;
  process.env.FM_GUARD_EVENT_LOG = log;
  writeFileSync(`${state}/audit.meta`, 'egress=["semantic-search","remote-storage"]\n');
  try {
    await handlers.tool_call({ toolName: 'read', input: { path: 'file.ts' } }, { cwd: state });
    await handlers.tool_call({ toolName: 'new-paid-host-tool', input: {} }, { cwd: state });
    await handlers.tool_call({ toolName: 'find', input: { query: 'synthetic' } }, { cwd: state });
    await handlers.tool_call({ toolName: 'web_search', input: { query: 'synthetic' } }, { cwd: state });
    for (const op of ['pr_push', 'repo_view', 'pr_create']) await handlers.tool_call({ toolName: 'github', input: { op } }, { cwd: state });
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
  assert.equal(metric('jev-github-write-op').denies, 2);
  assert.equal(metric('jev-github-write-op').recurrences, 0, 'a GitHub read allow never clears a write-op refusal');
  assert.equal(metric('jev-github-write-op').median_clear_attempts, 0);
  assert.equal(metric('jev-github-write-op').verdict, 'keep');
  rmSync(log);
});
await test('Claude Monitor and PowerShell share Bash shell-command treatment without a grant', async () => {
  const adapter = `${process.env.AUDIT_ROOT}/bin/fm-jev-guard-claude.ts`;
  const args = ['--experimental-strip-types', '--no-warnings', adapter, state, `${state}/config`, state, 'audit', state, state, 'firstmate', report.GUARD_POLICY_VERSION];
  for (const tool_name of ['Bash', 'Monitor', 'PowerShell']) {
    const before = rowCount();
    const output = execFileSync(process.execPath, args, {
      input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name, tool_input: { command: 'echo synthetic-shell-effect' }, cwd: state }),
      encoding: 'utf8',
    });
    assert.equal(output, '', `${tool_name}: a shell command needs no pre-call grant`);
    assert.equal(rowCount(), before, `${tool_name}: no egress or model decision row`);
  }
});
await test('a removed execution class cannot authorize an otherwise valid web grant', async () => {
  writeFileSync(`${state}/audit.meta`, 'egress=["web","dynamic-code"]\n');
  try {
    const r = await fresh(async () => {
      const patch = await handlers.tool_call({ toolName: 'webfetch', input: { url: 'https://synthetic.invalid' } }, { cwd: state });
      assert.equal(patch?.block, true, 'the removed class invalidates the entire grant');
    });
    assert.equal(r.branch, 'egress');
    assert.equal(r.destination_class, 'web');
    assert.equal(r.request_started, false);
  } finally { rmSync(`${state}/audit.meta`); }
});
await test('worker brief shell commands are never refused for a missing egress grant', async () => {
  const commands = ['gh-axi pr create --title synthetic --body synthetic', 'gh pr checks 1 --watch',
    'no-mistakes axi run --wait', 'no-mistakes axi respond --action fix --wait', 'git push -u origin HEAD',
    'git fetch origin', 'git pull --ff-only', 'npm install', 'pnpm install', 'bun install', 'uv sync', 'uv run pytest',
    'npx tsc --noEmit', 'chrome-devtools-axi open https://synthetic.invalid', 'git commit -m "Fixes https://synthetic.invalid/1"'];
  for (const command of commands) {
    const before = rowCount();
    assert.equal(await handlers.tool_call({ toolName: 'bash', input: { command } }, { cwd: state }), undefined, command);
    assert.equal(rowCount(), before, `no egress or model decision row: ${command}`);
  }
});
await test('S2(d): local read and bash stay unjudged, write/edit keep deterministic path checks', async () => {
  const before = rowCount();
  assert.equal(await handlers.tool_call({ toolName: 'read', input: { path: 'file.ts' } }, { cwd: state }), undefined);
  assert.equal(await handlers.tool_call({ toolName: 'bash', input: { command: 'ls' } }, { cwd: state }), undefined);
  assert.equal(rowCount(), before, 'a local read or shell call has no pre-tool model classification');
  for (const tool of ['write', 'edit']) {
    // A plain filename matching a tool must remain a file write, not device dispatch.
    const input = { path: 'find', content: 'fixture', new_string: 'fixture' };
    let patch;
    const r = await fresh(async () => { patch = await handlers.tool_call({ toolName: tool, input }, { cwd: state }); });
    assert.equal(patch, undefined);
    assert.equal(r.branch, 'deterministic');
    assert.equal(r.decision, 'allow');
    assert.equal(r.request_started, false);
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
// Settings-gated and subagent-only built-ins are absent from a default registry, so omp's own built-in name lists join it.
writeFileSync(extension, `import { writeFileSync } from 'node:fs';
import { BUILTIN_TOOL_NAMES, HIDDEN_TOOL_NAMES } from "@oh-my-pi/pi-coding-agent/tools/builtin-names";
export default function(pi: { on(name: string, fn: () => void): void; getAllTools(): {name: string}[] }) {
  pi.on('session_start', () => {
    writeFileSync(${JSON.stringify(`${lab}/tools.json`)}, JSON.stringify({ registry: pi.getAllTools().map(t => t.name).sort(), builtin: BUILTIN_TOOL_NAMES, hidden: HIDDEN_TOOL_NAMES }));
    process.exit(0);
  });
}`);
const dead = 'http://127.0.0.1:9';
execFileSync(`${process.env.AUDIT_ROOT}/bin/fm-proc-budget.sh`, ['--', 'omp', '--mode', 'rpc', '--no-session',
  '--no-extensions', '-e', extension, '--no-skills', '--no-rules', '--no-title', '--no-lsp'],
  { cwd: lab, input: '', env: { PATH: process.env.PATH, HOME: lab, PI_CODING_AGENT_DIR: `${lab}/agent`, OMP_SKIP_SETUP: '1',
    TYPESAFE_API_KEY: 'synthetic-inventory-only', OPENAI_API_KEY: 'synthetic-inventory-only',
    HTTP_PROXY: dead, HTTPS_PROXY: dead, ALL_PROXY: dead }, stdio: ['pipe', 'pipe', 'pipe'] });
const { registry, builtin, hidden } = JSON.parse(readFileSync(`${lab}/tools.json`, 'utf8'));
assert.ok(registry.includes('find'), 'the real host inventory must include the missed paid tool');
assert.ok(builtin.includes('ida') && hidden.includes('yield'), 'omp must expose its gated and hidden built-in names');
const installed = [...new Set([...registry, ...builtin, ...hidden])].sort();
assert.deepEqual(uncoveredTools(installed), [], 'every installed host tool needs an explicit classification');
assert.deepEqual(uncoveredTools([...installed, 'new-paid-host-tool']), ['new-paid-host-tool'], 'S2(c): an added installed tool fails coverage');
console.log(`installed omp: ${installed.length} tools classified; injected unknown tool rejected; no model turn`);
JS
  pass 'installed omp registry coverage (no model turn submitted)'
  node --experimental-strip-types --no-warnings --input-type=module <<'JS' || fail 'installed omp live memory settings'
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
const lab = `${process.env.AUDIT_TMP}/memory-settings`;
mkdirSync(`${lab}/agent`, { recursive: true });
writeFileSync(`${lab}/agent/config.yml`, 'setupVersion: 2\nmemory:\n  backend: mnemopi\nmnemopi:\n  llmMode: smol\n');
writeFileSync(`${lab}/overlay.yml`, 'mnemopi:\n  llmMode: none\n  noEmbeddings: true\n');
const extension = `${lab}/memory.ts`;
// The same live-settings import the extension generated by bin/fm-spawn.sh makes; omp resolves it only in an entry file.
writeFileSync(extension, `import { writeFileSync } from 'node:fs';
import { memoryEgress } from ${JSON.stringify(`${process.env.AUDIT_ROOT}/bin/fm-jev-egress.ts`)};
const setting = await Promise.all([import("@oh-my-pi/pi-coding-agent/config/settings"), import("@oh-my-pi/pi-coding-agent/config/registry")])
  .then(([{ settings }, { lookup }]) => (id: string) => lookup(id)?.get(settings), () => undefined);
export default function(pi: { on(name: string, fn: () => void): void }) {
  pi.on('session_start', () => {
    writeFileSync(${JSON.stringify(`${lab}/effects.json`)}, JSON.stringify(Object.fromEntries(['recall', 'retain', 'learn'].map(tool => [tool, memoryEgress(tool, setting) ?? 'local']))));
    process.exit(0);
  });
}`);
const dead = 'http://127.0.0.1:9';
execFileSync(`${process.env.AUDIT_ROOT}/bin/fm-proc-budget.sh`, ['--', 'omp', '--mode', 'rpc', '--no-session',
  '--no-extensions', '-e', extension, '--config', `${lab}/overlay.yml`, '--no-skills', '--no-rules', '--no-title', '--no-lsp'],
  { cwd: lab, input: '', env: { PATH: process.env.PATH, HOME: lab, PI_CODING_AGENT_DIR: `${lab}/agent`, OMP_SKIP_SETUP: '1',
    OPENAI_API_KEY: 'synthetic-settings-only', HTTP_PROXY: dead, HTTPS_PROXY: dead, ALL_PROXY: dead }, stdio: ['pipe', 'pipe', 'pipe'] });
const effects = JSON.parse(readFileSync(`${lab}/effects.json`, 'utf8'));
assert.deepEqual(effects, { recall: 'local', retain: 'local', learn: 'local' },
  'the guard reads the global backend and the --config overlay llmMode and noEmbeddings from the live omp settings');
console.log('installed omp: memory effects read from live global and --config overlay settings; no model turn');
JS
  pass 'installed omp live memory settings (no model turn submitted)'
else
  printf 'SKIP: installed tool coverage requires omp; offline added-tool regression ran above\n'
fi

# Only init.tools from an API-key session is enumerated, not claude.ai sign-in tools.
# ArtifactCheck/ArtifactComments/ArtifactData are covered by the explicit adapter cases above.
# The dead proxy and base URL keep the run off the network, so no model turn is submitted.
if command -v claude >/dev/null 2>&1; then
  node --experimental-strip-types --no-warnings --input-type=module <<'JS' || fail 'installed Claude tool coverage'
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { uncoveredTools } = await import(pathToFileURL(`${process.env.AUDIT_ROOT}/bin/fm-jev-egress.ts`));
const lab = `${process.env.AUDIT_TMP}/claude-inventory`;
mkdirSync(`${lab}/config`, { recursive: true });
writeFileSync(`${lab}/config/.claude.json`, JSON.stringify({ hasCompletedOnboarding: true }));
const dead = 'http://127.0.0.1:9';
const run = spawnSync(`${process.env.AUDIT_ROOT}/bin/fm-proc-budget.sh`, ['--', 'claude', '-p', 'inventory', '--output-format', 'stream-json', '--verbose',
  '--max-turns', '1', '--json-schema', '{"type":"object","properties":{}}'],
  { cwd: lab, input: '', encoding: 'utf8', env: { PATH: process.env.PATH, HOME: lab, CLAUDE_CONFIG_DIR: `${lab}/config`,
    ANTHROPIC_API_KEY: 'synthetic-inventory-only', ANTHROPIC_BASE_URL: dead, HTTPS_PROXY: dead, HTTP_PROXY: dead, CLAUDE_CODE_MAX_RETRIES: '0' } });
const init = run.stdout.split('\n').filter(Boolean).map(line => JSON.parse(line)).find(event => event.type === 'system' && event.subtype === 'init');
assert.ok(Array.isArray(init?.tools), `no init tool inventory (exit ${run.status})`);
const installed = init.tools.map(name => name.toLowerCase());
assert.ok(installed.includes('webfetch'), 'the real host inventory must include an outbound tool');
assert.deepEqual(uncoveredTools(installed), [], 'every installed Claude tool needs an explicit classification');
assert.deepEqual(uncoveredTools([...installed, 'newhosttool']), ['newhosttool'], 'T4(d): an added installed tool fails coverage');
console.log(`installed Claude ${init.claude_code_version}: ${installed.length} tools classified; injected unknown tool rejected; no model turn`);
JS
  pass 'installed Claude registry coverage (no model turn submitted)'
else
  printf 'SKIP: installed Claude tool coverage requires claude; offline added-tool regression ran above\n'
fi
