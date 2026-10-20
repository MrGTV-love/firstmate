import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, unlinkSync, existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [ROOT, LAB] = process.argv.slice(2);
const mk = (name) => { const home = `${LAB}/${name}`, wt = `${home}/wt`, data = `${home}/data/t1`;
  mkdirSync(`${home}/config`, { recursive: true }); mkdirSync(`${home}/state`, { recursive: true }); mkdirSync(data, { recursive: true }); mkdirSync(wt, { recursive: true });
  writeFileSync(`${home}/.env`, 'TYPESAFE_API_KEY=lab-key\n'); execFileSync('git', ['init', '-q', wt]);
  return { home, config: `${home}/config`, state: `${home}/state`, task: 't1', worktree: wt, data, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' }; };
const REQ = `${LAB}/prequests.log`; writeFileSync(REQ, '');
const fake = spawn('node', [`${LAB}/fake.mjs`, REQ, `${LAB}/pport`], { stdio: 'inherit' });
for (let i = 0; i < 100 && !existsSync(`${LAB}/pport`); i++) await new Promise(r => setTimeout(r, 50));
process.env.FM_TEST_SEAM = '1'; process.env.FM_FRICTION_EXECUTION_KIND = 'test';
process.env.FM_JEV_GUARD_BASE_URL = `http://127.0.0.1:${readFileSync(`${LAB}/pport`, 'utf8')}/v1/systemone`;
const { installJevGuard } = await import(pathToFileURL(`${ROOT}/bin/fm-jev-guard.ts`));
const sent = () => readFileSync(REQ, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const report = 'Ordinary report line with measured observations and no credentials.\n'.repeat(7000).slice(0, 396924);
let bad = 0; const ok = (n, c, d) => { if (!c) bad++; console.log(`${c ? 'PASS' : 'FAIL'} | ${n} | ${d}`); };
{ // privacy
  const c = mk('p1'); const h = {}; installJevGuard({ on(n, f) { h[n] = f; } }, c);
  const w = (content) => h.tool_call({ toolName: 'write', input: { path: `${c.worktree}/r.md`, content } }, { cwd: c.worktree });
  writeFileSync(`${c.config}/dispatch-never-send`, 'lab-never-send-canary\n');
  let n0 = sent().length;
  let r = await w(report.slice(0, 5000) + '\nlab-never-send-canary\n' + report.slice(5000));
  const row = JSON.parse(readFileSync(`${c.state}/jev-guard.jsonl`, 'utf8').trim().split('\n').at(-1));
  ok('canary in model-sent piece: write refused, nothing sent', r?.block === true && sent().length === n0 && row.error_type === 'PrivacyWithheldError', `blocked=${r?.block} extra_reqs=${sent().length - n0} error_type=${row.error_type}`);
  n0 = sent().length;
  r = await w(report + '\nlab-never-send-canary\n');
  ok('canary only in unscreened remainder: admitted, canary never sent (documented)', r === undefined && sent().length - n0 === 16 && sent().slice(n0).every(q => !JSON.stringify(q).includes('lab-never-send-canary')), `blocked=${r?.block === true} reqs=${sent().length - n0}`);
  unlinkSync(`${c.config}/dispatch-never-send`);
}
{ // multibyte / escapes / lone surrogates
  const c = mk('p2'); const h = {}; installJevGuard({ on(n, f) { h[n] = f; } }, c);
  const u = ('é"\\😀\n\ud800x\udfff' + String.fromCharCode(...Array.from({ length: 32 }, (_, i) => i))).repeat(12000);
  const n0 = sent().length;
  const r = await h.tool_call({ toolName: 'write', input: { path: `${c.worktree}/u.md`, content: u } }, { cwd: c.worktree });
  const row = JSON.parse(readFileSync(`${c.state}/jev-guard.jsonl`, 'utf8').trim().split('\n').at(-1));
  const q = readFileSync(REQ, 'utf8').trim().split('\n').slice(n0).map(JSON.parse);
  ok('multibyte/escape/lone-surrogate oversize write admitted within 16 requests of <=16384 bytes', r === undefined && q.length <= 16 && q.every(x => x.bytes <= 16384), `reqs=${q.length} max=${Math.max(...q.map(x => x.bytes))}`);
  ok('coverage bytes sum to UTF-8 size', row.write_coverage.model_screened_bytes + row.write_coverage.local_only_bytes === Buffer.byteLength(u), JSON.stringify(row.write_coverage) + ' vs ' + Buffer.byteLength(u));
  ok('no valid astral pair cut in any piece', q.every(x => !/\ud83d(?!\ude00)|(?<!\ud83d)\ude00/.test(x.content)), 'checked');
}
{ // inactive scope sends nothing
  const c = { ...mk('p3'), project: 'someotherproject' }; const h = {}; installJevGuard({ on(n, f) { h[n] = f; } }, c);
  const n0 = sent().length;
  const r = await h.tool_call({ toolName: 'write', input: { path: `${c.worktree}/r.md`, content: report } }, { cwd: c.worktree });
  ok('non-authorized project: oversize write sends nothing to a model', sent().length === n0, `blocked=${r?.block === true} reqs=${sent().length - n0}`);
}
fake.kill(); console.log(`PRIVACY bad=${bad}`); process.exit(bad ? 1 : 0);
