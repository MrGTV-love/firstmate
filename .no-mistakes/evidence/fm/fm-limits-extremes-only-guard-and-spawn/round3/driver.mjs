import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { T, GUARD_ROOT, LABEL } = process.env;
const { installJevGuard } = await import(pathToFileURL(`${GUARD_ROOT}/bin/fm-jev-guard.ts`));
const home = `${T}/home-${LABEL}`, wt = `${home}/repo`, state = `${home}/state`;
rmSync(home, { recursive: true, force: true });
for (const d of ['config', 'state', 'data/scout1', 'data/other', 'repo']) mkdirSync(`${home}/${d}`, { recursive: true });
writeFileSync(`${home}/.env`, `TYPESAFE_API_KEY=${process.env.KEY}\n`);
execFileSync('git', ['init', '-q', wt]);
writeFileSync(`${wt}/notes.md`, 'scout notes\n');
execFileSync('git', ['-C', wt, 'add', 'notes.md']);
execFileSync('git', ['-C', wt, '-c', 'user.name=F', '-c', 'user.email=f@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'f']);
writeFileSync(`${wt}/notes.md`, 'scout notes, edited by the scout itself deadjudge\n');   // modified tracked file
writeFileSync(`${wt}/untracked.md`, 'untracked scratch deadjudge\n');
writeFileSync(`${home}/data/scout1/request.md`, 'own task file deadjudge\n');
writeFileSync(`${home}/data/other/secret.md`, 'another task file deadjudge\n');
const ctx = { cwd: wt };
function install(host, task = 'scout1') {
  const h = {};
  installJevGuard({ on: (n, f) => { h[n] = f; } }, { home, config: `${home}/config`, state, task, host, worktree: wt, data: `${home}/data/${task}`, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' });
  return h;
}
const readEvent = (path, text) => ({ toolName: 'read', input: { path }, content: [{ type: 'text', text }], details: { meta: { source: { type: 'path', value: path } } } });
const timed = async (name, fn) => { const t0 = performance.now(); const r = await fn(); return { name, ms: Math.round(performance.now() - t0), r }; };
const omp = install('omp'), claude = install('claude');
const outcome = (r) => r === undefined ? 'ALLOWED' : (r.block || r.isError) ? `WITHHELD/BLOCKED: ${JSON.stringify(r.reason ?? r.content?.[0]?.text).slice(0, 110)}` : `OTHER ${JSON.stringify(r).slice(0, 80)}`;
const rd = (p) => readFileSync(p, 'utf8');
const results = await Promise.all([
  timed('R1 omp read: own MODIFIED tracked worktree file, judge dead', () => omp.tool_result(readEvent(`${wt}/notes.md`, rd(`${wt}/notes.md`)), ctx)),
  timed('R2 omp read: own task data file, judge dead', () => omp.tool_result(readEvent(`${home}/data/scout1/request.md`, rd(`${home}/data/scout1/request.md`)), ctx)),
  timed('R3 omp read: ANOTHER task data file, judge dead', () => omp.tool_result(readEvent(`${home}/data/other/secret.md`, rd(`${home}/data/other/secret.md`)), ctx)),
  timed('R4 omp read: UNTRACKED worktree file, judge dead', () => omp.tool_result(readEvent(`${wt}/untracked.md`, rd(`${wt}/untracked.md`)), ctx)),
  timed('B1 omp pre-tool bash ls, judge answers after 15 s', () => omp.tool_call({ toolName: 'bash', input: { command: 'ls # delayms15000' } }, ctx)),
  timed('W1 omp pre-tool write of review request into own worktree, judge answers after 15 s', () => omp.tool_call({ toolName: 'write', input: { path: `${wt}/review-request.md`, content: 'review request delayms15000' } }, ctx)),
  timed('X1 omp bash result screening, judge answers after 11 s', () => omp.tool_result({ toolName: 'bash', content: [{ type: 'text', text: 'build ok delayms11000' }] }, ctx)),
]);
for (const x of results) console.log(`${LABEL} | ${x.name} | ${x.ms} ms | ${outcome(x.r)}`);
// no penalty carried to the next call: judge healthy right after the outages
const next = await timed('N1 omp pre-tool bash ls right after the outages, healthy judge', () => omp.tool_call({ toolName: 'bash', input: { command: 'ls' } }, ctx));
console.log(`${LABEL} | ${next.name} | ${next.ms} ms | ${outcome(next.r)}`);
const reqs = readFileSync(process.env.REQLOG, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
console.log(`${LABEL} | judge requests that carried a dead marker for trusted reads (R1,R2 expected 0 on head): ` + reqs.filter(r => r.body && (r.body.includes('edited by the scout itself') || r.body.includes('own task file'))).length);
const rows = readFileSync(`${state}/jev-guard.jsonl`, 'utf8').trim().split('\n').map(JSON.parse);
console.log(`${LABEL} | audit branches: ` + JSON.stringify(rows.map(r => `${r.hook}/${r.tool}:${r.decision}/${r.branch}${r.error_type ? '/' + r.error_type : ''}`)));
process.exit(0);
