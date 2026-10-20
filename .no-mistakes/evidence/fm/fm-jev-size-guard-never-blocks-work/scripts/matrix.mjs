import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [ROOT, LAB] = process.argv.slice(2);
const home = `${LAB}/mhome`, wt = `${LAB}/mwt`, data = `${home}/data/t1`;
mkdirSync(`${home}/config`, { recursive: true }); mkdirSync(`${home}/state`, { recursive: true }); mkdirSync(data, { recursive: true }); mkdirSync(wt, { recursive: true });
writeFileSync(`${home}/.env`, 'TYPESAFE_API_KEY=lab-key\n');
execFileSync('git', ['init', '-q', wt]);
const REQ = `${LAB}/mrequests.log`; writeFileSync(REQ, '');
const fake = spawn('node', [`${LAB}/fake.mjs`, REQ, `${LAB}/mport`], { stdio: 'inherit' });
for (let i = 0; i < 100 && !existsSync(`${LAB}/mport`); i++) await new Promise(r => setTimeout(r, 50));
process.env.FM_TEST_SEAM = '1';
process.env.FM_JEV_GUARD_BASE_URL = `http://127.0.0.1:${readFileSync(`${LAB}/mport`, 'utf8')}/v1/systemone`;
process.env.FM_FRICTION_EXECUTION_KIND = 'test';
const ctxObj = { home, config: `${home}/config`, state: `${home}/state`, task: 't1', worktree: wt, data, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' };
const { installJevGuard } = await import(pathToFileURL(`${ROOT}/bin/fm-jev-guard.ts`));
const handlers = {}; installJevGuard({ on(n, h) { handlers[n] = h; } }, ctxObj);
const sentN = () => readFileSync(REQ, 'utf8').trim().split('\n').filter(Boolean).length;
const report = 'Ordinary report line with measured observations and no credentials.\n'.repeat(7000).slice(0, 396924);
const refuse = [
  ['gho_', 'gho_' + 'A'.repeat(25)], ['ghu_', 'ghu_' + 'A'.repeat(25)], ['ghs_', 'ghs_' + 'A'.repeat(25)], ['ghr_', 'ghr_' + 'A'.repeat(25)],
  ['github_pat_', 'github_pat_' + 'A'.repeat(30)], ['AKIA', 'AKIA' + 'A'.repeat(16)], ['ASIA', 'ASIA' + 'B'.repeat(16)],
  ['xoxa', 'xoxa-' + 'A'.repeat(20)], ['xoxp', 'xoxp-' + 'A'.repeat(20)], ['xoxr', 'xoxr-' + 'A'.repeat(20)], ['xoxs', 'xoxs-' + 'A'.repeat(20)],
  ['RSA key', '-----BEGIN RSA PRIVATE KEY-----'], ['EC key', '-----BEGIN EC PRIVATE KEY-----'], ['OPENSSH key', '-----BEGIN OPENSSH PRIVATE KEY-----'],
  ['ENCRYPTED key', '-----BEGIN ENCRYPTED PRIVATE KEY-----'], ['plain key', '-----BEGIN PRIVATE KEY-----'], ['PGP block', '-----BEGIN PGP PRIVATE KEY BLOCK-----'],
  ['mongodb+srv', 'mongodb+srv://admin:Sup3rSecretPw@cluster0.example.net/db'], ['empty-user redis', 'redis://:hunter2hunter2@cache:6379'],
  ['8-char password', 'ftp://u:12345678@h'], ['json-quoted url', '"url":"postgres://u:longpassword1@h/db"'], ['after paren word', 'x=(postgres://u:longpassword1@h/db)'],
  ['after hyphen', '-postgres://fixture:FAKE_PASSWORD@localhost/db'], ['mid-line after space', 'conn postgres://fixture:FAKE_PASSWORD@localhost/db ok'],
];
const admit = [
  ['7-char password', 'ftp://u:1234567@h'], ['prefix inside word ghp', 'xghp_' + 'A'.repeat(25)], ['hyphen-prefixed ghp', 'task-ghp_' + 'A'.repeat(25)],
  ['underscore-prefixed AKIA', 'my_AKIA' + 'A'.repeat(16)], ['short ghp (19)', 'ghp_' + 'A'.repeat(19)], ['sk- key (documented unscanned)', 'sk-' + 'a'.repeat(40)],
  ['Bearer token (documented unscanned)', 'Authorization: Bearer abcdefghijklmnop1234567890'], ['password assignment (unscanned)', 'password = "hunter2hunter2"'],
  ['url ? email', 'http://localhost:3000?email=foo@bar.com'], ['url # frag', 'https://ex.com:8443#a@b.co'], ['json host:port + email', '{"a":"http://h:8080","o":"x@y.com"}'],
  ['csv host:port + email', 'url,http://host:8080,owner,bob@example.com'], ['md paren', '(see http://localhost:3000),foo@example.com'], ['pipe', 'http://h:8080|owner@example.com'],
  ['semicolon', 'http://h:8080;owner@example.com'], ['backslash', 'http://h:8080\\owner@example.com'], ['angle', '<http://h:8080>owner@example.com'], ['bracket', 'http://h:8080]owner@example.com'],
  ['no scheme user:pass@', 'user:longpassword1@host'], ['PRIVATE KEY w/o BEGIN dashes', 'BEGIN PRIVATE KEY'],
];
const out = [];
let bad = 0;
async function w(content) { return handlers.tool_call({ toolName: 'write', input: { path: `${wt}/m.md`, content } }, { cwd: wt }); }
for (const [name, item] of refuse) {
  const before = sentN(); const t = performance.now(); const r = await w(report + '\n' + item + '\n');
  const ok = r?.block === true && sentN() === before; if (!ok) bad++;
  out.push(`${ok ? 'PASS' : 'FAIL'} | refuse ${name} | blocked=${r?.block === true} extra_requests=${sentN() - before} ms=${Math.round(performance.now() - t)}`);
}
for (const [name, item] of admit) {
  const before = sentN(); const t = performance.now(); const r = await w(report + '\n' + item + '\n');
  const ok = r === undefined && sentN() - before === 16; if (!ok) bad++;
  out.push(`${ok ? 'PASS' : 'FAIL'} | admit ${name} | blocked=${r?.block === true} reqs=${sentN() - before} ms=${Math.round(performance.now() - t)}`);
}
// Credential-shaped value within the fully-covered (<=16 pieces) range is NOT locally refused; the model judges it (fake provider says benign)
{
  const before = sentN(); const r = await w('small file\nghp_' + 'A'.repeat(30) + '\n');
  const ok = r === undefined && sentN() - before === 1; if (!ok) bad++;
  out.push(`${ok ? 'PASS' : 'FAIL'} | in-budget write with token shape goes to model screening (not local scan) | reqs=${sentN() - before}`);
}
console.log(out.join('\n'));
fake.kill();
console.log(`MATRIX bad=${bad} total=${out.length}`);
process.exit(bad ? 1 : 0);
