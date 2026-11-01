import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
const [root, home, worktree, host, mode] = process.argv.slice(2);
const { installJevGuard } = await import(pathToFileURL(`${root}/bin/fm-jev-guard.ts`));
const { readGuardAudit } = await import(pathToFileURL(`${root}/bin/fm-jev-audit-read.mjs`));
const state = `${home}/state`;
let handler;
installJevGuard({ on: (_, fn) => { handler = fn; } }, { home, config: `${home}/config`, state, task: 'smoke', worktree,
  data: `${home}/data/smoke`, host, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' });
const ctx = { cwd: worktree };
const lastRow = () => JSON.parse(readGuardAudit(state).trim().split('\n').at(-1));
const call = async (toolName, path, content = 'fixture') => {
  if (host === 'omp') return handler({ toolName, input: { path, content, new_string: content } }, ctx);
  const payload = { hook_event_name: 'PreToolUse', cwd: worktree, tool_name: toolName === 'write' ? 'Write' : 'Edit', tool_input: { file_path: path, content, new_string: content } };
  const out = execFileSync('node', ['--experimental-strip-types', '--no-warnings', `${root}/bin/fm-jev-guard-claude.ts`, home, `${home}/config`, state, 'smoke', worktree, `${home}/data/smoke`, 'firstmate', 'FIRSTMATE_JEV_GUARD_V1'], { input: JSON.stringify(payload), encoding: 'utf8' });
  if (!out) return undefined;
  const h = JSON.parse(out).hookSpecificOutput; return { block: h.permissionDecision === 'deny', reason: h.permissionDecisionReason };
};
const proved = mode === 'confined';
// Sandbox without the launch marker: the profile denies the task audit file, so the guard
// fails closed with AuditUnavailableError on every call (same on the base guard).
const auditOutage = mode === 'confined-no-marker';
const rowOk = () => !auditOutage;
const lines = [];
const log = (s) => { lines.push(s); };
// 1. Filesystem targets that fail the lexical spelling gate but have no device effect.
for (const tool of ['write', 'edit']) {
  for (const path of ['notes:v2.md', '~/fixture', '/etc/firstmate-probe-never-written', '../outside-worktree.txt']) {
    const patch = await call(tool, path);
    assert.equal(patch?.block === true, !proved, `${host} ${mode} ${tool} ${path}`);
    if (host === 'omp' && auditOutage) assert.match(patch.reason, /AuditUnavailableError/);
    else if (host === 'omp') {
      const r = lastRow();
      if (proved) { assert.equal(r.branch, 'confinement'); assert.equal(r.confinement_owner, 'T5'); assert.equal(r.request_started, false); }
      else assert.equal(r.branch, 'deterministic');
    }
    log(`${tool} ${JSON.stringify(path)} -> ${patch?.block ? 'BLOCK' : 'allow'}${host === 'omp' ? (auditOutage ? ' (audit unavailable, fail closed)' : ' branch=' + lastRow().branch) : ''}`);
  }
  // A plain worktree file is allowed in every mode.
  const ord = await call(tool, 'ordinary.txt');
  assert.equal(ord?.block, auditOutage ? true : undefined, `${host} ${mode} ordinary`);
  log(`${tool} "ordinary.txt" -> ${ord?.block ? 'BLOCK' : 'allow'}`);
}
// 2. Outbound devices in every omp-routed spelling stay denied under ALL grants and never defer to T5.
const devices = [['xd://github', 'remote-storage'], ['[xd://github]', 'remote-storage'], ['[xd://github#ABCD]', 'remote-storage'], ['[xd://github#abcd]  ', 'remote-storage'],
  ['xd://github ', 'remote-storage'], ['XD://github', 'remote-storage'], ['Xd://GitHub', null], ['xd://github:raw', null], ['XD://report_issue:conflicts', null], ['xd://git\thub', 'remote-storage'],
  ['xd://report_issue', 'provider'], ['XD://report_issue', 'provider'], ['xd://report_issue\t', 'provider'], ['[xd://report_issue#0aF9]', 'provider']];
for (const [path, cls] of devices) {
  const patch = await call('write', path, '{"op":"pr_push"}');
  assert.equal(patch?.block, true, `${host} ${mode} device ${JSON.stringify(path)} must be denied`);
  if (host === 'omp' && auditOutage) log(`write ${JSON.stringify(path)} -> BLOCK (audit unavailable, fail closed)`);
  else if (host === 'omp') {
    const r = lastRow();
    assert.notEqual(r.branch, 'confinement', `device deferred to T5: ${JSON.stringify(path)}`);
    if (cls) { assert.equal(r.branch, 'egress', JSON.stringify(path)); assert.equal(r.destination_class, cls); }
    log(`write ${JSON.stringify(path)} -> BLOCK branch=${r.branch} class=${r.destination_class ?? '-'}`);
  } else log(`write ${JSON.stringify(path)} -> BLOCK`);
}
// 3. Device via edit is refused too.
assert.equal((await call('edit', 'xd://github'))?.block, true); log('edit "xd://github" -> BLOCK');
// 4. Unknown non-xd URIs are refused without a remote-read remedy; unknown xd devices keep the read-docs remedy.
if (host === 'omp') {
  for (const path of ['ssh://remote/file', 'HTTPS://example.invalid/a', 'file:///etc/passwd', '[ssh://remote/file#ABCD]']) {
    const p = await call('write', path);
    assert.equal(p?.block, true, path); if (!auditOutage) assert.doesNotMatch(p.reason, /Read the device documentation/, path);
    if (!auditOutage) assert.match(p.reason, /Report the intended target and effect to Firstmate/, path);
    log(`write ${JSON.stringify(path)} -> BLOCK${auditOutage ? ' (audit unavailable, fail closed)' : ' (no remote-read remedy)'}`);
  }
  const fut = await call('write', 'xd://future_device', '{}');
  assert.equal(fut?.block, true); if (!auditOutage) assert.match(fut.reason, /Read the device documentation with read xd:\/\/future_device/);
  log(`write "xd://future_device" -> BLOCK${auditOutage ? ' (audit unavailable, fail closed)' : ' (read-docs remedy)'}`);
  // XD://lsp must not be proven as the local lsp device under a non-canonical spelling.
  assert.equal((await call('write', 'XD://lsp', '{}'))?.block, true); log('write "XD://lsp" -> BLOCK');
  // Invalid content never defers.
  assert.equal((await call('write', 'ordinary.txt', null))?.block, true); log('write ordinary.txt content=null -> BLOCK');
  if (!auditOutage) {
  // Device event subjects are the canonical device, distinct from granted class subjects.
  const ev = process.env.FM_GUARD_EVENT_LOG;
  const subjects = existsSync(ev) ? [...new Set(readFileSync(ev, 'utf8').trim().split('\n').map(JSON.parse).filter(e => e.guard === 'jev-egress-grant').map(e => `${e.decision} ${e.session}`))] : [];
  log('jev-egress-grant events: ' + JSON.stringify(subjects));
  assert.ok(subjects.includes('deny smoke:xd://github') && subjects.includes('deny smoke:xd://report_issue'), 'canonical device subjects');
  assert.ok(!subjects.some(s => /smoke:(provider|remote-storage)$/.test(s)), 'device denies must not reuse class subjects');
  }
}
console.log(`== ${host} ${mode} (filesystem=${proved ? 'T5' : 'lexical'}) PASS`);
for (const l of lines) console.log('  ' + l);
