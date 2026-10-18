// A/B driver for the guard: the reported scenarios against a judge that answers
// slowly (DELAY_MS). Usage: node ab-driver.mjs <bin-dir-of-checkout> <delay-ms> <label>
// Drives the real installJevGuard handlers (the code omp and the Claude hook run)
// against a throwaway home, worktree and a local judge that answers after the delay.
import { createServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, realpathSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

const [bin, delayArg, label] = process.argv.slice(2);
const delay = Number(delayArg);
const lab = realpathSync(mkdtempSync(`${tmpdir()}/ab-guard.`));
const requestLog = `${lab}/requests.jsonl`;
writeFileSync(requestLog, '');

const server = createServer((req, res) => {
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    appendFileSync(requestLog, JSON.stringify({ at: performance.now() }) + '\n');
    const request = JSON.parse(body);
    const answers = {};
    for (const [id, q] of Object.entries(request.questions)) {
      if (q.type === 'noul') { answers[id] = { type: 'noul', noul: 0.05 }; continue; }
      const keys = Object.keys(q.criteria);
      answers[id] = { type: 'choice', choice: keys[0], confidence: 1, probabilities: Object.fromEntries(keys.map((k) => [k, k === keys[0] ? 1 : 0])) };
    }
    setTimeout(() => {
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ model: 'jev-fake', answers, usage: { input_tokens: 3, output_tokens: 1 } }));
    }, delay);
  });
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
process.env.FM_TEST_SEAM = '1';
process.env.FM_JEV_GUARD_BASE_URL = `http://127.0.0.1:${server.address().port}/v1/systemone`;

const home = `${lab}/home`;
const worktree = `${lab}/worktree`;
const data = `${home}/data/scout1`;
for (const dir of [`${home}/config`, `${home}/state`, data, worktree, `${lab}/outside`]) mkdirSync(dir, { recursive: true });
writeFileSync(`${home}/.env`, 'TYPESAFE_API_KEY=ab-driver-key\n');
execFileSync('git', ['init', '-q', worktree]);
writeFileSync(`${data}/request.md`, 'Scout task: read the files and report.\n');
writeFileSync(`${lab}/outside/notes.txt`, 'ordinary notes outside every trusted root\n');

const { installJevGuard } = await import(pathToFileURL(`${bin}/fm-jev-guard.ts`));
function install(host, task) {
  const handlers = {};
  installJevGuard({ on(name, fn) { handlers[name] = fn; } },
    { home, config: `${home}/config`, state: `${home}/state`, task, host, worktree, data, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' });
  return handlers;
}
const requests = () => readFileSync(requestLog, 'utf8').split('\n').filter(Boolean).length;
const text = (r) => r === undefined ? 'undefined (allowed, output untouched)' : JSON.stringify(r).slice(0, 260);

async function run(name, fn) {
  const before = requests();
  const t0 = performance.now();
  let out;
  try { out = await fn(); } catch (e) { out = { threw: String(e) }; }
  const ms = Math.round(performance.now() - t0);
  console.log(`[${label}] ${name}: ${ms} ms, judge requests=${requests() - before}, result=${text(out)}`);
}

// 1. Scout reads its own task file on omp (the reported "[jev-guard] Tool output requires review" case).
const omp = install('omp', 'scout1');
const ompRead = (path) => ({ toolName: 'read', input: { path: `${path}:raw`, i: 'Reading own task file' },
  content: [{ type: 'text', text: readFileSync(path, 'utf8') }], details: { meta: { source: { type: 'path', value: path } } } });
await run('scout reads its own task file (omp)', () => omp.tool_result(ompRead(`${data}/request.md`), { cwd: worktree }));
// 2. Read of a file the guard must judge, Claude host: a slow judge must not withhold.
const claude = install('claude', 'scout2');
await run('read of an untrusted file, judge slow (claude)', () => claude.tool_result(
  { toolName: 'read', input: { path: `${lab}/outside/notes.txt` }, content: [{ type: 'text', text: 'ordinary notes outside every trusted root\n' }] }, { cwd: worktree }));
// 3. Fixer's Write of a review request ("block is final" in the report).
const fixer = install('omp', 'fixer1');
await run('fixer writes a review request (omp)', () => fixer.tool_call(
  { toolName: 'write', input: { path: `${data}/review-request.md`, content: 'Please review the change in src/app.ts.\n' } }, { cwd: worktree }));
// 4. Boundary: another task's data file and an untracked worktree file must still be judged.
mkdirSync(`${home}/data/other-task`, { recursive: true });
writeFileSync(`${home}/data/other-task/secret.md`, 'another task private note\n');
writeFileSync(`${worktree}/untracked.txt`, 'a new untracked file\n');
await run('read of ANOTHER task data file is still judged (omp)', () => omp.tool_result(ompRead(`${home}/data/other-task/secret.md`), { cwd: worktree }));
await run('read of an UNTRACKED worktree file is still judged (omp)', () => omp.tool_result(ompRead(`${worktree}/untracked.txt`), { cwd: worktree }));
// 5. A tracked, modified worktree file is the worker's own work: trusted, no judge.
writeFileSync(`${worktree}/tracked.txt`, 'v1\n');
execFileSync('git', ['-C', worktree, 'add', 'tracked.txt']);
execFileSync('git', ['-C', worktree, '-c', 'user.name=x', '-c', 'user.email=x@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'x']);
writeFileSync(`${worktree}/tracked.txt`, 'v2 modified by the worker\n');
await run('read of a MODIFIED tracked worktree file is trusted (omp)', () => omp.tool_result(ompRead(`${worktree}/tracked.txt`), { cwd: worktree }));
server.close();
process.exit(0);
