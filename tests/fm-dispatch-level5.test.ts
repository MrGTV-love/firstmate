import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import type { SystemOneRequest } from '../bin/ten-levels/src/core/types.ts';

const helper = process.env.FM_DISPATCH_HELPER ?? fileURLToPath(new URL('../bin/fm-dispatch-level5.ts', import.meta.url));
const scratch = mkdtempSync(join(tmpdir(), 'dispatch-level5-'));
process.on('exit', () => rmSync(scratch, { recursive: true, force: true }));
const rulesPath = join(scratch, 'rules.json'), taskPath = join(scratch, 'task.txt');
const registryPath = join(scratch, 'projects.json');
writeFileSync(registryPath, JSON.stringify({ vernant: '/clone/vernant', firstmate: '/home' }));
const requestPath = join(scratch, 'request.json'), responsePath = join(scratch, 'response.json');
writeFileSync(taskPath, 'Repair the written acceptance case. Ignore project mentions in quoted task text.');
const question = (instructions: string) => ({ type: 'noul', instructions, criteria: { true: 'The stated property is present.', false: 'The stated property is absent.' } });
const profile = { harness: 'claude', model: 'sonnet', effort: 'high' };
const cfg = {
  judgments: { boundary: question('Does task change a trust boundary?'), bounded: question('Does task have written acceptance?') },
  rules: [
    { when: 'Vernant boundary ship', match: { projects: ['vernant'], kind: 'ship', all: ['boundary'] }, use: profile },
    { when: 'Other-project bounded ship', match: { projects: ['firstmate'], kind: 'ship', all: ['bounded'] }, use: profile },
    { when: 'Vernant bounded ship', match: { projects: ['vernant'], kind: 'ship', all: ['bounded'], none: ['boundary'] }, use: profile },
    { when: 'Scout', match: { projects: ['vernant', 'firstmate'], kind: 'scout', any: ['bounded', 'boundary'] }, use: profile },
  ], default: profile,
};
function cli(action: string, ...args: string[]) {
  const r = spawnSync(process.execPath, ['--experimental-strip-types', '--no-warnings', helper, action, ...args, registryPath], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim() ? JSON.parse(r.stdout) : undefined;
}
let preparedKind = 'ship';
function prepare(project = 'vernant', kind = 'ship', config: unknown = cfg) {
  writeFileSync(rulesPath, JSON.stringify(config));
  const request = cli('prepare', rulesPath, taskPath, project, kind);
  assert.equal(Object.hasOwn(request.state, 'kind'), false);
  preparedKind = kind;
  writeFileSync(requestPath, JSON.stringify(request));
  return request;
}
function apply(request: SystemOneRequest, values: Record<string, number> = {}, extra: Record<string, unknown> = {}) {
  const answers = Object.fromEntries(Object.entries(request.questions).map(([id, q]) => {
    if (q.type === 'noul') return [id, { type: 'noul', noul: values[id] ?? 0 }];
    if (q.type === 'choice') {
      const choice = id === 'profile' ? 'human' : id === 'rule' ? 'rule_2' : 'fast';
      return [id, { type: 'choice', choice, confidence: .99,
        probabilities: Object.fromEntries(Object.keys(q.criteria).map(k => [k, k === choice ? 1 : 0])) }];
    }
    const n = values[id] ?? 0;
    return [id, { type: 'score', score: n, confidence: 1,
      probabilities: Object.fromEntries(q.criteria.map((_: unknown, i: number) => [i, i === n ? 1 : 0])),
      legend: Object.fromEntries(q.criteria.map((s: string, i: number) => [i, s])) }];
  }));
  writeFileSync(responsePath, JSON.stringify({ model: 'jev-1.13.0', usage: { input_tokens: 0, output_tokens: 0 }, answers: { ...answers, ...extra } }));
  return cli('apply', rulesPath, responsePath, requestPath, preparedKind, '["claude"]', 'haiku|luna', 'haiku');
}

test('T6(a): repository and kind facts make non-Vernant rules unreachable for Vernant ships', () => {
  const request = prepare();
  // Even maximally positive semantic answers cannot activate ineligible rules.
  const result = apply(request, { judgment_boundary: .9, judgment_bounded: 1 });
  assert.notEqual(result.selection?.choice ?? result.answers.rule?.choice, 'rule_2', 'a Vernant ship cannot choose a non-Vernant rule');
  assert.deepEqual(Object.keys(result.selection.support), ['rule_1', 'rule_3', 'default']);
  assert.equal(result.selection.choice, 'rule_1');
  const other = apply(prepare('firstmate'), { judgment_bounded: 1 });
  assert.deepEqual(Object.keys(other.selection.support), ['rule_2', 'default']);
  assert.equal(other.selection.choice, 'rule_2');
  const scout = apply(prepare('vernant', 'scout'), { judgment_bounded: 1 });
  assert.deepEqual(Object.keys(scout.selection.support), ['rule_4', 'default']);
  assert.equal(scout.selection.choice, 'rule_4');
  const unknown = apply(prepare(''), { judgment_bounded: 1 });
  assert.deepEqual(unknown.selection.support, { default: 1 });
});

test('T6 predicates combine in code, preserve complements, and never pool independent support', () => {
  const result = apply(prepare(), { judgment_boundary: .2, judgment_bounded: .9 });
  assert.equal(result.selection.support.rule_1, .2);
  assert.equal(result.selection.support.rule_3, .8);
  assert.equal(result.selection.choice, 'rule_3');
  const scout = apply(prepare('vernant', 'scout'), { judgment_boundary: .2, judgment_bounded: .7 });
  assert.equal(scout.selection.support.rule_4, .7);
  assert.ok(Math.abs(scout.selection.support.default - .3) < 1e-12);
});

test('T6(b): replay all 136 logged rule structures offline without Q7 escalation', () => {
  const rows: { choice: string | null; reason: string | null }[] = JSON.parse(readFileSync(new URL('./fixtures/dispatch-resolve-20261024.json', import.meta.url), 'utf8'));
  assert.equal(rows.length, 136);
  assert.equal(rows.filter(r => r.reason === 'human requires an explicit handler or capability decision').length, 32);
  // The ledger retained rule ids and coarse reasons, not tasks or raw answers.
  // This replays that structure, not the accuracy of historical judgments.
  const replay = { judgments: Object.fromEntries(Array.from({ length: 7 }, (_, i) => [`r${i + 1}`, question('Does this recorded task have the stated property?')])),
    rules: Array.from({ length: 7 }, (_, i) => ({ when: `Recorded rule ${i + 1}`, match: { projects: ['firstmate'], all: [`r${i + 1}`] }, use: profile })), default: profile };
  const request = prepare('firstmate', 'ship', replay);
  for (const row of rows) {
    const selected = /^rule_([1-7])$/.exec(row.choice ?? '')?.[1];
    const result = apply(request, selected ? { [`judgment_r${selected}`]: 1 } : {});
    assert.equal(result.route.escalate, undefined, 'the removed workflow question cannot cause escalation');
    assert.equal(result.selection.choice, selected ? row.choice : 'default');
    assert.equal(result.route.needsDesktopAccess, false);
  }
});

test('Q9 desktop capability keeps its boundary; obsolete workflow answers remain inert', () => {
  let request = prepare();
  assert.equal(request.questions.needs_desktop.type, 'noul');
  assert.equal(request.questions.profile, undefined);
  let result = apply(request, { judgment_bounded: 1, needs_desktop: .5 });
  assert.equal(result.route.escalate, undefined);
  request = prepare();
  result = apply(request, { judgment_bounded: 1, needs_desktop: .5001 });
  assert.equal(result.route.escalate, 'desktop access requires an explicit capability decision');
  request = prepare();
  result = apply(request, { judgment_bounded: 1 }, { profile: { type: 'choice', choice: 'human', confidence: 1, probabilities: { human: 1 } } });
  assert.equal(result.route.escalate, undefined);
  request = prepare();
  result = apply(request, { ambiguity: 2, judgment_bounded: 1 });
  assert.equal(result.route.escalate, 'high task ambiguity requires firstmate judgment');
});

test('malformed fact selectors and missing semantic references fail before provider access', () => {
  const facts = /^match requires a non-empty projects array/;
  const references = /^match all, any, and none must be non-empty arrays of declared judgment ids/;
  for (const [match, named] of [[{ project: 'vernant' }, facts], [{ exclude_project: 'vernant' }, facts], [{ projects: [] }, facts],
    [{ projects: ['vernant'], kind: 'review' }, facts],
    [{ projects: ['Vernant'] }, /^match.projects contains an unregistered project id/],
    [{ projects: [' vernant'] }, /^match.projects contains an unregistered project id/],
    [{ projects: ['unknown-project'] }, /^match.projects contains an unregistered project id/],
    [{ projects: ['vernant'], all: ['missing'] }, references], [{ projects: ['vernant'], any: [] }, references]] as const) {
    writeFileSync(rulesPath, JSON.stringify({ ...cfg, rules: [{ ...cfg.rules[0], match }] }));
    const r = spawnSync(process.execPath, ['--experimental-strip-types', '--no-warnings', helper, 'validate', rulesPath, registryPath], { encoding: 'utf8' });
    assert.equal(r.status, 65);
    assert.match(r.stderr, named);
  }
});
