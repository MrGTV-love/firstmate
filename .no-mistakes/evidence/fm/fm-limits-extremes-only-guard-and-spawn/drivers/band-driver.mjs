import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { T, GUARD_ROOT, LABEL } = process.env;
const { installJevGuard } = await import(pathToFileURL(`${GUARD_ROOT}/bin/fm-jev-guard.ts`));
const home = `${T}/home-band-${LABEL}`, wt = `${home}/repo`;
rmSync(home, { recursive: true, force: true });
for (const d of ['config', 'state', 'data/scout1', 'repo']) mkdirSync(`${home}/${d}`, { recursive: true });
writeFileSync(`${home}/.env`, `TYPESAFE_API_KEY=${process.env.KEY}\n`);
const ctx = { cwd: wt };
const mk = (host) => { const h = {}; installJevGuard({ on: (n, f) => { h[n] = f; } }, { home, config: `${home}/config`, state: `${home}/state`, task: 'scout1', host, worktree: wt, data: `${home}/data/scout1`, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' }); return h; };
const omp = mk('omp');
const lines = [];
for (const p of ['0.15', '0.50', '0.79', '0.85']) {
  const r = await omp.tool_result({ toolName: 'bash', content: [{ type: 'text', text: `output probability=${p}` }] }, ctx);
  const o = r === undefined ? 'ALLOWED, no advisory' : r.isError ? 'WITHHELD' : `ALLOWED + ${r.content.length - 1} extra part: ${r.content.at(-1).text.slice(0, 100)}`;
  lines.push(`${LABEL} | omp untrusted bash result, judge score ${p} | ${o}`);
}
console.log(lines.join('\n')); process.exit(0);
