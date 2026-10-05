#!/usr/bin/env bash
# Offline consumer-visible boundaries. Native hook/paid Jev proof is separate.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
node --input-type=module - "$ROOT" <<'JS'
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';
const root = process.argv[2];
const lab = mkdtempSync(resolve(process.env.TMPDIR || root, 'jev-test-'));
const tool = resolve(root, 'bin/fm-jev-guardrail.mjs');
const log = resolve(lab, 'records.jsonl');
const fakebin = resolve(lab, 'fakebin');
mkdirSync(fakebin);
const env = { ...process.env, FM_HOME: lab, FM_CONFIG_OVERRIDE: resolve(lab, 'config'), FM_STATE_OVERRIDE: resolve(lab, 'state'), TYPESAFE_API_KEY: '', PATH: `${fakebin}:${process.env.PATH}`, LOG_REQUEST: resolve(lab, 'request.json'), REPLY: 'valid' };
delete env.TYPESAFE_API_KEY_PRIVATE;
writeFileSync(resolve(fakebin, 'curl'), `#!/usr/bin/env node
const fs = require('node:fs');
if (process.env.TYPESAFE_API_KEY || process.env.TYPESAFE_API_KEY_PRIVATE) process.exit(9);
const request = fs.readFileSync(0, 'utf8');
fs.writeFileSync(process.env.LOG_REQUEST, request);
fs.readFileSync(3, 'utf8');
if (process.env.REPLY === 'timeout') process.exit(28);
if (process.env.REPLY === 'malformed') { process.stdout.write(JSON.stringify({model:'jev-1.13.0', usage:{input_tokens:100,output_tokens:1},answers:{risk:{choice:'evil secret response'}}})+'\\n200'); process.exit(0); }
process.stdout.write(JSON.stringify({model:'jev-1.13.0',usage:{input_tokens:100,output_tokens:1},answers:{risk:{type:'choice',choice:'risky',confidence:0.9,probabilities:{risky:0.9,routine:0.05,uncertain:0.05}}}})+'\\n200');
`);
chmodSync(resolve(fakebin, 'curl'), 0o700);
const records = () => readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse);
const hook = (command, overrides = {}, native = 'claude') => {
  const payload = native === 'claude' ? { tool_name: 'Bash', tool_input: { command } } : { toolName: 'bash', input: { command } };
  const result = spawnSync(process.execPath, [tool, 'hook', '--host', native, '--log', log], { env: { ...env, ...overrides }, input: JSON.stringify(payload), encoding: 'utf8' });
  assert.equal(result.status, 0);
  assert.equal(result.stdout, ''); assert.equal(result.stderr, '');
  return records().at(-1);
};
try {
  for (const command of ['cat README.md', 'git status --short', 'printf "rm -rf /production"', 'cat <<EOF\nrm -rf /production\nEOF', 'echo harmless # rm -rf /']) assert.equal(hook(command).status, 'excluded', command);
  for (const command of ['rm -f ./sandbox/item', 'git push --force-with-lease origin topic', 'kubectl --context prod apply -f plan.yml', 'cat .env', 'cat < .env', 'sh -c "rm -rf /production"', 'printf "%s" "$(cat .env)"', '(sudo rm -rf /production)', 'rmdir ./sandbox', "python3 -c 'import os; os.unlink(\"private\")'"]) assert.equal(hook(command).status, 'missing_key', command);
  assert.equal(hook('rm -rf ./sandbox', {}, 'omp').status, 'missing_key');
  assert.equal(records().filter(r => r.event === 'attempt').length, 0);
  console.log('ok - command-position selection excludes ordinary reads and literal examples; selects nested risky operations');

  const secret = 'synthetic-secret-customer-content';
  const result = hook(`TOKEN=${secret} rm -rf /production/${secret}; printf '${secret}'`, { TYPESAFE_API_KEY: 'synthetic-key' });
  assert.equal(result.status, 'judged');
  const request = JSON.parse(readFileSync(env.LOG_REQUEST, 'utf8'));
  assert.deepEqual(request.state, { operations: [{operation:'delete',scope:'production',recursive:true,force:true}], syntax_uncertain:false });
  assert.ok(!readFileSync(log, 'utf8').includes(secret));
  assert.ok(!readFileSync(log, 'utf8').includes('synthetic-key'));
  console.log('ok - closed structural request contains no arbitrary arguments; risky shadow judgment returns no permission decision');

  // These strings are screened only; no delete or secret-read is executed.
  const localDeletes = count => Array.from({length:count}, (_, i) => `rm -f ./sandbox/item-${i}`).join('; ');
  hook(`${localDeletes(31)}; cat .env.synthetic`, { TYPESAFE_API_KEY: 'synthetic-key' });
  const atLimit = JSON.parse(readFileSync(env.LOG_REQUEST, 'utf8')).state;
  assert.equal(atLimit.operations.length, 32);
  assert.equal(atLimit.syntax_uncertain, false);
  assert.equal(atLimit.operations.at(-1).operation, 'secret_read');
  hook(`${localDeletes(32)}; cat .env.synthetic`, { TYPESAFE_API_KEY: 'synthetic-key' });
  const beyondLimit = JSON.parse(readFileSync(env.LOG_REQUEST, 'utf8')).state;
  assert.equal(beyondLimit.syntax_uncertain, true, 'overflow must advertise uncertainty rather than silently lose the 33rd risky operation');
  assert.ok(beyondLimit.operations.some(operation => operation.operation === 'opaque_execution'));
  assert.ok(beyondLimit.operations.length <= 32);
  assert.ok(!readFileSync(env.LOG_REQUEST, 'utf8').includes('.env.synthetic'));
  console.log('ok - exact operation cap preserves the secret read; overflow emits explicit opaque risk without executing the command');

  assert.equal(hook('cat .env', { TYPESAFE_API_KEY: 'synthetic-key', REPLY: 'timeout' }).status, 'timeout');
  assert.equal(hook('cat .env', { TYPESAFE_API_KEY: 'synthetic-key', REPLY: 'malformed' }).status, 'malformed_response');
  assert.ok(!readFileSync(log, 'utf8').includes('evil secret response'));
  mkdirSync(resolve(lab, 'config'));
  writeFileSync(resolve(lab, 'config/dispatch-never-send'), 'private-customer\n');
  const before = records().filter(r => r.event === 'attempt').length;
  assert.equal(hook('rm private-customer', { TYPESAFE_API_KEY: 'synthetic-key' }).status, 'withheld');
  assert.equal(records().filter(r => r.event === 'attempt').length, before);
  writeFileSync(resolve(lab, 'config/dispatch-never-send'), 'private customer\n');
  assert.equal(hook("rm './private\ncustomer'", { TYPESAFE_API_KEY: 'synthetic-key' }).status, 'withheld');
  assert.equal(records().filter(r => r.event === 'attempt').length, before);
  console.log('ok - timeout, malformed response and never-send stay advisory and do not leak response data');

  writeFileSync(resolve(lab, '.env'), 'TYPESAFE_API_KEY=synthetic-file-key\n');
  assert.equal(hook('cat .env').status, 'judged');
  const bad = spawnSync(process.execPath, [tool, 'hook', '--host', 'claude', '--log', log], { env, input: 'not json', encoding:'utf8' });
  assert.equal(bad.status, 0); assert.equal(bad.stdout, '');
  assert.equal(records().at(-1).status, 'invalid_input');
  const attempts = records().filter(r => r.event === 'attempt').length;
  const report = spawnSync(process.execPath, [tool, 'metrics', '--log', log], { env, encoding:'utf8' });
  assert.equal(report.status, 0);
  const values = Object.fromEntries(report.stdout.trim().split('\n').map(line => { const i = line.indexOf(':'); return [line.slice(0,i),JSON.parse(line.slice(i+1).trim())]; }));
  assert.equal(values.attempts, attempts);
  assert.equal(values.unknown_cost_attempts, 1);
  assert.equal(values.known_input_tokens, (attempts - 1) * 100);
  assert.equal(values.promotion_volume_met, false);
  assert.equal(values.shadow_blocks, 0);
  assert.equal(values.risky_recall, null);
  const invalid = spawnSync(process.execPath, [tool, 'metrics', '--bogus', 'x'], { env, encoding:'utf8' });
  assert.equal(invalid.status, 2);
  console.log('ok - environment/file key boundary and all-attempt accounting retain malformed usage and unknown timeout spend');

  const incompleteLog = resolve(lab, 'incomplete.jsonl');
  writeFileSync(incompleteLog, JSON.stringify({version:1,at:1,mode:'shadow',event:'attempt',id:'interrupted',host:'evaluation',selected:true}) + '\n');
  const incomplete = spawnSync(process.execPath, [tool, 'metrics', '--log', incompleteLog], {env,encoding:'utf8'});
  assert.equal(incomplete.status, 0);
  const counters = Object.fromEntries(incomplete.stdout.trim().split('\n').map(line => {
    const i = line.indexOf(':'); return [line.slice(0,i),JSON.parse(line.slice(i+1).trim())];
  }));
  assert.equal(counters.attempts, 1);
  assert.equal(counters.incomplete_attempts, 1);
  assert.equal(counters.unknown_cost_attempts, 1);
  assert.equal(counters.p95_screen_ms, null);
  assert.equal(counters.promotion_volume_met, false);
  console.log('ok - interrupted attempts retain unknown spend and cannot satisfy native fleet volume');
} finally { rmSync(lab, {recursive:true,force:true}); }
JS
