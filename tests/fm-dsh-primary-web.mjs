// Native-SDK scope regression, invoked by fm-dsh-primary.test.sh when an SDK is supplied.
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, unlinkSync, realpathSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
const [root, temporary, anchor] = process.argv.slice(2);
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
mkdirSync(join(home, 'state'), {recursive: true});
const records = join(home, 'state/commands');
const script = (file, body) => writeFileSync(join(code, 'bin', file), `#!/usr/bin/env bash\nset -eu\nprintf '%s|%s|%s|%s|%s\\n' ${JSON.stringify(file)} "$PWD" "$FM_HOME" "\${DSH_SESSION_ID-}" "\${FM_DSH_HARNESS-}" >> "$FM_HOME/state/commands"\n${body}\n`);
script('fm-dsh-primary.sh', 'test ! -f "$FM_HOME/state/foreign" || exit 4; echo watch');
script('fm-turnend-guard.sh', 'exit 0');
script('fm-lock.sh', 'test "$1" = release; while [ -f "$FM_HOME/state/release-gate" ]; do sleep 0.025; done; echo released > "$FM_HOME/state/released"');
script('fm-sessionstart-run.sh', 'echo FORBIDDEN-HOT-STARTUP; exit 99');
script('fm-wake-drain.sh', 'test "$1" = --queued; cat "$FM_HOME/state/queue"');
// Only this recorder is launched; no production arm, host, startup or fleet code runs.
writeFileSync(join(code, 'bin/fm-timeout-lib.sh'), 'fm_exec_owned() { shift; "$@"; }\n');
script('fm-watch-arm.sh', 'echo "watcher: started pid=fixture"; while [ ! -f "$FM_HOME/state/release" ]; do read -r -t 0.02 _ || :; done; echo "check: tagged-native-wake"');
writeFileSync(join(home, 'state/queue'), '7\t1\tcheck\tfixture\tnative-wake\n');
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
let siblingEvents = 0;
const unrelated = sibling.ctx.plugin({name: 'original-contribution', apply(ctx) {ctx.on('agent/status', () => {siblingEvents++;});}});
await unrelated.await();
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
    legacySelected: existsSync(join(home, 'state/.dsh-primary-events.jsonl'))
      && readFileSync(join(home, 'state/.dsh-primary-events.jsonl'), 'utf8').trim().split('\n').map(JSON.parse).some(row => row.event === 'startup')},
    {refused: true, environmentUntouched: true, commands: 0, legacySelected: false},
    'a Web root/home config without sessionId must refuse before environment mutation or legacy future-CWD selection');
  console.log('ok - actual SDK Web config without sessionId refuses before environment mutation or legacy subscription');
  mounted = host.plugin(bridge, {root: code, home, sessionId: target.id});
  await mounted.await();
  assert.equal(Object.keys({...ambient, ...process.env}).every(key => ambient[key] === process.env[key]), true, 'attaching a Web bridge must not poison process.env');
  await until(() => existsSync(records), 'attach-existing must inspect ownership without a fresh agent/created event');
  await host.serial(scopeTarget(target, target), 'agent/created', {agent: target, source: 'resume'});
  await host.serial(scopeTarget(sibling, sibling), 'agent/created', {agent: sibling, source: 'startup'});
  await host.serial(scopeTarget(child, child), 'agent/created', {agent: child, source: 'startup'});
  await until(() => readFileSync(records, 'utf8').includes('fm-watch-arm.sh'), 'owned target must start only its fake command recorder');
  const duplicate = host.plugin(bridge, {root: code, home, sessionId: target.id});
  await assert.rejects(duplicate.await(), /home already has a native primary attachment/);
  await duplicate.dispose();
  writeFileSync(join(home, 'state/release'), '');
  await until(() => target.sent.length === 1, 'one fake FM completion must route one native followup');
  assert.equal(target.parked.length, 0, 'hot attach must not park a launch digest');
  assert.equal(sibling.sent.length + child.sent.length, 0, 'siblings and children must not receive the primary wake');
  const rows = readFileSync(records, 'utf8').trim().split('\n');
  assert(!rows.some(row => row.startsWith('fm-sessionstart-run.sh')), 'hot attach must never replay startup');
  assert.equal(rows.filter(row => row.startsWith('fm-watch-arm.sh')).length, 1, 'duplicate target creation must not duplicate arms');
  assert(rows.every(row => row.endsWith(`|${home}|${target.id}|dsh`)), 'every recorder must receive target-specific home/session/harness');
  assert(rows.every(row => realpathSync(row.split('|')[1]) === realpathSync(home)), 'commands run in operational home, not clean code root');
  await mounted.dispose();
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
  // A foreign canonical ownership verdict must remain read-only, even for the exact target.
  writeFileSync(join(home, 'state/foreign'), 'foreign-live-owner');
  const denied = host.plugin(bridge, {root: code, home, sessionId: target.id});
  await denied.await();
  await delay(40);
  assert.equal(readFileSync(records, 'utf8').split('\n').filter(row => row.startsWith('fm-watch-arm.sh')).length, 1);
  assert.equal(target.sent.length, 1, 'ownership refusal must not send a forced continuation');
  await denied.dispose();
  assert.equal(Object.keys({...ambient, ...process.env}).every(key => ambient[key] === process.env[key]), true);
  // Retire an old live identity while its own recorder is pending, then resume
  // the same durable ID with a new Agent object. Old work must not wake either.
  assert(home.startsWith(fixture + '/'));
  unlinkSync(join(home, 'state/foreign'));
  unlinkSync(join(home, 'state/release'));
  const resumedMount = host.plugin(bridge, {root: code, home, sessionId: target.id});
  await resumedMount.await();
  await until(() => readFileSync(records, 'utf8').split('\n').filter(row => row.startsWith('fm-watch-arm.sh')).length === 2, 'second isolated fake recorder must start');
  assert.equal(readFileSync(records, 'utf8').split('\n').filter(row => row.startsWith('fm-lock.sh')).length, 0, 'contribution/HMR disposal must never release a still-live primary');
  const gate = join(home, 'state/release-gate');
  writeFileSync(gate, 'held');
  await target.scope.dispose();
  live.delete(target.id);
  // Match native teardown: scope first, exact registry detach, then paired emit.
  host.emit(scopeTarget(target, target), 'agent/disposed', {agent: target});
  host.emit(scopeTarget(target, target), 'agent/disposed', {agent: target});
  await until(() => readFileSync(records, 'utf8').includes('fm-lock.sh'), 'true root termination must invoke the canonical release owner');
  const replacement = agent(target.id);
  writeFileSync(join(home, 'state/release'), '');
  const resumed = host.serial(scopeTarget(replacement, replacement), 'agent/created', {agent: replacement, source: 'resume'});
  await delay(40);
  assert.equal(readFileSync(records, 'utf8').split('\n').filter(row => row.startsWith('fm-watch-arm.sh')).length, 2, 'same-ID resume must wait for the old canonical release');
  assert.equal(replacement.sent.length, 0);
  unlinkSync(gate);
  await resumed;
  await host.serial(scopeTarget(replacement, replacement), 'agent/created', {agent: replacement, source: 'resume'});
  await until(() => replacement.sent.length === 1, 'new same-ID Agent must receive its own single followup');
  assert.equal(target.sent.length, 1, 'retired Agent must not receive late completion');
  assert.equal(readFileSync(records, 'utf8').split('\n').filter(row => row.startsWith('fm-watch-arm.sh')).length, 3);
  host.emit(scopeTarget(target, target), 'agent/disposed', {agent: target});
  await resumedMount.dispose();
  assert.equal(readFileSync(records, 'utf8').split('\n').filter(row => row.startsWith('fm-lock.sh')).length, 1, 'duplicate/stale termination and HMR disposal must not release resumed ownership');
  await replacement.scope.dispose();

  // A genuine process-owned TUI profile still admits the legacy root/home
  // configuration and its future-created primary through the same native SDK.
  const tuiHome = join(fixture, 'owned-tui-home');
  mkdirSync(join(tuiHome, 'state'), {recursive: true});
  writeFileSync(join(tuiHome, 'state/queue'), '8\t1\tcheck\tlegacy\twake\n');
  writeFileSync(join(tuiHome, 'state/release'), '');
  script('fm-sessionstart-run.sh', "echo 'LEGACY SESSION START - fixture'");
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
    Object.assign(process.env, {FM_DSH_HARNESS: 'dsh', DSH_PROFILE: 'dsh-tui', DSH_SESSION_ID: tuiAgent.id});
    tui = tuiHost.plugin(bridge, {root: code, home: tuiHome});
    await tui.await();
    await tuiHost.serial(scopeTarget(tuiAgent, tuiAgent), 'agent/created', {agent: tuiAgent, source: 'startup'});
    await until(() => tuiAgent.sent.length === 1, 'owned TUI profile must retain legacy startup and supervision');
    const commands = readFileSync(join(tuiHome, 'state/commands'), 'utf8').trim().split('\n');
    assert.equal(commands.filter(row => row.startsWith('fm-sessionstart-run.sh')).length, 1);
    assert.equal(commands.filter(row => row.startsWith('fm-watch-arm.sh')).length, 1);
  } finally {
    await tui?.dispose();
    await tuiScope.dispose();
    await tuiOwner.dispose();
    for (const key of Object.keys({...ambient, ...process.env})) {
      if (ambient[key] === undefined) delete process.env[key];
      else process.env[key] = ambient[key];
    }
  }
  console.log('ok - actual SDK owned TUI profile preserves legacy root/home startup and one supervision followup');
  console.log('ok - native Web existing/resumed Agent, explicit env, no startup, one followup, true-termination release barrier, no HMR/stale release, foreign refusal and scoped cleanup');
} finally {
  const gate = join(home, 'state/release-gate');
  if (existsSync(gate)) { assert(home.startsWith(fixture + '/')); unlinkSync(gate); }
  await mounted?.dispose();
  await target.scope.dispose();
  await sibling.scope.dispose();
  await child.scope.dispose();
  await owner.dispose();
}
