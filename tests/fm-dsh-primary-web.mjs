// Native-SDK scope regression, invoked by fm-dsh-primary.test.sh when an SDK is supplied.
import assert from 'node:assert/strict';
import {chmodSync, mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, unlinkSync, realpathSync, readdirSync, rmSync, symlinkSync} from 'node:fs';
import {execFileSync, spawn, spawnSync} from 'node:child_process';
import {join, resolve} from 'node:path';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
const [root, temporary, anchor] = process.argv.slice(2);
if (!process.env.FM_NATIVE_WEB_FIXTURE) {
  // Re-enter as the nearest modern DSH server argv, so the real ownership
  // commands resolve this fixture process as their shared native Web host.
  const server = mkdtempSync(join(temporary, 'native-web-server-'));
  const entry = join(server, 'node_modules/@deepseek-ai/dsh/lib/bin.js');
  mkdirSync(join(entry, '..'), {recursive: true});
  writeFileSync(entry, `import(${JSON.stringify(import.meta.url)});\n`);
  const env = {...process.env, FM_NATIVE_WEB_FIXTURE: '1'};
  for (const key of Object.keys(env)) {
    if (/^(CLAUDE|DSH_|FM_TEST_)/.test(key) || ['FM_DSH_HARNESS', 'PI_CODING_AGENT', 'GROK_AGENT', 'FM_PI_HARNESS',
      'FM_OMP_HARNESS', 'GEMINI_CLI', 'CURSOR_AGENT', 'CURSOR_INVOKED_AS'].includes(key)) delete env[key];
  }
  const result = spawnSync(process.execPath, [entry, root, temporary, anchor], {env, stdio: 'inherit'});
  assert.equal(result.status, 0, 'native Web SDK scenario must pass');
} else {
const sdk = createRequire(resolve(anchor));
const {Context} = await import(pathToFileURL(sdk.resolve('@deepseek-ai/cordis')));
const {createScope, scopeTarget} = await import(pathToFileURL(sdk.resolve('@deepseek-ai/dsh-scope')));
const bridge = await import(pathToFileURL(join(root, '.dsh/fm-primary.mjs')));
const delay = ms => new Promise(done => setTimeout(done, ms));
async function until(predicate, detail) {
  const deadline = Date.now() + 60000;
  while (!predicate()) {
    if (Date.now() > deadline) assert.fail(detail);
    await delay(25);
  }
}
const fixture = mkdtempSync(join(temporary, 'native-web-'));
const code = join(fixture, 'clean-code'), home = join(fixture, 'operational-home');
mkdirSync(join(code, 'bin'), {recursive: true});
// Real ownership, inspection and claim-lock code; only the arm, guard, startup
// and queue read below are recorders.
for (const entry of readdirSync(join(root, 'bin'))) symlinkSync(join(root, 'bin', entry), join(code, 'bin', entry));
const primaryHome = dir => {
  mkdirSync(join(dir, 'state'), {recursive: true});
  mkdirSync(join(dir, 'bin'), {recursive: true});
  execFileSync('git', ['init', '-q', dir]);
  writeFileSync(join(dir, 'AGENTS.md'), 'fixture\n');
  // An in-flight task is what makes the real inspection request supervision.
  writeFileSync(join(dir, 'state/demo.meta'), 'fixture\n');
};
primaryHome(home);
const records = join(home, 'state/commands');
const script = (file, body) => {
  rmSync(join(code, 'bin', file), {force: true});
  writeFileSync(join(code, 'bin', file), `#!/usr/bin/env bash\nset -eu\nprintf '%s|%s|%s|%s|%s\\n' ${JSON.stringify(file)} "$PWD" "$FM_HOME" "\${DSH_SESSION_ID-}" "\${FM_DSH_HARNESS-}" >> "$FM_HOME/state/commands"\n${body}\n`);
};
script('fm-turnend-guard.sh', 'exit 0');
// The gate only delays the canonical writer so the release barrier is observable.
script('fm-lock.sh', `printf '%s\\n' "\${1:-acquire}" >> "$FM_HOME/state/lock-calls"; while [ -f "$FM_HOME/state/release-gate" ]; do sleep 0.025; done; exec bash ${JSON.stringify(join(root, 'bin/fm-lock.sh'))} "$@"`);
script('fm-sessionstart-run.sh', 'echo FORBIDDEN-HOT-STARTUP; exit 99');
script('fm-wake-drain.sh', 'test "$1" = --queued; cat "$FM_HOME/state/queue"');
script('fm-watch-arm.sh', 'echo "watcher: started pid=fixture"; while [ ! -f "$FM_HOME/state/release" ]; do read -r -t 0.02 _ || :; done; echo "check: tagged-native-wake"');
writeFileSync(join(home, 'state/queue'), '7\t1\tcheck\tfixture\tnative-wake\n');
const lockFile = join(home, 'state/.lock'), sidecar = join(home, 'state/.lock-session');
const pair = () => existsSync(lockFile) || existsSync(sidecar)
  ? [existsSync(lockFile) ? readFileSync(lockFile, 'utf8') : '', existsSync(sidecar) ? readFileSync(sidecar, 'utf8') : ''] : undefined;
const lockCalls = () => existsSync(join(home, 'state/lock-calls')) ? readFileSync(join(home, 'state/lock-calls'), 'utf8').trim().split('\n') : [];
const arms = () => readFileSync(records, 'utf8').split('\n').filter(row => row.startsWith('fm-watch-arm.sh')).length;
const inspect = id => spawnSync('bash', [join(code, 'bin/fm-dsh-primary.sh'), 'inspect', home], {encoding: 'utf8',
  env: {...process.env, FM_HOME: home, FM_ROOT_OVERRIDE: home, FM_STATE_OVERRIDE: join(home, 'state'),
    FM_CONFIG_OVERRIDE: join(home, 'config'), FM_DSH_HARNESS: 'dsh', DSH_PROFILE: 'web', DSH_SESSION_ID: id}});
const ambient = {...process.env};
const app = new Context();
let host;
const live = new Map();
const owner = app.plugin({name: 'native-web-fixture', apply(ctx) {
  host = ctx;
  ctx.provide('agents', {get: id => live.get(id)});
  ctx.provide('profileContext', {name: 'web'});
}});
await owner.await();
function agent(id, header = {}) {
  const target = {id, session: {header: {cwd: home, ...header}}, sent: [], parked: [], followup(value) {this.sent.push(value);}, inject(value) {this.parked.push(value);}};
  target.scope = createScope(host, target);
  target.ctx = target.scope.ctx;
  live.set(id, target);
  return target;
}
const target = agent('session-explicit-primary');
const sibling = agent('session-sibling');
const child = agent('session-child', {origin: 'subagent', delegationDepth: 1});
const owned = [String(process.pid) + '\n', `dsh-web:${target.id}\n`];
let siblingEvents = 0;
const unrelated = sibling.ctx.plugin({name: 'original-contribution', apply(ctx) {ctx.on('agent/status', () => {siblingEvents++;});}});
await unrelated.await();
symlinkSync('/bin/bash', join(fixture, 'claude'));
const foreign = spawn(join(fixture, 'claude'), ['-c', 'read -r _'], {stdio: ['pipe', 'ignore', 'ignore']});
const foreignExit = new Promise(done => foreign.once('exit', done));
let mounted;
try {
  // Actual host identity, not a missing config field, decides whether legacy
  // process-owned behavior is admissible in this shared Web context.
  const implicit = host.plugin(bridge, {root: code, home});
  let refused = false;
  try { await implicit.await(); }
  catch (error) { refused = /requires a native sessionId/.test(String(error)); }
  try {
    await host.serial(scopeTarget(target, target), 'agent/created', {agent: target, source: 'startup'});
  } finally { await implicit.dispose(); }
  assert.deepEqual({refused,
    environmentUntouched: Object.keys({...ambient, ...process.env}).every(key => ambient[key] === process.env[key]),
    commands: existsSync(records) ? readFileSync(records, 'utf8').trim().split('\n').length : 0,
    ownership: pair(),
    legacySelected: existsSync(join(home, 'state/.dsh-primary-events.jsonl'))
      && readFileSync(join(home, 'state/.dsh-primary-events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse).some(row => row.event === 'startup')},
    {refused: true, environmentUntouched: true, commands: 0, ownership: undefined, legacySelected: false},
    'a Web root/home config without sessionId must refuse before environment mutation, ownership or legacy future-CWD selection');
  console.log('ok - actual SDK Web config without sessionId refuses before environment mutation or legacy subscription');
  assert.equal(inspect(target.id).status, 4, 'the real inspection refuses an unowned free home');
  mounted = host.plugin(bridge, {root: code, home, sessionId: target.id});
  await mounted.await();
  assert.equal(Object.keys({...ambient, ...process.env}).every(key => ambient[key] === process.env[key]), true, 'attaching a Web bridge must not poison process.env');
  assert.deepEqual(pair(), owned, 'attaching to a free home acquires the exact native pair through the canonical writer');
  assert.deepEqual(lockCalls(), ['acquire']);
  assert.equal(inspect(target.id).stdout.trim(), 'watch', 'the real inspection accepts the attached native owner');
  await until(() => existsSync(records) && arms() === 1, 'attach-existing must inspect ownership and arm without a fresh agent/created event');
  await host.serial(scopeTarget(target, target), 'agent/created', {agent: target, source: 'resume'});
  await host.serial(scopeTarget(sibling, sibling), 'agent/created', {agent: sibling, source: 'startup'});
  await host.serial(scopeTarget(child, child), 'agent/created', {agent: child, source: 'startup'});
  const duplicate = host.plugin(bridge, {root: code, home, sessionId: target.id});
  await assert.rejects(duplicate.await(), /home already has a native primary attachment/);
  await duplicate.dispose();
  writeFileSync(join(home, 'state/release'), '');
  await until(() => target.sent.length === 1, 'one fake FM completion must route one native followup');
  assert.equal(target.parked.length, 0, 'hot attach must not park a launch digest');
  assert.equal(sibling.sent.length + child.sent.length, 0, 'siblings and children must not receive the primary wake');
  const rows = readFileSync(records, 'utf8').trim().split('\n');
  assert(!rows.some(row => row.startsWith('fm-sessionstart-run.sh')), 'hot attach must never replay startup');
  assert.equal(arms(), 1, 'duplicate target creation must not duplicate arms');
  assert(rows.every(row => row.endsWith(`|${home}|${target.id}|dsh`)), 'every recorder must receive target-specific home/session/harness');
  assert(rows.every(row => realpathSync(row.split('|')[1]) === realpathSync(home)), 'commands run in operational home, not clean code root');
  await mounted.dispose();
  assert.deepEqual(pair(), owned, 'contribution/HMR disposal must never release a still-live primary');
  const stoppedCount = rows.length;
  host.emit(scopeTarget(target, target), 'session/event', target.session, {type: 'turn/end', seq: 1});
  await delay(40);
  assert.equal(readFileSync(records, 'utf8').trim().split('\n').length, stoppedCount, 'retired callbacks must not spawn commands');
  host.emit(scopeTarget(sibling, sibling), 'agent/status', {agent: sibling, status: 'idle'});
  assert.equal(siblingEvents, 1, 'bridge disposal must preserve original unrelated contribution');

  // Even an explicitly configured ID cannot turn a delegated Agent into a primary.
  for (const header of [{origin: 'subagent'}, {delegationDepth: 1}]) {
    Object.assign(target.session.header, header);
    const delegated = host.plugin(bridge, {root: code, home, sessionId: target.id});
    await delegated.await();
    assert.equal(readFileSync(records, 'utf8').trim().split('\n').length, stoppedCount);
    await delegated.dispose();
    delete target.session.header.origin;
    delete target.session.header.delegationDepth;
  }
  // A live foreign owner stays byte-identical and read-only, even for the exact target.
  writeFileSync(lockFile, `${foreign.pid}\n`);
  writeFileSync(sidecar, 'foreign-claude-session\n');
  const foreignPair = pair();
  const denied = host.plugin(bridge, {root: code, home, sessionId: target.id});
  await denied.await();
  await delay(40);
  assert.deepEqual(pair(), foreignPair, 'canonical acquire must refuse a live foreign owner');
  assert.deepEqual(lockCalls(), ['acquire', 'acquire']);
  assert.equal(arms(), 1);
  assert.equal(target.sent.length, 1, 'ownership refusal must not send a forced continuation');
  await denied.dispose();
  assert.equal(Object.keys({...ambient, ...process.env}).every(key => ambient[key] === process.env[key]), true);
  // A restarted server leaves the same durable ID beside its dead old pid.
  foreign.stdin.end();
  await foreignExit;
  writeFileSync(lockFile, `${foreign.pid}\n`);
  writeFileSync(sidecar, `dsh-web:${target.id}\n`);
  assert.equal(inspect(target.id).status, 4, 'the same ID on a dead old server is not current ownership');
  assert(home.startsWith(fixture + '/'));
  unlinkSync(join(home, 'state/release'));
  const resumedMount = host.plugin(bridge, {root: code, home, sessionId: target.id});
  await resumedMount.await();
  assert.deepEqual(pair(), owned, 'a restarted server reclaims the dead same-ID lock canonically');
  await until(() => arms() === 2, 'the reclaimed attachment must arm again');
  // Retire an old live identity while its own release is pending, then resume
  // the same durable ID with a new Agent object. Old work must not wake either.
  const gate = join(home, 'state/release-gate');
  writeFileSync(gate, 'held');
  await target.scope.dispose();
  live.delete(target.id);
  // Match native teardown: scope first, exact registry detach, then its single paired emit.
  host.emit(scopeTarget(target, target), 'agent/disposed', {agent: target});
  await until(() => lockCalls().length === 4, 'true root termination must invoke the canonical release owner');
  assert.equal(lockCalls()[3], 'release');
  const replacement = agent(target.id);
  writeFileSync(join(home, 'state/release'), '');
  const resumed = host.serial(scopeTarget(replacement, replacement), 'agent/created', {agent: replacement, source: 'resume'});
  await delay(40);
  assert.equal(arms(), 2, 'same-ID resume must wait for the old canonical release');
  assert.deepEqual(pair(), owned, 'the gated release has not run yet');
  assert.equal(replacement.sent.length, 0);
  unlinkSync(gate);
  await resumed;
  assert.deepEqual(lockCalls(), ['acquire', 'acquire', 'acquire', 'release', 'acquire'], 'the successor finds the released home unowned and acquires it');
  assert.deepEqual(pair(), owned);
  await host.serial(scopeTarget(replacement, replacement), 'agent/created', {agent: replacement, source: 'resume'});
  await until(() => replacement.sent.length === 1, 'new same-ID Agent must receive its own single followup');
  assert.equal(target.sent.length, 1, 'retired Agent must not receive late completion');
  assert.equal(arms(), 3);
  host.emit(scopeTarget(target, target), 'agent/disposed', {agent: target});
  await resumedMount.dispose();
  await delay(40);
  assert.equal(lockCalls().filter(call => call === 'release').length, 1, 'stale termination and HMR disposal must not release resumed ownership');
  assert.deepEqual(pair(), owned);
  const events = () => readFileSync(join(home, 'state/.dsh-primary-events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  const releaseErrors = () => events().filter(row => row.event === 'release-error');
  assert.equal(releaseErrors().length, 0, 'a successful owned release is not an error');
  // A real canonical release fault (exit 1 from the unwritable state directory)
  // stays visible and leaves ownership in place, without poisoning the next
  // legitimate same-ID attachment.
  unlinkSync(join(home, 'state/release'));
  const failing = host.plugin(bridge, {root: code, home, sessionId: target.id});
  await failing.await();
  await until(() => arms() === 4, 'the replacement re-attaches through its owned lock');
  chmodSync(join(home, 'state'), 0o555);
  try {
    assert.throws(() => writeFileSync(join(home, 'state/write-probe'), ''), {code: 'EACCES'}, 'the fault needs a really unwritable state directory');
    await replacement.scope.dispose();
    live.delete(replacement.id);
    host.emit(scopeTarget(replacement, replacement), 'agent/disposed', {agent: replacement});
    await until(() => releaseErrors().length === 1, 'a real exit-1 release fault must be recorded');
  } finally { chmodSync(join(home, 'state'), 0o755); }
  assert.match(releaseErrors()[0].detail, /cannot write session lock/);
  assert.deepEqual(pair(), owned, 'a failed release must fail closed without removing ownership');
  const successor = agent(target.id);
  writeFileSync(join(home, 'state/release'), '');
  await host.serial(scopeTarget(successor, successor), 'agent/created', {agent: successor, source: 'resume'});
  await until(() => successor.sent.length === 1, 'a later legitimate same-ID Agent must still attach and receive its followup');
  assert.deepEqual(lockCalls().slice(-1), ['release'], 'the owned successor needs no further lock call');
  await failing.dispose();
  await successor.scope.dispose();
  // A different live session stays refused after that failure. Its own
  // termination records the legitimate refusal and changes nothing.
  const different = agent('session-different');
  const refusedMount = host.plugin(bridge, {root: code, home, sessionId: different.id});
  await refusedMount.await();
  assert.deepEqual(pair(), owned, 'a different session must not acquire after a failed release');
  await different.scope.dispose();
  live.delete(different.id);
  host.emit(scopeTarget(different, different), 'agent/disposed', {agent: different});
  await until(() => releaseErrors().length === 2, 'a refused release must be recorded');
  assert.match(releaseErrors()[1].detail, /cannot release another or unverified/);
  assert.deepEqual(pair(), owned, 'a refused release must leave the exact owner in place');
  await refusedMount.dispose();

  // A genuine process-owned TUI profile still admits the legacy root/home
  // configuration and its future-created primary through the same native SDK.
  const tuiHome = join(fixture, 'owned-tui-home');
  primaryHome(tuiHome);
  writeFileSync(join(tuiHome, 'state/queue'), '8\t1\tcheck\tlegacy\twake\n');
  writeFileSync(join(tuiHome, 'state/release'), '');
  // The legacy session start owns acquisition for this profile through the canonical writer.
  script('fm-sessionstart-run.sh', 'bash "$(dirname "$0")/fm-lock.sh" >&2; echo "LEGACY SESSION START - fixture"');
  const tuiApp = new Context();
  let tuiHost;
  const tuiAgent = {id: 'legacy-TUI-fixture', session: {header: {cwd: tuiHome}}, sent: [],
    followup(value) {this.sent.push(value);}, inject() {}};
  const tuiOwner = tuiApp.plugin({name: 'owned-tui-fixture', apply(ctx) {
    tuiHost = ctx;
    ctx.provide('agents', {get: id => id === tuiAgent.id ? tuiAgent : undefined});
    ctx.provide('profileContext', {name: 'dsh-tui'});
  }});
  await tuiOwner.await();
  const tuiScope = createScope(tuiHost, tuiAgent);
  tuiAgent.ctx = tuiScope.ctx;
  let tui;
  try {
    // A TUI launched from a Web conversation's shell inherits that conversation's identity.
    Object.assign(process.env, {FM_DSH_HARNESS: 'dsh', DSH_PROFILE: 'web', DSH_SESSION_ID: 'session-parent-web', DSH_SHELL: '1'});
    tui = tuiHost.plugin(bridge, {root: code, home: tuiHome});
    await tui.await();
    await tuiHost.serial(scopeTarget(tuiAgent, tuiAgent), 'agent/created', {agent: tuiAgent, source: 'startup'});
    await until(() => tuiAgent.sent.length === 1, 'owned TUI profile must retain legacy startup and supervision');
    const commands = readFileSync(join(tuiHome, 'state/commands'), 'utf8').trim().split('\n');
    assert.equal(commands.filter(row => row.startsWith('fm-sessionstart-run.sh')).length, 1);
    assert.equal(commands.filter(row => row.startsWith('fm-watch-arm.sh')).length, 1);
    assert.deepEqual(readFileSync(join(tuiHome, 'state/lock-calls'), 'utf8').trim().split('\n'), ['acquire'], 'only legacy session start acquires; the TUI never runs the Web acquire');
    assert.equal(readFileSync(join(tuiHome, 'state/.lock'), 'utf8'), `${process.pid}\n`);
    assert.equal(existsSync(join(tuiHome, 'state/.lock-session')), false, 'an inherited Web identity must not tag the TUI lock');
    const shell = spawnSync('bash', [join(code, 'bin/fm-dsh-primary.sh'), 'inspect', tuiHome], {encoding: 'utf8',
      env: {...process.env, DSH_PROFILE: 'dsh-tui', DSH_SESSION_ID: tuiAgent.id, DSH_SHELL: '1'}});
    assert.equal(shell.status, 0, `the TUI model's own shell must own its primary lock: ${shell.stderr}`);
  } finally {
    await tui?.dispose();
    await tuiScope.dispose();
    await tuiOwner.dispose();
    for (const key of Object.keys({...ambient, ...process.env})) {
      if (ambient[key] === undefined) delete process.env[key];
      else process.env[key] = ambient[key];
    }
  }
  console.log('ok - actual SDK owned TUI profile preserves legacy root/home startup and one supervision followup, and ignores inherited Web identity');
  console.log('ok - native Web existing/resumed Agent through real inspect and canonical lock: free/dead acquire, live foreign refusal, explicit env, no startup, one followup, true-termination release barrier, visible fail-closed release failure with later recovery, no HMR/stale release and scoped cleanup');
} finally {
  const gate = join(home, 'state/release-gate');
  if (existsSync(gate)) { assert(home.startsWith(fixture + '/')); unlinkSync(gate); }
  foreign.kill('SIGTERM');
  foreign.stdin.end();
  await mounted?.dispose();
  await target.scope.dispose();
  await sibling.scope.dispose();
  await child.scope.dispose();
  await owner.dispose();
}
}
