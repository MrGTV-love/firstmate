// Independent live driver: real Claude hook script + real OMP installJevGuard handler, loopback provider.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, appendFileSync, existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const [ROOT, LAB] = process.argv.slice(2);
const results = [];
const log = (name, ok, detail) => { results.push({ name, ok, detail }); console.log(`${ok ? 'PASS' : 'FAIL'} | ${name} | ${detail}`); };
const home = `${LAB}/home`, wt = `${LAB}/wt`, data = `${home}/data/t1`;
mkdirSync(`${home}/config`, { recursive: true }); mkdirSync(`${home}/state`, { recursive: true }); mkdirSync(data, { recursive: true }); mkdirSync(wt, { recursive: true });
writeFileSync(`${home}/.env`, 'TYPESAFE_API_KEY=lab-key\n');
execFileSync('git', ['init', '-q', wt]);
const REQ = `${LAB}/requests.log`; writeFileSync(REQ, '');
const fake = spawn('node', [`${LAB}/fake.mjs`, REQ, `${LAB}/port`], { stdio: 'inherit' });
for (let i = 0; i < 100 && !existsSync(`${LAB}/port`); i++) await new Promise(r => setTimeout(r, 50));
process.env.FM_TEST_SEAM = '1';
process.env.FM_JEV_GUARD_BASE_URL = `http://127.0.0.1:${readFileSync(`${LAB}/port`, 'utf8')}/v1/systemone`;
process.env.FM_FRICTION_EXECUTION_KIND = 'test';
process.env.HOME = process.env.HOME; // unchanged
const ctxObj = { home, config: `${home}/config`, state: `${home}/state`, task: 't1', worktree: wt, data, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' };
const sent = () => readFileSync(REQ, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const rows = () => readFileSync(`${home}/state/jev-guard.jsonl`, 'utf8').trim().split('\n').map(JSON.parse);
const last = () => rows().at(-1);
const { installJevGuard } = await import(pathToFileURL(`${ROOT}/bin/fm-jev-guard.ts`));
const { MAX_REQUEST_BYTES, MAX_CHUNKS, SIZE_REFUSAL_NOTICE } = await import(pathToFileURL(`${ROOT}/bin/ten-levels/extensions/report.ts`));
const handlers = {};
installJevGuard({ on(n, h) { handlers[n] = h; } }, ctxObj);
const ompCtx = { cwd: wt };
const hookPath = `${ROOT}/bin/fm-jev-guard-hook.sh`;
function claude(tool, input, event = 'PreToolUse', extra = {}) {
  const payload = JSON.stringify({ hook_event_name: event, cwd: wt, tool_name: tool, tool_input: input, tool_use_id: 'x', ...extra });
  const r = execFileSync(hookPath, [home, ctxObj.config, ctxObj.state, 't1', wt, data, 'firstmate', 'FIRSTMATE_JEV_GUARD_V1'], { input: payload, encoding: 'utf8', env: { ...process.env } });
  return r === '' ? undefined : JSON.parse(r).hookSpecificOutput;
}
const omp = (tool, input) => handlers.tool_call({ toolName: tool, input }, ompCtx);
const isDeny = (r) => r?.block === true || r?.permissionDecision === 'deny';
const reasonOf = (r) => r?.reason ?? r?.permissionDecisionReason ?? '';

const report = 'Ordinary report line with measured observations and no credentials.\n'.repeat(7000).slice(0, 396924);
assert.equal(Buffer.byteLength(report), 396924);
const path = `${wt}/report.md`;

for (const host of ['claude', 'omp']) {
  const call = async (tool, content, p = path) => host === 'claude'
    ? claude(tool === 'write' ? 'Write' : 'Edit', tool === 'write' ? { file_path: p, content } : { file_path: p, old_string: '', new_string: content })
    : omp(tool, tool === 'write' ? { path: p, content } : { path: p, old_string: '', new_string: content });
  // S1: 396,924-byte report admitted, 16 requests, each within bound, exact coverage audit, then write+commit
  let before = sent().length;
  const t0 = performance.now();
  const out = await call('write', report);
  const ms = Math.round(performance.now() - t0);
  const reqs = sent().slice(before);
  const row = last();
  log(`${host}: 396924-byte Write admitted`, out === undefined && reqs.length === 16 && reqs.every(r => r.bytes <= MAX_REQUEST_BYTES) && row.decision === 'allow',
    `out=${JSON.stringify(out)} requests=${reqs.length} maxbytes=${Math.max(...reqs.map(r => r.bytes))} coverage=${JSON.stringify(row.write_coverage)} note=${JSON.stringify(row.note)} loopback_ms=${ms}`);
  log(`${host}: audit coverage sums to file size with note`, row.write_coverage.model_screened_bytes + row.write_coverage.local_only_bytes === 396924 && /unscreened remainder/.test(row.note ?? ''), JSON.stringify(row.write_coverage));
  writeFileSync(path, report);
  const cmd = 'git add report.md && git -c user.name=Lab -c user.email=lab@example.invalid -c commit.gpgsign=false commit --allow-empty -qm "report ' + host + '"';
  const shellOut = host === 'claude' ? claude('Bash', { command: cmd }) : await omp('bash', { command: cmd });
  execFileSync('bash', ['-c', cmd], { cwd: wt });
  const committed = execFileSync('git', ['show', 'HEAD:report.md'], { cwd: wt }).length;
  log(`${host}: git commit of the 396924-byte report`, shellOut === undefined && committed === 396924, `shell_guard_out=${JSON.stringify(shellOut)} committed_bytes=${committed}`);
  // S2: Edit tool oversize
  before = sent().length;
  const eo = await call('edit', report);
  log(`${host}: oversize Edit admitted`, eo === undefined && sent().length - before === 16, `out=${JSON.stringify(eo)} requests=${sent().length - before}`);
  // S3: credentials start/middle/end
  for (const tool of ['write', 'edit']) for (const [pos, at] of [['start', 0], ['middle', 200000], ['end', report.length]]) for (const fake of ['\nghp_' + 'A'.repeat(30) + '\n', '\n-----BEGIN PGP PRIVATE KEY BLOCK-----\n', '\nredis://:hunter2hunter2@cache:6379\n']) {
    before = sent().length;
    const d = await call(tool, report.slice(0, at) + fake + report.slice(at));
    const ok = isDeny(d) && sent().length === before && last().request_started === false && last().branch === 'deterministic';
    if (!ok) log(`${host}: ${tool} credential ${pos}`, false, `deny=${isDeny(d)} reqs=${sent().length - before} row=${JSON.stringify(last())}`);
  }
  log(`${host}: credentials at start/middle/end refused locally, zero requests (write+edit, 3 shapes)`, !results.some(r => !r.ok && r.name.startsWith(`${host}: `) && /credential/.test(r.name)), 'see no FAIL lines above');
  // S4: root refusal
  before = sent().length;
  const od = await call('write', report, '/etc/jev-live-lab');
  log(`${host}: oversize write outside repo roots refused, zero requests`, isDeny(od) && sent().length === before, `reason=${reasonOf(od).slice(0, 80)}`);
  // S5: adversarial benign: hyphenated words, compact JSON, query-string email in remainder
  const prose = ['task-specific-guidelines', 'risk-based-assessment', 'disk-backed-storage-layer', '{"endpoint":"http://localhost:3000","owner":"alice@example.com"}', 'url,http://host:8080,owner,bob@example.com', 'http://localhost:3000?email=foo@bar.com', 'password = process.env.DATABASE_PASSWORD'].join('\n');
  before = sent().length;
  const pd = await call('write', report + '\n' + prose);
  log(`${host}: oversize write with benign compact data/hyphenated prose admitted`, pd === undefined, `out=${JSON.stringify(pd)} reqs=${sent().length - before}`);
  // S6: a policy-risky piece inside the screened window still blocks; and an outage still blocks
  const rd = await call('write', 'rm -rf /\n' + report);
  log(`${host}: model-screened destructive piece in oversize write blocks`, isDeny(rd), `reason=${reasonOf(rd).slice(0, 100)}`);
  const od2 = await call('write', 'fail500 ' + report);
  log(`${host}: provider outage on oversize write stays blocked (guard still active)`, isDeny(od2) && last().write_coverage === undefined, `reason=${reasonOf(od2).slice(0, 100)}`);
  // S7: boundary: fits-in-one vs just-over
  for (const n of [12000, 16384, 20000]) {
    before = sent().length;
    const bd = await call('write', 'a'.repeat(n));
    const rr = sent().length - before; const w = last().write_coverage;
    log(`${host}: ${n}-byte write coverage`, bd === undefined && w.model_screened_bytes + w.local_only_bytes === n && w.local_only_bytes === 0, `reqs=${rr} coverage=${JSON.stringify(w)}`);
  }
  for (const n of [245000, 262145, 1048576]) {
    before = sent().length;
    const bd = await call('write', 'a '.repeat(Math.ceil(n / 2)).slice(0, n));
    const rr = sent().length - before; const w = last().write_coverage;
    log(`${host}: ${n}-byte write admitted with exact coverage`, bd === undefined && w.model_screened_bytes + w.local_only_bytes === n && rr <= 16, `reqs=${rr} coverage=${JSON.stringify(w)}`);
  }
}

// S8: shell + result still bounded; refusal text no longer advises splitting
const hugeCmd = 'echo ' + 'x'.repeat(262145);
let before = sent().length;
const sd = handlers.tool_call({ toolName: 'bash', input: { command: hugeCmd } }, ompCtx) ; const sdr = await sd;
log('omp: oversize shell command still refused (FM-JEV-SIZE), zero requests', isDeny(sdr) && sent().length === before && /FM-JEV-SIZE/.test(reasonOf(sdr)), `reason=${reasonOf(sdr).slice(0, 200)}`);
log('size refusal text has no split-the-report / 150,000 advice', !/split the report|separate files|150,000/i.test(reasonOf(sdr)) && !/split the report|separate files|150,000/i.test(SIZE_REFUSAL_NOTICE), `notice_tail=${SIZE_REFUSAL_NOTICE.slice(-160)}`);
const cd = claude('Bash', { command: hugeCmd });
log('claude: oversize shell command still refused, no split advice', isDeny(cd) && /FM-JEV-SIZE/.test(reasonOf(cd)) && !/split the report|separate files|150,000/i.test(reasonOf(cd)), `reason=${reasonOf(cd).slice(0, 120)}`);
before = sent().length;
const rres = await handlers.tool_result({ toolName: 'bash', input: { command: 'cat x' }, content: [{ type: 'text', text: 'y'.repeat(262145) }], details: {}, isError: false }, ompCtx);
log('omp: oversize tool result still withheld (unchanged)', rres?.isError === true && /RequestTooLargeError|REFUSED|withheld/.test(JSON.stringify(rres)), `result=${JSON.stringify(rres).slice(0, 200)} reqs=${sent().length - before}`);
fake.kill();
const bad = results.filter(r => !r.ok);
console.log(`\nSUMMARY total=${results.length} fail=${bad.length}`);
process.exit(bad.length ? 1 : 0);
