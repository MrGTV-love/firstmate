// One adversarial 1 MiB input per child process with a hard watchdog (sync regex cannot be interrupted in-process).
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
const [ROOT, LAB] = process.argv.slice(2);
const N = 1048576;
const cases = {
  hyphens: '-'.repeat(N), 'hyphen-words': 'ordinary-word-'.repeat(100000), 'scheme-chars': 'a+b.c-'.repeat(200000),
  'slashes-colon': 'a://'.repeat(260000), 'colon-run-after-scheme': 'a://' + 'b:'.repeat(520000), 'empty-user-long-pw-no-at': 'a://:' + 'x'.repeat(N),
  'many-colon-urls-no-at': 'http://h:' .repeat(110000), 'user-long-no-colon': 'a://' + 'u'.repeat(N), 'ghp-prefix-spam': 'ghp_'.repeat(260000),
  'xox-spam': 'xoxb-'.repeat(200000), 'begin-spam': '-----BEGIN '.repeat(90000), 'at-spam': 'a://u:12345678'.repeat(70000), 'pw-then-delims': ('x://u:' + 'p'.repeat(40) + ',').repeat(20000),
  'unicode-escapes': ('é"\\😀\n').repeat(100000),
};
const body = (name) => `
  import assert from 'node:assert/strict';
  import { readFileSync, mkdirSync } from 'node:fs';
  import { pathToFileURL } from 'node:url';
  const { context, content } = JSON.parse(readFileSync(0, 'utf8'));
  const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
  const handlers = {}; installJevGuard({ on(n, h) { handlers[n] = h; } }, context);
  const t = performance.now();
  const r = await handlers.tool_call({ toolName: 'write', input: { path: context.worktree + '/x.md', content } }, { cwd: context.worktree });
  console.log(JSON.stringify({ blocked: r?.block === true, ms: Math.round(performance.now() - t) }));
`;
let bad = 0;
for (const [name, content] of Object.entries(cases)) {
  const dir = `${LAB}/redos-${name}`; const home = `${dir}/home`, wt = `${dir}/wt`, data = `${home}/data/t1`;
  mkdirSync(`${home}/config`, { recursive: true }); mkdirSync(`${home}/state`, { recursive: true }); mkdirSync(data, { recursive: true }); mkdirSync(wt, { recursive: true });
  writeFileSync(`${home}/.env`, 'TYPESAFE_API_KEY=k\n'); execFileSync('git', ['init', '-q', wt]);
  const context = { home, config: `${home}/config`, state: `${home}/state`, task: 't1', worktree: wt, data, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' };
  const start = performance.now();
  try {
    // Provider unreachable on purpose: a scan stall would hit the watchdog; a local refusal returns before any request.
    const o = execFileSync(process.execPath, ['--experimental-strip-types', '--no-warnings', '--input-type=module', '-e', body(name)],
      { input: JSON.stringify({ context, content: content.slice(0, N) }), encoding: 'utf8', timeout: 25000, killSignal: 'SIGKILL', env: { ...process.env, GUARD: `${ROOT}/bin/fm-jev-guard.ts`, FM_TEST_SEAM: '1', FM_JEV_GUARD_BASE_URL: 'http://127.0.0.1:9/v1/systemone', FM_FRICTION_EXECUTION_KIND: 'test' } });
    console.log(`PASS | ${name} (${Math.min(N, content.length)} chars) | ${o.trim()} wall_ms=${Math.round(performance.now() - start)}`);
  } catch (e) { bad++; console.log(`FAIL | ${name} | ${e.code ?? e.message.slice(0, 100)} wall_ms=${Math.round(performance.now() - start)}`); }
}
console.log(`REDOS bad=${bad}`);
process.exit(bad ? 1 : 0);
