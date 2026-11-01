import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
const [root, guardDir, home, worktree, host, mode, baseline] = process.argv.slice(2);
const { installJevGuard } = await import(pathToFileURL(`${guardDir}/fm-jev-guard.ts`));
const { readGuardAudit } = await import(pathToFileURL(`${root}/bin/fm-jev-audit-read.mjs`));
let handler;
const state = `${home}/state`;
installJevGuard({ on: (_, fn) => { handler = fn; } }, { home, config: `${home}/config`, state, task: 'smoke', worktree,
  data: `${home}/data/smoke`, host, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' });
const ctx = { cwd: worktree };
const call = async (toolName, path, content = 'fixture') => {
  const input = { path, content, new_string: content };
  if (host === 'omp') return handler({ toolName, input }, ctx);
  const payload = { hook_event_name: 'PreToolUse', cwd: worktree, tool_name: toolName === 'write' ? 'Write' : 'Edit',
    tool_input: { file_path: path, content, new_string: content } };
  const output = execFileSync('node', ['--experimental-strip-types', '--no-warnings', `${guardDir}/fm-jev-guard-claude.ts`,
    home, `${home}/config`, state, 'smoke', worktree, `${home}/data/smoke`, 'firstmate', 'FIRSTMATE_JEV_GUARD_V1'],
    { input: JSON.stringify(payload), encoding: 'utf8' });
  return output ? { block: JSON.parse(output).hookSpecificOutput.permissionDecision === 'deny' } : undefined;
};
const delegated = mode === 'confined' && baseline !== 'before';
for (const tool of ['write', 'edit']) {
  for (const path of ['~/fixture', '/etc/firstmate-smoke-never-written']) {
    const patch = await call(tool, path);
    assert.equal(patch?.block === true, !delegated, `${host} ${mode}: filesystem ownership ${path}`);
  }
  assert.equal((await call(tool, 'ssh://remote/file'))?.block, true, 'URI must not become a confined filesystem write');
}
for (const path of ['xd://report_issue', 'xd://github']) {
  assert.equal((await call('write', path, '{}'))?.block, true, 'device stays refused even with all grants');
  if (host === 'omp' && baseline !== 'before') {
    const row = JSON.parse(readGuardAudit(state).trim().split('\n').at(-1));
    assert.equal(row.branch, 'egress');
    assert.equal(row.destination_class, path === 'xd://github' ? 'remote-storage' : 'provider');
  }
}
if (mode === 'confined') {
  const protectedPath = `${home}/config/protected`;
  // This fixture is under an allowed temp root even for the baseline lexical
  // gate. After the cutover its filesystem classification instead defers to T5.
  assert.equal(await call('write', protectedPath), undefined);
  assert.throws(() => writeFileSync(protectedPath, 'corrupted'), { code: 'EPERM' });
  assert.equal(readFileSync(protectedPath, 'utf8'), 'original');
}
console.log(`${baseline === 'before' ? 'BEFORE' : 'AFTER'} ${host} ${mode}: filesystem=${delegated ? 'T5' : 'lexical'} devices=denied${mode === 'confined' ? ' protected-write=EPERM unchanged' : ''}`);
