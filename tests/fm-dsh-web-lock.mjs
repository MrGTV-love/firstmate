// Public lock-command regression using real process ancestry and disposable homes.
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, symlinkSync, existsSync} from 'node:fs';
import {spawnSync, spawn} from 'node:child_process';
import {join} from 'node:path';
const [root, temporary, recognition] = process.argv.slice(2);
if (!process.env.FM_NATIVE_LOCK_FIXTURE) {
  const fixture = mkdtempSync(join(temporary, 'web-lock-'));
  const code = join(fixture, 'code'), home = join(fixture, 'home');
  mkdirSync(join(code, 'bin'), {recursive: true});
  mkdirSync(join(home, 'state'), {recursive: true});
  for (const file of ['fm-lock.sh', 'fm-session-lock-lib.sh', 'fm-proc-info.py']) copyFileSync(join(root, 'bin', file), join(code, 'bin', file));
  copyFileSync(recognition, join(code, 'bin/fm-dsh-lib.sh'));
  writeFileSync(join(code, 'bin/fm-cursor-lib.sh'), 'fm_cursor_process_matches() { return 1; }\n');
  writeFileSync(join(code, 'bin/fm-wake-lib.sh'), 'fm_lock_try_acquire() { mkdir "$1"; }\nfm_lock_acquire_wait() { mkdir "$1"; }\nfm_lock_release() { rmdir "$1"; }\n');
  const entry = join(fixture, 'node_modules/@deepseek-ai/dsh/lib/bin.js');
  mkdirSync(join(entry, '..'), {recursive: true});
  writeFileSync(entry, `import(${JSON.stringify(import.meta.url)});\n`);
  symlinkSync('/bin/bash', join(code, 'pi'));
  symlinkSync('/bin/bash', join(code, 'claude'));
  const foreign = spawn(join(code, 'claude'), ['-c', 'read -r _'], {stdio: ['pipe', 'ignore', 'ignore']});
  try {
    const result = spawnSync(process.execPath, [entry, code, home, recognition], {env: {...process.env, FM_NATIVE_LOCK_FIXTURE: '1', FM_NATIVE_FOREIGN_PID: String(foreign.pid)}, encoding: 'utf8'});
    process.stdout.write(result.stdout);
    process.stderr.write(result.stderr);
    assert.equal(result.status, 0, 'native Web lock scenario must pass');
  } finally {
    foreign.kill('SIGTERM');
    foreign.stdin.end();
  }
} else {
  const home = temporary;
  const env = {...process.env, FM_HOME: home, FM_ROOT_OVERRIDE: home, FM_STATE_OVERRIDE: join(home, 'state'), FM_DSH_HARNESS: 'dsh', DSH_SHELL: '1', DSH_PROFILE: 'web', DSH_SESSION_ID: 'native-A'};
  for (const name of ['CLAUDE_PID', 'CLAUDE_CODE_SESSION_ID', 'CLAUDECODE', 'FM_TEST_HARNESS', 'FM_TEST_SEAM']) delete env[name];
  const lock = join(home, 'state/.lock'), sidecar = join(home, 'state/.lock-session');
  const commandEnv = extra => Object.fromEntries(Object.entries({...env, ...extra}).filter(([, value]) => value !== undefined));
  const acquire = extra => spawnSync('bash', [join(root, 'bin/fm-lock.sh')], {env: commandEnv(extra), encoding: 'utf8'});
  const release = extra => spawnSync('bash', [join(root, 'bin/fm-lock.sh'), 'release'], {env: commandEnv(extra), encoding: 'utf8'});
  const owned = extra => spawnSync('bash', ['-c', '. "$1/bin/fm-session-lock-lib.sh"; fm_session_lock_owned_by_self "$FM_HOME/state"', '_', root], {env: commandEnv(extra), encoding: 'utf8'});
  // Empty native state must not acquire a server-PID-only lease when native
  // identity is missing, malformed or unsupported by either real shell evidence.
  for (const [label, invalid] of [
    ['missing native SID', {DSH_SESSION_ID: undefined}],
    ['invalid native SID', {DSH_SESSION_ID: 'invalid/native/id'}],
    ['no native shell evidence', {DSH_SHELL: undefined, FM_DSH_HARNESS: undefined}],
  ]) {
    assert.notEqual(acquire(invalid).status, 0, label);
    assert.notEqual(owned(invalid).status, 0, label);
    const status = spawnSync('bash', [join(root, 'bin/fm-lock.sh'), 'status'], {env: commandEnv(invalid), encoding: 'utf8'});
    assert.equal(status.status, 0, `${label}: read-only status remains usable`);
    assert(!existsSync(lock) && !existsSync(sidecar), `${label}: authority files stay absent`);
  }
  console.log('ok - empty Web homes refuse missing/invalid SID or missing native shell evidence before authority publication; status remains usable');
  // Initial ownership is acquired through the canonical writer, never by writing a fake native receipt.
  let result = acquire();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(lock, 'utf8').trim(), String(process.pid));
  assert.equal(readFileSync(sidecar, 'utf8').trim(), 'dsh-web:native-A', 'canonical lock must bind native session, not only shared PID');
  const before = readFileSync(lock, 'utf8') + readFileSync(sidecar, 'utf8');
  assert.equal(owned().status, 0, 'correct bound native session owns its lock');
  for (const id of ['native-sibling', 'native-delegated-child']) {
    assert.notEqual(owned({DSH_SESSION_ID: id}).status, 0, 'different native identity must not own a shared PID');
    result = acquire({DSH_SESSION_ID: id});
    assert.notEqual(result.status, 0, 'shared-PID sibling must not re-key the canonical sidecar');
    assert.match(result.stderr, /another live firstmate session/);
    assert.notEqual(release({DSH_SESSION_ID: id}).status, 0, 'a sibling must not release the native owner');
    assert.equal(readFileSync(lock, 'utf8') + readFileSync(sidecar, 'utf8'), before);
  }
  for (const missing of [{DSH_SESSION_ID: ''}, {DSH_PROFILE: ''}]) {
    assert.notEqual(acquire(missing).status, 0, 'missing native metadata must not bypass a tagged shared-server lock');
    assert.equal(readFileSync(lock, 'utf8') + readFileSync(sidecar, 'utf8'), before);
  }
  result = spawnSync(join(root, 'pi'), ['-c', 'set -e; . "$1/bin/fm-session-lock-lib.sh"; [ "$(fm_harness_ancestry_pids)" = "$$" ]; if fm_session_lock_trusted_session_id; then exit 90; fi; set +e; bash "$1/bin/fm-lock.sh"; result=$?; :; exit "$result"', '_', root], {env, encoding: 'utf8'});
  assert.notEqual(result.status, 0, 'a closer Pi harness must not inherit a DSH native identity');
  assert.equal(readFileSync(lock, 'utf8') + readFileSync(sidecar, 'utf8'), before);
  result = acquire();
  assert.equal(result.status, 0, 'same native session reconfirms canonically');
  assert.equal(readFileSync(lock, 'utf8') + readFileSync(sidecar, 'utf8'), before);
  assert.equal(release().status, 0, 'the exact owner can release after true Agent termination');
  assert(!existsSync(lock) && !existsSync(sidecar), 'canonical release removes its verified pair');
  assert.equal(acquire({DSH_SESSION_ID: 'native-next-primary'}).status, 0, 'ordinary next ownership progresses after owned release');
  assert.equal(readFileSync(sidecar, 'utf8').trim(), 'dsh-web:native-next-primary');
  assert.notEqual(release().status, 0, 'a stale old-session release must not erase the next primary');
  assert.equal(release({DSH_SESSION_ID: 'native-next-primary'}).status, 0);
  // A restarted server leaves the same durable ID beside its dead old server pid.
  const dead = spawnSync('bash', ['-c', 'echo "$$"'], {encoding: 'utf8'}).stdout.trim();
  writeFileSync(lock, `${dead}\n`);
  writeFileSync(sidecar, 'dsh-web:native-A\n');
  assert.notEqual(owned().status, 0, 'the same ID on a dead old server is not current ownership');
  result = acquire();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(lock, 'utf8').trim(), String(process.pid), 'canonical acquire reclaims the dead old server pid');
  assert.equal(readFileSync(sidecar, 'utf8').trim(), 'dsh-web:native-A');
  assert.equal(owned().status, 0);
  // A real removal failure keeps the exact pair, so the same ID still owns it.
  // The stand-in rm fails like an immutable lock file: it keeps going past the
  // operand it cannot remove, then exits 1.
  const faulty = join(root, 'faulty-rm');
  mkdirSync(faulty);
  writeFileSync(join(faulty, 'rm'), '#!/usr/bin/env bash\nstatus=0\nfor target in "$@"; do\n  case "$target" in\n    -*) ;;\n    */state/.lock) echo "rm: $target: Operation not permitted" >&2; status=1 ;;\n    *) /bin/rm -f "$target" ;;\n  esac\ndone\nexit "$status"\n', {mode: 0o755});
  const paired = readFileSync(lock, 'utf8') + readFileSync(sidecar, 'utf8');
  result = release({PATH: `${faulty}:${process.env.PATH}`});
  assert.equal(result.status, 1, 'the failed removal must exit 1');
  assert.match(result.stderr, /Operation not permitted/);
  assert(existsSync(sidecar), 'a failed lock removal must not remove the sidecar');
  assert.equal(readFileSync(lock, 'utf8') + readFileSync(sidecar, 'utf8'), paired, 'a failed lock removal must keep the exact pair');
  assert.equal(owned().status, 0, 'the same ID still owns its pair after a failed removal');
  assert.equal(acquire().status, 0, 'the same ID reconfirms after a failed removal');
  assert.notEqual(acquire({DSH_SESSION_ID: 'native-sibling'}).status, 0, 'a different session stays refused after a failed removal');
  assert.equal(release().status, 0);
  // A live foreign Claude lock remains byte-identical; this stands for the real handoff prerequisite.
  writeFileSync(lock, process.env.FM_NATIVE_FOREIGN_PID + '\n');
  writeFileSync(sidecar, 'foreign-claude-session\n');
  result = acquire();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /another live firstmate session/);
  assert.equal(readFileSync(lock, 'utf8'), process.env.FM_NATIVE_FOREIGN_PID + '\n');
  assert.equal(readFileSync(sidecar, 'utf8'), 'foreign-claude-session\n');
  assert.notEqual(release().status, 0, 'native cleanup must not release a live foreign owner');
  assert.equal(readFileSync(lock, 'utf8'), process.env.FM_NATIVE_FOREIGN_PID + '\n');
  assert.equal(readFileSync(sidecar, 'utf8'), 'foreign-claude-session\n');
  console.log('ok - canonical native acquire/reconfirm/owned-release, next-primary progress, same-PID sibling/child refusal, stale-release refusal, dead old-server same-ID reclaim, failed removal keeps the pair and same-ID recovery, closer-harness rejection, foreign owner preserved');
}
