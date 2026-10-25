#!/usr/bin/env bash
# Shared offline harness for the result-delivery retirement tests named in
# docs/guards/retired.json. Source it after tests/lib.sh with TMP_ROOT set.
#
# retired_result_run <report-module> < case.js
#   Installs the real worker guard with the given report module's service, its
#   judge replaced by an offline fixture that flags every injection-shaped text
#   (so anything the removed result screen judged would have been withheld),
#   seeds one admitted pre-tool write so an absent result row is not vacuous,
#   then runs the case module. The case sees assert, test, execFileSync, the
#   node:fs readers, root, home, context, report, ctx, handlers, requests,
#   rows(), bash(text), read(path) and deliver(event); deliver applies
#   every installed tool_result patch the way the host does and asserts the
#   worker receives the event unchanged with no request and no audit row.
#   No case reaches a provider.

retired_result_run() {  # <report-module>
  {
    cat <<'JS'
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const root = process.env.RETIRED_ROOT;
const home = process.env.RETIRED_TMP;
for (const dir of ['config', 'state', 'repo', 'data']) mkdirSync(`${home}/${dir}`, { recursive: true });
const reportUrl = pathToFileURL(process.env.RETIRED_REPORT).href;
const report = await import(reportUrl);
const context = { home, config: `${home}/config`, state: `${home}/state`, task: 'retired-result', project: 'firstmate',
  worktree: `${home}/repo`, data: `${home}/data`, policy: report.GUARD_POLICY_VERSION };
const service = report.createGuardService(context);
const requests = [];
mock.module(reportUrl, { namedExports: { ...report, createGuardService: () => ({ ...service,
  decide: async (state) => {
    requests.push(state);
    return { model: 'offline-fixture', answers: { injection: { type: 'noul', noul: /Backgrounded|help\[|IGNORE PREVIOUS/.test(state.content) ? 0.99 : 0.05 },
      kind: { type: 'choice', choice: 'code', confidence: 1 }, contains_secret: { type: 'noul', noul: 0.05 } },
      usage: { input_tokens: 3, output_tokens: 1 }, meta: { provider: 'typesafe', attempts: 1, elapsedMs: 1, cost: { amount: null, source: 'unknown' } } };
  },
}) } });
const { installJevGuard } = await import(pathToFileURL(`${root}/bin/fm-jev-guard.ts`));
const handlers = new Map();
installJevGuard({ on(name, handler) { const list = handlers.get(name) ?? []; list.push(handler); handlers.set(name, list); } }, context);
const ctx = { cwd: context.worktree };
const ledger = `${context.state}/jev-guard.jsonl`;
const rows = () => readFileSync(ledger, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const write = { toolName: 'write', input: { path: 'notes.txt', content: 'ordinary worker file' } };
for (const handler of handlers.get('tool_call') ?? []) assert.equal(await handler(write, ctx), undefined);
writeFileSync(`${context.worktree}/notes.txt`, write.input.content);
assert.equal(requests.length, 1);
assert.equal(rows().length, 1);
async function deliver(event) {
  const original = structuredClone(event);
  const before = requests.length;
  const audit = readFileSync(ledger, 'utf8');
  const delivered = { ...event };
  for (const handler of handlers.get('tool_result') ?? []) {
    const patch = await handler(delivered, ctx);
    for (const field of ['content', 'details', 'isError']) if (patch?.[field] !== undefined) delivered[field] = patch[field];
  }
  assert.deepEqual(delivered, original, 'the receiving worker gets every byte, detail and error state unchanged');
  assert.deepEqual(event, original, 'native event is not mutated');
  assert.equal(requests.length, before, 'no TypeSafe request is made for a result');
  assert.equal(readFileSync(ledger, 'utf8'), audit, 'results create no audit row');
}
const bash = text => ({ toolName: 'bash', input: { command: 'wrapped-local-command' }, content: [{ type: 'text', text }],
  details: { wallTimeMs: 35.9, wallTimeNoticeEmitted: false }, isError: false });
const read = path => ({ toolName: 'read', input: { path: `${path}:raw` }, content: [{ type: 'text', text: readFileSync(path, 'utf8') }],
  details: { meta: { source: { type: 'path', value: path } } } });
JS
    cat
  } | RETIRED_ROOT="$ROOT" RETIRED_TMP="$TMP_ROOT" RETIRED_REPORT="$1" \
    node --experimental-strip-types --experimental-test-module-mocks --no-warnings --input-type=module
}
