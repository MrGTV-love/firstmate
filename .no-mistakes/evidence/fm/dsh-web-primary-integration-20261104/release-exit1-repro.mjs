// Scratch reproduction: real bin/fm-lock.sh and real .dsh/fm-primary.mjs under a fixture server argv.
// Usage: node release-exit1-repro.mjs <root> <tmp> <sdk-anchor>
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, symlinkSync, chmodSync} from 'node:fs';
import {execFileSync, spawn, spawnSync} from 'node:child_process';
import {join, resolve} from 'node:path';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
const [root, temporary, anchor] = process.argv.slice(2);
if (!process.env.FM_REPRO_FIXTURE) {
  const server = mkdtempSync(join(temporary, 'server-'));
  const entry = join(server, 'node_modules/@deepseek-ai/dsh/lib/bin.js');
  mkdirSync(join(entry, '..'), {recursive: true});
  writeFileSync(entry, `import(${JSON.stringify(import.meta.url)});\n`);
  const env = {...process.env, FM_REPRO_FIXTURE: '1'};
  for (const key of Object.keys(env)) if (/^(CLAUDE|DSH_|FM_TEST_)/.test(key) || ['FM_DSH_HARNESS'].includes(key)) delete env[key];
  process.exit(spawnSync(process.execPath, [entry, root, temporary, anchor], {env, stdio: 'inherit'}).status ?? 99);
}
const sdk = createRequire(resolve(anchor));
const {Context} = await import(pathToFileURL(sdk.resolve('@deepseek-ai/cordis')));
const {createScope, scopeTarget} = await import(pathToFileURL(sdk.resolve('@deepseek-ai/dsh-scope')));
const bridge = await import(pathToFileURL(join(root, '.dsh/fm-primary.mjs')));
const delay = ms => new Promise(done => setTimeout(done, ms));
const fixture = mkdtempSync(join(temporary, 'cases-'));
const code = join(fixture, 'code');
mkdirSync(join(code, 'bin'), {recursive: true});
for (const e of readdirSync(join(root, 'bin'))) symlinkSync(join(root, 'bin', e), join(code, 'bin', e));
for (const [f, body] of [['fm-turnend-guard.sh', 'exit 0'], ['fm-wake-drain.sh', 'exit 0'], ['fm-sessionstart-run.sh', 'exit 99'],
  ['fm-watch-arm.sh', 'echo "watcher: started pid=fixture"; read -r -t 600 _ || :']]) {
  rmSync(join(code, 'bin', f)); writeFileSync(join(code, 'bin', f), `#!/usr/bin/env bash\n${body}\n`);
}
symlinkSync('/bin/bash', join(fixture, 'claude'));
const foreign = spawn(join(fixture, 'claude'), ['-c', 'read -r _'], {stdio: ['pipe', 'ignore', 'ignore']});
const ID = 'session-repro';
let n = 0;
const makeHome = (primary = true) => {
  const home = join(fixture, `home-${++n}`);
  mkdirSync(join(home, 'state'), {recursive: true});
  if (primary) { mkdirSync(join(home, 'bin')); execFileSync('git', ['init', '-q', home]); writeFileSync(join(home, 'AGENTS.md'), 'f\n'); writeFileSync(join(home, 'state/demo.meta'), 'f\n'); }
  return home;
};
const cmdEnv = (home, id = ID) => ({...process.env, FM_HOME: home, FM_ROOT_OVERRIDE: home, FM_STATE_OVERRIDE: join(home, 'state'), FM_DSH_HARNESS: 'dsh', DSH_PROFILE: 'web', DSH_SESSION_ID: id});
const lockCli = (home, args = [], id) => { const r = spawnSync('bash', [join(root, 'bin/fm-lock.sh'), ...args], {env: cmdEnv(home, id), encoding: 'utf8'}); return {status: r.status, stderr: r.stderr.trim(), stdout: r.stdout.trim()}; };
const pair = home => [join(home, 'state/.lock'), join(home, 'state/.lock-session')].map(p => existsSync(p) ? readFileSync(p, 'utf8').trim() : null);
const releaseErrors = home => { const f = join(home, 'state/.dsh-primary-events.jsonl'); return existsSync(f) ? readFileSync(f, 'utf8').trim().split('\n').map(JSON.parse).filter(r => r.event === 'release-error').map(r => r.detail) : []; };
const cases = {
  'success-owned': {setup: h => lockCli(h)},
  'refusal-live-foreign': {setup: h => { writeFileSync(join(h, 'state/.lock'), `${foreign.pid}\n`); writeFileSync(join(h, 'state/.lock-session'), 'foreign-claude-session\n'); }},
  'refusal-next-primary': {setup: h => lockCli(h, [], 'session-next')},
  'refusal-free-lock': {setup: () => {}, primary: false},
  'real-error-readonly-state': {setup: h => lockCli(h), fault: h => chmodSync(join(h, 'state'), 0o555), clear: h => chmodSync(join(h, 'state'), 0o755)},
  'real-error-immutable-lock': {setup: h => lockCli(h), fault: h => execFileSync('chflags', ['uchg', join(h, 'state/.lock')]), clear: h => execFileSync('chflags', ['nouchg', join(h, 'state/.lock')])},
};
for (const [name, c] of Object.entries(cases)) {
  // A: direct CLI, real exit status.
  const cliHome = makeHome(c.primary !== false);
  c.setup(cliHome); c.fault?.(cliHome);
  const cli = lockCli(cliHome, ['release']);
  const cliAfter = pair(cliHome);
  c.clear?.(cliHome);
  // B: real plugin, true termination.
  const home = makeHome(c.primary !== false);
  c.setup(home);
  const before = pair(home);
  const live = new Map();
  let host;
  const app = new Context();
  const owner = app.plugin({name: 'fixture', apply(ctx) { host = ctx; ctx.provide('agents', {get: id => live.get(id)}); ctx.provide('profileContext', {name: 'web'}); }});
  await owner.await();
  const agent = () => { const a = {id: ID, session: {header: {cwd: home}}, sent: [], followup(v) {this.sent.push(v);}, inject() {}}; a.scope = createScope(host, a); a.ctx = a.scope.ctx; live.set(ID, a); return a; };
  const a = agent();
  const mount = host.plugin(bridge, {root: code, home, sessionId: ID});
  await mount.await();
  await delay(300);
  const attached = pair(home);
  c.fault?.(home);
  await a.scope.dispose();
  live.delete(ID);
  host.emit(scopeTarget(a, a), 'agent/disposed', {agent: a});
  await mount.dispose();
  const after = pair(home);
  const errors = releaseErrors(home);
  c.clear?.(home);
  // C: after the fault clears, the different session and the same ID.
  const sameBefore = pair(home);
  const sameInspect = spawnSync('bash', [join(code, 'bin/fm-dsh-primary.sh'), 'inspect', home], {env: cmdEnv(home), encoding: 'utf8'});
  const same = lockCli(home);
  const sameAfter = pair(home);
  const other = lockCli(home, [], 'session-different');
  const afterOther = pair(home);
  console.log(JSON.stringify({case: name, cli: {...cli, after: cliAfter}, plugin: {before, attached, after, releaseErrors: errors}, sameIdAfter: {before: sameBefore, inspect: sameInspect.status, inspectOut: sameInspect.stdout.trim(), acquire: same.status, stderr: same.stderr, pair: sameAfter}, differentSessionAfter: {status: other.status, stderr: other.stderr, pair: afterOther}}, null, 1));
  await owner.dispose();
}
foreign.stdin.end(); foreign.kill('SIGTERM');
process.exit(0);
